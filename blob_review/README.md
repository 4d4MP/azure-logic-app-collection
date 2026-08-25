# Blob review — blocklist IP review

**Logic App:** `blob-review` (Consumption) in `LSY_WEUR_ITCS_PRD_SEC_RG_002`.
**Function App:** `lsy-weur-itcs-prd-blobreview-func` (Linux Consumption, **Node 20**, Durable Functions).
**Source of truth:** `playbook/workflow.json` + `playbook/azuredeploy.json` + `function/`.
**Trigger:** HTTP request, by hand, on demand. No schedule, no Sentinel incident.

The other playbooks in this collection *write* to the Palo Alto EDL blob
(`lsyweuritcsprdmspalo001/$web/index.html`). This one *reviews* it: it reads every
entry, runs a set of pluggable rules over it, and raises a **CLOPSSEC** Task naming
every address that should not be on the list — with the blob line each one sits on.

It is read-only against the blob. It never removes an entry; a human does that after
reading the ticket.

## Flow

```
HTTP POST (by hand; optional {"container": "...", "blobPath": "..."})
  → Capture_run_start
  → Resolve_blob_target        request body overrides the parameters
  → Respond_accepted           202 + run id immediately; the review runs on
  → Get_blocklist_blob         GET the EDL over managed identity
  → Check_blocklist_not_empty
       ├─ empty → Terminate Failed (a blank EDL is a fetch fault, not an all-clear)
       └─ content
            → Run_review              ONE HTTP POST to the Durable starter
            → Capture_run_end
            → Compose_review
            → Guard_review_completed  not Completed ⇒ Terminate Failed
            → Get_Jira_password       Key Vault, secured in + out
            → Jira_health_check
            → Create_CLOPSSEC_ticket  ALWAYS, findings or not
            → Parse_ticket_response
            → Findings_attachment_gate
                 └─ findings > 0 → Attach_findings_CSV
            → Assign_ticket           best effort, tolerated
            → Guard_lookup_errors
                 ├─ errors > MaxLookupErrors → Terminate Failed
                 └─ Compose_run_result
```

Sixteen billed actions per run, whatever the blocklist's size.

`Respond_accepted` returns **202** before the review starts, so the caller never waits
on a multi-minute run. The result lives in the run history and in the ticket.

### Why one action and not thirty thousand

A `Foreach` with an HTTP action inside it bills one action execution *per address*.
At ~30,000 entries that is 30,000 billed actions per run. Everything expensive
therefore happens inside the Function App, and the Logic App's job is to fetch the
blob, make one call, and raise the ticket.

