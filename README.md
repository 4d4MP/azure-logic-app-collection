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
                              parallelism, opens a CLOPSSEC Incident on every run with a
                              CSV of findings
clopssec_ticket_creation/     HTTP-triggered building block — raises one CLOPSSEC issue
                              (Task, Problem or Incident) and answers synchronously with
                              the ticket key and URL
create_subtask/               HTTP-triggered building block — creates one Jira subtask
                              under an existing parent issue
opslsy_ticket_transition/     HTTP-triggered building block — performs at most one
                              validated Jira transition for an OPSLSY change ticket
clopssec_ticket_transition/   HTTP-triggered building block — lists the transitions a CLOPSSEC
                              ticket offers from its current status with their required and
                              optional fields, or performs one validated transition and
                              returns the transitions available from the new status
get_id/                       HTTP-triggered building block — finds Sentinel incidents by title,
                              status and created-time window, returns each match's ARM id, GUID
                              and entities, and — only on request — moves them to Active
dev_tool/                     Test harness for the building blocks — calls each one over
                              HTTPS against its own Request trigger, the way a live
                              caller does: raises a CLOPSSEC Incident and a subtask,
                              walks both to Closed through the transition block, and
                              reports the status code and contract of every call in its
                              HTTP response
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
project semantics, and picks the subtask issue type, priority and assignee defaults for that
project from `SubtaskDefaultsByProject` (CLOPSSEC: `Sub-task` by id `5`, Jira's own priority and
assignee), falling back to the `DefaultSubtask*` parameters (OPSLSY: `Operation sub-task`). Deployable artifacts are in `create_subtask/playbook/`.

### `opslsy_ticket_transition` — OPSLSY change transition building block

HTTP-triggered Logic App building block that performs at most one direct Jira
transition for an OPSLSY change ticket: validates ticket scope (project + issue type),
validates a unique destination-status match against `transition.to.name`, validates
required transition fields, submits the transition without retries, and verifies the
resulting status within a bounded synchronous window. Deployable artifacts are in
`opslsy_ticket_transition/playbook/`.

### `clopssec_ticket_transition` — CLOPSSEC ticket transition building block

HTTP-triggered Logic App building block (`CLOPSSEC_ticket_transition`) with two modes. Called with
only `ticket_key`, it lists the transitions Jira offers from the ticket's current status. Each
transition comes with its required and optional fields: type, whether Jira fills in a default, and
allowed values. With `transition_id` and/or `transition_name` it performs that one transition. The
transition must be listed for the current status, and every key in the request `fields` must
resolve to exactly one of the transition's fields, by id or case-insensitive display name. Values
are shaped from the field metadata: allowed values matched by id or name (select options by
value), users and groups by name, `comment` and add-only fields such as `worklog` as `update`
operations, and `null` or blank to clear a field. Required fields without a Jira default must be
in the request. Unrecognised top-level request properties are refused. Any problem is a 400 or 409 before any Jira write. The POST is sent once without retries, the resulting status is
verified within a bounded synchronous window, and a 200 carries the transitions available from the
new status. Jira 4xx answers are passed through, and an unverified outcome is a 504. Field keys are
enumerated with `xml()`/`xpath()` because the Workflow Definition Language has no `keys()`. Needs a
Key Vault access policy (secret `get`) for its own managed identity. Deployable artifacts are in
`clopssec_ticket_transition/playbook/`; the contract and the 120-second budget are in
`clopssec_ticket_transition/README.md`.

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

### `dev_tool` — building-block test harness

Exercises the building blocks the way production will: an **HTTPS POST to each block's
own Request trigger**, not a nested-workflow call. The nested `Workflow` action resolves
the callee through ARM and never touches the wire, so it cannot tell you whether the
block answers a real caller correctly — which is the only thing worth testing here.

A run has three stages:

1. `clopssec_ticket_creation` raises the parent (default: an `Incident` at priority `10114`,
   the lowest).
2. `create_subtask` raises a subtask under the returned parent key.
3. **Close stage** (`close_tickets`, on by default): `clopssec_ticket_transition` walks the
   **subtask first, then the parent** along `close_path` (default `In Progress` → `Resolved` →
   `Closed`). Jira can refuse to close a parent that has open subtasks, hence the order. A
   ticket is walked only if it was created, so a failed subtask still gets its parent closed.
   For each status on the path the harness:
   * calls the block in **list** mode (`{"ticket_key": …}`). If the ticket is already in that
     status (case-insensitive), it moves on to the next one;
   * picks the first listed transition whose `to_status` is that status. If none is listed, it
     records a failed step (`no transition to <status> from <current>; available: …`);
   * fills that transition's **required** fields. The value comes from `transition_field_values`
     by field id, else by display name, else the first allowed value Jira lists for the field
     (for example `resolution` → `Done`). A field for which Jira has a default gets only a
     configured value. A field with no value from any of these is left out, and the block
     answers 400 "missing required field", which is recorded;
   * calls the block in **transition** mode (`ticket_key`, `transition_id`, `fields`). The
     block verifies the new status before it answers.

   The first failed step stops that ticket's walk. The other ticket is still walked.

For each call the harness records the **HTTP status code**, whether the response honoured
the block's contract, and the error the block reported. For creation, "honoured" means
`status: ok` plus a non-empty `ticket_key`. For a list call it means `200` with `status: ok`.
For a transition call it means `200`, `status: ok`, and a `current_status` equal to the target.
A 4xx/5xx from a block is a recorded result, not a crash: the harness reads the error envelope
and carries on, so a validation failure is as legible as a success. Calls do not retry and do
not follow the 202 async pattern — the first synchronous answer is the answer under test.

