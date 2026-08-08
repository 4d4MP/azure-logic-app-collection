# Blob review — blocklist hygiene audit

**Logic App:** `blob-review` (Consumption) in `LSY_WEUR_ITCS_PRD_SEC_RG_002`.
**Function App:** `lsy-weur-itcs-prd-blobreview-func` (Linux Consumption, Python 3.11).
**Source of truth:** `playbook/workflow.json` + `playbook/azuredeploy.json` + `function/`.
**Trigger:** HTTP request (manual / on demand). No schedule, no Sentinel incident.

The other playbooks in this collection *write* to the Palo Alto EDL blob
(`lsyweuritcsprdmspalo001/$web/index.html`). This one *audits* it: it reads every
IP currently on the blocklist, enriches it against AbuseIPDB, and flags the entries
that should never have been blocked — partner/vendor address space and internal
addresses. If anything is flagged it raises a **CLOPSSEC** Task assigned to
`secops` listing the offenders.

It is read-only against the blob. It never removes an IP; a human does that after
reviewing the ticket.

## Flow

```
HTTP POST (optional {"blobPath": "...", "container": "..."})
  → Resolve_blob_target            request body overrides the parameters
  → Respond_accepted               202 + run id, immediately; the rest runs async
  → Get_blocklist_blob             GET the EDL over managed identity
  → Split / trim / filter          drop blanks, '#' and '//' comments, stray '<' HTML
  → Check_blocklist_not_empty
       ├─ empty → Terminate Failed (a blank EDL is a fetch/format fault, not an all-clear)
       └─ entries → Compose_shards            chunk into ceil(n/5) — at most 5 shards
                    → Guard_shard_count       >5 shards ⇒ Terminate Failed, never a partial review
                    → Get_AbuseIPDB_key       Key Vault, secured in + out
                    → Enrich_shard_1..5       5 parallel POSTs to the function,
                                              10 in-flight AbuseIPDB lookups each
                                              ⇒ 50 concurrent requests at the gateway
                    → Compose_findings        union of the five results arrays
                    → Compose_scan_summary    scanned / checked / skipped / invalid / errors
                    → Findings_gate
                         ├─ no findings → Compose_no_findings, run ends Succeeded
                         └─ findings    → Get_Jira_password (Key Vault)
                                          → Jira_health_check
                                          → Build_table_rows
                                          → Create_CLOPSSEC_ticket
                                          → Assign_ticket (best effort, tolerated)
                                          → Compose_run_result
```

`Respond_accepted` returns **202** before the scan starts, so the caller never waits
on a multi-minute run. The result lives in the run history and in the ticket.

### Why five actions and not a Foreach

The fan-out is five *named* actions (`Enrich_shard_1` … `Enrich_shard_5`), not a
`Foreach` with `concurrency: 5`. Logic Apps variables are not safe to mutate from a
concurrent `Foreach`, and referencing an in-loop action's output from outside the
loop is unreliable — both are the usual ways a concurrent fan-out silently loses
results. Five explicit actions plus a `union()` of their five response bodies is
fully deterministic.

The cost is that the shard count is structural. `Guard_shard_count` exists so that
if the chunk arithmetic is ever edited into producing more than five shards, the run
fails loudly instead of reviewing four-fifths of the blocklist and reporting "clean".

## The filter

Two independent reasons for an IP to become a finding. Both are driven by
**Logic App parameters**, passed to the function on every call — change them in the
ARM parameters file (or in the portal, *Logic app* → *Parameters*) and redeploy the
workflow. **No function-code change or code redeploy is needed to change the
criteria.**

| Parameter | Default | Meaning |
| --- | --- | --- |
| `VendorKeywords` | `["lufthansa", "lido", "sita aero"]` | Matched against the AbuseIPDB `isp`, `domain` and `hostnames` of each IP |
| `ExtraInternalCidrs` | `[]` | Extra CIDRs counted as internal on top of the built-in private space |

**Vendor matching is whole-word over normalised text.** Both the keyword and the
haystack are lower-cased and every run of non-alphanumerics collapses to a single
space, so `SITA.aero`, `sita-aero.net` and `sita aero` all match the keyword
`sita aero`. Word boundaries are what keep a four-letter keyword usable: a plain
substring test for `lido` would also fire on `Lidonet Communications` and
`solido.com`. Verified both ways in the test suite.

