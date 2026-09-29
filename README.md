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
                              caller does: raises a CLOPSSEC Incident, walks it to Closed
                              through the transition block along a configurable list of
                              statuses/transitions, and reports the status code and
                              contract of every call; answers asynchronously (202 +
                              Location, poll for the report)
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

```
validate request + targets ──400──► (nothing created)
clopssec_ticket_creation ──fail──► report 502
│
└─ for each transition_path entry, in order (close_ticket on)
     list mode ──fail──► stop the walk
     ├─ ticket already in that status ─────────────► next entry
     ├─ transition to that status, else one with that name
     │    fill required fields ─► transition mode ─► status verified ─► next entry
     └─ no match / budget used up ─────────────────► stop the walk
report: 200 when every entry was reached, else 502
```

A run has two stages:

1. `clopssec_ticket_creation` raises one ticket (default: an `Incident` at priority `10114`,
   the lowest). No subtask is created.
2. **Close stage** (`close_ticket`, on by default): `clopssec_ticket_transition`, called at the
   URL held in the `TicketTransitionUrl` parameter, walks the ticket along `transition_path`
   (parameter `TransitionPath`, default `In Progress` → `Resolved` → `Closed`). Each entry names
   **a status or a transition**, case-insensitive; list every one the ticket has to pass through
   up to Closed. For each entry the harness:
   * calls the block in **list** mode (`{"ticket_key": …}`). If the ticket is already in a status
     of that name, the entry is reached and the harness moves on to the next one;
   * picks the first listed transition whose `to_status` is the entry, else the first whose
     `name` is the entry. `["In Progress", "Resolved", "Closed"]` and
     `["Start Progress", "Resolve Issue", "Close Issue"]` therefore walk the same way, and the two
     can be mixed. If neither matches, it records a failed step
     (`<entry> is neither the target status nor the name of a transition available from <current>; available: …`);
   * fills that transition's fields. Every field the transition lists, **required or optional**,
     gets its `transition_field_values` value, looked up by field id, else by exact display name.
     Optional fields matter because Jira workflow validators can demand fields that the
     transition metadata does not flag as required: CLOPSSEC's *Resolve Issue* rejects the POST
     without **Category** (`customfield_10905`) and **Solution description** (`customfield_17802`),
     which is why the `TransitionFieldValues` default sets both. Keys that a transition does not
     list are skipped for that transition. A **required** field without a configured value gets
     the first allowed value Jira lists for it (for example `resolution` → `Done`), unless Jira has
     a default for it. A required field with no value from any of these is left out, and the block
     answers 400 "missing required field", which is recorded;
   * calls the block in **transition** mode (`ticket_key`, `transition_id`, `fields`). The
     block verifies the new status before it answers; the harness checks that it is the chosen
     transition's `to_status`.

   The first failed step stops the walk.

For each call the harness records the **HTTP status code**, whether the response honoured
the block's contract, and the error the block reported. For creation, "honoured" means
`status: ok` plus a non-empty `ticket_key`. For a list call it means `200` with `status: ok`.
For a transition call it means `200`, `status: ok`, and a `current_status` equal to the chosen
transition's `to_status`. A 4xx/5xx from a block is a recorded result, not a crash: the harness
reads the error envelope and carries on, so a validation failure is as legible as a success.
Calls do not retry and do not follow the 202 async pattern — the first synchronous answer is the
answer under test.

#### `TicketTransitionUrl` (placeholder until set)

The transition block's trigger URL is an ARM `securestring` parameter, `TicketTransitionUrl`,
not read with `listCallbackUrl`, so dev_tool deploys whether or not the block is in the same
resource group. Its default is the placeholder `REPLACE_WITH_CLOPSSEC_TICKET_TRANSITION_TRIGGER_URL`.
While the placeholder (or any non-https value) is in place, every run with the close stage on
answers **400** before any ticket is raised. `{"close_ticket": false}` still tests the creation
block alone, and `targets.ticket_transition_url` supplies the URL for one run. The value is set in
the Logic App's secure `parameters`, never in the definition, so it does not show in code view or
deployment history. It carries the SAS signature: pass it at deploy time and do not commit it to
`azuredeploy.parameters.json`.

```powershell
$transitionUrl = (Get-AzLogicAppTriggerCallbackUrl -ResourceGroupName LSY_WEUR_ITCS_PRD_SEC_RG_002 `
    -Name CLOPSSEC_ticket_transition -TriggerName manual).Value
