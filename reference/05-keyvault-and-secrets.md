# Topic 05: Azure Key Vault and Secrets

Generated: 2026-04-29 | Sources: 8 | Confidence: high

## Scope

How secrets — Jira API token, third-party webhook URLs, anything else with a credential — get from the developer's hands into Azure Key Vault, and from Key Vault into the Logic App and Azure Function at runtime, without ever touching source control or being visible in logs. Covers the two RBAC models, system-assigned vs user-assigned managed identity choices, the runtime fetch vs deploy-time reference trade-off, rotation hygiene, and the failure modes that look like network problems but aren't.

Out of scope: certificate management (Key Vault stores certs too, but that's a different workflow), HSM-backed keys (Premium SKU concern), and BYOK / customer-managed keys for storage encryption (relevant but tangential).

## Key entities & terms

- **Key Vault**: an Azure resource that stores three things: *secrets* (opaque strings up to 25 KiB), *keys* (asymmetric key material with crypto operations), *certificates* (managed cert lifecycle wrapping a key + secret). [src 1]
- **Secret**: name + value + version. Each set creates a new version; old versions are addressable by URI but are *Disabled* by default after a few rotations if you set retention policies. [src 2]
- **Vault URI**: `https://<vault-name>.vault.azure.net/`. Secret URI: `https://<vault-name>.vault.azure.net/secrets/<name>/<version>`. Latest version: omit the `<version>` segment. [src 2]
- **Access model**: two mutually-exclusive systems on a vault — *Vault access policies* (legacy, granular but additive only) or *Azure RBAC* (recommended, integrates with Azure RBAC roles). New vaults default to RBAC. [src 3]
- **Key Vault Secrets User** (RBAC role): read secret values. Use this for runtime consumers (Logic App, Function MSI). [src 3]
- **Key Vault Secrets Officer** (RBAC role): read + write secrets. Use this for the deploy pipeline that rotates secrets, not for application identities.
- **Soft delete + purge protection**: when a secret is deleted, it goes to a recoverable state for 7–90 days. Purge protection prevents permanent deletion within that window. Both should be ON for any vault holding production secrets. [src 4]
- **Key Vault reference syntax** (App Service / Functions): `@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/<name>/)` — resolved by the runtime, not your code. [src 5]
- **Logic Apps Key Vault connector**: provides `Get secret`, `List secrets`, `Set secret` actions. Uses managed identity if configured, otherwise an OAuth connection. [src 6]
- **Managed identity** (recap): an AAD identity attached to an Azure resource, used to authenticate to Key Vault (and other Azure services) without holding a secret. *System-assigned* (1:1 with resource) or *user-assigned* (many:many).

## Core facts

1. **Use RBAC, not access policies, for new vaults.** RBAC integrates with Azure's standard role model, supports deny-by-default semantics, and propagates correctly with policy-as-code. [src 3]
2. **Always enable soft delete and purge protection.** The cost is zero; the cost of accidentally permanently deleting a production secret is unbounded. [src 4]
3. **Per-environment vaults.** One vault per environment (dev / test / prod), not per app. Apps share a vault scoped by RBAC; environments do not. [src 1]
4. **The Logic App's managed identity needs `Key Vault Secrets User` at the secret or vault scope.** Subscription-level role assignments work but are too broad — assign at vault scope minimum. [src 3]
5. **Runtime fetch vs deploy-time reference.** Logic App can fetch a secret each run (Key Vault `Get secret` action) or have the secret value baked into a parameter at deploy time. Runtime fetch tolerates rotation without redeploy; deploy-time reference avoids per-run KV calls. [src 6]
6. **Function App KV references** are deploy-time-resolved via `@Microsoft.KeyVault(...)` syntax. Updating the secret triggers a re-resolve within minutes; you don't have to redeploy. [src 5]
7. **Throttling**: Key Vault data plane has rate limits per vault. ~2,000 requests / 10s per vault; secret-fetch is the cheapest operation. Don't fetch in tight loops; cache for the duration of a Function invocation. [src 7]
8. **Auditing**: every data-plane operation is logged to Key Vault diagnostic logs. Send these to a Log Analytics workspace and alert on unexpected fetch sources or volumes. [src 8]
9. **Network isolation**: Key Vault supports private endpoints and a built-in firewall. For production, set the firewall to deny by default and allow only the Logic App / Function VNets and any required CI/CD agents. [src 1]
10. **Rotation should be automated.** Manual rotation in the portal is fine for a demo; in production, use a rotation runbook (Function or Automation account) that mints a new credential at the source (Jira API tokens, storage SAS, etc.) and writes a new version to KV.

## Wiring the Logic App ↔ Key Vault path

End-to-end:

1. **Create the Logic App** with a system-assigned managed identity (Identity blade → On).
2. **Create the Key Vault** with RBAC permission model and soft delete / purge protection enabled.
3. **Assign role** `Key Vault Secrets User` to the Logic App's managed identity at the vault scope.
4. **Add the secret** (`Set secret` via portal, Azure CLI, or your CI/CD pipeline).
5. **Reference it** in the Logic App in one of two ways:

   **Option A — Runtime fetch** (recommended for rotation-friendly secrets):
   ```json
   "Get_jira_token": {
     "type": "ApiConnection",
     "inputs": {
       "host": { "connection": { "name": "@parameters('$connections')['keyvault']['connectionId']" } },
       "method": "get",
       "path": "/secrets/@{encodeURIComponent('jira-api-token')}/value"
     }
   }
   ```
   And reference the value in the next action as `@body('Get_jira_token').value`.

   **Option B — Deploy-time parameter** (for low-rotation secrets, or when you want to avoid per-run KV traffic):
   - Create a Logic App parameter `jira_token` of type `secureString`.
   - In the ARM/Bicep template, reference `parameters('keyVault').getSecret('jira-api-token')` (the Bicep `getSecret` works only when the deployment runs with permissions to the vault).
   - Reference in actions as `@parameters('jira_token')`. The value is encrypted in the Logic App resource and never appears in run history if you mark inputs/outputs secure on the action that uses it.

For **Logic Apps Standard**, use the App Settings layer plus `@Microsoft.KeyVault(...)` references — it's the same pattern as Functions and is much cleaner than the Consumption-era connector.

## Wiring the Function ↔ Key Vault path

For an Azure Function, prefer App Settings + Key Vault references:

1. **App Settings** (`local.settings.json` for local dev, App Configuration / Function App settings for cloud):
   ```json
   {
     "Values": {
       "JIRA_TOKEN": "@Microsoft.KeyVault(SecretUri=https://my-vault.vault.azure.net/secrets/jira-api-token/)"
     }
   }
   ```
2. **Code** reads `os.environ["JIRA_TOKEN"]` — sees the resolved secret.
3. **At runtime**, Functions resolves the reference via the Function App's managed identity. The runtime caches the resolved value and re-resolves on a periodic interval (≈24h) or when the App Setting is changed.

For values that rotate frequently (every minutes/hours), bypass the cache by using the SDK directly:

```python
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

_kv = SecretClient(vault_url=os.environ["KEY_VAULT_URL"], credential=DefaultAzureCredential())

def get_secret(name: str) -> str:
    return _kv.get_secret(name).value
```

Cache the SecretClient itself (it's threadsafe). Cache fetched values for the lifetime of an invocation; do not cache across invocations of a Consumption-plan Function (cold starts can outlive secrets, and you want fresh on each cold start).

## System-assigned vs user-assigned managed identity

Use **system-assigned** when:
- The identity is conceptually owned by the resource (a Logic App that should die with its resource).
- You have one resource needing the access.
- You want zero ceremony.

Use **user-assigned** when:
- Multiple resources need to share the same identity (Logic App + Function + DevOps pipeline all using the same KV access).
- The identity outlives any single resource (e.g. a CI/CD identity used across deploys).
- You need to pre-provision access before the consuming resource exists (chicken-and-egg in IaC).

For our pipeline: Logic App and Function each get **system-assigned** identities. Each is granted *Key Vault Secrets User* on the vault scope. The Function App may additionally get *Storage Blob Data Contributor* on the audit container scope. Two identities, two scopes, two clean separation lines.

## Rotation

Rotation is a process, not a feature toggle. The minimum viable rotation flow for a Jira API token:

1. **Mint** a new token at `id.atlassian.com/manage-profile/security/api-tokens` using the service account (this part is currently manual; Atlassian doesn't expose a token-mint API).
2. **Store** the new value as a new version of the `jira-api-token` secret in KV (CLI: `az keyvault secret set ...`).
3. **Validate** by hitting Jira with the new token from the deploy environment.
4. **Promote** the new token by allowing the Logic App / Function to refresh its cached value (App Settings re-resolve, runtime fetch picks up automatically).
5. **Revoke** the old token from the Atlassian profile (this is the bit people forget).
6. **Audit** that all callers are using the new version (Key Vault diagnostic logs show secret-version on every fetch).

Schedule this monthly or quarterly. For storage SAS (if you must use it), automate fully with a rotation Function on a timer.

## LHsystems environment — actual resource names

The production Sentinel→Trackspace pipeline uses these specific resources. Verified 2026-05-04 against the deployed `LSY-WEUR-ITCS-PRD-APICON-KV` API connection.

| Aspect | Value |
|---|---|
| Subscription | `f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29` |
| Resource group | `LSY_WEUR_ITCS_PRD_SEC_RG_002` (westeurope) |
| **Key Vault name** | **`LSY-WEUR-ITCS-PRD-KV-02`** |
| Vault URI | `https://lsy-weur-itcs-prd-kv-02.vault.azure.net/` |
| KV API connection (Logic App side) | `LSY-WEUR-ITCS-PRD-APICON-KV` (kind `V1`, MSI-backed) |
| Sentinel API connection | `LSY-WEUR-ITCS-PRD-APICON-SENTINEL` (ManagedServiceIdentity) |
| Secret for Trackspace Logic App auth | `sentinelsvc` (password for the `sentinelsvc` service account, used in Basic auth from the Logic App) |
| Secret URI | `https://lsy-weur-itcs-prd-kv-02.vault.azure.net/secrets/sentinelsvc/` |
| TI-handler-specific KV API connection | `keyvault-TI-handler` (in same RG, MSI-backed, kind V1) — created alongside the playbook rather than reusing the shared APICON-KV |

Note: the local Python automation (`daily.py`, `work.py`) does **not** use this KV secret — it authenticates to Trackspace with a personal Bearer PAT held in the `TRACKSPACE_PAT` environment variable, under a personal account, not `sentinelsvc`. Two completely separate credentials, two separate code paths, audited under different principals.

### Discovered during deployment — KV firewall blocks Cloud Shell

The KV firewall is set to deny by default and does not allowlist Cloud Shell egress IPs. `Get-AzKeyVaultSecret` from a Cloud Shell session returns `Forbidden`, including for benign operations like listing secrets. The playbook's MSI-backed connection reaches KV fine at runtime — the firewall block only affects the operator's interactive session.

If you need to verify the `sentinelsvc` secret exists before deployment, options are:
- Portal access (browser hits KV through a different path).
- Connect from a VM inside an allowlisted VNet.
- Trust the deployment's runtime test (the first playbook run failing on `Get_Jira_password` would surface a missing secret immediately).

### Discovering the vault name from a KV API connection

The Logic App references KV through an `APICON-KV` connection resource, not the vault directly. To resolve which vault it points at:

```powershell
az resource show --ids /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Web/connections/<connection-name>
```

Then look at `properties.parameterValueType`:

- If `"Alternative"` (MSI-backed connection) → vault name is at `properties.alternativeParameterValues.vaultName`.
- If `"Default"` (OAuth-backed connection) → vault name is at `properties.parameterValues.vaultName` or `properties.nonSecretParameterValues.vaultName`.

A `--query "properties.parameterValues.vaultName"` against an MSI-backed connection silently returns empty. Always check `parameterValueType` first, or just dump the whole resource and inspect the right field.

## Common failure modes that look like network errors

These all look like "Logic App can't reach KV" but are something else:

- **`Forbidden` (403) returned to the Logic App** — RBAC role assignment is missing or scoped wrong. Re-check: who is the principal (the Logic App's managed-identity object id, NOT the Logic App resource's resource id), what role (`Key Vault Secrets User`), what scope (the vault). [src 3]
- **MSI-backed KV API connection — vault name not where you'd expect.** When the connection's `parameterValueType` is `Alternative` (the MSI case), the vault name lives under `properties.alternativeParameterValues.vaultName`, **not** `properties.parameterValues.vaultName`. A `--query "properties.parameterValues.vaultName"` returns empty and looks like a misconfigured connection when in fact the value is fine, just at a different path.
- **`Unauthorized` (401) when calling KV from Function** — the Function's identity isn't enabled, or the App Setting `KEY_VAULT_URL` points at the wrong vault. Verify with `az role assignment list --assignee <mi-object-id>`.
- **Logic App `connection` resource has stale credentials** — the KV connector has its own connection resource (Consumption SKU); if the connection was created with a user account and that user's tokens expire, the connector silently fails. Fix: recreate connection with managed identity.
- **Secret value contains characters Logic App expressions don't escape** — embedding the secret directly in a URL with `@{parameters('jira_token')}` URL-encodes incorrectly for some characters. Fix: place the secret in an `Authorization` header, not the URL.
- **Network firewall blocks** — KV firewall set to deny-by-default and Logic App egress IPs not allowlisted. For Consumption SKU, use the Logic App's regional egress IP ranges (published doc) or move to Standard with VNet + private endpoint.
- **DNS for private endpoint not resolving inside the VNet** — common with Standard SKU and KV private endpoint. The VNet needs a Private DNS Zone link for `privatelink.vaultcore.azure.net`. [src 1]
- **`Throttled` (429) under load** — the playbook fetches secrets in a loop. Refactor to fetch once, pass the value via workflow variable, or move the loop to a Function with in-process caching.

## Where this commonly breaks in practice

The two-line summary you'll come back to: **"It's almost always RBAC, sometimes DNS, occasionally a stale connection resource."** Networking issues do happen, but they're a small fraction of KV failures. Start with `az role assignment list --scope <vault-id>` and work outward.

A useful triage Logic App: a tiny "KV self-test" workflow that fetches a known dummy secret, runs every 5 minutes, and alerts on failure. When the SOC pages "playbook is failing", the self-test tells you immediately whether KV is the cause.

## Sources

1. Microsoft Learn — *About Azure Key Vault* — https://learn.microsoft.com/azure/key-vault/general/overview — accessed 2026-04-29
2. Microsoft Learn — *About secrets in Key Vault* — https://learn.microsoft.com/azure/key-vault/secrets/about-secrets — accessed 2026-04-29
3. Microsoft Learn — *Provide access to Key Vault keys, certificates, and secrets with Azure RBAC* — https://learn.microsoft.com/azure/key-vault/general/rbac-guide — accessed 2026-04-29
4. Microsoft Learn — *Soft-delete and purge protection* — https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview — accessed 2026-04-29
5. Microsoft Learn — *Use Key Vault references for App Service and Azure Functions* — https://learn.microsoft.com/azure/app-service/app-service-key-vault-references — accessed 2026-04-29
6. Microsoft Learn — *Connect to Azure Key Vault from Logic Apps* — https://learn.microsoft.com/azure/connectors/connectors-create-api-azure-key-vault — accessed 2026-04-29
7. Microsoft Learn — *Azure Key Vault throttling guidance* — https://learn.microsoft.com/azure/key-vault/general/overview-throttling — accessed 2026-04-29
8. Microsoft Learn — *Key Vault logging* — https://learn.microsoft.com/azure/key-vault/general/logging — accessed 2026-04-29
