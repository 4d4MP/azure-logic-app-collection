<#
    blob-review - deploy / redeploy from a checkout of this repository.
    Safe to re-run: the ARM deployment is incremental.

      ./deploy.ps1          deploy the playbook
      ./deploy.ps1 -Grant   also grant the two permissions the playbook needs
                            (Key Vault get for the Logic App, blob read for the
                            Logic App). Omit if access goes through a separate
                            change; the script prints
                            the exact commands either way.
      ./deploy.ps1 -IssueTypeId 10
                            override the Jira issue type id without editing the
                            parameters file. ./jira-issue-types.ps1 lists the
                            ids sentinelsvc may actually create in CLOPSSEC.

    One step, because there is no code to publish: the whole review runs in the
    Logic App and AbuseIPDB is reached through the existing abuseipdbapi-1 API
    connection, which already holds the key.

    Needs the Azure CLI.
#>
[CmdletBinding()]
param(
    [switch] $Grant,
    [string] $IssueTypeId,
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
    'playbook/azuredeploy.json', 'playbook/azuredeploy.parameters.json'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $here $f) -PathType Leaf)) {
        Stop-Deploy "$(Join-Path $here $f) is missing - incomplete checkout?"
    }
}

# Every check in validate.py exists because a real deployment was rejected by
# it. Azure reports one such error per attempt, so failing here saves a round
# trip each time.
$validator = Join-Path $here 'validate.py'
$python = (Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1).Source
if ($python -and (Test-Path -LiteralPath $validator)) {
    Write-Step 'Validating the playbook JSON'
    & $python $validator
    if ($LASTEXITCODE -ne 0) { Stop-Deploy 'validation failed - fix the problems above before deploying' }
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

# The AbuseIPDB connection is owned by OMS and is NOT created here. Without it
# the deployment succeeds and every enrichment call then fails at runtime, so
# check first rather than discover it in a run.
Write-Step 'Checking the AbuseIPDB API connection'
$abuseConnection = if ($env:ABUSE_CONNECTION) { $env:ABUSE_CONNECTION } else { 'abuseipdbapi-1' }
$null = & az resource show --resource-group $ResourceGroup --name $abuseConnection `
    --resource-type Microsoft.Web/connections --query id --output tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Stop-Deploy "API connection '$abuseConnection' not found in $ResourceGroup. It is owned by OMS and holds the AbuseIPDB key; this playbook does not create it."
}
Write-Host "  $abuseConnection is present in $ResourceGroup"

# --- 1. the playbook --------------------------------------------------------
# PlaybookName comes from the parameters file and must stay set, or a redeploy
# stands up a parallel Logic App with a fresh managed identity.
$deployment = "blob-review-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
Write-Step "Deploying ARM template as $deployment"
# The '@' on the parameters file must stay inside a quoted string: a bare @
# starts PowerShell's splatting operator and the file reference would never
# reach the CLI.
$deployArgs = @(
    '--parameters', "@$(Join-Path $here 'playbook/azuredeploy.parameters.json')"
)
# A later --parameters wins, so the override goes after the file.
if ($IssueTypeId) { $deployArgs += @('--parameters', "JiraIssueTypeId=$IssueTypeId") }
& az deployment group create `
    --name $deployment `
    --resource-group $ResourceGroup `
    --template-file (Join-Path $here 'playbook/azuredeploy.json') `
    @deployArgs `
    --output none
Assert-Az 'az deployment group create'

$json = & az deployment group show `
    --name $deployment --resource-group $ResourceGroup `
    --query 'properties.outputs' --output json
Assert-Az 'az deployment group show'
$outputs = ($json -join "`n") | ConvertFrom-Json

$logicApp       = $outputs.logicAppName.value
$logicPrincipal = $outputs.logicAppPrincipalId.value
$keyVault       = $outputs.keyVaultName.value
$blobAccount    = $outputs.blocklistStorageAccountName.value

$resolved = [ordered]@{
    logicAppName                = $logicApp
    logicAppPrincipalId         = $logicPrincipal
    keyVaultName                = $keyVault
    blocklistStorageAccountName = $blobAccount
}
foreach ($entry in $resolved.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($entry.Value)) {
        Stop-Deploy "deployment output $($entry.Key) came back empty"
    }
}