The trigger callback URLs are read at deploy time with `listCallbackUrl` and held as
`SecureString` workflow parameters, and every HTTP action keeps its inputs out of run
history so the trigger SAS signature is never recorded. Any run can override a target with
`targets.*_url` in the request body, to point the same harness at INT or at a freshly
redeployed block without redeploying the harness. Only the query-stripped URL ever
reaches the report.

#### Request body

Every property is optional; `POST {}` runs the default test.

| Property | Type | Default | Meaning |
| --- | --- | --- | --- |
| `issue_type` | string | `Incident` (`DefaultIssueType`) | `Task`, `Problem` or `Incident` for the parent. `sentinelsvc` cannot create `Task` in CLOPSSEC. |
| `priority` | string | `10114` (`DefaultPriority`) | Jira priority name or numeric id for the parent. |
| `summary`, `description` | string | `DefaultSummary`, `DefaultDescription` | Parent ticket text. |
| `subtask_summary`, `subtask_description` | string | `DefaultSubtaskSummary`, `DefaultSubtaskDescription` | Subtask text. |
| `subtask_assignee` | string | none (the subtask block's default) | Jira user name for the subtask. |
| `close_tickets` | boolean | `true` (`CloseTickets`) | `false` skips the close stage and the tickets stay open. Must be a JSON boolean. |
| `close_path` | array of strings | `["In Progress","Resolved","Closed"]` (`ClosePath`) | Statuses to walk through, in order, case-insensitive. The last one is the status both tickets must end in. Loops are allowed (e.g. through `Waiting for 3rd Party / Clarification` and back). A workflow with an extra step, such as an `Approval` status, needs that status in the path. |
| `transition_field_values` | object | `{}` (`TransitionFieldValues`) | Values for **required** transition fields, keyed by Jira field id (`resolution`, `customfield_12345`) or display name (`Resolution`). The block matches allowed values by id, name or value, e.g. `{"resolution": "Won't Do"}`. |
| `targets.ticket_creation_url` | string | deploy-time callback URL | HTTPS trigger URL (SAS included) of the ticket-creation block for this run. |
| `targets.create_subtask_url` | string | deploy-time callback URL | Same, for the subtask block. |
| `targets.ticket_transition_url` | string | deploy-time callback URL | Same, for the transition block. Checked only when the close stage runs. |

A `close_tickets`, `close_path` or `transition_field_values` of the wrong type, an empty or
non-string `close_path`, or a non-https target is a **400** before any block is called.

#### Report

Each run returns its report in the HTTP response (also kept in run history): `200` when
the parent and the subtask were created, every step passed, and (with the close stage on)
both tickets ended in the last `close_path` status. Otherwise the answer is `502` and the run
is terminated as Failed. The report carries `steps` (per-call detail), `parent_ticket_key`/`_url`,
`subtask_key`/`_url`, and `parent_final_status` / `subtask_final_status`: the status the last
block call reported for that ticket, or `null` when the ticket was not created, the close
stage was off, or the last call reported none. It also carries `close_tickets`, `close_path`, and
`error`, the first failure: the parent error, else the subtask error, else the first close-stage
failure. Close-stage steps are named `ticket_transition:list` / `ticket_transition` and add
`from_status`, `to_status` (the target), `transition_id`, and for transitions `transition_name`
and `current_status`. A step that was not sent (no matching transition, time budget used up) has
`http_status: null`.

#### Duration

The harness answers synchronously, and a Consumption Request trigger must answer within
**120 seconds**. The default run makes 14 block calls: 2 creates, then 3 × (list + transition)
per ticket. The figures below are estimates, not measurements. A list call takes about 3–6 s
(Key Vault, cookie primer, issue, transitions). A transition call takes about 6–12 s (the same
plus the POST, the status poll and the re-read of the transitions). Expect **about 60–100 s**
for a full default run, and about 10 s with `close_tickets: false`. The block's own worst case
per transition call is 112 s (see `clopssec_ticket_transition/README.md`).

To make sure the report still goes out, **no close-stage call is started once
`CloseStageBudgetSeconds` (90 s) have passed** since the run started. The walk stops with a failed
step ("close stage time budget of 90 s used up; …"), and the run answers 502 with the report. A
call already in flight at 90 s can still take the run past 120 s: it normally takes 6–12 s, but
up to 112 s if Trackspace is slow. A `close_path` longer than three statuses adds about 10–18 s
per extra status and will usually hit the budget. Redo this arithmetic before raising the budget.

#### Deploy

Deploy **`CLOPSSEC_ticket_creation`, `create_subtask` and `CLOPSSEC_ticket_transition` first**,
in the same resource group. The template reads their `manual` trigger URLs with `listCallbackUrl`
and fails if one is missing. The transition block needs its own Key Vault access policy
(secret `get` for its managed identity, see `clopssec_ticket_transition/README.md`). Without it,
every close-stage call answers 500 and the harness reports `fail`. `dev_tool` itself needs no
storage or other Azure RBAC; its only outbound calls are to the blocks' triggers. It deploys by
overwriting the existing `dev_tool` Logic App in place; no API connections are created.
Deployable artifacts are in `dev_tool/playbook/`. The ARM parameters `TicketTransitionPlaybookName`,
`CloseTickets`, `ClosePath`, `TransitionFieldValues` and `CloseStageBudgetSeconds` set the defaults
above.

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

## Where the repos went

| Original repository | Now |
| --- | --- |
| `4d4MP/sentinel_logs_weur3_opener` | `sentinel_logs_weur3_opener/` |
| `4d4MP/TI_handleing_automation` | `ti_handling_automation/` |

Contents were imported unmodified — directory relocation only (the TI-handler
directory name also fixes the original repo-name typo). Both original
repositories are unchanged and remain online.
