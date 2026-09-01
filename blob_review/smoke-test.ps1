<#
    blob-review - end-to-end smoke test.

    Checks everything the playbook needs, fires one review, follows it to a
    terminal state and reports what it produced.

      ./smoke-test.ps1              full test against the production blocklist
      ./smoke-test.ps1 -ChecksOnly  preflight only, fires nothing
      ./smoke-test.ps1 -BlobPath test/sample.txt   review a small test blob

    QUOTA: a full run costs one AbuseIPDB lookup per public single address on
    the blocklist - roughly 30,000. Point -BlobPath at a small seeded blob
    first if your AbuseIPDB plan cannot absorb that. The script asks before
    firing at the default blob unless -Force is given.

    Needs the Azure CLI and an account that can read the workflow, the AbuseIPDB
    API connection and the Key Vault's access policies.
#>
[CmdletBinding()]
param(
    [switch] $ChecksOnly,
    [switch] $Force,
    [string] $Container,
    [string] $BlobPath,
    [int]    $TimeoutMinutes = 45,
    [string] $PlaybookName        = 'blob-review',
    [string] $AbuseConnectionName = 'abuseipdbapi-1',
    [string] $KeyVaultName        = 'LSY-WEUR-ITCS-PRD-KV-02',
    [string] $BlobAccount         = 'lsyweuritcsprdmspalo001',
    [string] $ResourceGroup = $(if ($env:RG) { $env:RG } else { 'LSY_WEUR_ITCS_PRD_SEC_RG_002' }),
    [string] $Subscription  = $(if ($env:SUBSCRIPTION) { $env:SUBSCRIPTION } else { 'f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29' })
)

$ErrorActionPreference = 'Stop'
$mgmt = 'https://management.azure.com'
# The portal deep link takes the resource PATH, the management API the full URL.
$wfPath = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$PlaybookName"
$wfBase = "$mgmt$wfPath"

$script:Failures = 0
$script:Warnings = 0

