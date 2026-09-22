# Sentinel Logic App playbooks

Azure **Logic Apps** triggered by Microsoft Sentinel incidents in the LSY
West-Europe environment. Every playbook lives in its own directory with its
`workflow.json`, ARM template and docs; this top level only indexes them.

Each playbook was imported from its own repository with full git history
(`git subtree`). The original repositories remain in place; this collection is
the monolith going forward.

```
sentinel_logs_weur3_opener/   Sentinel-triggered ticket "Opener" — raises a Trackspace/CLOPSSEC
                              issue from a Sentinel signal; reference KB + playbook scaffold
ti_handling_automation/       TI-handler — autonomous OPSLSY technical change, AbuseIPDB
                              enrichment, blocklist blob update, CSV attach, walk to Closed
malformed_user_agents_handler/ Malformed user agents handler — AbuseIPDB enrichment,
                              autonomous OPSLSY technical change, blocklist blob update,
                              CSV attach, walk to Post implementation review
blob_review/                  Blocklist IP review — reads the EDL blob, runs a modular
                              rule set over it (internal, malformed, duplicate,
                              whitelisted ISP below an abuse score), enriches the rest
                              via a Node Durable Functions runner at 50-way
                              parallelism, opens a CLOPSSEC Task on every run with a
                              CSV of findings
clopssec_ticket_creation/     HTTP-triggered building block — raises one CLOPSSEC issue
                              (Task, Problem or Incident) and answers synchronously with
                              the ticket key and URL
create_subtask/               HTTP-triggered building block — creates one Jira subtask
                              under an existing parent issue
opslsy_ticket_transition/     HTTP-triggered building block — performs at most one
                              validated Jira transition for an OPSLSY change ticket
get_id/                       HTTP-triggered building block — finds Sentinel incidents by title,
                              status and created-time window, returns each match's ARM id, GUID
                              and entities, and — only on request — moves them to Active
blob_append/                  HTTP-triggered building block — appends lines to a text blob named
                              by the request (sub, RG, account, container, blob), one item per
                              line with a shared " #" comment, de-duplicated and written under
                              an etag precondition
dev_tool/                     Test harness for the building blocks — calls each one over
                              HTTPS against its own Request trigger, the way a live
                              caller does, and reports the status code and contract of
                              every call to a ledger blob; the blob_append request body
                              is a workflow parameter, editable from the portal
```

## The playbooks

### `sentinel_logs_weur3_opener` — Sentinel → Trackspace ticket Opener

A West-Europe ("weur3") ticket **Opener**: raises a Trackspace/`CLOPSSEC` issue
from a Sentinel signal. Fork-point from TI-handler minus what an opener doesn't
need (no AbuseIPDB enrichment, no approval wait-loop, no blocklist blob PUT).
Carries the reusable environment constants, the Sentinel→Logic-App trigger
contract, the Trackspace create-issue pattern, the Key Vault plumbing and the
deployment discipline.

Start at `sentinel_logs_weur3_opener/README.md` — it has a prioritised reading
order over `reference/00..08`, `env/environment-constants.md` and
`docs/deployment-discipline.md`. The deployable artifacts are in
`sentinel_logs_weur3_opener/playbook/` (`workflow.json`, `azuredeploy.json`).

### `ti_handling_automation` — TI-handler

Source of truth for the deployed **TI-handler** playbook: on each incident it
autonomously raises an OPSLSY *Technical change* (clone of `OPSLSY-75376`),
walks it to Implementation, enriches incident IPs against AbuseIPDB, appends
kept IPs to the static-site blocklist blob, attaches the CSV report, then walks
the change to Closed. No human approval step.

Start at `ti_handling_automation/README.md` for deploy instructions (ARM,
required RBAC, API-connection consent) and configuration knobs;
`ti_handling_automation/docs/` holds the architecture, runbook and the
knowledge-base page. Deployable artifacts are in
`ti_handling_automation/playbook/`.

### `malformed_user_agents_handler` — Malformed user agents handler

