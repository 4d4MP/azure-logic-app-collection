#!/usr/bin/env bash
#
# blob-review — deploy / redeploy. Safe to re-run; the ARM deployment is
# incremental and the function publish overwrites in place.
#
# Run it straight from a clone — it resolves every artifact relative to its own
# location, so there is nothing to copy and nothing to go stale:
#
#   ./deploy.sh           deploy infrastructure, then publish the function code
#   ./deploy.sh --grant   also grant the three permissions the playbook needs
#                         (Key Vault get for the Logic App, Key Vault get for the
#                         function identity, blob read for the Logic App). Omit if
#                         access goes through a separate change; the script prints
#                         the exact commands either way.
#
set -euo pipefail

RG="${RG:-LSY_WEUR_ITCS_PRD_SEC_RG_002}"
SUBSCRIPTION="${SUBSCRIPTION:-f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29}"
DEPLOYMENT="blob-review-$(date -u +%Y%m%d-%H%M%S)"
GRANT=0
[[ "${1:-}" == "--grant" ]] && GRANT=1

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# --- paths ------------------------------------------------------------------
# Everything is resolved from the script's own directory. Copying artifacts into
# a working directory is what let a stale azuredeploy.json get deployed twice.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$ROOT/playbook/azuredeploy.json"
PARAMETERS="$ROOT/playbook/azuredeploy.parameters.json"
FUNCTION_DIR="$ROOT/function"

for f in "$TEMPLATE" "$PARAMETERS" "$FUNCTION_DIR/package.json" "$FUNCTION_DIR/host.json"; do
  [[ -f "$f" ]] || fail "not found: $f"
done
[[ -d "$FUNCTION_DIR/src" ]] || fail "not found: $FUNCTION_DIR/src"

# --- preflight --------------------------------------------------------------
command -v az >/dev/null || fail "the Azure CLI (az) is not on PATH"
az account show >/dev/null 2>&1 || fail "not signed in — run 'az login' first"

# ARM rejects runtime functions in parameters/variables, and the failure only
# surfaces after a round-trip to Azure. Catch it here instead.
if command -v jq >/dev/null; then
  jq -e '[(.parameters, .variables) | .. | strings | select(test("listKeys\\(|reference\\("))] | length == 0' \
     "$TEMPLATE" >/dev/null \
    || fail "$TEMPLATE has a runtime function in parameters/variables; ARM resolves those before deployment and will reject the template"
fi

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
  --template-file "$TEMPLATE" \
  --parameters "@$PARAMETERS" \
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
  step "Granting Key Vault get to $LOGIC_APP and $FUNC_APP"
  # Access-policy vault: the Key Vault Secrets User RBAC role would be inert.
  az keyvault set-policy --name "$KEYVAULT" \
    --object-id "$LOGIC_PRINCIPAL" --secret-permissions get --output none
  az keyvault set-policy --name "$KEYVAULT" \
    --object-id "$FUNC_PRINCIPAL" --secret-permissions get --output none

  step "Granting Storage Blob Data Reader on $BLOB_ACCOUNT to $LOGIC_APP"
  BLOB_SCOPE="$(az storage account show --name "$BLOB_ACCOUNT" --query id -o tsv)"
  az role assignment create \
    --assignee-object-id "$LOGIC_PRINCIPAL" --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Reader" --scope "$BLOB_SCOPE" --output none \
    || echo "  (role assignment already present, or insufficient rights)"
else
  BLOB_SCOPE="$(az storage account show --name "$BLOB_ACCOUNT" --query id -o tsv 2>/dev/null || true)"
  step "Access NOT granted — run with --grant, or pass these on"
  echo "  az keyvault set-policy --name $KEYVAULT --object-id $LOGIC_PRINCIPAL --secret-permissions get"
  echo "  az keyvault set-policy --name $KEYVAULT --object-id $FUNC_PRINCIPAL --secret-permissions get"
  echo "  az role assignment create --assignee-object-id $LOGIC_PRINCIPAL --assignee-principal-type ServicePrincipal --role 'Storage Blob Data Reader' --scope ${BLOB_SCOPE:-<resource id of $BLOB_ACCOUNT>}"
fi

# --- 3. function code -------------------------------------------------------
# ARM cannot carry a JavaScript payload, so the code is a separate step. Both
# tools publish the current directory, hence the subshell cd.
step "Publishing function code to $FUNC_APP"
(
  cd "$FUNCTION_DIR"
  if command -v func >/dev/null; then
    # --javascript is required: local.settings.json is not in the repository, so
    # Core Tools has nothing to infer the language from and refuses to publish.
    # Core Tools runs npm install itself as part of the publish.
    func azure functionapp publish "$FUNC_APP" --javascript
  else
    echo "Azure Functions Core Tools not found; falling back to az zip deploy."
    command -v zip >/dev/null || fail "neither 'func' nor 'zip' is available"
    command -v npm >/dev/null || fail "npm is required to install dependencies"
    npm install --omit=dev --no-audit --no-fund
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    zip -q -r "$tmp/function.zip" package.json host.json src node_modules
    az functionapp deployment source config-zip \
      --resource-group "$RG" --name "$FUNC_APP" \
      --src "$tmp/function.zip" --output none
  fi
)

# --- 4. verify the code actually landed -------------------------------------
# The ARM step replaces the app settings collection wholesale, which wipes the
# WEBSITE_RUN_FROM_PACKAGE pointer that the publish sets. The publish above puts
# it back - but if it had failed, the app would be left with no code at all and
# nothing so far would have said so.
step "Verifying functions registered on $FUNC_APP"
EXPECTED="enrichBatch reviewOrchestrator startReview"
for attempt in 1 2 3 4 5; do
  FOUND="$(az functionapp function list --name "$FUNC_APP" --resource-group "$RG" \
             --query '[].name' -o tsv 2>/dev/null | sed 's#.*/##' | sort | tr '\n' ' ' || true)"
  MISSING=""
  for fn in $EXPECTED; do
    [[ " $FOUND " == *" $fn "* ]] || MISSING="$MISSING $fn"
  done
  [[ -z "$MISSING" ]] && break
  (( attempt < 5 )) && { echo "  not registered yet ($attempt/5), waiting for trigger sync..."; sleep 10; }
done
if [[ -n "$MISSING" ]]; then
  fail "function(s) missing after publish:$MISSING (found: ${FOUND:-none}).
  The app has no usable code. Re-run this script; if the publish keeps failing,
  the app is left in that state and every review will fail."
fi
echo "  registered: $FOUND"

# --- done -------------------------------------------------------------------
step "Deployed"
cat <<EOF
  Logic App        $LOGIC_APP   ($LOGIC_PRINCIPAL)
  Function App     $FUNC_APP    ($FUNC_PRINCIPAL)
  Functions        $FOUND

The trigger URL carries its own SAS signature — treat it as a credential, so it
is deliberately not printed here. Fetch it with:

  az rest --method post --query value -o tsv --url \\
    "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.Logic/workflows/$LOGIC_APP/triggers/manual/listCallbackUrl?api-version=2016-06-01"

Then fire a review:

  curl -X POST "<trigger-url>" -H 'Content-Type: application/json' -d '{}'

Logic App runs are immutable: cancel anything left in flight from before this
redeploy before firing a fresh run.
EOF
