#!/usr/bin/env bash
#
# blob-review — end-to-end smoke test.
#
# Checks everything the playbook needs, fires one review, follows it to a
# terminal state and reports what it produced.
#
#   ./smoke-test.sh                     full test against the production blocklist
#   ./smoke-test.sh --checks-only       preflight only, fires nothing
#   ./smoke-test.sh --blob-path test/sample.txt   review a small test blob
#   ./smoke-test.sh --force             skip the quota confirmation
#
# QUOTA: a full run costs one AbuseIPDB lookup per public single address on the
# blocklist — roughly 30,000. Point --blob-path at a small seeded blob first if
# your AbuseIPDB plan cannot absorb that. The script asks before firing at the
# default blob unless --force is given.
#
# Overrides: RG, SUBSCRIPTION.
#
set -uo pipefail

PLAYBOOK="${PLAYBOOK:-blob-review}"
FUNC_APP="${FUNC_APP:-lsy-weur-itcs-prd-blobreview-func}"
KEYVAULT="${KEYVAULT:-LSY-WEUR-ITCS-PRD-KV-02}"
ABUSE_SECRET="${ABUSE_SECRET:-abuseipdb-api-key}"
BLOB_ACCOUNT="${BLOB_ACCOUNT:-lsyweuritcsprdmspalo001}"
RG="${RG:-LSY_WEUR_ITCS_PRD_SEC_RG_002}"
SUBSCRIPTION="${SUBSCRIPTION:-f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-45}"

CHECKS_ONLY=0; FORCE=0; CONTAINER=""; BLOB_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --checks-only) CHECKS_ONLY=1; shift ;;
    --force)       FORCE=1; shift ;;
    --container)   CONTAINER="$2"; shift 2 ;;
    --blob-path)   BLOB_PATH="$2"; shift 2 ;;
    --timeout)     TIMEOUT_MINUTES="$2"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

MGMT="https://management.azure.com"
# The portal deep link takes the resource PATH, the management API the full URL.
WF_PATH="/subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.Logic/workflows/$PLAYBOOK"
WF="$MGMT$WF_PATH"
FAILURES=0; WARNINGS=0

step() { printf '\n==> %s\n' "$*"; }
pass() { printf '  [ OK ] %s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '  [WARN] %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf '  [FAIL] %s\n' "$*"; }

# az does not set -e semantics usefully here; every call goes through this so a
# failure becomes empty output rather than an abort.
azq() { az "$@" 2>/dev/null || true; }

step "Subscription"
command -v az >/dev/null || { printf 'ERROR: the Azure CLI (az) is not on PATH\n' >&2; exit 1; }
azq account set --subscription "$SUBSCRIPTION" >/dev/null
ACCT="$(azq account show --query name -o tsv)"
[[ -n "$ACCT" ]] || { printf 'ERROR: not signed in — run az login\n' >&2; exit 1; }
printf '  %s  (%s)\n' "$ACCT" "$SUBSCRIPTION"

# --- 1. the resources exist --------------------------------------------------
step "Resources"
LOGIC_PRINCIPAL="$(azq rest --method get --url "$WF?api-version=2019-05-01" --query identity.principalId -o tsv)"
if [[ -n "$LOGIC_PRINCIPAL" ]]; then pass "Logic App $PLAYBOOK ($LOGIC_PRINCIPAL)"
else fail "Logic App $PLAYBOOK not found, or it has no managed identity"; fi

FUNC_PRINCIPAL="$(azq functionapp show --resource-group "$RG" --name "$FUNC_APP" --query identity.principalId -o tsv)"
FUNC_STATE="$(azq functionapp show --resource-group "$RG" --name "$FUNC_APP" --query state -o tsv)"
if [[ -n "$FUNC_PRINCIPAL" ]]; then pass "Function App $FUNC_APP ($FUNC_PRINCIPAL), state $FUNC_STATE"
else fail "Function App $FUNC_APP not found, or it has no managed identity"; fi
[[ -z "$FUNC_STATE" || "$FUNC_STATE" == "Running" ]] || fail "Function App state is '$FUNC_STATE', expected 'Running'"