Source of truth for the deployed **malformed-user-agents-handler** playbook: on each
incident from the *Malformed user agents* detection rule it enriches the incident IPs
against AbuseIPDB, drops everything under the report threshold or on the excluded-ISP
list and — when anything actionable remains — raises an OPSLSY *Technical change*
(clone of `OPSLSY-75376`), walks it to Implementation, appends the kept IPs to the
static-site blocklist blob, attaches the CSV report, then walks the change to
**Post implementation review** and leaves it there for a human to close. No human
approval gate. An AbuseIPDB outage still opens a CLOPSSEC triage Task instead.

Start at `malformed_user_agents_handler/README.md` for the flow, the ticket mechanics
and deploy instructions; `docs/` holds the design diagram. Deployable artifacts are in
`malformed_user_agents_handler/playbook/`.

### `blob_review` — blocklist IP review

The only playbook here that **reads** the Palo Alto EDL blob
(`lsyweuritcsprdmspalo001/$web/index.html`) instead of writing to it, and the only one
with an Azure Function behind it. Triggered by HTTP, by hand, on demand: it reads every
entry off the blocklist and flags the ones that should not be there. Four rules ship
enabled by default — **internal / non-routable** addresses, **malformed** entries
(typos), **duplicates** (the later copy is flagged for removal), and addresses belonging
to a **whitelisted ISP whose AbuseIPDB confidence score is below 80**. The first three
are settled locally and never sent to AbuseIPDB; everything else is enriched. Every run raises a **CLOPSSEC** Task
assigned to `secops`, with a CSV attachment naming each finding, why it was flagged,
its AbuseIPDB enrichment and the blob line it sits on. Read-only: it never edits the
blocklist.

The rules live in a registry, and which ones run — plus their thresholds, CIDRs and
ISP lists — is a Logic App parameter passed to the function at call time, so criteria
change without a code redeploy. Adding a rule is one object in the registry.

The runner is a **Node 20 Durable Functions** orchestration rather than a plain HTTP
function, for two reasons: an HTTP-triggered function is cut off at 230 seconds by the
Azure load balancer, which ~30,000 lookups at 50 concurrent would brush against; and
the Logic App's built-in asynchronous pattern turns the whole review into **one billed
action** instead of one per address. Unlike the other playbooks here, its Function App
holds a credential — Durable persists orchestration input, so the AbuseIPDB key is a
Key Vault reference on the function rather than a bearer token from the Logic App.

Start at `blob_review/README.md`; the deployable artifacts are `blob_review/playbook/`
(ARM + workflow) and `blob_review/function/` (Node). The README carries a `deploy.sh`
that does both halves and expects the artifacts copied flat into the directory it runs
from.

### `clopssec_ticket_creation` — CLOPSSEC ticket creation building block

HTTP-triggered Logic App, called by other playbooks, that raises one CLOPSSEC issue
(Task, Problem or Incident) from the request body and answers synchronously: 200 with
the ticket key and URL, 400 on validation failure, 4xx/5xx when Trackspace refuses the
issue. Mandatory fields are checked per issue type before any Jira call; custom field
ids are resolved by display name at run time. Needs a Key Vault access policy (secret
`get`) on the vault holding the Trackspace service-account password. Deployable
artifacts are in `clopssec_ticket_creation/playbook/`.

### `create_subtask` — Jira subtask building block

HTTP-triggered Logic App building block that creates one Jira subtask under an existing
parent issue and returns a synchronous JSON response (`parent_ticket_key`,
`fields.summary`/`fields.description` required; `fields.priority`/`fields.assignee`
optional). Resolves the parent project from Jira before creating the subtask to preserve
project semantics. Deployable artifacts are in `create_subtask/playbook/`.

### `opslsy_ticket_transition` — OPSLSY change transition building block

HTTP-triggered Logic App building block that performs at most one direct Jira
transition for an OPSLSY change ticket: validates ticket scope (project + issue type),
validates a unique destination-status match against `transition.to.name`, validates
required transition fields, submits the transition without retries, and verifies the
resulting status within a bounded synchronous window. Deployable artifacts are in
`opslsy_ticket_transition/playbook/`.

### `get_id` — Sentinel incident lookup and activation building block

HTTP-triggered Logic App building block that finds Microsoft Sentinel incidents matching
caller-supplied criteria (title prefix/suffix or exact title, `incident_status`, created-time
window) and answers synchronously with each match's ARM id, GUID and attached entities, plus a
count. **Despite the name, this block writes**: with `activate_incident: true` every match that is
neither already Active nor Closed is moved to Active through the azuresentinel connector, a delta
update that cannot blank severity, owner, description or labels. Closed incidents are refused per
incident and never reopened; the whole request is refused at validation if it asks for status
`Closed` and activation at once.