New-AzResourceGroupDeployment -ResourceGroupName LSY_WEUR_ITCS_PRD_SEC_RG_002 `
  -TemplateFile dev_tool/playbook/azuredeploy.json `
  -TemplateParameterFile dev_tool/playbook/azuredeploy.parameters.json `
  -TicketTransitionUrl (ConvertTo-SecureString $transitionUrl -AsPlainText -Force)
```

```bash
az deployment group create -g LSY_WEUR_ITCS_PRD_SEC_RG_002 \
  --template-file dev_tool/playbook/azuredeploy.json \
  --parameters @dev_tool/playbook/azuredeploy.parameters.json \
  --parameters TicketTransitionUrl="$TRANSITION_URL"
```

#### Trigger URLs and run history

The creation block's trigger URL is read at deploy time with `listCallbackUrl`; both it and
`TicketTransitionUrl` are held as `SecureString` workflow parameters, and every HTTP action keeps
its inputs out of run history. The manual trigger also secures its outputs
(`runtimeConfiguration.secureData: outputs`), so a `targets.*_url` passed in the request body is
hidden in trigger and run history, SAS included. The Composes that read the request body directly
are hidden with it. The report and the HTTP response stay visible and carry only query-stripped
URLs; no error message ever echoes a URL. Anyone with Reader or Logic App Operator can read
unsecured run history but cannot call `listCallbackUrl`, so an override SAS must never appear
there. The raw request body is therefore not visible in run history; the report echoes the
resolved `issue_type`, `summary`, `close_ticket` and `transition_path`, and each step names its
query-stripped `target`. Any run can override a target with `targets.*_url` in the request body,
to point the same harness at INT or at a freshly redeployed block without redeploying the harness.
To point it at INT, pass both `targets.*_url`. With `close_ticket` true, overriding the creation
URL without `targets.ticket_transition_url` is a **400**. Otherwise the stored transition URL
would walk the key that INT, or any endpoint the caller names, returned, and close whatever
production ticket carries it. Only the query-stripped URL ever reaches the report.

#### Request body

Every property is optional; `POST {}` runs the default test.

| Property | Type | Default | Meaning |
| --- | --- | --- | --- |
| `issue_type` | string | `Incident` (`DefaultIssueType`) | `Task`, `Problem` or `Incident`. `sentinelsvc` cannot create `Task` in CLOPSSEC. |
| `priority` | string | `10114` (`DefaultPriority`) | Jira priority name or numeric id. |
| `summary`, `description` | string | `DefaultSummary`, `DefaultDescription` | Ticket text. |
| `close_ticket` | boolean | `true` (`CloseTicket`) | `false` skips the close stage and the ticket stays open. Must be a JSON boolean. |
| `transition_path` | array of strings | `["In Progress","Resolved","Closed"]` (`TransitionPath`) | Every status or transition the ticket must reach, in order, case-insensitive. A status name is matched against the listed transitions' `to_status` first, then a transition name against their `name`. Loops are allowed (e.g. through `Waiting for 3rd Party / Clarification` and back). A workflow with an extra step, such as an `Approval` status, needs that step in the path. |
| `transition_field_values` | object | `{"Category": "Undetermined", "Solution description": "Automated dev_tool test ticket; …"}` (`TransitionFieldValues`) | Values for transition fields, required or optional, keyed by Jira field id (`resolution`, `customfield_10905`) or exact display name (`Resolution`, `Category`). Sent on every transition that lists the field. The block matches allowed values by id, name or value, e.g. `{"resolution": "Won't Do"}`. **Replaces the parameter as a whole**, so an override must repeat `Category` and `Solution description`, or *Resolve Issue* fails its validator. CLOPSSEC Category values: `BenignPositive`, `FalsePositive`, `TruePositive`, `Undetermined`. |
| `targets.ticket_creation_url` | string | deploy-time callback URL | HTTPS trigger URL (SAS included) of the ticket-creation block for this run. |
| `targets.ticket_transition_url` | string | `TicketTransitionUrl` | Same, for the transition block. Checked only when the close stage runs. Required when `ticket_creation_url` is overridden and the close stage runs. |