# --- 2. the function actually has the code -----------------------------------
step "Function code"
FNS="$(azq functionapp function list --resource-group "$RG" --name "$FUNC_APP" --query '[].name' -o tsv)"
if [[ "$FNS" == *startReview* ]]; then
  pass "startReview is deployed ($(printf '%s\n' "$FNS" | grep -c . ) function(s) present)"
elif [[ -n "$FNS" ]]; then
  fail "startReview missing. Present: $(printf '%s' "$FNS" | tr '\n' ' ')"
else
  # Consumption apps can take a minute to index a fresh publish.
  warn "No functions listed yet. A fresh publish can take a minute to index; re-run if the review then fails to start."
fi

# --- 3. permissions ----------------------------------------------------------
# The three grants ./deploy.sh --grant makes. Without them the run fails at
# Get_Jira_password, at Get_blocklist_blob, or inside the function.
step "Permissions"
# Which authorisation model the vault uses decides which grant counts. Turning
# on Azure RBAC *invalidates every access policy* on the vault, so checking
# policies without checking the model reports a grant that does nothing:
# https://learn.microsoft.com/azure/key-vault/general/rbac-guide
KV_RBAC="$(azq keyvault show --name "$KEYVAULT" --query properties.enableRbacAuthorization -o tsv)"
KV_ID="$(azq keyvault show --name "$KEYVAULT" --query id -o tsv)"
KV_NET="$(azq keyvault show --name "$KEYVAULT" \
  --query '[properties.publicNetworkAccess, properties.networkAcls.defaultAction]' -o tsv)"
if [[ "$KV_RBAC" == "true" ]]; then MODEL="Azure RBAC"; else MODEL="access policies (legacy)"; fi
printf '  %s authorisation model: %s\n' "$KEYVAULT" "$MODEL"

check_kv_access() {
  local label="$1" oid="$2"
  [[ -n "$oid" ]] || return 0
  if [[ "$KV_RBAC" == "true" ]]; then
    # --include-inherited: the role may be assigned at subscription or
    # resource-group scope rather than on the vault itself.
    local r
    r="$(azq role assignment list --assignee "$oid" --scope "$KV_ID" --include-inherited \
      --role "Key Vault Secrets User" --query '[].id' -o tsv)"
    if [[ -n "$r" ]]; then pass "$label has Key Vault Secrets User on $KEYVAULT"
    elif [[ -z "$KV_ID" ]]; then warn "Could not resolve $KEYVAULT to check role assignments"
    else fail "$label has NO Key Vault Secrets User on $KEYVAULT (vault is in RBAC mode). Run ./deploy.sh --grant"; fi
  else
    local secrets
    secrets="$(azq keyvault show --name "$KEYVAULT" \
      --query "properties.accessPolicies[?objectId=='$oid'].permissions.secrets[]" -o tsv)"
    if [[ "$secrets" == *get* || "$secrets" == *all* ]]; then
      pass "$label has Key Vault get on $KEYVAULT"
    elif [[ -z "$secrets" ]]; then
      warn "No Key Vault get found for $label on $KEYVAULT (or you lack permission to check). Run ./deploy.sh --grant"
    else
      fail "$label has NO Key Vault get on $KEYVAULT. Run ./deploy.sh --grant"
    fi
  fi
}
check_kv_access "Logic App" "$LOGIC_PRINCIPAL"
check_kv_access "Function App" "$FUNC_PRINCIPAL"

if [[ "$KV_NET" == *Disabled* || "$KV_NET" == *Deny* ]]; then
  warn "$KEYVAULT restricts network access ($(printf '%s' "$KV_NET" | tr '\n' ' ')). A Consumption function app has no VNet integration, so it may be blocked regardless of its permissions."
fi

