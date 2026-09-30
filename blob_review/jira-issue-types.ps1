<#
    blob-review - list the Jira issue types sentinelsvc may actually create.

    Trackspace answers a bad issue type with a 400 that names no field:

        {"errorMessages":["You are not allowed to create this isse type."],"errors":{}}

    That is a permission/create-screen answer, not a payload problem, so the
    only way to fix it without guessing is to ask Jira what it will accept.
    This prints the id and name of every issue type sentinelsvc can create in
    the project, and the id to put in JiraIssueTypeId.

      ./jira-issue-types.ps1
      ./jira-issue-types.ps1 -Project OPSLSY

    Needs the Azure CLI, an account that can read the sentinelsvc secret from
    the Key Vault, and network reach to Trackspace. The password is read into
    memory and used for one request - it is never printed or written to disk.
#>
[CmdletBinding()]
param(
    [string] $Project        = 'CLOPSSEC',
    [string] $JiraHost       = 'https://trackspace.lhsystems.com',
    [string] $JiraUser       = 'sentinelsvc',
    [string] $KeyVaultName   = 'LSY-WEUR-ITCS-PRD-KV-02',
    [string] $SecretName     = 'sentinelsvc',
    [string] $Subscription   = $(if ($env:SUBSCRIPTION) { $env:SUBSCRIPTION } else { 'f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29' })
)

$ErrorActionPreference = 'Stop'

# 'az' is an application, but PowerShell command lookup is case-insensitive and
# would happily bind a function of ours instead. Resolve the executable once.
$script:AzExe = (Get-Command az -CommandType Application -ErrorAction SilentlyContinue |
                 Select-Object -First 1).Source
if (-not $script:AzExe) {
    Write-Host 'Azure CLI not found on PATH.' -ForegroundColor Red
    exit 1
}
function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments = $true)] $Arguments)
    $out = & $script:AzExe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($out | Out-String) }
    return $out
}

Write-Host '==> Reading the Jira password from Key Vault' -ForegroundColor Cyan
$null = Invoke-Az account set --subscription $Subscription
try {
    $pw = Invoke-Az keyvault secret show --vault-name $KeyVaultName --name $SecretName `
                                         --query 'value' --output tsv
} catch {
    Write-Host "  Could not read $SecretName from $KeyVaultName." -ForegroundColor Red
    Write-Host '  Your own account needs "get" on secrets in that vault - the grant the'
    Write-Host '  Logic App has does not extend to you. Ask the vault owner, or run this'
    Write-Host '  from an account that already has it.'
    exit 1
}
$pw = ($pw | Out-String).Trim()
if (-not $pw) { Write-Host '  Secret is empty.' -ForegroundColor Red; exit 1 }

$auth = 'Basic ' + [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes("${JiraUser}:${pw}"))
$pw = $null
$headers = @{ Authorization = $auth; Accept = 'application/json' }

Write-Host "==> Asking Trackspace what $JiraUser may create in $Project" -ForegroundColor Cyan

# Jira Server/DC 8.x answers on the classic createmeta endpoint; 9.x and Cloud
# split the issue types onto their own path. Try both.
$types = $null
try {
    $r = Invoke-RestMethod -Method Get -Headers $headers `
            -Uri "$JiraHost/rest/api/2/issue/createmeta?projectKeys=$Project"
    $types = $r.projects | Where-Object { $_.key -eq $Project } |
             Select-Object -First 1 -ExpandProperty issuetypes -ErrorAction SilentlyContinue
} catch { }
if (-not $types) {
    try {
        $r = Invoke-RestMethod -Method Get -Headers $headers `
                -Uri "$JiraHost/rest/api/2/issue/createmeta/$Project/issuetypes?maxResults=100"
        $types = $r.values
    } catch {
        Write-Host "  Both createmeta endpoints failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
if (-not $types) {
    Write-Host "  $JiraUser cannot create anything in $Project - that is the real problem." -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host ('  {0,-8}  {1,-30}  {2}' -f 'id', 'name', 'subtask')
Write-Host ('  {0,-8}  {1,-30}  {2}' -f '--', '----', '-------')
foreach ($t in $types) {
    Write-Host ('  {0,-8}  {1,-30}  {2}' -f $t.id, $t.name, $(if ($t.subtask) { 'yes' } else { '' }))
}
Write-Host ''

$pick = $types | Where-Object { -not $_.subtask } | Select-Object -First 1
Write-Host 'Put one of the non-subtask ids above in JiraIssueTypeId:' -ForegroundColor Cyan
Write-Host "  ./deploy.ps1 -IssueTypeId $($pick.id)      # $($pick.name)"
Write-Host 'or edit playbook/azuredeploy.parameters.json and redeploy.'