Worth considering as additions once you see the first ticket: `lhsystems`
(Lufthansa Systems' own domain does **not** contain the string "lufthansa") and any
other partner whose traffic keeps landing on the EDL.

**Internal matching is real CIDR arithmetic**, not the prefix-string tables the
Logic-App-only playbooks have to use — the function has Python's `ipaddress`
module. `1.10.0.1`, `172.15.x`, `172.32.x` and `193.168.x` are correctly *not*
internal, which a naive `startsWith` gets wrong.

Note that `ipaddress.is_private` spans the whole IANA special-purpose registry, not
only RFC1918: loopback, link-local, CGNAT (`100.64/10`), TEST-NET (`192.0.2/24`,
`198.51.100/24`, `203.0.113/24`), benchmarking (`198.18/15`) and the IPv6
equivalents are all internal for our purposes. None of them belong on an EDL, so
flagging them is the point.

**Internal addresses are never sent to AbuseIPDB** — same discipline as commit
`aec4657` on the TI handler. They are findings on their own merit, so their
Abuse Confidence Score column reads `n/a`.

## The ticket

Project `CLOPSSEC`, issue type `Task`, summary
`Blocklist review - <blob> - <yyyy.MM.dd>`, assigned to `secops`. A fresh create via
`POST /rest/api/2/issue` — no clone dance, because a CLOPSSEC Task has no
`customfield_24305` (Assets) requirement, unlike the OPSLSY changes the other
playbooks raise.

Description:

```
The following IPs should be reviewed in index.html:

||IP||vendor||Abuse Confidence Score||
|193.142.145.12|lufthansa|0|
|10.34.2.7|internal|n/a|

----
Source: lsyweuritcsprdmspalo001/$web/index.html — 812 entr(ies) scanned, 799 checked
against AbuseIPDB, 4 skipped (public CIDR ranges), 0 unparseable, 1 lookup error(s).
Filter: vendor keywords [lufthansa, lido, sita aero] matched whole-word against the
AbuseIPDB ISP, domain and hostnames, plus private (RFC1918 and friends) address space.
Internal addresses are never sent to AbuseIPDB, so their score reads n/a.
Raised automatically by the blob-review Logic App, run 08584...
```

Two deliberate departures from the format as originally specified:

- **The table header is Jira wiki markup (`||…||`), not a Markdown `|---|`
  separator row.** Trackspace renders wiki markup in plain-text descriptions; a
  Markdown separator row would render as a literal fourth table row. Same three
  columns, same order, same lead sentence.
- **The footer below the rule is an addition.** Without it a run that could not
  reach AbuseIPDB for some IPs, or that skipped CIDR entries, would produce a
  ticket indistinguishable from a complete one. The counts make the coverage of
  each run explicit.

`Assign_ticket` is a separate `PUT …/assignee` whose failure is tolerated
(`Compose_run_result` runs after `Succeeded`/`Failed`/`TimedOut`), so a stale
assignee name can never cost you the ticket itself. `Compose_run_result.assigned`
records whether it landed.

**Every run with a finding opens a new ticket.** There is no dedupe against
existing open tickets, so re-running before the blocklist is cleaned produces
duplicates by design.

## The function

`function/function_app.py`, one HTTP-triggered endpoint, `POST /api/enrich-ips`,
function-key auth. It is stateless, read-only and idempotent.

Request:

```json
{
  "shard": 1,
  "ips": ["1.2.3.4", "10.0.0.0/8"],
  "vendorKeywords": ["lufthansa", "lido", "sita aero"],
  "extraInternalCidrs": [],
  "maxAgeInDays": 90,
  "concurrency": 10
}
```

### Where the AbuseIPDB key lives

**Nowhere on the function app.** It is a Key Vault secret that only the *Logic App*
reads; it reaches the function as `Authorization: Bearer <key>` on each shard call
and lives in that invocation's memory. The Function App therefore has **no managed
identity, no Key Vault reference and no access to any Azure resource** — the only
new grant this playbook needs is `get` on secrets for the Logic App, the same
change every other playbook here already makes.

Four things keep the key out of the logs:

1. **`Get_AbuseIPDB_key` secures both inputs and outputs.** The secret never
   appears in its own run-history entry.
2. **Each `Enrich_shard_*` action secures its inputs**, so the outgoing request —
   headers included — is hidden in run history and not returned by the Logic Apps
   management API.
3. **The key rides in `Authorization`, which Logic Apps redacts from run history by
   default** even without (2). That is why it is a bearer token rather than a body
   field or a custom header.
4. **Secured data is never emitted to Log Analytics or Application Insights**, so
   turning on diagnostic settings can't leak it, and secured actions can't carry
   tracked properties.

Two rules the design depends on, both from
[*Secure access and data for workflows*](https://learn.microsoft.com/azure/logic-apps/logic-apps-securing-a-logic-app#access-to-run-history-data):

- **Never route the key through `Compose`, `Parse JSON` or `Response`.** Those
  actions propagate obfuscation only one hop — anything downstream of *them* is
  shown in the clear. `Get_AbuseIPDB_key` feeds the five HTTP actions directly for
  exactly this reason.
- **Securing inputs does not secure outputs.** The shard responses are deliberately
  left visible (they hold findings and counts, no credential).

On the function side the key is read once into a local and never logged; the
handler logs only the shard number and the counts, and the 401 for a missing key
names no value. App Service HTTP logs record the URL and status, not headers, and
Application Insights does not capture request headers by default.

`ABUSEIPDB_API_KEY` survives as a local-development fallback only — it is not set
on the deployed app. A request with neither header nor setting gets **401**, never
an empty "all clear".

Response carries **findings only** in `results`, plus a `counts` object that always
holds the true totals — the `skipped` / `invalid` / `errors` arrays are capped at
100 entries each (with `truncated: true`), but the counts never are, so a capped
array can't hide how much was dropped.

Per-lookup handling: up to 4 attempts, honouring `Retry-After` on 429 and backing
off on 5xx. An IP whose lookup never succeeds lands in `errors` and is counted, not
silently treated as clean.

| App setting | Default | |
| --- | --- | --- |
| `ABUSEIPDB_MAX_CONCURRENCY` | `10` | Fallback when the caller omits `concurrency` |
| `ABUSEIPDB_MAX_AGE_DAYS` | `90` | Fallback when the caller omits `maxAgeInDays` |
| `ABUSEIPDB_TIMEOUT_SECONDS` | `30` | Per-request timeout |
| `ABUSEIPDB_MAX_ATTEMPTS` | `4` | Attempts per IP |

### Tests

`function/tests/test_function_app.py` stubs `azure.functions` and `httpx`, so it
runs against a bare interpreter with nothing installed:

```bash
cd function && python3 tests/test_function_app.py
```

It pins the two behaviours that are easy to get quietly wrong — whole-word vendor
matching (`Lidonet`, `solido.com` and `Sitawi` must **not** match; `SITA.aero` and
`sita-aero.net` must) and internal classification (`1.10.0.1`, `172.15.x`,
`172.32.x`, `193.168.x` are **not** internal) — plus the response shape the Logic
App parses.

### Throughput ceiling

Azure's load balancer cuts an HTTP-triggered function at ~230 s regardless of
`functionTimeout`, and `Enrich_shard_*` is capped at `PT4M`. At 10 in-flight
lookups and a ~300 ms AbuseIPDB round trip that is roughly 7,000 IPs per shard —
about 35,000 across the five, far above any realistic EDL. If the blocklist ever
approaches that, raise `EnrichmentConcurrency` before adding shards.

Mind the AbuseIPDB plan quota: five shards × `EnrichmentConcurrency` is the
concurrent request count the gateway sees (50 at the defaults), and one run costs
one lookup per public single address on the list.

## Parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `PlaybookName` | `blob-review` | Pass explicitly on every deploy |
| `FunctionAppName` | `lsy-weur-itcs-prd-blobreview-func` | Globally unique |
| `FunctionStorageAccountName` | `lsyweuritcsprdblobrev01` | Function runtime only; holds no security data. Globally unique, ≤24 lowercase alphanumerics |
| `Location` | `westeurope` | |
| `KeyVaultName` | `LSY-WEUR-ITCS-PRD-KV-02` | Trackspace password **and** AbuseIPDB key |
| `AbuseIPDBKeyVaultSecretName` | `abuseipdb-api-key` | Read by the **Logic App**, passed to the function as a bearer token — see Deploy |
| `AppInsightsWorkspaceResourceId` | `…/workspaces/LSY-PRD-OMS` | Backs the function's Application Insights |
| `JIRAHOST` / `JIRAUserName` / `JiraKeyVaultSecretName` | `https://trackspace.lhsystems.com` / `sentinelsvc` / `sentinelsvc` | |
| `JiraProjectKey` / `JiraIssueTypeName` | `CLOPSSEC` / `Task` | |
| `TicketAssigneeName` | `secops` | Jira **login**, not an email |
| `TicketSummary` | `Blocklist review` | ` - <blob> - yyyy.MM.dd` is appended |
| `StorageAccountName` / `BlocklistContainer` / `BlocklistBlobPath` | `lsyweuritcsprdmspalo001` / `$web` / `index.html` | The blob under review; overridable per run via the request body |
| `EnrichmentConcurrency` | `10` | In-flight lookups **per shard** |
| `AbuseIPDBMaxAgeInDays` | `90` | |
| `VendorKeywords` | `lufthansa`, `lido`, `sita aero` | See *The filter* |
| `ExtraInternalCidrs` | `[]` | See *The filter* |

## Deploy

Two steps: ARM for the infrastructure, then the function code (ARM cannot carry a
Python payload).

```bash
RG=LSY_WEUR_ITCS_PRD_SEC_RG_002
az deployment group create \
  --resource-group "$RG" \
  --template-file playbook/azuredeploy.json \
  --parameters @playbook/azuredeploy.parameters.json
```

The template creates the function's runtime storage account, a Y1 (Consumption)
Linux plan, the Application Insights component, the Function App, the Key Vault API
connection and the Logic App. It reads the function's host key with `listKeys()` at
deploy time and injects it into the workflow's `EnrichmentFunctionKey`
**securestring** parameter, so no key is ever committed here. The Function App is
created **without a managed identity** — it needs no access to anything.

Then the code:

```bash
cd function
func azure functionapp publish lsy-weur-itcs-prd-blobreview-func --python
```

(or `az functionapp deployment source config-zip -g "$RG" -n <app> --src <zip>`).

### One-time prerequisites

Only the Logic App's managed identity needs anything. The Function App has no
identity at all.

1. **Key Vault access for the Logic App.** The vault is in **access-policy mode**
   (`EnableRbacAuthorization=False`), so the `Key Vault Secrets User` RBAC role is
   inert. Grant with a policy, not a role assignment:

   ```powershell
   Set-AzKeyVaultAccessPolicy -VaultName LSY-WEUR-ITCS-PRD-KV-02 `
     -ObjectId <LogicAppPrincipalId> -PermissionsToSecrets get
   ```

   `LogicAppPrincipalId` is a template output. This one policy covers both secrets
   the playbook reads — the Trackspace password and the AbuseIPDB key.
2. **Blob read for the Logic App.** Grant the same identity **Storage Blob Data
   Reader** on `lsyweuritcsprdmspalo001`. Reader is sufficient; this playbook never
   writes.
3. **The AbuseIPDB key must exist as a Key Vault secret**, named by
   `AbuseIPDBKeyVaultSecretName` (default `abuseipdb-api-key`). The other playbooks
   reach AbuseIPDB through the OMS-owned `abuseipdbapi-1` API connection, which
   seals the key away where nothing can read it back — so the raw key has to be
   available in the vault for this playbook. Point the parameter at whatever the
   secret is actually called.

## Run it

```bash
# trigger URL: Logic app → Overview → Workflow URL (carries the SAS signature)
curl -X POST "<workflow-url>" -H 'Content-Type: application/json' -d '{}'

# or point it at a different blob for a one-off
curl -X POST "<workflow-url>" -H 'Content-Type: application/json' \
     -d '{"container": "$web", "blobPath": "index.html"}'
```

Returns `202` with the run id. Watch the run in *Logic app* → *Run history*;
`Compose_run_result` (or `Compose_no_findings`) holds the outcome.

## Sync / acceptance

`playbook/workflow.json` and `playbook/azuredeploy.json` must not drift:

```bash
diff <(jq -S '.definition.actions' playbook/workflow.json) \
     <(jq -S '.resources[]|select(.type=="Microsoft.Logic/workflows")|.properties.definition.actions' playbook/azuredeploy.json)
diff <(jq -S '.definition.triggers' playbook/workflow.json) \
     <(jq -S '.resources[]|select(.type=="Microsoft.Logic/workflows")|.properties.definition.triggers' playbook/azuredeploy.json)
```

Both must be empty. The only permitted residual `jq -S` difference between the two
files is the parameter `defaultValue`s — literals in `workflow.json`,
`[parameters('…')]` / `listKeys(…)` / `reference(…)` in ARM.

A test run against a blocklist containing at least one Lufthansa/LIDO/SITA address
and one RFC1918 address should produce exactly one CLOPSSEC Task assigned to
`secops`, whose description names the blob, lists both addresses in the wiki-markup
table with `n/a` on the internal one, and whose footer reports `0 unparseable` and
`0 lookup error(s)`.

Logic App runs are immutable: after a redeploy, cancel any stuck in-flight runs and
fire fresh ones.
