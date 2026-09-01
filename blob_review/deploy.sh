#!/usr/bin/env bash
#
# blob-review — deploy / redeploy from a checkout of this repository.
# Safe to re-run; the ARM deployment is incremental.
#
#   ./deploy.sh           deploy the playbook
#   ./deploy.sh --grant   also grant the two permissions it needs (Key Vault get
#                         for the Logic App, blob read for the Logic App). Omit if
#                         access goes through a separate change; the script prints
#                         the exact commands either way.
#
# One step, because there is no code to publish: the whole review runs in the
# Logic App and AbuseIPDB is reached through the existing abuseipdbapi-1 API
# connection, which already holds the key.
#
# Overrides: RG, SUBSCRIPTION.
#
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RG="${RG:-LSY_WEUR_ITCS_PRD_SEC_RG_002}"
SUBSCRIPTION="${SUBSCRIPTION:-f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29}"
ABUSE_CONNECTION="${ABUSE_CONNECTION:-abuseipdbapi-1}"
DEPLOYMENT="blob-review-$(date -u +%Y%m%d-%H%M%S)"
GRANT=0
[[ "${1:-}" == "--grant" ]] && GRANT=1

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# --- preflight --------------------------------------------------------------
for f in playbook/azuredeploy.json playbook/azuredeploy.parameters.json; do
  [[ -f "$HERE/$f" ]] || fail "$HERE/$f is missing — incomplete checkout?"
done
# Every check in validate.py exists because a real deployment was rejected by
# it. Azure reports one such error per attempt, so failing here saves a round
# trip each time.
if command -v python3 >/dev/null && [[ -x "$HERE/validate.py" ]]; then
  step "Validating the playbook JSON"
  "$HERE/validate.py" || fail "validation failed — fix the problems above before deploying"
fi

command -v az >/dev/null || fail "the Azure CLI (az) is not on PATH"
az account show >/dev/null 2>&1 || fail "not signed in — run 'az login' first"

step "Subscription"
az account set --subscription "$SUBSCRIPTION"
az account show --query '{subscription:name, id:id}' -o tsv

# The AbuseIPDB connection is owned by OMS and is NOT created here. Without it
# the deployment succeeds and every enrichment call then fails at runtime, so
# check first rather than discover it in a run.
step "Checking the AbuseIPDB API connection"
if az resource show --resource-group "$RG" --name "$ABUSE_CONNECTION" \
     --resource-type Microsoft.Web/connections --query id -o tsv >/dev/null 2>&1; then
  echo "  $ABUSE_CONNECTION is present in $RG"
else
  fail "API connection '$ABUSE_CONNECTION' not found in $RG. It is owned by OMS and holds the AbuseIPDB key; this playbook does not create it."
fi

# --- 1. the playbook --------------------------------------------------------
# PlaybookName comes from the parameters file and must stay set, or a redeploy
# stands up a parallel Logic App with a fresh managed identity.
step "Deploying ARM template as $DEPLOYMENT"
az deployment group create \
  --name "$DEPLOYMENT" \
  --resource-group "$RG" \
  --template-file "$HERE/playbook/azuredeploy.json" \
  --parameters "@$HERE/playbook/azuredeploy.parameters.json" \
  --output none

IFS=$'\t' read -r LOGIC_APP LOGIC_PRINCIPAL KEYVAULT BLOB_ACCOUNT <<<"$(
  az deployment group show \
    --name "$DEPLOYMENT" --resource-group "$RG" \
    --query 'properties.outputs.[logicAppName.value, logicAppPrincipalId.value,
              keyVaultName.value, blocklistStorageAccountName.value]' \
    -o tsv
)"
for v in LOGIC_APP LOGIC_PRINCIPAL KEYVAULT BLOB_ACCOUNT; do
  [[ -n "${!v}" ]] || fail "deployment output $v came back empty"
done

