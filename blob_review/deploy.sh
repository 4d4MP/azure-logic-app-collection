#!/usr/bin/env bash
#
# blob-review — deploy / redeploy from a checkout of this repository.
# Safe to re-run: the ARM deployment is incremental and the function publish
# overwrites in place.
#
#   ./deploy.sh           deploy the infrastructure, then publish the function code
#   ./deploy.sh --grant   also grant the three permissions the playbook needs
#                         (Key Vault get for the Logic App, Key Vault get for the
#                         function identity, blob read for the Logic App). Omit if
#                         access goes through a separate change; the script prints
#                         the exact commands either way.
#
# Everything it deploys sits beside it — playbook/ and function/ — so it can be
# run from any working directory and needs no arguments and no file shuffling.
#
# Overrides: RG, SUBSCRIPTION.
#
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RG="${RG:-LSY_WEUR_ITCS_PRD_SEC_RG_002}"
SUBSCRIPTION="${SUBSCRIPTION:-f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29}"
DEPLOYMENT="blob-review-$(date -u +%Y%m%d-%H%M%S)"
GRANT=0
[[ "${1:-}" == "--grant" ]] && GRANT=1

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# --- preflight --------------------------------------------------------------
for f in playbook/azuredeploy.json playbook/azuredeploy.parameters.json \
         function/package.json function/host.json; do
  [[ -f "$HERE/$f" ]] || fail "$HERE/$f is missing — incomplete checkout?"
done
[[ -d "$HERE/function/src" ]] || fail "$HERE/function/src is missing — incomplete checkout?"

command -v az >/dev/null || fail "the Azure CLI (az) is not on PATH"
az account show >/dev/null 2>&1 || fail "not signed in — run 'az login' first"

step "Subscription"
az account set --subscription "$SUBSCRIPTION"
az account show --query '{subscription:name, id:id}' -o tsv

# --- 1. infrastructure ------------------------------------------------------
# PlaybookName comes from the parameters file and must stay set, or a redeploy
# stands up a parallel Logic App with a fresh managed identity.
step "Deploying ARM template as $DEPLOYMENT"
az deployment group create \
  --name "$DEPLOYMENT" \
  --resource-group "$RG" \
  --template-file "$HERE/playbook/azuredeploy.json" \
  --parameters "@$HERE/playbook/azuredeploy.parameters.json" \
  --output none

IFS=$'\t' read -r LOGIC_APP LOGIC_PRINCIPAL FUNC_APP FUNC_PRINCIPAL KEYVAULT BLOB_ACCOUNT <<<"$(
  az deployment group show \
    --name "$DEPLOYMENT" --resource-group "$RG" \
    --query 'properties.outputs.[logicAppName.value, logicAppPrincipalId.value,
              functionAppName.value, functionAppPrincipalId.value,
              keyVaultName.value, blocklistStorageAccountName.value]' \
    -o tsv
)"
for v in LOGIC_APP LOGIC_PRINCIPAL FUNC_APP FUNC_PRINCIPAL KEYVAULT BLOB_ACCOUNT; do
  [[ -n "${!v}" ]] || fail "deployment output $v came back empty"
done