That one call cannot be a plain synchronous request. **An HTTP-triggered function is
cut off at 230 seconds by the Azure load balancer regardless of `functionTimeout`**
([docs](https://learn.microsoft.com/azure/azure-functions/functions-scale#function-app-timeout-duration)),
and 30,000 lookups at 50 concurrent and ~300 ms each is roughly 180 seconds of pure
API time before a single retry.

So the runner is a **Durable Functions orchestration**. Its HTTP starter returns
`202` with a `Location` header, and the Logic App's HTTP action follows that header
using its [built-in asynchronous
pattern](https://learn.microsoft.com/azure/durable-task/durable-functions/durable-functions-http-features#expose-http-apis)
— Microsoft documents exactly this embedding. Polling happens inside the single
action, so a review of any length stays one billed action with no time ceiling.

`Run_review` sets `retryPolicy: none` on purpose. The default retry policy would
re-POST the starter on a transient failure and launch a **second** orchestration,
doubling the AbuseIPDB spend for that run.

**Logic Apps' Inline Code action cannot do this job.** In Consumption, *Execute
JavaScript Code* is capped at 1,024 characters, 5 seconds of run time, and does not
support `require()`
([limits](https://learn.microsoft.com/azure/logic-apps/logic-apps-limits-and-config#inline-code-action-limits)).
It cannot make an HTTP request, let alone thirty thousand.

## The rules

`function/src/lib/rules.js` holds a registry. **Adding a criterion is one object in
that array plus one key in the `ReviewRules` parameter** — nothing else in the
codebase knows the rules by name.

Each rule declares a stage:

- **`pre`** — evaluated on the raw entry, before AbuseIPDB. A `terminal` pre rule
  ends evaluation for that entry, so it is **never sent to AbuseIPDB** and costs no
  API quota. This is what implements "filter out the internal and typoed IPs first,
  the rest go through AbuseIPDB".
- **`post`** — evaluated after enrichment, against the AbuseIPDB record. All post
  rules run, so one address can carry several reasons.

| Rule | Stage | Default | Flags |
| --- | --- | --- | --- |
| `malformed` | pre, terminal | **on** | Anything that is not a valid IPv4/IPv6 address or CIDR — typos |
| `internal` | pre, terminal | **on** | Private and other non-routable space |
| `duplicate` | pre, terminal | **on** | An address that already appeared on an earlier line — the **later copy** is flagged for removal |
| `whitelistedIsp` | post | **on** | An ISP on the whitelist whose abuse confidence score is **below** `maxScore` |

Configuration is the **`ReviewRules` Logic App parameter**, passed to the function on
every call. Change it in the ARM parameters file (or in the portal, *Logic app* →
*Parameters*) and redeploy the workflow. **No function code change and no code
redeploy is needed to change the criteria.** A key that matches no rule is rejected
with a 400 rather than ignored, so a typo cannot silently disable a rule and report a
clean blocklist.

```json
"ReviewRules": {
  "internal":       { "enabled": true, "extraCidrs": [], "extraPatterns": [] },
  "malformed":      { "enabled": true },
  "duplicate":      { "enabled": true },
  "whitelistedIsp": { "enabled": true, "maxScore": 80,
                      "isps": ["akamai technologies", "google", "palo alto networks",
                               "the shadowserver foundation", "censys",
                               "lufthansa", "lido", "sita aero"] }
}
```

The first five ISPs are the `ExcludedISPs` list shared by `ti_handling_automation`
and `malformed_user_agents_handler`; the last three are the partner keywords this
playbook previously carried. Worth adding once you see the first ticket:
**`lhsystems`** — Lufthansa Systems' own domain does not contain the string
"lufthansa".

### Duplicates

A repeated address is flagged **once, on the later line**, with a reason naming the
line the first copy sits on: `duplicate entry - this address is already on line 45;
remove this copy`. Flagging every occurrence would leave nobody knowing which one to
delete, so the earliest is always the keeper.

Matching is on the **canonical** address, so `1.2.3.4` and `1.2.3.4/32` are the same
entry, as are `2001:db8::1` and `2001:0db8:0000:0000:0000:0000:0000:0001`.

The rule is terminal: the first copy is already queued for enrichment, so looking the
repeat up again would spend a second AbuseIPDB call on an address that is going to be
deleted either way. The consequence is that a duplicate row's AbuseIPDB columns read
`n/a` — the enrichment lives on the row for the first copy. An address that is *both*
a duplicate and, say, internal carries both reasons.

Malformed lines have no canonical form and are skipped by this rule: a repeated typo is
reported as malformed on each line it appears on, which is what needs fixing anyway.

### The score gate

`whitelistedIsp` flags an address only when its AbuseIPDB confidence score is
**strictly below** `maxScore` (default 80). At or above the threshold the address has
earned its place on the blocklist: whitelisted ISP or not, it stays blocked and is not
reported. A missing score counts as `0`, so an ISP match with no reputation data is
flagged rather than waved through.

### ISP matching is whole-word over normalised text

Both the keyword and the haystack (the AbuseIPDB `isp`, `domain` and `hostnames`) are
lower-cased and every run of non-alphanumerics collapses to a single space. So one
keyword `sita aero` matches `SITA.aero`, `sita-aero.net` and `SITA AERO`, and
`palo alto networks` matches AbuseIPDB's `Palo Alto Networks, Inc` — the other two
playbooks need a *substring* match for that last case, and pay for it in false
positives.

Word boundaries are what keep a four-letter keyword usable: a plain substring test for
`lido` also fires on `Lidonet Communications` and `solido.com`. Both directions are
pinned in the test suite.

### Internal matching is CIDR arithmetic, not a regex

`function/src/lib/ipaddr.js` reimplements the part of Python's `ipaddress` module this
playbook used to rely on, with `BigInt`, for both address families and with no
dependency.

A regex over dotted quads gets `172.16.0.0/12` wrong almost every time — it has to
match `172.16.`–`172.31.` and must *not* match `172.15.` or `172.32.`. That is why
`malformed_user_agents_handler` carries a 25-entry `LocalIPPrefixes` string table: a
Logic App has no better option, and a Node runner does. `1.10.0.1`, `172.15.x`,
`172.32.x` and `193.168.x` are correctly **not** internal here, which a `startsWith`
table gets wrong.

"Internal" spans the whole IANA special-purpose registry, not only RFC1918: loopback,
link-local, CGNAT (`100.64/10`), TEST-NET (`192.0.2/24`, `198.51.100/24`,
`203.0.113/24`), benchmarking (`198.18/15`), reserved (`240/4`) and the IPv6
equivalents. None of them belong on an EDL, so flagging them is the point.

Two escape hatches, both parameters:

- **`extraCidrs`** — additional ranges counted as internal.
- **`extraPatterns`** — regular expressions matched against the raw blob entry, for
  when a regex criterion is genuinely what you want. An unparseable or absurdly long
  pattern is dropped rather than failing the run.

Multicast (`224/4`, `ff00::/8`) is deliberately **not** built in, to keep the
classification identical to what this playbook flagged before. Add it with
`"extraCidrs": ["224.0.0.0/4", "ff00::/8"]` — no code change.

### Malformed entries

The EDL is written by the other playbooks as plain newline-separated addresses
(`ti_handling_automation` composes `<existing>\n<new IPs>\n` and PUTs it as a
BlockBlob with `x-ms-blob-content-type: text/html`). Despite the `index.html` name
there is no markup in it, so a line that does not parse is a genuine typo rather than
a stray tag. Blank lines and lines starting with `#`, `//` or `<` are skipped as
comments; everything else must parse.

Parsing is strict on purpose: `999.1.1.1`, `10.0.0`, `1.2.3.4.5`, `192.168.0.256` and
`010.0.0.1` are all malformed. A `/32` or `/128` is treated as a single host.

### Public CIDR ranges

AbuseIPDB's `/check` takes a single address; `/check-block` is a different endpoint
with its own quota. A **public** CIDR range on the list is therefore counted and
reported as skipped rather than dropped or guessed at. A **private** range is still
flagged by the `internal` rule, which does real subnet arithmetic.

## The ticket

**Every run raises one**, findings or not. Project `CLOPSSEC`, issue type `Task`,
assigned to `secops`, created with a plain `POST /rest/api/2/issue` — no clone dance,
because a CLOPSSEC Task has no `customfield_24305` (Assets) requirement, unlike the
OPSLSY changes the other playbooks raise.

**Title:** `index.html IP review.` — the blob's file name plus `TicketSummarySuffix`.

**Description:**

```
Run ID: 08584512345678901234567890
Start: 2026-08-25 09:14
End: 2026-08-25 09:18
Flagged IPs: 7

Coverage: lsyweuritcsprdmspalo001/$web/index.html - 812 entr(ies) read, 4 flagged
before enrichment (internal, malformed or a duplicate copy - never sent to AbuseIPDB),
806 checked against AbuseIPDB, 2 public CIDR range(s) not checked, 0 lookup error(s).
Rules applied:
malformed: entries that are not a valid IPv4/IPv6 address or CIDR (typos)
internal: private / non-routable address space (...)
whitelistedIsp: addresses whose AbuseIPDB ISP, domain or hostnames match [...] with
an abuse confidence score below 80

Raised automatically by the blob-review Logic App. Findings, with the blob line each
one sits on, are in the attachment.
```

The first four lines are the specified format. **Everything from `Coverage:` down is
an addition** — without it, a run that could not reach AbuseIPDB produces
`Flagged IPs: 0` indistinguishable from a genuinely clean scan. Times are
Central European, matching the other playbooks in this collection.

**Attachment**, only when there is something to flag:
`index.html-ip-review-20260825-091800.csv`, one row per finding:

| Column | |
| --- | --- |
| `IP` | Canonical form of the address |
| `Line` | **1-based line number in the blob** |
| `Blob entry` | The text as it actually appears on that line |
| `Rules` | Which rules fired, space-separated |
| `Reason` | Why, in words, joined with `; ` |
| `ISP` / `Domain` / `Hostnames` / `Country` / `Usage type` | AbuseIPDB enrichment |
| `Abuse confidence score` / `Total reports` / `Last reported at` | AbuseIPDB enrichment |

Entries flagged before enrichment have no AbuseIPDB data, so those columns read
`n/a` — never `0`, which would be a real score.

The CSV is built **in the runner**, not in the Logic App: quoting `Palo Alto
Networks, Inc` correctly is trivial in JavaScript and painful in the Workflow
Definition Language. Values that would otherwise begin with `=`, `+`, `-` or `@` are
prefixed with `'`, because AbuseIPDB supplies the ISP text and an operator opens the
result in a spreadsheet.

### Failure behaviour

- **The ticket cannot be created or the attachment cannot be uploaded** → the run
  ends **Failed**, as asked. Neither action tolerates a failure.
- **`Assign_ticket` fails** → tolerated. A stale assignee name can never cost you the
  ticket itself; `Compose_run_result.assigned` records whether it landed.
- **The orchestration ends as anything but `Completed`** → Terminate Failed, no
  ticket. A ticket reading `Flagged IPs: 0` for a review that never finished would be
  worse than no ticket.
- **More than `MaxLookupErrors` (default `0`) addresses fail to resolve against
  AbuseIPDB** → the ticket is raised *first*, with whatever the run did find, and
  *then* the run terminates Failed. Findings are never lost to a partial scan, and
  the run is still visibly red.
- **The blob is empty** → Terminate Failed. A blank EDL is a fetch or format problem.

**Every run opens a new ticket.** There is no dedupe against existing open tickets —
unrelated to the `duplicate` rule, which is about repeated addresses inside the blob —
so re-running before the blocklist is cleaned produces duplicate *tickets* by design.

## The function

`function/`, a Node 20 Durable Functions app. Three functions, and every piece of
logic lives in `src/lib/` as a pure, dependency-free module.

```
startReview        POST /api/start-review, function-key auth
                   parses the blob into entries that remember their line number,
                   runs the pre-stage rules, batches what is left, starts the
                   orchestration and returns 202 + Location
reviewOrchestrator walks the batches one at a time, publishing progress with
                   setCustomStatus, then aggregates and builds the CSV
enrichBatch        one batch against AbuseIPDB with `parallelism` requests in
                   flight, per-lookup retry, then the post-stage rules
```

### How the concurrency is actually bounded

In-flight AbuseIPDB requests equal exactly `EnrichmentParallelism` (50), because:

1. The orchestrator awaits each batch before starting the next, so **one activity
   runs at a time**.
2. That activity holds a fixed pool of `parallelism` workers pulling from a shared
   cursor — a slow lookup delays only itself instead of holding a whole chunk's
   worth of slots idle.
3. `host.json` sets `maxConcurrentActivityFunctions: 1` and the app sets
   `WEBSITE_MAX_DYNAMIC_APPLICATION_SCALE_OUT: 1`, so host scale-out cannot
   silently multiply that number.

Fanning the batches out in parallel would multiply 50 by however many activities the
host chose to run.

Sequencing also buys checkpointing: a host restart resumes at the next batch instead
of re-scanning the blocklist. The cost is roughly 200 ms of Durable queue latency
between batches — about 3 % of wall clock at the defaults.

### Throughput

Activity functions answer to `functionTimeout` (10 minutes on Consumption), **not**
to the 230-second load balancer cut that binds HTTP triggers. At `EnrichmentBatchSize
= 1000` and 50 concurrent lookups a batch finishes in roughly 6 seconds, about 30×
the headroom it needs, and 30,000 addresses take about 30 batches.

Mind the AbuseIPDB plan quota: one run costs one lookup per public single address on
the list, and `EnrichmentParallelism` is the concurrent request count the gateway
sees. Internal and malformed entries cost nothing — they never leave the function.

Per-lookup handling: up to 4 attempts, honouring `Retry-After` on 429 (capped at 30
seconds, so a hostile header cannot park the activity) and backing off on 5xx. A
4xx that is not 429 is not retried. **An address whose lookup never succeeds lands in
`errors` and is counted — never silently treated as clean.**

### Where the AbuseIPDB key lives

**On the Function App, as a Key Vault reference — and this is a deliberate reversal
of how it used to work.**

The previous Python runner held nothing: the Logic App read the key from Key Vault
and passed it as a bearer token, so it lived only in that invocation's memory. That
design does not survive Durable Functions. **Anything passed into an orchestration is
persisted to the task hub's storage account** as part of the replay history, so a key
sent in the request body would be written to disk in the clear.

Instead:

- The Function App has a **system-assigned managed identity** and a Key Vault `get`
  access policy.
- `ABUSEIPDB_API_KEY` is a **Key Vault reference** app setting
  (`@Microsoft.KeyVault(SecretUri=…)`), resolved by the platform at startup.
- Only `enrichBatch` reads it, from `process.env`. It is never a function argument,
  never part of the orchestration input, and never logged.
- `startReview` refuses the request with a 500 if the setting is missing, rather than
  starting a review that would return an empty "all clear".

Net effect: the key now appears in **neither** the Logic App run history **nor** the
Durable replay history. The cost is one extra Key Vault access policy, and the
Function App is no longer credential-free.

The blob text *is* written to Durable's storage as orchestration input. That is fine
— the EDL is served from a public `$web` static site.

The Logic App still secures the inputs of every action that touches a credential
(`Run_review` carries the function key; `Get_Jira_password` secures inputs *and*
outputs; the Jira actions secure inputs), so nothing lands in run history or in Log
Analytics. Two rules the design depends on, both from [*Secure access and data for
workflows*](https://learn.microsoft.com/azure/logic-apps/logic-apps-securing-a-logic-app#access-to-run-history-data):
obfuscation propagates only one hop, so a secret must never be routed through
`Compose` or `Parse JSON`; and securing inputs does not secure outputs. The shard
responses are deliberately left visible — they hold findings and counts, no
credential.

The `Location` URL the starter returns carries the Durable **system key**, which is
why `Run_review` secures its inputs and why the starter returns a minimal 202 rather
than `createCheckStatusResponse` — the latter would also hand back the terminate and
purge-history URLs, which have no business in a run history. It appends
`showInput=false` so the polled response carries the result rather than the entire
plan.

### Tests

`function/tests/` uses Node's built-in `node:test` runner and imports only from
`src/lib/`, which has no dependencies — so the suite runs against a bare interpreter
with nothing installed:

```bash
cd function && node --test tests/*.test.js
```

66 tests pinning the behaviours that fail quietly: whole-word ISP matching in both
directions, internal classification and its near misses, the score gate at exactly
the threshold, malformed detection, line numbers surviving CRLF and comments, CSV
quoting and formula-injection defence, concurrency never exceeding the cap, retry and
`Retry-After` handling, an unresolved lookup never reading as clean, duplicates being
flagged on the later line and matched canonically, rule enable and disable, and batching
not changing the verdict.

## Parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `PlaybookName` | `blob-review` | Pass explicitly on every deploy |
| `FunctionAppName` | `lsy-weur-itcs-prd-blobreview-func` | Globally unique |
| `FunctionStorageAccountName` | `lsyweuritcsprdblobrev01` | Function runtime **and the Durable task hub**. Globally unique, ≤24 lowercase alphanumerics |
| `Location` | `westeurope` | |
| `KeyVaultName` | `LSY-WEUR-ITCS-PRD-KV-02` | Trackspace password **and** AbuseIPDB key |
| `AbuseIPDBKeyVaultSecretName` | `abuseipdb-api-key` | Read by the **function**, via a Key Vault reference — see above |
| `AppInsightsWorkspaceResourceId` | `…/workspaces/LSY-PRD-OMS` | Backs the function's Application Insights |
| `JIRAHOST` / `JIRAUserName` / `JiraKeyVaultSecretName` | `https://trackspace.lhsystems.com` / `sentinelsvc` / `sentinelsvc` | |
| `JiraProjectKey` / `JiraIssueTypeName` | `CLOPSSEC` / `Task` | |
| `TicketAssigneeName` | `secops` | Jira **login**, not an email |
| `TicketSummarySuffix` | `IP review.` | Title is `<blob file name> <suffix>` |
| `StorageAccountName` / `BlocklistContainer` / `BlocklistBlobPath` | `lsyweuritcsprdmspalo001` / `$web` / `index.html` | The blob under review; overridable per run via the request body |
| `EnrichmentParallelism` | `50` | Concurrent AbuseIPDB lookups, **global** |
| `EnrichmentBatchSize` | `1000` | Addresses per activity invocation |
| `AbuseIPDBMaxAgeInDays` | `90` | |
| `MaxFindings` | `5000` | Caps the findings array and the CSV. The reported count is never capped, so truncation stays visible |
| `MaxLookupErrors` | `0` | Above this the run ends Failed — after the ticket is raised |
| `ReviewRules` | see *The rules* | The modular knob |

The async polling limit on `Run_review` is a literal `PT30M` in the action rather
than a parameter, because `limit.timeout` is a static property of the action schema
and not a reliable place for an expression. Edit it in `workflow.json` and
`azuredeploy.json` together if a review ever needs longer.

## Deploy

Two steps, because ARM cannot carry a JavaScript payload: the template stands up the
infrastructure, then the function code is published separately. Both scripts below do
both halves — take `deploy.sh` for bash or `deploy.ps1` for PowerShell, whichever
matches your shell. They are equivalent; run one, not both.

The template creates the function's storage account (runtime **and** Durable task
hub), a Y1 (Consumption) Linux plan, the Application Insights component, the Function
App **with a system-assigned identity**, the Key Vault API connection and the Logic
App. It reads the function's host key with `listKeys()` at deploy time and injects it
into the workflow's `EnrichmentFunctionKey` **securestring** parameter, so no key is
ever committed here.

### The working directory

Save whichever script you pick next to the files it names and run it from that
directory — neither takes any paths, so copying the artifacts flat into a working
directory (a Cloud Shell folder, say) is all the setup there is:

```
azuredeploy.json   azuredeploy.parameters.json     <- from playbook/
package.json       host.json   .funcignore         <- from function/
src/                                               <- from function/ (whole directory)
```

From a clone that is:

```bash
mkdir -p ~/blob-review-deploy && cd ~/blob-review-deploy
cp <repo>/blob_review/playbook/azuredeploy.json \
   <repo>/blob_review/playbook/azuredeploy.parameters.json \
   <repo>/blob_review/function/package.json \
   <repo>/blob_review/function/host.json \
   <repo>/blob_review/function/.funcignore .
cp -r <repo>/blob_review/function/src .
# then save deploy.sh here too
chmod +x deploy.sh && ./deploy.sh
```

Or in PowerShell:

```powershell
New-Item -ItemType Directory -Force ~/blob-review-deploy | Out-Null
Set-Location ~/blob-review-deploy
$repo = '<repo>'
Copy-Item "$repo/blob_review/playbook/azuredeploy.json",
          "$repo/blob_review/playbook/azuredeploy.parameters.json",
          "$repo/blob_review/function/package.json",
          "$repo/blob_review/function/host.json",
          "$repo/blob_review/function/.funcignore" -Destination .
Copy-Item "$repo/blob_review/function/src" -Destination . -Recurse
# then save deploy.ps1 here too
./deploy.ps1
```

`.funcignore` is in the list on purpose: it keeps the two ARM files out of the
published function package now that everything shares one directory.

### `deploy.sh` — bash

```bash
#!/usr/bin/env bash
#
# blob-review — deploy / redeploy. Safe to re-run; the ARM deployment is
# incremental and the function publish overwrites in place.
#
# Run it from a directory holding these files and nothing else required:
#   azuredeploy.json   azuredeploy.parameters.json
#   package.json       host.json   .funcignore   src/
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

# --- preflight --------------------------------------------------------------
missing=()
for f in azuredeploy.json azuredeploy.parameters.json \
         package.json host.json .funcignore; do
  [[ -f "$f" ]] || missing+=("$f")
done
[[ -d src ]] || missing+=("src/")
(( ${#missing[@]} == 0 )) || fail "missing from $PWD: ${missing[*]}"

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
  --template-file azuredeploy.json \
  --parameters @azuredeploy.parameters.json \
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
step "Publishing function code to $FUNC_APP"
if command -v func >/dev/null; then
  func azure functionapp publish "$FUNC_APP"
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

# --- done -------------------------------------------------------------------
step "Deployed"
cat <<EOF
  Logic App        $LOGIC_APP   ($LOGIC_PRINCIPAL)
  Function App     $FUNC_APP    ($FUNC_PRINCIPAL)

The trigger URL carries its own SAS signature — treat it as a credential, so it
is deliberately not printed here. Fetch it with:

  az rest --method post --query value -o tsv --url \\
    "https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.Logic/workflows/$LOGIC_APP/triggers/manual/listCallbackUrl?api-version=2016-06-01"

Then fire a review:

  curl -X POST "<trigger-url>" -H 'Content-Type: application/json' -d '{}'

Logic App runs are immutable: cancel anything left in flight from before this
redeploy before firing a fresh run.
EOF
```

### `deploy.ps1` — PowerShell

The same deployment for PowerShell — Azure Cloud Shell in PowerShell mode, Windows
PowerShell 5.1, or PowerShell 7 anywhere. Save it in the working directory described
above and run `./deploy.ps1` (or `./deploy.ps1 -Grant`). Override the target with the
`-ResourceGroup` and `-Subscription` parameters, or the `RG` / `SUBSCRIPTION`
environment variables.

```powershell
<#
    blob-review - deploy / redeploy. Safe to re-run; the ARM deployment is
    incremental and the function publish overwrites in place.

    Run it from a directory holding these files and nothing else required:
      azuredeploy.json   azuredeploy.parameters.json
      package.json       host.json   .funcignore   src/

      ./deploy.ps1          deploy infrastructure, then publish the function code
      ./deploy.ps1 -Grant   also grant the three permissions the playbook needs
                            (Key Vault get for the Logic App, Key Vault get for the
                            function identity, blob read for the Logic App). Omit if
                            access goes through a separate change; the script prints
                            the exact commands either way.

    Needs the Azure CLI. Azure Functions Core Tools (func) is used when it is on
    PATH, otherwise the script falls back to npm + Compress-Archive + az zip deploy.
#>
[CmdletBinding()]
param(
    [switch] $Grant,
    [string] $ResourceGroup = $(if ($env:RG) { $env:RG } else { 'LSY_WEUR_ITCS_PRD_SEC_RG_002' }),
    [string] $Subscription  = $(if ($env:SUBSCRIPTION) { $env:SUBSCRIPTION } else { 'f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29' })
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string] $Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Stop-Deploy {
    param([string] $Message)
    Write-Host "`nERROR: $Message" -ForegroundColor Red
    exit 1
}

# $ErrorActionPreference does not apply to native executables, so every az call
# is followed by this check. Without it the script sails straight past a failed
# deployment and reports success.
function Assert-Az {
    param([string] $What)
    if ($LASTEXITCODE -ne 0) { Stop-Deploy "$What failed with exit code $LASTEXITCODE" }
}

# --- preflight --------------------------------------------------------------
$missing = @(
    'azuredeploy.json', 'azuredeploy.parameters.json',
    'package.json', 'host.json', '.funcignore'
) | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
if (-not (Test-Path -LiteralPath 'src' -PathType Container)) { $missing += 'src/' }
if ($missing) { Stop-Deploy "missing from $($PWD.Path): $($missing -join ', ')" }

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-Deploy 'the Azure CLI (az) is not on PATH'
}
$null = & az account show --output none 2>&1
if ($LASTEXITCODE -ne 0) { Stop-Deploy "not signed in - run 'az login' first" }

Write-Step 'Subscription'
& az account set --subscription $Subscription
Assert-Az 'az account set'
& az account show --query '{subscription:name, id:id}' --output tsv
Assert-Az 'az account show'

# --- 1. infrastructure ------------------------------------------------------
# PlaybookName comes from the parameters file and must stay set, or a redeploy
# stands up a parallel Logic App with a fresh managed identity.
$deployment = "blob-review-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
Write-Step "Deploying ARM template as $deployment"
# '@azuredeploy.parameters.json' must stay quoted: bare @ starts PowerShell's
# splatting operator and the file reference would never reach the CLI.
& az deployment group create `
    --name $deployment `
    --resource-group $ResourceGroup `
    --template-file azuredeploy.json `
    --parameters '@azuredeploy.parameters.json' `
    --output none
Assert-Az 'az deployment group create'

$json = & az deployment group show `
    --name $deployment --resource-group $ResourceGroup `
    --query 'properties.outputs' --output json
Assert-Az 'az deployment group show'
$outputs = ($json -join "`n") | ConvertFrom-Json

$logicApp       = $outputs.logicAppName.value
$logicPrincipal = $outputs.logicAppPrincipalId.value
$funcApp        = $outputs.functionAppName.value
$funcPrincipal  = $outputs.functionAppPrincipalId.value
$keyVault       = $outputs.keyVaultName.value
$blobAccount    = $outputs.blocklistStorageAccountName.value

$resolved = [ordered]@{
    logicAppName                = $logicApp
    logicAppPrincipalId         = $logicPrincipal
    functionAppName             = $funcApp
    functionAppPrincipalId      = $funcPrincipal
    keyVaultName                = $keyVault
    blocklistStorageAccountName = $blobAccount
}
foreach ($entry in $resolved.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($entry.Value)) {
        Stop-Deploy "deployment output $($entry.Key) came back empty"
    }
}

# --- 2. access, before the code ---------------------------------------------
# The function resolves ABUSEIPDB_API_KEY from Key Vault at startup, so the
# access policy has to exist before the app starts, or every invocation 500s.
if ($Grant) {
    Write-Step "Granting Key Vault get to $logicApp and $funcApp"
    # Access-policy vault: the Key Vault Secrets User RBAC role would be inert.
    & az keyvault set-policy --name $keyVault --object-id $logicPrincipal --secret-permissions get --output none
    Assert-Az 'az keyvault set-policy (Logic App)'
    & az keyvault set-policy --name $keyVault --object-id $funcPrincipal --secret-permissions get --output none
    Assert-Az 'az keyvault set-policy (Function App)'

    Write-Step "Granting Storage Blob Data Reader on $blobAccount to $logicApp"
    $blobScope = & az storage account show --name $blobAccount --query id --output tsv
    Assert-Az 'az storage account show'
    & az role assignment create `
        --assignee-object-id $logicPrincipal --assignee-principal-type ServicePrincipal `
        --role 'Storage Blob Data Reader' --scope $blobScope --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  (role assignment already present, or insufficient rights)'
    }
}
else {
    $blobScope = & az storage account show --name $blobAccount --query id --output tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $blobScope) { $blobScope = "<resource id of $blobAccount>" }
    Write-Step 'Access NOT granted - run with -Grant, or pass these on'
    Write-Host "  az keyvault set-policy --name $keyVault --object-id $logicPrincipal --secret-permissions get"
    Write-Host "  az keyvault set-policy --name $keyVault --object-id $funcPrincipal --secret-permissions get"
    Write-Host "  az role assignment create --assignee-object-id $logicPrincipal --assignee-principal-type ServicePrincipal --role 'Storage Blob Data Reader' --scope $blobScope"
}