function Write-Step { param([string] $m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Pass { param([string] $m) Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Warn { param([string] $m) $script:Warnings++; Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Fail { param([string] $m) $script:Failures++; Write-Host "  [FAIL] $m" -ForegroundColor Red }

# Resolved once, and deliberately NOT by name. PowerShell command lookup is
# case-insensitive, so a helper called `Az` would shadow the `az` CLI and call
# itself forever ("The script failed due to call depth overflow"). Binding the
# Application directly is what makes the helper safe whatever it is named.
$script:AzExe = (Get-Command az -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1).Source
if (-not $script:AzExe) {
    Write-Host 'ERROR: the Azure CLI (az) is not on PATH' -ForegroundColor Red
    exit 1
}

# az writes tsv as a string array and does not honour $ErrorActionPreference,
# so every call goes through here: flatten, trim, and report failure as $null.
function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
    $out = & $script:AzExe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $flat = (@($out) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($flat)) { return $null }
    return $flat
}

# --- 0. context --------------------------------------------------------------
Write-Step 'Subscription'
$null = Invoke-Az account set --subscription $Subscription
$acct = Invoke-Az account show --query 'name' --output tsv
if (-not $acct) { Write-Host 'ERROR: not signed in - run az login' -ForegroundColor Red; exit 1 }
Write-Host "  $acct  ($Subscription)"

# --- 1. the resources exist --------------------------------------------------
Write-Step 'Resources'

$logicPrincipal = Invoke-Az rest --method get --url "$wfBase`?api-version=2019-05-01" --query 'identity.principalId' --output tsv
if ($logicPrincipal) { Pass "Logic App $PlaybookName ($logicPrincipal)" }
else { Fail "Logic App $PlaybookName not found, or it has no managed identity" }

$abuseConn = Invoke-Az resource show --resource-group $ResourceGroup --name $AbuseConnectionName `
    --resource-type Microsoft.Web/connections --query 'id' --output tsv
if ($abuseConn) { Pass "AbuseIPDB API connection $AbuseConnectionName is present" }
else { Fail "AbuseIPDB API connection '$AbuseConnectionName' not found in $ResourceGroup. It is owned by OMS and holds the API key; this playbook does not create it." }

# --- 2. permissions ----------------------------------------------------------
# The two grants ./deploy.ps1 -Grant makes. Without them the run fails at
# Get_Jira_password or at Get_blocklist_blob.
Write-Step 'Permissions'

# Which authorisation model the vault uses decides which grant counts. Turning
# on Azure RBAC *invalidates every access policy* on the vault, so checking
# policies without checking the model reports a grant that does nothing:
# https://learn.microsoft.com/azure/key-vault/general/rbac-guide
$kvRbac    = Invoke-Az keyvault show --name $KeyVaultName --query 'properties.enableRbacAuthorization' --output tsv
$kvId      = Invoke-Az keyvault show --name $KeyVaultName --query 'id' --output tsv
$kvNetwork = Invoke-Az keyvault show --name $KeyVaultName `
    --query '[properties.publicNetworkAccess, properties.networkAcls.defaultAction]' --output tsv
$rbacMode  = ($kvRbac -eq 'true')
Write-Host "  $KeyVaultName authorisation model: $(if ($rbacMode) { 'Azure RBAC' } else { 'access policies (legacy)' })"

foreach ($p in @(@{ Name = 'Logic App'; Id = $logicPrincipal })) {
    if (-not $p.Id) { continue }

    if ($rbacMode) {
        # --include-inherited: the role may be assigned at subscription or
        # resource-group scope rather than on the vault itself.
        $r = Invoke-Az role assignment list --assignee $p.Id --scope $kvId --include-inherited `
            --role 'Key Vault Secrets User' --query '[].id' --output tsv
        if ($r) { Pass "$($p.Name) has Key Vault Secrets User on $KeyVaultName" }
        elseif ($null -eq $kvId) { Warn "Could not resolve $KeyVaultName to check role assignments" }
        else { Fail "$($p.Name) has NO Key Vault Secrets User on $KeyVaultName (vault is in RBAC mode). Run ./deploy.ps1 -Grant" }
    }
    else {
        $secrets = Invoke-Az keyvault show --name $KeyVaultName `
            --query "properties.accessPolicies[?objectId=='$($p.Id)'].permissions.secrets[]" --output tsv
        if ($secrets -and $secrets -match 'get|all') { Pass "$($p.Name) has Key Vault get on $KeyVaultName" }
        elseif ($null -eq $secrets) { Warn "Could not read $KeyVaultName access policies - you may lack permission to check" }
        else { Fail "$($p.Name) has NO Key Vault get on $KeyVaultName. Run ./deploy.ps1 -Grant" }
    }
}

if ($kvNetwork) {
    $net = @($kvNetwork -split "`n")
    if ($net -contains 'Disabled' -or $net -contains 'Deny') {
        $bypass = Invoke-Az keyvault show --name $KeyVaultName --query 'properties.networkAcls.bypass' --output tsv
        $nIps   = Invoke-Az keyvault show --name $KeyVaultName --query 'length(properties.networkAcls.ipRules)' --output tsv
        $nVnets = Invoke-Az keyvault show --name $KeyVaultName --query 'length(properties.networkAcls.virtualNetworkRules)' --output tsv
        Warn ("$KeyVaultName has a firewall (publicNetworkAccess/defaultAction: $($net -join ', '); " +
              "bypass: $bypass; $nIps IP rule(s), $nVnets VNet rule(s)). Permissions are not enough on their own: " +
              'the Logic App reaches this vault from West Europe Logic Apps outbound IPs, which the existing ' +
              'rules already cover; if Get_Jira_password starts failing, that is the first thing to check.')
    }
}

$blobScope = Invoke-Az storage account show --name $BlobAccount --query 'id' --output tsv
if ($blobScope -and $logicPrincipal) {
    $role = Invoke-Az role assignment list --assignee $logicPrincipal --scope $blobScope `
        --role 'Storage Blob Data Reader' --query '[].id' --output tsv
    if ($role) { Pass "Logic App has Storage Blob Data Reader on $BlobAccount" }
    else { Fail "Logic App has NO Storage Blob Data Reader on $BlobAccount. Run ./deploy.ps1 -Grant" }
}
else { Warn "Could not resolve $BlobAccount to check the blob role assignment" }

# --- 3. the schedule ---------------------------------------------------------
Write-Step 'Schedule'
$next = Invoke-Az rest --method get --url "$wfBase/triggers/Scheduled_review`?api-version=2016-06-01" `
    --query 'properties.nextExecutionTime' --output tsv
if ($next) { Pass "Scheduled_review is armed; next run $next (UTC)" }
else { Fail 'Scheduled_review reports no next run time - the playbook will only run when fired by hand' }

# --- verdict on the checks ---------------------------------------------------
Write-Step 'Preflight result'
Write-Host "  $script:Failures failure(s), $script:Warnings warning(s)"
if ($script:Failures -gt 0) {
    Write-Host "`nStopping: fix the failures above before firing a review." -ForegroundColor Red
    exit 1
}
if ($ChecksOnly) { Write-Host "`nChecks only - nothing fired." -ForegroundColor Cyan; exit 0 }

# --- 6. fire one review ------------------------------------------------------
$body = @{}
if ($Container) { $body.container = $Container }
if ($BlobPath)  { $body.blobPath  = $BlobPath }
$targeted = $body.Count -gt 0

if (-not $targeted -and -not $Force) {
    Write-Host "`nAbout to review the FULL production blocklist." -ForegroundColor Yellow
    Write-Host 'That costs one AbuseIPDB lookup per public single address on it (~30,000),' -ForegroundColor Yellow
    Write-Host 'and raises a real CLOPSSEC ticket. Use -BlobPath for a small test blob instead.' -ForegroundColor Yellow
    $answer = Read-Host 'Type YES to continue'
    if ($answer -cne 'YES') { Write-Host 'Aborted.'; exit 0 }
}

Write-Step 'Fetching the trigger URL'
$triggerUrl = Invoke-Az rest --method post --url "$wfBase/triggers/manual/listCallbackUrl`?api-version=2016-06-01" `
    --query 'value' --output tsv
if (-not $triggerUrl) { Write-Host 'ERROR: could not fetch the callback URL' -ForegroundColor Red; exit 1 }
Pass 'Got the callback URL (not printed - it carries a SAS signature)'

Write-Step 'Firing a review'
$firedAt = [DateTime]::UtcNow.AddSeconds(-30)
$json = if ($body.Count) { $body | ConvertTo-Json -Compress } else { '{}' }
Write-Host "  body: $json"
$resp = Invoke-WebRequest -Method Post -Uri $triggerUrl -ContentType 'application/json' -Body $json
Write-Host "  HTTP $($resp.StatusCode) $($resp.StatusDescription)"

$runId = $null
if ($resp.Headers['x-ms-workflow-run-id']) { $runId = @($resp.Headers['x-ms-workflow-run-id'])[0] }
if (-not $runId) {
    # Header naming varies by client; fall back to the newest run started since we fired.
    Start-Sleep -Seconds 5
    $runId = Invoke-Az rest --method get --url "$wfBase/runs`?api-version=2016-06-01&`$top=5" `
        --query "value[?properties.startTime>='$($firedAt.ToString('o'))'] | [0].name" --output tsv
}
if (-not $runId) { Write-Host 'ERROR: could not determine the run id' -ForegroundColor Red; exit 1 }
Pass "Run id $runId"

# --- 7. follow it to a terminal state ----------------------------------------
Write-Step "Waiting for the run (timeout ${TimeoutMinutes}m)"
$deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$status = 'Running'
while ([DateTime]::UtcNow -lt $deadline) {
    $status = Invoke-Az rest --method get --url "$wfBase/runs/$runId`?api-version=2016-06-01" `
        --query 'properties.status' --output tsv
    if (-not $status) { $status = 'Unknown' }
    if ($status -notin @('Running', 'Waiting', 'Unknown')) { break }
    Write-Host ("  {0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $status)
    Start-Sleep -Seconds 15
}

# --- 8. report ---------------------------------------------------------------
Write-Step "Run finished: $status"

$actions = Invoke-Az rest --method get --url "$wfBase/runs/$runId/actions`?api-version=2016-06-01" --output json
if ($actions) {
    $parsed = $actions | ConvertFrom-Json
    foreach ($a in $parsed.value) {
        $s = $a.properties.status
        $colour = switch ($s) { 'Succeeded' { 'Green' } 'Skipped' { 'DarkGray' } default { 'Red' } }
        Write-Host ("  {0,-28} {1}" -f $a.name, $s) -ForegroundColor $colour
        if ($s -eq 'Failed') {
            if ($a.properties.error) {
                Write-Host "      $($a.properties.error.code): $($a.properties.error.message)" -ForegroundColor Red
            }
            # An HTTP or connector action puts its failure in outputs, not in
            # properties.error, so "Failed" alone would say nothing useful.
            elseif ($a.properties.outputsLink.uri) {
                try {
                    $o = Invoke-RestMethod -Uri $a.properties.outputsLink.uri
                    $detail = if ($o.body) { ($o.body | ConvertTo-Json -Depth 4 -Compress) } else { '' }
                    Write-Host "      HTTP $($o.statusCode) $($detail.Substring(0, [Math]::Min(300, $detail.Length)))" -ForegroundColor Red
                } catch { }
            }
        }
    }

    # Compose_run_result carries the ticket URL and the scan counts. Outputs are
    # inline when small and behind a SAS link when large; handle both.
    $result = $parsed.value | Where-Object { $_.name -eq 'Compose_run_result' }
    if ($result) {
        Write-Step 'Run result'
        $outputs = $null
        if ($result.properties.outputs) { $outputs = $result.properties.outputs }
        elseif ($result.properties.outputsLink.uri) {
            try { $outputs = Invoke-RestMethod -Uri $result.properties.outputsLink.uri } catch { }
        }
        if ($outputs) { $outputs | ConvertTo-Json -Depth 8 }
        else { Write-Host '  Could not read the outputs; open the run in the portal.' }
    }
}

Write-Host ''
Write-Host "Run history: https://portal.azure.com/#@/resource$wfPath/runs" -ForegroundColor Cyan
if ($status -eq 'Succeeded') {
    Write-Host 'PASS - the review completed and raised its ticket.' -ForegroundColor Green
    exit 0
}
Write-Host "FAIL - run ended as '$status'. The failing action and its error are listed above." -ForegroundColor Red
exit 1