# --- 2. access --------------------------------------------------------------
if ($Grant) {
    # Which grant works depends on the vault's authorisation model, and getting
    # it wrong is silent: enabling Azure RBAC invalidates every access policy,
    # so set-policy still succeeds while granting nothing. Ask the vault.
    $kvRbac = & az keyvault show --name $keyVault --query 'properties.enableRbacAuthorization' --output tsv
    Assert-Az 'az keyvault show'
    $kvRbac = (@($kvRbac) -join '').Trim()

    if ($kvRbac -eq 'true') {
        Write-Step "Granting Key Vault Secrets User to $logicApp (vault is in RBAC mode)"
        $kvId = & az keyvault show --name $keyVault --query 'id' --output tsv
        Assert-Az 'az keyvault show (id)'
        $kvId = (@($kvId) -join '').Trim()
        & az role assignment create --assignee-object-id $logicPrincipal --assignee-principal-type ServicePrincipal `
            --role 'Key Vault Secrets User' --scope $kvId --output none
        if ($LASTEXITCODE -ne 0) { Write-Host '  (role assignment already present, or insufficient rights)' }
    }
    else {
        Write-Step "Granting Key Vault get to $logicApp (vault uses access policies)"
        & az keyvault set-policy --name $keyVault --object-id $logicPrincipal --secret-permissions get --output none
        Assert-Az 'az keyvault set-policy (Logic App)'
    }

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
    Write-Host "  az role assignment create --assignee-object-id $logicPrincipal --assignee-principal-type ServicePrincipal --role 'Storage Blob Data Reader' --scope $blobScope"
}

# --- 3. confirm the schedule actually took ----------------------------------
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

# --- 4. confirm the deployed definition is the one in this checkout ---------
# A redeploy from a stale checkout succeeds and changes nothing, so a fixed bug
# comes back looking identical. Read one field that only the current definition
# has back off the live workflow rather than trusting the deployment reported
# success.
Write-Step 'Confirming the deployed definition'
$deployedIssueType = & az rest --method get --output tsv `
    --query 'properties.definition.parameters.JiraIssueTypeId.defaultValue' `
    --url "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$logicApp`?api-version=2019-05-01" 2>&1
$deployedIssueType = (@($deployedIssueType) -join '').Trim()
if ([string]::IsNullOrWhiteSpace($deployedIssueType)) {
    $deployedIssueType = 'MISSING'
    Write-Host '  WARNING: the live workflow has no JiraIssueTypeId parameter.' -ForegroundColor Yellow
    Write-Host '  It is still on the old definition that sends the issue type by name,' -ForegroundColor Yellow
    Write-Host '  which Trackspace rejects with "You are not allowed to create this isse' -ForegroundColor Yellow
    Write-Host '  type." Your checkout is behind - git pull, then run this again.' -ForegroundColor Yellow
}
else {
    Write-Host "  Jira issue type id $deployedIssueType is live"
}

# --- done -------------------------------------------------------------------
Write-Step 'Deployed'
@"
  Logic App        $logicApp   ($logicPrincipal)
  AbuseIPDB        via the $abuseConnection API connection
  Schedule         Mondays 07:00 CET  (next: $nextRun)
  Jira issue type  id $deployedIssueType  (./jira-issue-types.ps1 lists the valid ids)

It now runs itself. This redeploy does not fire an off-schedule review: the
Recurrence trigger carries a startTime and an explicit weekday/hour schedule,
which is what stops a deploy kicking off a full AbuseIPDB scan.

To prove the deployment now rather than waiting for Monday, run ./smoke-test.ps1,
or fire one by hand.
The trigger URL carries its own SAS signature - treat it as a credential, so it
is deliberately not printed here. Fetch it with:

  az rest --method post --query value -o tsv --url "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$logicApp/triggers/manual/listCallbackUrl?api-version=2016-06-01"

Then fire a review:

  Invoke-RestMethod -Method Post -Uri "<trigger-url>" -ContentType 'application/json' -Body '{}'

Logic App runs are immutable: cancel anything left in flight from before this
redeploy before firing a fresh run.
"@ | Write-Host