A `close_ticket`, `transition_path` or `transition_field_values` of the wrong type, an empty
`transition_path` or one with a blank or non-string entry, a non-https target (including the
`TicketTransitionUrl` placeholder while the close stage runs), or an overridden creation URL
without `targets.ticket_transition_url` while the close stage runs is a **400** before any block
is called. So are the properties of the earlier two-ticket harness (`close_tickets`,
`close_path`, `subtask_summary`, `subtask_description`, `subtask_assignee`,
`targets.create_subtask_url`), so an old request never runs with its settings silently ignored.

#### Report

Each run returns its report as the final answer of the polled request (see *Calling it*; also
kept in run history): `200` when the ticket was created, every step passed, and (with the close
stage on) every `transition_path` entry was reached. Otherwise the answer is `502` and the run
is terminated as Failed. The report carries `steps` (per-call detail), `ticket_key` / `ticket_url`,
`final_status` (the status the last block call reported, or `null` when the ticket was not
created, the close stage was off, or the last call reported none), `path_steps_reached` (how many
entries were reached), `close_ticket`, `transition_path`, `transition_field_values` (the values in
effect for this run), and `error`, the first failure: the
creation error, else the first close-stage failure. Close-stage steps are named
`ticket_transition:list` / `ticket_transition` and add `path_entry` (the entry as given),
`from_status`, and for transitions `to_status` (the chosen transition's target), `transition_id`,
`transition_name`, `current_status`, `fields_listed` (every field the transition lists, as
`id (name[, required])`) and `fields_sent` (the `fields` object dev_tool posted). When Jira refuses
the transition with field errors, the `error` repeats both lists: a field Jira demands that the
transition does not list sits on no transition screen, so no transition request can set it; it
has to be on the ticket before the transition. A step that was not sent (no matching transition, time
budget used up) has `http_status: null`. A call that got no HTTP response (timed out or the
connection failed) has `http_status: 0`: "no HTTP response (timed out or the connection failed)".
For a transition the block may still finish it afterwards, so list the ticket before rerunning.

#### Calling it (asynchronous)

dev_tool answers **asynchronously**: all three Response actions (`Respond_result`,
`Respond_400_invalid_close_config`, `Respond_400_invalid_targets`) have
`"operationOptions": "Asynchronous"` (the designer's *Asynchronous Response* setting; Learn
requires every Response in a workflow to use the same pattern). The POST returns **`202
Accepted`** at once, with a `Location` header (and usually `Retry-After`). `GET` the `Location`
URL until the status is no longer 202, honouring `Retry-After`; the final answer is the
`200`/`502` report, and the input `400`s also arrive through the poll. Per the Logic Apps limits
page, with an asynchronous Response the 120-second inbound limit does not apply: the workflow
"can take whatever time is needed to respond". The `Location` URL carries a signature, so treat
it like the trigger URL (do not paste it into tickets or chat).

```bash
url='<dev_tool trigger URL>'
loc=$(curl -sS -o /dev/null -D - -X POST -H 'Content-Type: application/json' -d '{}' "$url" \
      | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
while :; do
  code=$(curl -sS -o report.json -D headers.txt -w '%{http_code}' "$loc")
  [ "$code" != 202 ] && break
  wait=$(awk 'tolower($1)=="retry-after:"{print $2}' headers.txt | tr -d '\r'); sleep "${wait:-10}"
done
echo "HTTP $code"; cat report.json
```

```powershell
$url = '<dev_tool trigger URL>'
$r = Invoke-WebRequest -Method Post -Uri $url -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck
$loc = [string]$r.Headers['Location']
do {
    $wait = if ($r.Headers['Retry-After']) { [int][string]$r.Headers['Retry-After'] } else { 10 }
    Start-Sleep -Seconds $wait
    $r = Invoke-WebRequest -Method Get -Uri $loc -SkipHttpErrorCheck
} while ($r.StatusCode -eq 202)
"HTTP $($r.StatusCode)"; $r.Content
```

(`-SkipHttpErrorCheck` needs PowerShell 7; the 400 and 502 answers are reports too.)

**Before relying on the JSON key**, note that Learn documents the designer toggle, not the
`operationOptions` value: after the first deployment, open dev_tool in the designer, check that
*Asynchronous Response* shows **On** for the Response actions, and compare the code view (or an
INT export) with `workflow.json`.

#### Duration

A healthy default run takes roughly **45–75 seconds (unmeasured)**. It makes 7 block calls, one
after the other: 1 create, then 3 × (list + transition), and each call is a whole Logic App run of
its own (a list call runs about 40 actions, a transition call 70–80, dev_tool itself about 110 in a
default run). With `close_ticket: false` it takes about 5–10 s. Consumption has per-action
scheduling overhead and no latency SLA, so measure on INT rather than trusting these figures.

* **Runaway guard**, `CloseStageBudgetSeconds` (default **600 s**, counted from the first action
  of the run): no transition is submitted after it, and no list call is started after it minus 6 s.
  It only bounds a walk that has gone wrong (for example a very long `transition_path` against a
  slow Trackspace); the walk then stops with a failed step such as "close stage time budget used up
  (no list call is started after 594 s); the list call for Closed was not made", and the run
  answers 502 with the report. Because the answer is asynchronous, it is not tied to the 120 s
  window.
* **Per-call limit**: the close-stage block calls use `DisableAsyncPattern`, so each is a single
  synchronous request. Microsoft documents `limit.timeout` only for the asynchronous pattern
  ("Change asynchronous duration" in the workflow schema reference) and for retries; the designer's
  action *Timeout* setting likewise says it limits the async pattern, not a single request (see also
  Microsoft Q&A question 941704). A single synchronous request is
  bounded only by the **120 s outbound limit** (logic-apps-limits-and-config). The calls carry
  `limit.timeout` `PT2M`, equal to that limit, so dev_tool never cuts a slow but healthy call
  short on its own; the block's documented worst case is 112 s per transition call. A call that
  gets no answer within 120 s ends TimedOut and is recorded with `http_status: 0`.

The creation call follows the same 120 s outbound limit.

#### Deploy

Deploy **`CLOPSSEC_ticket_creation` first**, in the same resource group: the template reads its
`manual` trigger URL with `listCallbackUrl` and fails if it is missing. Pass the
`CLOPSSEC_ticket_transition` trigger URL as `TicketTransitionUrl` (see above); until then the
close stage answers 400. The transition block needs its own Key Vault access policy (secret `get`
for its managed identity, see `clopssec_ticket_transition/README.md`). Without it, every
close-stage call answers 500 and the harness reports `fail`. `dev_tool` itself needs no storage or
other Azure RBAC; its only outbound calls are to the blocks' triggers. It deploys by overwriting
the existing `dev_tool` Logic App in place; no API connections are created. Deployable artifacts
are in `dev_tool/playbook/`. The ARM parameters `CloseTicket`, `TransitionPath`,
`TransitionFieldValues` and `CloseStageBudgetSeconds` set the defaults above.

The template publishes no trigger URL output. The URL contains the trigger SAS signature, and an
ARM output is stored in cleartext in the resource group's deployment history, where anyone with
Reader can read it. dev_tool's URL also drives the transition block, so it can close CLOPSSEC
tickets. Get the URL when you need it with
`(Get-AzLogicAppTriggerCallbackUrl -ResourceGroupName LSY_WEUR_ITCS_PRD_SEC_RG_002 -Name dev_tool -TriggerName manual).Value`,
or with
`az rest --method post --url "https://management.azure.com/subscriptions/<subscriptionId>/resourceGroups/LSY_WEUR_ITCS_PRD_SEC_RG_002/providers/Microsoft.Logic/workflows/dev_tool/triggers/manual/listCallbackUrl?api-version=2019-05-01" --query value -o tsv`.
Both need `Microsoft.Logic/workflows/triggers/listCallbackUrl/action`, which Logic App
Contributor has and Logic App Operator does not.

Earlier dev_tool templates did output `triggerUrl`, so the current SAS is still in older
deployment records. Removing the output does not revoke it. When you first deploy this version:

1. Delete those records. List them with
   `az deployment group list -g LSY_WEUR_ITCS_PRD_SEC_RG_002 --query "[?properties.outputs.triggerUrl && properties.outputs.logicAppName.value=='dev_tool'].name" -o tsv`,
   then run `az deployment group delete -g LSY_WEUR_ITCS_PRD_SEC_RG_002 -n <name>` for each name.
2. Regenerate dev_tool's primary access key so the leaked signature stops working:
   `az rest --method post --url "https://management.azure.com/subscriptions/<subscriptionId>/resourceGroups/LSY_WEUR_ITCS_PRD_SEC_RG_002/providers/Microsoft.Logic/workflows/dev_tool/regenerateAccessKey?api-version=2019-05-01" --body '{"keyType":"Primary"}'`.
   dev_tool is only called by hand and nothing stores its URL, so this breaks nothing. Get the
   new URL as above.

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
