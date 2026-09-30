#!/usr/bin/env bash
#
# blob-review — list the Jira issue types sentinelsvc may actually create.
#
# Trackspace answers a bad issue type with a 400 that names no field:
#
#   {"errorMessages":["You are not allowed to create this isse type."],"errors":{}}
#
# That is a permission/create-screen answer, not a payload problem, so the only
# way to fix it without guessing is to ask Jira what it will accept. This prints
# the id and name of every issue type sentinelsvc can create in the project, and
# the id to put in JiraIssueTypeId.
#
#   ./jira-issue-types.sh
#   PROJECT=OPSLSY ./jira-issue-types.sh
#
# Needs the Azure CLI, jq, an account that can read the sentinelsvc secret from
# the Key Vault, and network reach to Trackspace. The password is held in a
# variable for one request — it is never printed or written to disk.
#
set -euo pipefail

PROJECT="${PROJECT:-CLOPSSEC}"
JIRA_HOST="${JIRA_HOST:-https://trackspace.lhsystems.com}"
JIRA_USER="${JIRA_USER:-sentinelsvc}"
KEYVAULT="${KEYVAULT:-LSY-WEUR-ITCS-PRD-KV-02}"
SECRET="${SECRET:-sentinelsvc}"
SUBSCRIPTION="${SUBSCRIPTION:-f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29}"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null || fail "the Azure CLI (az) is not on PATH"
command -v jq >/dev/null || fail "jq is not on PATH"

step "Reading the Jira password from Key Vault"
az account set --subscription "$SUBSCRIPTION"
if ! PW="$(az keyvault secret show --vault-name "$KEYVAULT" --name "$SECRET" \
             --query value -o tsv 2>/dev/null)"; then
  echo "  Could not read $SECRET from $KEYVAULT." >&2
  echo '  Your own account needs "get" on secrets in that vault — the grant the' >&2
  echo '  Logic App has does not extend to you. Ask the vault owner, or run this' >&2
  echo '  from an account that already has it.' >&2
  exit 1
fi
[[ -n "$PW" ]] || fail "secret is empty"

step "Asking Trackspace what $JIRA_USER may create in $PROJECT"
# Jira Server/DC 8.x answers on the classic createmeta endpoint; 9.x and Cloud
# split the issue types onto their own path. Try both.
TYPES="$(curl -sS -u "$JIRA_USER:$PW" -H 'Accept: application/json' \
           "$JIRA_HOST/rest/api/2/issue/createmeta?projectKeys=$PROJECT" \
         | jq -c --arg p "$PROJECT" \
             '[.projects[]? | select(.key == $p) | .issuetypes[]?]' 2>/dev/null || echo '[]')"
if [[ "$(jq 'length' <<<"$TYPES")" == "0" ]]; then
  TYPES="$(curl -sS -u "$JIRA_USER:$PW" -H 'Accept: application/json' \
             "$JIRA_HOST/rest/api/2/issue/createmeta/$PROJECT/issuetypes?maxResults=100" \
           | jq -c '[.values[]?]' 2>/dev/null || echo '[]')"
fi
PW=""
if [[ "$(jq 'length' <<<"$TYPES")" == "0" ]]; then
  fail "$JIRA_USER cannot create anything in $PROJECT — that is the real problem."
fi

printf '\n  %-8s  %-30s  %s\n' id name subtask
printf '  %-8s  %-30s  %s\n' -- ---- -------
jq -r '.[] | "  \(.id)\t\(.name)\t\(if .subtask then "yes" else "" end)"' <<<"$TYPES" |
  while IFS=$'\t' read -r id name sub; do
    printf '  %-8s  %-30s  %s\n' "$id" "$name" "$sub"
  done

PICK="$(jq -r 'map(select(.subtask | not)) | .[0] | "\(.id)\t\(.name)"' <<<"$TYPES")"
PICK_ID="${PICK%%$'\t'*}"
PICK_NAME="${PICK#*$'\t'}"
printf '\nPut one of the non-subtask ids above in JiraIssueTypeId:\n'
printf '  ./deploy.sh --issue-type-id %s      # %s\n' "$PICK_ID" "$PICK_NAME"
printf 'or edit playbook/azuredeploy.parameters.json and redeploy.\n'