BLOB_SCOPE="$(azq storage account show --name "$BLOB_ACCOUNT" --query id -o tsv)"
if [[ -n "$BLOB_SCOPE" && -n "$LOGIC_PRINCIPAL" ]]; then
  ROLE="$(azq role assignment list --assignee "$LOGIC_PRINCIPAL" --scope "$BLOB_SCOPE" \
    --role "Storage Blob Data Reader" --query '[].id' -o tsv)"
  if [[ -n "$ROLE" ]]; then pass "Logic App has Storage Blob Data Reader on $BLOB_ACCOUNT"
  else fail "Logic App has NO Storage Blob Data Reader on $BLOB_ACCOUNT. Run ./deploy.sh --grant"; fi
else
  warn "Could not resolve $BLOB_ACCOUNT to check the blob role assignment"
fi

# --- 4. the AbuseIPDB key ----------------------------------------------------
# The function reads ABUSEIPDB_API_KEY as a Key Vault reference AT STARTUP, so
# an unresolved reference means every invocation fails, not just some.
step "AbuseIPDB key"
SECRET_ID="$(azq keyvault secret show --vault-name "$KEYVAULT" --name "$ABUSE_SECRET" --query id -o tsv)"
if [[ -n "$SECRET_ID" ]]; then pass "Secret '$ABUSE_SECRET' exists in $KEYVAULT"
else warn "Could not read secret '$ABUSE_SECRET' — it may be missing, or you may lack get permission yourself"; fi

REF_STATUS="$(azq rest --method get \
  --url "$MGMT/subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.Web/sites/$FUNC_APP/config/configreferences/appsettings?api-version=2022-03-01" \
  --query "value[?name=='ABUSEIPDB_API_KEY'].properties.status" -o tsv)"
if [[ "$REF_STATUS" == *Resolved* ]]; then pass "ABUSEIPDB_API_KEY resolves from Key Vault"
elif [[ -n "$REF_STATUS" ]]; then fail "ABUSEIPDB_API_KEY Key Vault reference status is '$REF_STATUS'. Every function call will fail until this resolves."
else warn "Could not read Key Vault reference status for ABUSEIPDB_API_KEY"; fi

# --- 5. the schedule ---------------------------------------------------------
step "Schedule"
NEXT="$(azq rest --method get --url "$WF/triggers/Scheduled_review?api-version=2016-06-01" \
  --query properties.nextExecutionTime -o tsv)"
if [[ -n "$NEXT" ]]; then pass "Scheduled_review is armed; next run $NEXT (UTC)"
else fail "Scheduled_review reports no next run time — the playbook will only run when fired by hand"; fi

# --- verdict on the checks ---------------------------------------------------
step "Preflight result"
printf '  %d failure(s), %d warning(s)\n' "$FAILURES" "$WARNINGS"
(( FAILURES == 0 )) || { printf '\nStopping: fix the failures above before firing a review.\n'; exit 1; }
(( CHECKS_ONLY == 0 )) || { printf '\nChecks only — nothing fired.\n'; exit 0; }

# --- 6. fire one review ------------------------------------------------------
BODY='{}'
TARGETED=0
if [[ -n "$CONTAINER" || -n "$BLOB_PATH" ]]; then
  TARGETED=1
  BODY="$(python3 -c '
import json,sys
b={}
if sys.argv[1]: b["container"]=sys.argv[1]
if sys.argv[2]: b["blobPath"]=sys.argv[2]
print(json.dumps(b))' "$CONTAINER" "$BLOB_PATH")"
fi

if (( TARGETED == 0 && FORCE == 0 )); then
  printf '\nAbout to review the FULL production blocklist.\n'
  printf 'That costs one AbuseIPDB lookup per public single address on it (~30,000),\n'
  printf 'and raises a real CLOPSSEC ticket. Use --blob-path for a small test blob instead.\n'
  read -r -p 'Type YES to continue: ' ANSWER
  [[ "$ANSWER" == "YES" ]] || { printf 'Aborted.\n'; exit 0; }