# --- 2. access, before the code ---------------------------------------------
# The function resolves ABUSEIPDB_API_KEY from Key Vault at startup, so the
# access policy has to exist before the app starts, or every invocation 500s.
if (( GRANT )); then
  # Which grant works depends on the vault's authorisation model, and getting it
  # wrong is silent: enabling Azure RBAC invalidates every access policy, so
  # set-policy still succeeds while granting nothing. Ask the vault.
  KV_RBAC="$(az keyvault show --name "$KEYVAULT" --query properties.enableRbacAuthorization -o tsv)"
  if [[ "$KV_RBAC" == "true" ]]; then
    step "Granting Key Vault Secrets User to $LOGIC_APP and $FUNC_APP (vault is in RBAC mode)"
    KV_ID="$(az keyvault show --name "$KEYVAULT" --query id -o tsv)"
    for OID in "$LOGIC_PRINCIPAL" "$FUNC_PRINCIPAL"; do
      az role assignment create --assignee-object-id "$OID" --assignee-principal-type ServicePrincipal \
        --role "Key Vault Secrets User" --scope "$KV_ID" --output none \
        || echo "  (role assignment already present, or insufficient rights) $OID"
    done
  else
    step "Granting Key Vault get to $LOGIC_APP and $FUNC_APP (vault uses access policies)"
    az keyvault set-policy --name "$KEYVAULT" \
      --object-id "$LOGIC_PRINCIPAL" --secret-permissions get --output none
    az keyvault set-policy --name "$KEYVAULT" \
      --object-id "$FUNC_PRINCIPAL" --secret-permissions get --output none
  fi

  # The function resolves its Key Vault references at startup and caches the
  # result, so a grant made after the app started does not take effect until it
  # restarts. Without this the app keeps reporting AccessToKeyVaultDenied long
  # after the permission is correct.
  step "Restarting $FUNC_APP so its Key Vault references re-resolve"
  az functionapp restart --resource-group "$RG" --name "$FUNC_APP" --output none \
    || echo "  (restart failed; restart the function app by hand before testing)"

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
  echo "  az keyvault set-policy --name $KEYVAULT \\"
  echo "    --object-id $FUNC_PRINCIPAL --secret-permissions get"
  echo "  az role assignment create --assignee-object-id $LOGIC_PRINCIPAL \\"
  echo "    --assignee-principal-type ServicePrincipal \\"
  echo "    --role 'Storage Blob Data Reader' \\"
  echo "    --scope ${BLOB_SCOPE:-<resource id of $BLOB_ACCOUNT>}"
fi

# --- 3. function code -------------------------------------------------------
# ARM cannot carry a JavaScript payload, so the code is a separate step.
# Published from function/, which is a normal Functions project root: both
# paths below package their current directory, and function/.funcignore is what
# keeps tests/, *.md and the ARM templates out of the package.
step "Publishing function code to $FUNC_APP"
cd "$HERE/function"
if command -v func >/dev/null; then
  # --javascript is required, not cosmetic. func infers the project language
  # from local.settings.json, which is gitignored because it holds local
  # secrets — so it never exists in a fresh clone, and without the flag func
  # fails with "Can't determine project language from files" and "Worker
  # runtime cannot be 'None'".
  func azure functionapp publish "$FUNC_APP" --javascript
else
  echo "Azure Functions Core Tools not found; falling back to az zip deploy."
  command -v zip >/dev/null || fail "neither 'func' nor 'zip' is available"
  command -v npm >/dev/null || fail "npm is required to install dependencies"
  npm install --omit=dev --no-audit --no-fund
  # The zip is built outside the checkout so it cannot package itself, and the
  # contents are listed explicitly rather than relying on .funcignore.
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  zip -q -r "$tmp/function.zip" package.json host.json src node_modules
  az functionapp deployment source config-zip \
    --resource-group "$RG" --name "$FUNC_APP" \
    --src "$tmp/function.zip" --output none
fi

# --- 4. confirm the schedule actually took ----------------------------------
# A deployed workflow is not the same as a scheduled one, and this playbook's
# whole failure mode is running only when somebody remembers to fire it. Read
# the Recurrence trigger back rather than assuming the deployment armed it.
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
  Function App     $FUNC_APP    ($FUNC_PRINCIPAL)
  Schedule         Mondays 07:00 CET  (next: ${NEXT_RUN:-UNKNOWN — see warning above})

It now runs itself. This redeploy does not fire an off-schedule review: the
Recurrence trigger carries a startTime and an explicit weekday/hour schedule,
which is what stops a deploy kicking off a full AbuseIPDB scan.

To prove the deployment now rather than waiting for Monday, fire one by hand.
The trigger URL carries its own SAS signature — treat it as a credential, so it
is deliberately not printed here. Fetch it with:

  az rest --method post --query value -o tsv --url \\
    "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.Logic/workflows/$LOGIC_APP/triggers/manual/listCallbackUrl?api-version=2016-06-01"

Then fire a review:

  curl -X POST "<trigger-url>" -H 'Content-Type: application/json' -d '{}'

Logic App runs are immutable: cancel anything left in flight from before this
redeploy before firing a fresh run.
EOF
