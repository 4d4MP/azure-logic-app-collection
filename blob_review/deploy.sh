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
  # Dependencies must be installed BEFORE the publish. Core Tools does not run
  # npm install for you here and does not trigger a remote build on this path -
  # it zips what it finds. Publishing without node_modules uploads source only,
  # the v4 entry point then throws "Cannot find module '@azure/functions'" at
  # startup, and the host registers zero functions while the publish reports
  # success.
  command -v npm >/dev/null || fail "npm is required to install dependencies"
  npm install --omit=dev --no-audit --no-fund
  [[ -d node_modules ]] || fail "npm install left no node_modules; the publish would ship source with no dependencies"

  if command -v func >/dev/null; then
    # --javascript is required: local.settings.json is not in the repository, so
    # Core Tools has nothing to infer the language from and refuses to publish.
    func azure functionapp publish "$FUNC_APP" --javascript
  else
    echo "Azure Functions Core Tools not found; falling back to az zip deploy."
    command -v zip >/dev/null || fail "neither 'func' nor 'zip' is available"
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
  The app has no usable code. The usual cause is a deployment package with no
  node_modules, which makes the v4 entry point throw at startup. Check the
  entry-point errors in Application Insights:

    let myAppName = \"$FUNC_APP\";
    union traces,requests,exceptions
    | where cloud_RoleName =~ myAppName
    | where timestamp > ago(1d) and severityLevel > 2
    | where message has \"entry point\""
fi
echo "  registered: $FOUND"

# --- 5. smoke-test the endpoint the Logic App will call ---------------------
# Registering every function is not the same as being callable. A rejected key
# or an unresolved Key Vault reference surfaces only at run time, as a bare
# 401/403/500 on Run_review with the inputs hidden by secureData - which tells
# you almost nothing. Posting an empty object exercises the whole path (key
# auth, host start, the ABUSEIPDB_API_KEY app setting) and then stops at the
# body check, so it starts no orchestration and spends no AbuseIPDB quota.
step "Smoke-testing the enrichment endpoint"
if command -v curl >/dev/null; then
  FUNC_HOST="$(az functionapp show --name "$FUNC_APP" --resource-group "$RG" \
                 --query defaultHostName -o tsv)"
  # The same key ARM hands the Logic App as EnrichmentFunctionKey.
  FUNC_KEY="$(az functionapp keys list --name "$FUNC_APP" --resource-group "$RG" \
                --query 'functionKeys.default' -o tsv)"
  [[ -n "$FUNC_HOST" ]] || fail "could not resolve the function app host name"
  [[ -n "$FUNC_KEY" ]] || fail "the app has no default host key, so the Logic App's
  EnrichmentFunctionKey resolves to an empty string and every call is rejected.
  Host keys live in the app's own storage account; check AzureWebJobsStorage."

  SMOKE_OUT="$(mktemp)"
  SMOKE_CODE="$(curl -sS -m 90 -o "$SMOKE_OUT" -w '%{http_code}' \
      -X POST "https://$FUNC_HOST/api/start-review" \
      -H "x-functions-key: $FUNC_KEY" \
      -H 'Content-Type: application/json' \
      -d '{}' 2>/dev/null || echo 000)"
  SMOKE_TEXT="$(head -c 300 "$SMOKE_OUT" | tr -d '\r\n')"
  rm -f "$SMOKE_OUT"

  case "$SMOKE_CODE" in
    400)
      # Expected: the handler got past the key check and the ABUSEIPDB_API_KEY
      # check, and rejected the empty body on its own terms.
      echo "  ok — 400 $SMOKE_TEXT"
      ;;
    401)
      fail "401 from the endpoint using the app's own default host key.
  The host is refusing a key it issued itself, so key validation - not the key -
  is broken. Host keys are read from the azure-webjobs-secrets container in the
  app's storage account; a wrong or rotated AzureWebJobsStorage connection
  string makes every call 401, master key included. Check with:
    az functionapp keys list -g $RG -n $FUNC_APP -o json
    az functionapp config appsettings list -g $RG -n $FUNC_APP --query \"[?name=='AzureWebJobsStorage']\""
      ;;
    403)
      fail "403 from the endpoint. A 403 does not come from the key check - that
  answers 401 - so something in front of the host refused the request. Check:
    az functionapp config access-restriction show -g $RG -n $FUNC_APP
    az webapp auth show -g $RG -n $FUNC_APP --query '{enabled:enabled,action:unauthenticatedClientAction}'
    az functionapp show -g $RG -n $FUNC_APP --query '{state:state,enabled:enabled,publicNetworkAccess:publicNetworkAccess}'"
      ;;
    404)
      fail "404 — the route /api/start-review does not exist even though the
  function list reported startReview. Check host.json's routePrefix is 'api'."
      ;;
    500)
      fail "500 — the function started and failed: $SMOKE_TEXT
  If that names ABUSEIPDB_API_KEY, the Key Vault reference did not resolve.
  Confirm the secret exists and the function identity ($FUNC_PRINCIPAL) has get:
    az keyvault secret show --vault-name $KEYVAULT --name abuseipdb-api-key --query id
    az functionapp config appsettings list -g $RG -n $FUNC_APP --query \"[?name=='ABUSEIPDB_API_KEY']\""
      ;;
    000)
      fail "no response within 90s from https://$FUNC_HOST/api/start-review"
      ;;
    *)
      fail "unexpected $SMOKE_CODE from the endpoint: $SMOKE_TEXT"
      ;;
  esac
else
  echo "  (curl not on PATH — skipped; the first real run will be the first test)"
fi

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