fi

step "Fetching the trigger URL"
TRIGGER_URL="$(azq rest --method post --url "$WF/triggers/manual/listCallbackUrl?api-version=2016-06-01" --query value -o tsv)"
[[ -n "$TRIGGER_URL" ]] || { printf 'ERROR: could not fetch the callback URL\n' >&2; exit 1; }
pass "Got the callback URL (not printed — it carries a SAS signature)"

step "Firing a review"
FIRED_AT="$(date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '  body: %s\n' "$BODY"
HEADERS="$(mktemp)"; trap 'rm -f "$HEADERS"' EXIT
CODE="$(curl -sS -o /dev/null -D "$HEADERS" -w '%{http_code}' \
  -X POST "$TRIGGER_URL" -H 'Content-Type: application/json' -d "$BODY")"
printf '  HTTP %s\n' "$CODE"

RUN_ID="$(grep -i '^x-ms-workflow-run-id:' "$HEADERS" | tr -d '\r' | awk '{print $2}')"
if [[ -z "$RUN_ID" ]]; then
  sleep 5
  RUN_ID="$(azq rest --method get --url "$WF/runs?api-version=2016-06-01&\$top=5" \
    --query "value[?properties.startTime>='$FIRED_AT'] | [0].name" -o tsv)"
fi
[[ -n "$RUN_ID" ]] || { printf 'ERROR: could not determine the run id\n' >&2; exit 1; }
pass "Run id $RUN_ID"

# --- 7. follow it to a terminal state ----------------------------------------
step "Waiting for the run (timeout ${TIMEOUT_MINUTES}m)"
DEADLINE=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
STATUS="Running"
while (( $(date +%s) < DEADLINE )); do
  STATUS="$(azq rest --method get --url "$WF/runs/$RUN_ID?api-version=2016-06-01" --query properties.status -o tsv)"
  [[ -n "$STATUS" ]] || STATUS="Unknown"
  case "$STATUS" in Running|Waiting|Unknown) ;; *) break ;; esac
  printf '  %s  %s\n' "$(date +%H:%M:%S)" "$STATUS"
  sleep 15
done

# --- 8. report ---------------------------------------------------------------
step "Run finished: $STATUS"
ACTIONS="$(azq rest --method get --url "$WF/runs/$RUN_ID/actions?api-version=2016-06-01" -o json)"
if [[ -n "$ACTIONS" ]]; then
  printf '%s' "$ACTIONS" | jq -r '.value[] | "  \(.name|.[0:28])\t\(.properties.status)"'
  printf '%s' "$ACTIONS" | jq -r '.value[] | select(.properties.status=="Failed") | select(.properties.error)
    | "      \(.properties.error.code): \(.properties.error.message)"'

  # Compose_run_result carries the ticket URL and the scan counts. Outputs are
  # inline when small and behind a SAS link when large; handle both.
  LINK="$(printf '%s' "$ACTIONS" | jq -r '.value[] | select(.name=="Compose_run_result") | .properties.outputsLink.uri // empty')"
  INLINE="$(printf '%s' "$ACTIONS" | jq -r '.value[] | select(.name=="Compose_run_result") | .properties.outputs // empty')"
  if [[ -n "$INLINE" ]]; then step "Run result"; printf '%s\n' "$INLINE"
  elif [[ -n "$LINK" ]]; then step "Run result"; curl -sS "$LINK" | jq . || printf '  Could not read the outputs; open the run in the portal.\n'
  fi
fi

printf '\nRun history: https://portal.azure.com/#@/resource%s/runs\n' "$WF_PATH"
if [[ "$STATUS" == "Succeeded" ]]; then
  printf 'PASS — the review completed and raised its ticket.\n'; exit 0
fi
printf "FAIL — run ended as '%s'. The failing action and its error are listed above.\n" "$STATUS"
exit 1
