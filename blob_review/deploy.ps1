<#
    blob-review - deploy / redeploy. Safe to re-run; the ARM deployment is
    incremental and the function publish overwrites in place.

    Run it straight from a clone - it resolves every artifact relative to its
    own location, so there is nothing to copy and nothing to go stale:

      ./deploy.ps1          deploy infrastructure, then publish the function code
      ./deploy.ps1 -Grant   also grant the three permissions the playbook needs
                            (Key Vault get for the Logic App, Key Vault get for the
                            function identity, blob read for the Logic App). Omit if
                            access goes through a separate change; the script prints
                            the exact commands either way.

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

# Invoke-WebRequest hands Content back as a byte array whenever the response has
# no usable content type - which is exactly what a bare 401 or 403 from the
# Functions host looks like. Interpolating one of those yields a string of
# decimal byte values, and calling a string method on it throws.
function Get-BodyText {
    param($Content)
    if ($null -eq $Content) { return '' }
    if ($Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($Content) }
    return [string] $Content
}

# --- paths ------------------------------------------------------------------
# Everything is resolved from the script's own directory. Copying artifacts into
# a working directory is what let a stale azuredeploy.json get deployed twice.
$root        = $PSScriptRoot
$templateDir = Join-Path $root 'playbook'
$functionDir = Join-Path $root 'function'
$template    = Join-Path $templateDir 'azuredeploy.json'
$parameters  = Join-Path $templateDir 'azuredeploy.parameters.json'

foreach ($path in @($template, $parameters, (Join-Path $functionDir 'package.json'), (Join-Path $functionDir 'host.json'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-Deploy "not found: $path" }
}
if (-not (Test-Path -LiteralPath (Join-Path $functionDir 'src') -PathType Container)) {
    Stop-Deploy "not found: $(Join-Path $functionDir 'src')"
}

# --- preflight --------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-Deploy 'the Azure CLI (az) is not on PATH'
}
$null = & az account show --output none 2>&1
if ($LASTEXITCODE -ne 0) { Stop-Deploy "not signed in - run 'az login' first" }