Reads go over the ARM management API with the workflow's managed identity (Microsoft Sentinel
**Responder** required, not Reader); title matching is client-side because the incidents endpoint
implements only a partial OData `$filter`. Because the block answers inside the 120-second
synchronous window, `max_results` is capped at 16 for a read-only call and 8 when activating — the
arithmetic is in `get_id/README.md` and must be redone before any timeout or ceiling is changed.
200 on success including zero matches, 400 on validation, 409 when a matched incident was refused
because it is closed, 500 on an internal failure, 502 on an upstream read failure or an incomplete
result, 504 when an activation outcome is unknown.

It is the `Find_And_Activate_Incidents` scope of `ti_handling_automation` lifted into a reusable
block: same list → filter → select-ids → activate shape, with the TI-handler's fixed title filters
replaced by request fields. Deployable artifacts are in `get_id/playbook/`.

### `blob_append` — blob line-append building block

HTTP-triggered Logic App building block that appends lines to a text blob: an array of IPs (or
any other strings, one per line) plus a single `comment` carried onto every line after a `" #"`
separator. The target is entirely request-driven — `subscription_id`, `resource_group_name`,
`storage_account_name`, `container_name`, `blob_name` — so one deployment serves every blob the
playbook's identity can reach. 200 when the append landed, and the mapped error code when it did
not, with the raw storage code in `upstream_status_code`.

The two locator fields are not decoration: the storage account is resolved through ARM and its
own `primaryEndpoints.blob` becomes the base URL, so a wrong subscription or resource group is a
clean 404 rather than a write into a same-named account elsewhere. Lines already on the blob are
dropped by default, comparing the part before the `" #"` separator so provenance comments never
mask a duplicate address. The write is conditional on the etag of the read it was merged from and
retried up to three times on 412 — the lost-update window that `ti_handling_automation` and
`malformed_user_agents_handler` still carry in their own blocklist read-modify-write is the
reason this block exists. A block blob is rewritten whole and keeps its stored content type; an
append blob gets a `comp=appendblock` write. A missing blob is a 404 unless the caller passes
`create_if_missing`. Deployable artifacts are in `blob_append/playbook/`.

### `dev_tool` — building-block test harness

Exercises the building blocks the way production will: an **HTTPS POST to each block's
own Request trigger**, not a nested-workflow call. The nested `Workflow` action resolves
the callee through ARM and never touches the wire, so it cannot tell you whether the
block answers a real caller correctly — which is the only thing worth testing here.

It chains `clopssec_ticket_creation` → `create_subtask` under the returned parent key, then
calls `blob_append` — and records for each call the **HTTP status code**, whether the response
honoured the block's contract, and the error the block reported. A 4xx/5xx from a block is a
recorded result, not a crash: the harness reads the error envelope and carries on, so a
validation failure is as legible as a success. Calls do not retry and do not follow the 202
async pattern — the first synchronous answer is the answer under test. Any step recorded as
`fail` fails the run.

The contract checked per block is the one that block promises: `status: ok` plus a non-empty
`ticket_key` for the two Jira blocks; for `blob_append`, `status: ok` **and** `appended_count`
equal to the `distinct_count` it reported back. Because "200 with nothing appended" is a
legitimate answer, the append is then tested a second time: the same body with
`skip_duplicates` forced true must come back with `appended_count: 0` and every line counted
as a duplicate. That second call is what distinguishes a block that appended from one that
merely answered 200, and it is skipped on a dry run (and by `BlobAppendVerifyDedupe: false`).

The `blob_append` request body is a **workflow parameter**, `BlobAppendRequest`, holding the
posted JSON verbatim — edit it in the portal under *Logic App Designer → Parameters* to
retarget the test (different account, container, blob, lines, comment, flags) without touching
an action or redeploying. It defaults to `blob-append-test.txt` in the same `dev-tool`
container as the ledger, with `create_if_missing: true` and `skip_duplicates: false`, so each
run appends and the test blob doubles as a run log; delete the blob whenever it gets long. One
value needs checking before the first run: `resource_group_name` must be the resource group of
the **storage account**, which is not necessarily the one these playbooks live in — `blob_append`
answers 404 if it is wrong. A redeploy resets the parameter to the template value, so keep any
lasting change in `azuredeploy.parameters.json` as well.

