<#
    blob-review - deploy / redeploy from a checkout of this repository.
    Safe to re-run: the ARM deployment is incremental and the function publish
    overwrites in place.

      ./deploy.ps1          deploy the infrastructure, then publish the function code
      ./deploy.ps1 -Grant   also grant the three permissions the playbook needs
                            (Key Vault get for the Logic App, Key Vault get for the
                            function identity, blob read for the Logic App). Omit if
                            access goes through a separate change; the script prints
                            the exact commands either way.

    Everything it deploys sits beside it - playbook/ and function/ - so it can be
    run from any working directory and needs no arguments and no file shuffling.

    Needs the Azure CLI. Azure Functions Core Tools (func) is used when it is on
    PATH, otherwise the script falls back to npm + Compress-Archive + az zip deploy.
#>
[CmdletBinding()]
param(
    [switch] $Grant,
    [string] $ResourceGroup = $(if ($env:RG) { $env:RG } else { 'LSY_WEUR_ITCS_PRD_SEC_RG_002' }),
    [string] $Subscription  = $(if ($env:SUBSCRIPTION) { $env:SUBSCRIPTION } else { 'f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29' })
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath

function Write-Step {
    param([string] $Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Stop-Deploy {
    param([string] $Message)
    Write-Host "`nERROR: $Message" -ForegroundColor Red
    exit 1
}

# $ErrorActionPreference does not apply to native executables, so every az call
# is followed by this check. Without it the script sails straight past a failed
# deployment and reports success.
function Assert-Az {
    param([string] $What)
    if ($LASTEXITCODE -ne 0) { Stop-Deploy "$What failed with exit code $LASTEXITCODE" }
}

# --- preflight --------------------------------------------------------------
foreach ($f in @(
    'playbook/azuredeploy.json', 'playbook/azuredeploy.parameters.json',
    'function/package.json', 'function/host.json'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $here $f) -PathType Leaf)) {
        Stop-Deploy "$(Join-Path $here $f) is missing - incomplete checkout?"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $here 'function/src') -PathType Container)) {
    Stop-Deploy "$(Join-Path $here 'function/src') is missing - incomplete checkout?"
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-Deploy 'the Azure CLI (az) is not on PATH'
}
$null = & az account show --output none 2>&1
if ($LASTEXITCODE -ne 0) { Stop-Deploy "not signed in - run 'az login' first" }

Write-Step 'Subscription'
& az account set --subscription $Subscription
Assert-Az 'az account set'
& az account show --query '{subscription:name, id:id}' --output tsv
Assert-Az 'az account show'

# --- 1. infrastructure ------------------------------------------------------
# PlaybookName comes from the parameters file and must stay set, or a redeploy
# stands up a parallel Logic App with a fresh managed identity.
$deployment = "blob-review-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
Write-Step "Deploying ARM template as $deployment"
# The '@' on the parameters file must stay inside a quoted string: a bare @
# starts PowerShell's splatting operator and the file reference would never
# reach the CLI.
& az deployment group create `
    --name $deployment `
    --resource-group $ResourceGroup `
    --template-file (Join-Path $here 'playbook/azuredeploy.json') `
    --parameters "@$(Join-Path $here 'playbook/azuredeploy.parameters.json')" `
    --output none
Assert-Az 'az deployment group create'

$json = & az deployment group show `
    --name $deployment --resource-group $ResourceGroup `
    --query 'properties.outputs' --output json
Assert-Az 'az deployment group show'
$outputs = ($json -join "`n") | ConvertFrom-Json

$logicApp       = $outputs.logicAppName.value
$logicPrincipal = $outputs.logicAppPrincipalId.value
$funcApp        = $outputs.functionAppName.value
$funcPrincipal  = $outputs.functionAppPrincipalId.value
$keyVault       = $outputs.keyVaultName.value
$blobAccount    = $outputs.blocklistStorageAccountName.value

$resolved = [ordered]@{
    logicAppName                = $logicApp
    logicAppPrincipalId         = $logicPrincipal
    functionAppName             = $funcApp
    functionAppPrincipalId      = $funcPrincipal
    keyVaultName                = $keyVault
    blocklistStorageAccountName = $blobAccount
}
foreach ($entry in $resolved.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($entry.Value)) {
        Stop-Deploy "deployment output $($entry.Key) came back empty"
    }
}