# --- 3. function code -------------------------------------------------------
# ARM cannot carry a JavaScript payload, so the code is a separate step.
Write-Step "Publishing function code to $funcApp"
if (Get-Command func -ErrorAction SilentlyContinue) {
    & func azure functionapp publish $funcApp
    if ($LASTEXITCODE -ne 0) { Stop-Deploy "func azure functionapp publish failed with exit code $LASTEXITCODE" }
}
else {
    Write-Host 'Azure Functions Core Tools not found; falling back to az zip deploy.'
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Stop-Deploy "neither 'func' nor 'npm' is available"
    }
    & npm install --omit=dev --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { Stop-Deploy "npm install failed with exit code $LASTEXITCODE" }

    $zip = Join-Path ([System.IO.Path]::GetTempPath()) "blob-review-$([Guid]::NewGuid().ToString('N')).zip"
    try {
        # Windows PowerShell 5.1 can trip over node_modules paths beyond 260
        # characters here; PowerShell 7, or installing 'func', avoids it.
        Compress-Archive -Path package.json, host.json, src, node_modules -DestinationPath $zip -Force
        & az functionapp deployment source config-zip `
            --resource-group $ResourceGroup --name $funcApp --src $zip --output none
        Assert-Az 'az functionapp deployment source config-zip'
    }
    finally {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    }
}

# --- done -------------------------------------------------------------------
Write-Step 'Deployed'
@"
  Logic App        $logicApp   ($logicPrincipal)
  Function App     $funcApp    ($funcPrincipal)

The trigger URL carries its own SAS signature - treat it as a credential, so it
is deliberately not printed here. Fetch it with:

  az rest --method post --query value -o tsv --url "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$logicApp/triggers/manual/listCallbackUrl?api-version=2016-06-01"

Then fire a review:

  Invoke-RestMethod -Method Post -Uri "<trigger-url>" -ContentType 'application/json' -Body '{}'

Logic App runs are immutable: cancel anything left in flight from before this
redeploy before firing a fresh run.
"@ | Write-Host
```

Re-running is the redeploy path — the ARM deployment is incremental and the function
publish overwrites in place. The resource group and subscription can be overridden
(`RG` / `SUBSCRIPTION` in the environment for either script, or `-ResourceGroup` /
`-Subscription` on the PowerShell one); everything else comes from
`azuredeploy.parameters.json` and the deployment's own outputs, so neither script can
drift from the template.

Three PowerShell details worth knowing, since each one fails quietly if you edit the
script:

- **`$ErrorActionPreference = 'Stop'` does not apply to native executables.** Every
  `az` call is followed by an explicit `$LASTEXITCODE` check; without them the script
  would run past a failed deployment and report success.
- **`'@azuredeploy.parameters.json'` must stay quoted.** A bare `@` starts
  PowerShell's splatting operator, and the file reference never reaches the CLI.
- **`curl` is an alias for `Invoke-WebRequest` in Windows PowerShell 5.1**, which does
  not accept `-X` or `-d`. The script prints an `Invoke-RestMethod` line instead.

The grant step runs **before** the code publish on purpose: the function resolves
`ABUSEIPDB_API_KEY` from Key Vault when the app starts, so without the access policy
in place every invocation fails.

### One-time prerequisites

1. **Key Vault access for the Logic App.** The vault is in **access-policy mode**
   (`EnableRbacAuthorization=False`), so the `Key Vault Secrets User` RBAC role is
   inert — it must be an access policy. The Logic App reads the Trackspace password.
2. **Key Vault access for the Function App.** Same vault, same mechanism, for the
   AbuseIPDB key. **New in this version** — see *Where the AbuseIPDB key lives*.
3. **Blob read for the Logic App.** **Storage Blob Data Reader** on
   `lsyweuritcsprdmspalo001`. Reader is sufficient; this playbook never writes.
4. **The AbuseIPDB key must exist as a Key Vault secret**, named by
   `AbuseIPDBKeyVaultSecretName` (default `abuseipdb-api-key`). The other playbooks
   reach AbuseIPDB through the OMS-owned `abuseipdbapi-1` API connection, which seals
   the key away where nothing can read it back — so the raw key has to be available
   in the vault for this playbook. Point the parameter at whatever the secret is
   actually called.

`./deploy.sh --grant` — or `./deploy.ps1 -Grant` — does 1–3 against the identities the
deployment just created. Without it, either script prints the three commands with the
real object ids substituted, to hand to whoever holds the rights.

## Run it

```bash
# trigger URL: Logic app → Overview → Workflow URL (carries the SAS signature)
curl -X POST "<workflow-url>" -H 'Content-Type: application/json' -d '{}'

# or point it at a different blob for a one-off
curl -X POST "<workflow-url>" -H 'Content-Type: application/json' \
     -d '{"container": "$web", "blobPath": "index.html"}'
```

Returns `202` with the run id. Watch the run in *Logic app* → *Run history*;
`Compose_run_result` holds the outcome, including the ticket URL, the scan counts and
the blob's ETag and Last-Modified at the moment it was read — so a ticket can always
be tied back to the exact version of the blocklist it describes.

While a review is running, the orchestration's custom status reports which batch it is
on. `Run_review` shows as a single action that polled to completion.

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

A test run against a blocklist seeded with one address of each kind:

```
10.34.2.7        internal              -> flagged
999.1.1.1        malformed             -> flagged
23.55.x.x        Akamai, low score     -> flagged
<known bad IP>   score >= 80           -> NOT flagged
<known bad IP>   repeat of the line above -> flagged as a duplicate
```

should produce exactly one CLOPSSEC Task titled `index.html IP review.`, assigned to
`secops`, whose description carries the run id and `Flagged IPs: 4`, and whose CSV
attachment has four rows with the correct line numbers, `n/a` in the AbuseIPDB columns
of all but the Akamai row, and the duplicate row pointing at the line above it — not
the other way round.

Then a clean blob: still one ticket, `Flagged IPs: 0`, **no attachment**. And a
negative test — point `JIRAHOST` at an unreachable host and confirm the run ends
**Failed**.

Logic App runs are immutable: after a redeploy, cancel any stuck in-flight runs and
fire fresh ones.