The two Jira blocks' trigger callback URLs are read at deploy time with `listCallbackUrl` and
held as `SecureString` workflow parameters. **`blob_append`'s URL is pinned instead**, as the
`BlobAppendCallbackUrl` parameter, so that block does not have to be resolvable from this
template's resource group — which means this repository carries a live callback credential:
anyone who can read `dev_tool/playbook/` can invoke `blob_append` and write to whatever
`BlobAppendRequest` points at. Rotate it under the `blob_append` Logic App → *Access keys*,
which invalidates the pinned URL, then paste the new one into the parameter (in
`azuredeploy.parameters.json`, or in *Logic App Designer → Parameters*, which needs no
redeploy). To go back to deploy-time resolution, restore the `BlobAppendPlaybookName`
parameter and the `listCallbackUrl` expression that fed `BlobAppendCallbackUrl`.

Every HTTP action keeps its inputs out of run history, so no trigger SAS signature is ever
recorded in a run, and only the query-stripped URL reaches the report and the ledger. Any run
can override a target with `targets.ticket_creation_url` / `targets.create_subtask_url` /
`targets.blob_append_url` in the request body, and the whole `blob_append` body with
`blob_append`, to point the same harness at INT or at a freshly redeployed block without
redeploying the harness.

Each run appends its report to a ledger append blob (managed identity, no connection
strings) and returns it: `200` when every step passed, `502` otherwise, with a `steps`
array carrying the per-call detail. Deploys by overwriting the existing `dev_tool` Logic
App in place; no API connections are created. Deployable artifacts are in
`dev_tool/playbook/`.

## Cross-references

The Opener repo was cut as a fork-point from TI-handler:
`sentinel_logs_weur3_opener/ti-handler-repo-notes.md` points into the
TI-handler content, and `reference/07-ti-handler-playbook.md` /
`docs/07-ti-handler-playbook.md` are the same knowledge-base page carried by
both. Inside this monolith the other playbook is always one directory up.

`malformed_user_agents_handler` ports TI-handler's OPSLSY change lifecycle (clone via
`CloneIssueDetails.jspa`, find-by-search, name-driven walk, run-record sub-task) onto its
own single triggering incident; `ti_handling_automation/docs/07-ti-handler-playbook.md`
remains the reference page for that pattern.

`blob_append` generalises the blocklist blob write both handlers carry in their
`Write_Blocklist_Blob` scope, and adds the etag precondition neither of them has. Both are
candidates to be rewritten as calls into it; neither has been, so the read-modify-write in
`ti_handling_automation/playbook/workflow.json` and
`malformed_user_agents_handler/playbook/workflow.json` is still the deployed path.

## Adding a playbook

1. Create a snake_case directory named after what the playbook does.
2. Give it its own `README.md`, a `playbook/` directory holding
   `workflow.json` + `azuredeploy.json` (+ `azuredeploy.parameters.json` when
   there are production values), and a `docs/` directory for architecture,
   runbook and references.
3. Add it to the layout block and index above. Nothing at the top level may be
   required to deploy an individual playbook.
4. If importing an existing repo, use `git subtree add --prefix=<dir> <url> <branch>`
   so history comes along, and record the mapping below.
5. A `SetVariable` at the **top level** of a definition may not read the variable it sets.
   The engine refuses the deployment — *"Self reference is not supported when updating the
   value of variable X"* — while the same expression nested inside an `If`, `Scope` or `Until`
   is accepted, which is why the self-references in `dev_tool`, `get_id` and
   `opslsy_ticket_transition` all sit inside scopes. Where the intent is "set this only if
   nothing is set yet", put that test in a condition and leave the value standing on its own.

## Where the repos went

| Original repository | Now |
| --- | --- |
| `4d4MP/sentinel_logs_weur3_opener` | `sentinel_logs_weur3_opener/` |
| `4d4MP/TI_handleing_automation` | `ti_handling_automation/` |

Contents were imported unmodified — directory relocation only (the TI-handler
directory name also fixes the original repo-name typo). Both original
repositories are unchanged and remain online.