# --- 2. access --------------------------------------------------------------
if (( GRANT )); then
  # Which grant works depends on the vault's authorisation model, and getting it
  # wrong is silent: enabling Azure RBAC invalidates every access policy, so
  # set-policy still succeeds while granting nothing. Ask the vault.
  KV_RBAC="$(az keyvault show --name "$KEYVAULT" --query properties.enableRbacAuthorization -o tsv)"
  if [[ "$KV_RBAC" == "true" ]]; then
    step "Granting Key Vault Secrets User to $LOGIC_APP (vault is in RBAC mode)"
    KV_ID="$(az keyvault show --name "$KEYVAULT" --query id -o tsv)"
    az role assignment create --assignee-object-id "$LOGIC_PRINCIPAL" \
      --assignee-principal-type ServicePrincipal \
      --role "Key Vault Secrets User" --scope "$KV_ID" --output none \
      || echo "  (role assignment already present, or insufficient rights)"
  else
    step "Granting Key Vault get to $LOGIC_APP (vault uses access policies)"
    az keyvault set-policy --name "$KEYVAULT" \
      --object-id "$LOGIC_PRINCIPAL" --secret-permissions get --output none
  fi

  step "Granting Storage Blob Data Reader on $BLOB_ACCOUNT to $LOGIC_APP"
  BLOB_SCOPE="$(az storage account show --name "$BLOB_ACCOUNT" --query id -o tsv)"
  az role assignment create \
    --assignee-object-id "$LOGIC_PRINCIPAL" --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Reader" --scope "$BLOB_SCOPE" --output none \
    || echo "  (role assignment already present, or insufficient rights)"
else
  BLOB_SCOPE="$(az storage account show --name "$BLOB_ACCOUNT" --query id -o tsv 2>/dev/null || true)"
  step "Access NOT granted — run with --grant, or pass these on"
  echo "  az keyvault set-policy --name $KEYVAULT \\"
  echo "    --object-id $LOGIC_PRINCIPAL --secret-permissions get"
  echo "  az role assignment create --assignee-object-id $LOGIC_PRINCIPAL \\"
  echo "    --assignee-principal-type ServicePrincipal \\"
  echo "    --role 'Storage Blob Data Reader' \\"
  echo "    --scope ${BLOB_SCOPE:-<resource id of $BLOB_ACCOUNT>}"
fi

# --- 3. confirm the schedule actually took ----------------------------------
# A deployed workflow is not the same as a scheduled one, and this playbook's
# whole failure mode is running only when somebody remembers to fire it.
step "Confirming the weekly schedule is registered"
NEXT_RUN="$(az rest --method get --query 'properties.nextExecutionTime' -o tsv --url \
  "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.Logic/workflows/$LOGIC_APP/triggers/Scheduled_review?api-version=2016-06-01" \
  2>/dev/null || true)"
if [[ -n "$NEXT_RUN" ]]; then
  echo "  Scheduled_review is armed; next run $NEXT_RUN (UTC)"
else
  echo "  WARNING: Scheduled_review reported no next run time."
  echo "  The playbook will only run when somebody fires it by hand — which is"
  echo "  exactly the state the schedule exists to fix. Check Logic app ->"
  echo "  Overview -> Trigger history before relying on it."
fi

# --- done -------------------------------------------------------------------
step "Deployed"
cat <<EOF
  Logic App        $LOGIC_APP   ($LOGIC_PRINCIPAL)
  AbuseIPDB        via the $ABUSE_CONNECTION API connection
  Schedule         Mondays 07:00 CET  (next: ${NEXT_RUN:-UNKNOWN — see warning above})

It now runs itself. This redeploy does not fire an off-schedule review: the
Recurrence trigger carries a startTime and an explicit weekday/hour schedule,
which is what stops a deploy kicking off a full AbuseIPDB scan.

To prove the deployment now rather than waiting for Monday, run ./smoke-test.sh,
or fire one by hand. The trigger URL carries its own SAS signature — treat it as
a credential, so it is deliberately not printed here. Fetch it with:

  az rest --method post --query value -o tsv --url \\
    "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.Logic/workflows/$LOGIC_APP/triggers/manual/listCallbackUrl?api-version=2016-06-01"

Then fire a review:

  curl -X POST "<trigger-url>" -H 'Content-Type: application/json' -d '{}'

Logic App runs are immutable: cancel anything left in flight from before this
redeploy before firing a fresh run.
EOF