# ARM rejects runtime functions in parameters/variables, and the failure only
# surfaces after a round-trip to Azure. Catch it here instead.
$templateJson = [IO.File]::ReadAllText($template) | ConvertFrom-Json
foreach ($section in @('parameters', 'variables')) {
    $blob = $templateJson.$section | ConvertTo-Json -Depth 40 -Compress
    if ($blob -and $blob -match 'listKeys\(|reference\(') {
        Stop-Deploy "$template has a runtime function in '$section'; ARM resolves that section before deployment and will reject the template"
    }
}

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
# The '@' prefix must stay quoted: bare @ starts PowerShell's splatting operator
# and the file reference would never reach the CLI.
& az deployment group create `
    --name $deployment `
    --resource-group $ResourceGroup `
    --template-file $template `
    --parameters "@$parameters" `
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
# ARM cannot carry a JavaScript payload, so the code is a separate step. Both
# tools publish the current directory, hence the Push-Location.
Write-Step "Publishing function code to $funcApp"
Push-Location $functionDir
try {
    # Dependencies must be installed BEFORE the publish. Core Tools does not run
    # npm install for you here and does not trigger a remote build on this path -
    # it zips what it finds. Publishing without node_modules uploads source only,
    # the v4 entry point then throws "Cannot find module '@azure/functions'" at
    # startup, and the host registers zero functions while the publish reports
    # success.
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Stop-Deploy 'npm is required to install dependencies'
    }
    & npm install --omit=dev --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { Stop-Deploy "npm install failed with exit code $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath 'node_modules' -PathType Container)) {
        Stop-Deploy 'npm install left no node_modules; the publish would ship source with no dependencies'
    }

    if (Get-Command func -ErrorAction SilentlyContinue) {
        # --javascript is required: local.settings.json is not in the repository,
        # so Core Tools has nothing to infer the language from and refuses to publish.
        & func azure functionapp publish $funcApp --javascript
        if ($LASTEXITCODE -ne 0) { Stop-Deploy "func azure functionapp publish failed with exit code $LASTEXITCODE" }
    }
    else {
        Write-Host 'Azure Functions Core Tools not found; falling back to az zip deploy.'
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
finally {
    Pop-Location
}

# --- 4. verify the code actually landed -------------------------------------
# The ARM step replaces the app settings collection wholesale, which wipes the
# WEBSITE_RUN_FROM_PACKAGE pointer that the publish sets. The publish above puts
# it back - but if it had failed, the app would be left with no code at all and
# nothing so far would have said so.
Write-Step "Verifying functions registered on $funcApp"
$expected = @('enrichBatch', 'reviewOrchestrator', 'startReview')
$found = @()
foreach ($attempt in 1..5) {
    $names = & az functionapp function list --name $funcApp --resource-group $ResourceGroup --query '[].name' --output tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and $names) {
        $found = @($names | ForEach-Object { ($_ -split '/')[-1] })
    }
    $missing = @($expected | Where-Object { $found -notcontains $_ })
    if ($missing.Count -eq 0) { break }
    if ($attempt -lt 5) {
        Write-Host "  not registered yet ($attempt/5), waiting for trigger sync..."
        Start-Sleep -Seconds 10
    }
}
if ($missing.Count -gt 0) {
    Stop-Deploy ("function(s) missing after publish: $($missing -join ', ') (found: $(if ($found) { $found -join ', ' } else { 'none' })). " +
                 "The app has no usable code. The usual cause is a deployment package with no node_modules, which makes the v4 entry point throw at startup. " +
                 "Check entry-point errors in Application Insights for cloud_RoleName '$funcApp' where message has 'entry point'.")
}
Write-Host "  registered: $($found -join ', ')"

# --- 5. smoke-test the endpoint the Logic App will call ---------------------
# Registering every function is not the same as being callable. A rejected key
# or an unresolved Key Vault reference surfaces only at run time, as a bare
# 401/403/500 on Run_review with the inputs hidden by secureData - which tells
# you almost nothing. Posting an empty object exercises the whole path (key
# auth, host start, the ABUSEIPDB_API_KEY app setting) and then stops at the
# body check, so it starts no orchestration and spends no AbuseIPDB quota.
Write-Step 'Smoke-testing the enrichment endpoint'
$funcHost = & az functionapp show --name $funcApp --resource-group $ResourceGroup --query defaultHostName --output tsv
Assert-Az 'az functionapp show (defaultHostName)'
# The same key ARM hands the Logic App as EnrichmentFunctionKey.
$funcKey = & az functionapp keys list --name $funcApp --resource-group $ResourceGroup --query 'functionKeys.default' --output tsv
Assert-Az 'az functionapp keys list'
if ([string]::IsNullOrWhiteSpace($funcHost)) { Stop-Deploy 'could not resolve the function app host name' }
if ([string]::IsNullOrWhiteSpace($funcKey)) {
    Stop-Deploy @"
the app has no default host key, so the Logic App's EnrichmentFunctionKey
  resolves to an empty string and every call is rejected. Host keys live in the
  app's own storage account; check AzureWebJobsStorage.
"@
}

$smokeUri = "https://$funcHost/api/start-review"
$smokeCode = 0
$smokeText = ''
try {
    # -SkipHttpErrorCheck needs PowerShell 7; the catch covers 5.1.
    $resp = Invoke-WebRequest -SkipHttpErrorCheck -Method Post -Uri $smokeUri `
        -Headers @{ 'x-functions-key' = $funcKey } `
        -ContentType 'application/json' -Body '{}' -TimeoutSec 90
    $smokeCode = [int] $resp.StatusCode
    $smokeText = Get-BodyText $resp.Content
}
catch {
    if ($_.Exception.Response) {
        $smokeCode = [int] $_.Exception.Response.StatusCode
        try { $smokeText = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
    }
    else { Stop-Deploy "no response from $smokeUri - $($_.Exception.Message)" }
}
if ($smokeText.Length -gt 300) { $smokeText = $smokeText.Substring(0, 300) }
$smokeText = ($smokeText -replace '\s+', ' ').Trim()

switch ($smokeCode) {
    400 {
        # Expected: the handler got past the key check and the ABUSEIPDB_API_KEY
        # check, and rejected the empty body on its own terms.
        Write-Host "  ok - 400 $smokeText"
    }
    401 {
        Stop-Deploy @"
401 from the endpoint using the app's own default host key.
  The host is refusing a key it issued itself, so key validation - not the key -
  is broken. Host keys are read from the azure-webjobs-secrets container in the
  app's storage account; a wrong or rotated AzureWebJobsStorage connection
  string makes every call 401, master key included. Check with:
    az functionapp keys list -g $ResourceGroup -n $funcApp -o json
    az functionapp config appsettings list -g $ResourceGroup -n $funcApp --query "[?name=='AzureWebJobsStorage']"
"@
    }
    403 {
        Stop-Deploy @"
403 from the endpoint. A 403 does not come from the key check - that answers
  401 - so something in front of the host refused the request. Check:
    az functionapp config access-restriction show -g $ResourceGroup -n $funcApp
    az webapp auth show -g $ResourceGroup -n $funcApp --query '{enabled:enabled,action:unauthenticatedClientAction}'
    az functionapp show -g $ResourceGroup -n $funcApp --query '{state:state,enabled:enabled,publicNetworkAccess:publicNetworkAccess}'
"@
    }
    404 {
        Stop-Deploy @"
404 - the route /api/start-review does not exist even though the function list
  reported startReview. Check host.json's routePrefix is 'api'.
"@
    }
    500 {
        Stop-Deploy @"
500 - the function started and failed: $smokeText
  If that names ABUSEIPDB_API_KEY, the Key Vault reference did not resolve.
  Confirm the secret exists and the function identity ($funcPrincipal) has get:
    az keyvault secret show --vault-name $keyVault --name abuseipdb-api-key --query id
    az functionapp config appsettings list -g $ResourceGroup -n $funcApp --query "[?name=='ABUSEIPDB_API_KEY']"
"@
    }
    default { Stop-Deploy "unexpected $smokeCode from $smokeUri - $smokeText" }
}

# --- done -------------------------------------------------------------------
Write-Step 'Deployed'
@"
  Logic App        $logicApp   ($logicPrincipal)
  Function App     $funcApp    ($funcPrincipal)
  Functions        $($found -join ', ')

The trigger URL carries its own SAS signature - treat it as a credential, so it
is deliberately not printed here. Fetch it with:

  az rest --method post --query value -o tsv --url "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$logicApp/triggers/manual/listCallbackUrl?api-version=2016-06-01"

Then fire a review:

  Invoke-RestMethod -Method Post -Uri "<trigger-url>" -ContentType 'application/json' -Body '{}'

Logic App runs are immutable: cancel anything left in flight from before this
redeploy before firing a fresh run.
"@ | Write-Host