# --- 2. access, before the code ---------------------------------------------
# The function resolves ABUSEIPDB_API_KEY from Key Vault at startup, so the
# access policy has to exist before the app starts, or every invocation 500s.
if ($Grant) {
    Write-Step "Granting Key Vault get to $logicApp and $funcApp"
    # Access-policy vault: the Key Vault Secrets User RBAC role would be inert.
    & az keyvault set-policy --name $keyVault --object-id $logicPrincipal --secret-permissions get --output none
    Assert-Az 'az keyvault set-policy (Logic App)'
    & az keyvault set-policy --name $keyVault --object-id $funcPrincipal --secret-permissions get --output none
    Assert-Az 'az keyvault set-policy (Function App)'

    Write-Step "Granting Storage Blob Data Reader on $blobAccount to $logicApp"
    $blobScope = & az storage account show --name $blobAccount --query id --output tsv
    Assert-Az 'az storage account show'
    & az role assignment create `
        --assignee-object-id $logicPrincipal --assignee-principal-type ServicePrincipal `
        --role 'Storage Blob Data Reader' --scope $blobScope --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  (role assignment already present, or insufficient rights)'
    }
}
else {
    $blobScope = & az storage account show --name $blobAccount --query id --output tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $blobScope) { $blobScope = "<resource id of $blobAccount>" }
    Write-Step 'Access NOT granted - run with -Grant, or pass these on'
    Write-Host "  az keyvault set-policy --name $keyVault --object-id $logicPrincipal --secret-permissions get"
    Write-Host "  az keyvault set-policy --name $keyVault --object-id $funcPrincipal --secret-permissions get"
    Write-Host "  az role assignment create --assignee-object-id $logicPrincipal --assignee-principal-type ServicePrincipal --role 'Storage Blob Data Reader' --scope $blobScope"
}

# --- 3. function code -------------------------------------------------------
# ARM cannot carry a JavaScript payload, so the code is a separate step.
# Published from function/, which is a normal Functions project root: both
# paths below package their current directory, and function/.funcignore is what
# keeps tests/, *.md and the ARM templates out of the package.
Write-Step "Publishing function code to $funcApp"
Push-Location (Join-Path $here 'function')
try {
    if (Get-Command func -ErrorAction SilentlyContinue) {
        # --javascript is required, not cosmetic. func infers the project language
        # from local.settings.json, which is gitignored because it holds local
        # secrets - so it never exists in a fresh clone, and without the flag func
        # fails with "Can't determine project language from files" and "Worker
        # runtime cannot be 'None'".
        & func azure functionapp publish $funcApp --javascript
        if ($LASTEXITCODE -ne 0) { Stop-Deploy "func azure functionapp publish failed with exit code $LASTEXITCODE" }
    }
    else {
        Write-Host 'Azure Functions Core Tools not found; falling back to az zip deploy.'
        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            Stop-Deploy "neither 'func' nor 'npm' is available"
        }
        & npm install --omit=dev --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { Stop-Deploy "npm install failed with exit code $LASTEXITCODE" }

        # The zip is built outside the checkout so it cannot package itself, and
        # the contents are listed explicitly rather than relying on .funcignore.
        $zip = Join-Path ([System.IO.Path]::GetTempPath()) "blob-review-$([Guid]::NewGuid().ToString('N')).zip"
        try {
            # Windows PowerShell 5.1 can trip over node_modules paths beyond 260
            # characters here; PowerShell 7, or installing 'func', avoids it.
            Compress-Archive -Path package.json, host.json, src, node_modules -DestinationPath $zip -Force
            & az functionapp deployment source config-zip `
                --resource-group $ResourceGroup --name $funcApp --src $zip --output none
            Assert-Az 'az functionapp deployment source config-zip'
        }
        finally {
            if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        }
    }
}
finally { Pop-Location }

# --- 4. confirm the schedule actually took ----------------------------------
# A deployed workflow is not the same as a scheduled one, and this playbook's
# whole failure mode is running only when somebody remembers to fire it. Read
# the Recurrence trigger back rather than assuming the deployment armed it.
Write-Step 'Confirming the weekly schedule is registered'
$nextRun = & az rest --method get --query 'properties.nextExecutionTime' --output tsv `
    --url "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$logicApp/triggers/Scheduled_review?api-version=2016-06-01" 2>&1
# az emits tsv as a string array; flatten before testing so a single blank line
# does not read as a populated value.
$nextRun = (@($nextRun) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($nextRun)) {
    $nextRun = 'UNKNOWN - see warning above'
    Write-Host '  WARNING: Scheduled_review reported no next run time.' -ForegroundColor Yellow
    Write-Host '  The playbook will only run when somebody fires it by hand - which is' -ForegroundColor Yellow
    Write-Host '  exactly the state the schedule exists to fix. Check Logic app ->' -ForegroundColor Yellow
    Write-Host '  Overview -> Trigger history before relying on it.' -ForegroundColor Yellow
}
else {
    Write-Host "  Scheduled_review is armed; next run $nextRun (UTC)"
}

# --- done -------------------------------------------------------------------
Write-Step 'Deployed'
@"
  Logic App        $logicApp   ($logicPrincipal)
  Function App     $funcApp    ($funcPrincipal)
  Schedule         Mondays 07:00 CET  (next: $nextRun)

It now runs itself. This redeploy does not fire an off-schedule review: the
Recurrence trigger carries a startTime and an explicit weekday/hour schedule,
which is what stops a deploy kicking off a full AbuseIPDB scan.

To prove the deployment now rather than waiting for Monday, fire one by hand.
The trigger URL carries its own SAS signature - treat it as a credential, so it
is deliberately not printed here. Fetch it with:

  az rest --method post --query value -o tsv --url "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$logicApp/triggers/manual/listCallbackUrl?api-version=2016-06-01"

Then fire a review:

  Invoke-RestMethod -Method Post -Uri "<trigger-url>" -ContentType 'application/json' -Body '{}'

Logic App runs are immutable: cancel anything left in flight from before this
redeploy before firing a fresh run.
"@ | Write-Host
