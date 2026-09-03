# Blob review — blocklist IP review

**Logic App:** `blob-review` (Consumption) in `LSY_WEUR_ITCS_PRD_SEC_RG_002`.
**Source of truth:** `playbook/workflow.json` + `playbook/azuredeploy.json`.
**Triggers:** a **weekly schedule** (Mondays 07:00 CET) *and* an HTTP request for an
on-demand run. No Sentinel incident.

The other playbooks in this collection *write* to the Palo Alto EDL blob
(`lsyweuritcsprdmspalo001/$web/index.html`). This one *reviews* it: it reads every
entry, runs four rules over it, and raises a **CLOPSSEC** Task naming every address
that should not be on the list.

It is read-only against the blob. It never removes an entry; a human does that after
reading the ticket.

**There is no Function App.** The whole review runs in the Logic App, and AbuseIPDB is
reached through the existing OMS-owned **`abuseipdbapi-1`** API connection — the same
one `ti_handling_automation` and `malformed_user_agents_handler` use. See *Why there is
no function* for what that cost and bought.

## Flow

```
Scheduled_review   Mondays 07:00 CET       ─┐
manual             HTTP POST, on demand    ─┴→
  → Capture_run_start · Resolve_blob_target · Get_blocklist_blob
  → Check_blocklist_not_empty
       ├─ empty → Terminate Failed (a blank EDL is a fetch fault, not an all-clear)
       └─ content
            Split_lines → Trim_lines → Entries → Distinct_entries
            ├─ Number_lines → Compose_line_map   [entry]=line; lookup table
            ├─ Filter_cidr_ranges          public CIDRs, never checked
            ├─ Filter_bad_shape ─┐
            ├─ Filter_bad_octets ┴→ Compose_malformed
            ├─ Filter_duplicates           appears more than once
            ├─ Filter_internal             non-routable
            └─ Filter_candidates → AbuseIPDB_health_check
                                 → Enrich_candidates   Foreach, 50 concurrent,
                                                       ONE action per iteration
                                 → Compose_lookups (result())
                                 → Select_enriched · Filter_lookup_errors
                                 → Select_scores → Compose_score_map
                                 → Filter_whitelisted_isp
            → Rows_* → Compose_findings (sorted by line)
                     → Create_findings_CSV → Capture_run_end
            → Create_CLOPSSEC_ticket   ALWAYS, findings or not
            → Parse_ticket_response → Findings_attachment_gate → Assign_ticket
            → Guard_lookup_errors
                 ├─ errors > MaxLookupErrors → Terminate Failed
                 └─ Compose_run_result
```

`Get_Jira_password` → `Jira_health_check` runs as its own branch alongside the whole
review and joins at `Create_CLOPSSEC_ticket`, so a broken Trackspace credential shows
up in seconds rather than after the scan.

## The Designer will not open this playbook. That is expected

The portal says the workflow **has multiple starting points and is not supported in
Designer**. It is right, and nothing is broken:

| Triggers per workflow | Consumption **designer** | Consumption **JSON** |
| --- | --- | --- |
| Supported | **1** | **10** |

> Multiple triggers are possible only when you work on the JSON workflow definition,
> whether in code view or an Azure Resource Manager (ARM) template, **not the designer**.
> — [Limits and configuration reference](https://learn.microsoft.com/azure/logic-apps/logic-apps-limits-and-config#workflow-limits)

This definition declares two, and the Designer counts what is **declared**, not what
you happen to fire:

```
"triggers": {
    "manual":           { "type": "Request",    "kind": "Http" },   <- starting point 1
    "Scheduled_review": { "type": "Recurrence", ... }               <- starting point 2
}
```

It is a **tooling** limit, not an engine limit. Deploys, runs, run history and the run
details view all work normally — every run in this playbook's history was read in the
portal. Only the editing surface is blocked. **Code view still opens**, and it is the
right place to look anyway, because `playbook/workflow.json` in this repo is the
source of truth.

### Running it from the portal

The **Run Trigger** button most people know lives on the *Designer* toolbar, which is
why it looks like there is no way to run this one by hand. There is a second one:

**Logic app → Overview → toolbar → Run Trigger**

> You can recheck the trigger without waiting for the next recurrence. On the
> **Overview** page toolbar *or* on the designer toolbar, select **Run**, **Run**.
> — [Check workflow status and run history](https://learn.microsoft.com/azure/logic-apps/view-workflow-status-run-history#review-trigger-history)

That path is served by the management API rather than the Designer, so the
multiple-trigger block should not apply to it. *Should* — the docs do not state what
the dropdown does when a workflow has two triggers, and it has not been confirmed on
this playbook. If it is missing or unusable, the equivalent call is:

```
az rest --method post --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Logic/workflows/blob-review/triggers/manual/run?api-version=2016-06-01"
```

**A portal run reviews production.** It sends no body, so `triggerBody()` is null and
`Resolve_blob_target` falls back to `BlocklistContainer` / `BlocklistBlobPath` —
`$web/index.html`, the same target as the Monday run. There is no portal path to
supply `{container, blobPath}` overrides; that is what `smoke-test.*` and the callback
URL are for. To repeat an earlier *test-blob* run from the portal, use **Overview →
Runs history → pick the run → Resubmit**, which replays that run's original trigger
body.

### If you would rather have the Designer

Only one thing restores it: **declare one trigger**. Both ways of getting there cost
something real, so neither is done by default:

| | Designer | Run by hand from the portal | Test-blob smoke test | Extra resources |
| --- | --- | --- | --- | --- |
| **Today** — both triggers | no | Overview → Run Trigger | yes | none |
| **Recurrence only** | yes | Overview → Run Trigger | **no** — `listCallbackUrl` is gone with the Request trigger, so `smoke-test.*` can only fire `triggers/Scheduled_review/run`, with no body and therefore no override | none |
| **Request only** + a scheduler | yes | Overview → Run Trigger | yes | a second Logic App with the Recurrence trigger, a managed identity, and a **Logic App Contributor** role assignment on this one — a missing role assignment is silent until the following Monday |

The trade is the Designer against the ability to point a manual run at a small test
blob. Keep both triggers unless somebody actually needs to edit this in the Designer —
which mostly means the day a **connector** action is added, since the Designer is what
authors the `$connections` entry and the connection resource, and hand-writing those is
genuinely unpleasant.

## Why there is no function

The previous version ran enrichment in a Node Durable Functions app. It deployed
cleanly and could not work, for a reason no amount of code fixed:
`LSY-WEUR-ITCS-PRD-KV-02` denies by default, and its ~50 IP rules are **Logic Apps and
App Service West Europe outbound ranges**. A Linux Consumption function app has no
VNet integration, no stable outbound IP, and is [not reliably admitted by the
trusted-services
bypass](https://learn.microsoft.com/azure/key-vault/general/overview-vnet-service-endpoints#trusted-services)
— which was already enabled and did not help. Its `ABUSEIPDB_API_KEY` Key Vault
reference reported `AccessToKeyVaultDenied` while every access-policy check passed.

Running in the Logic App removes the problem rather than working around it:

- **No AbuseIPDB secret is needed at all.** The `abuseipdbapi-1` connection holds the
  key. Nothing in this playbook reads an AbuseIPDB secret from Key Vault.
- **The one Key Vault read left is the Trackspace password**, done by the Logic App,
  from Logic Apps outbound IPs the vault firewall already allows — which is why the
  other playbooks in this collection have always worked.
- **Two grants instead of three**, no function app, no storage account, no App
  Insights, no hosting plan, no `func` tooling, no JavaScript to publish.

What it cost: the rules are now Logic App expressions rather than unit-tested
JavaScript, and the run is billed per action rather than as one asynchronous call.
Both are covered below.

## The rules, in Logic App expressions

Every rule is a **Filter Array** (`Query`) or **Select** action, which processes the
whole array in a single billed action however long it is. Only enrichment loops.

`Distinct_entries` is `union(Entries, Entries)` — the idiom for distinct. Enriching
only distinct addresses is also what stops duplicates being paid for twice.

**Malformed is two stages, and has to be.** `and()` evaluates every argument, so a
four-octet check and an octet-value check cannot share one expression: `split('junk','.')[1]`
throws before the shape test can rule it out.

```
Filter_dotted_quads   equals(length(split(item(), '.')), 4)      <- total, never throws
Filter_valid_addresses  every octet in ValidOctets               <- safe: 4 octets guaranteed
```

`ValidOctets` is the string `,0,1,…,255,` and membership is `contains(ValidOctets,
concat(',', octet, ','))`. That is deliberate: Logic Apps has no regex, and `int()`
throws on non-numeric input, so string-set membership is the only *total* test
available. `InternalFirstOctets`, `Internal172Seconds` and `Internal100Seconds` work
the same way, which is how `172.16–172.31` and `100.64–100.127` are matched without
arithmetic. All four are parameters, so the ranges are data, not code.

**Duplicates** are counted by bracketing: `Join_entries` builds `[a][b][c]`, and an
entry is duplicated when splitting that string on `[entry]` yields more than two
parts. The brackets matter — a plain comma join undercounts *adjacent* duplicates,
because the delimiters overlap.

**Whitelisted ISP** runs after enrichment: the lower-cased `isp` **contains** one of
`WhitelistedIsps` **and** `abuseConfidenceScore` is below `WhitelistedIspMaxScore`
(80).

Substring, not equality, and that distinction is the whole rule: AbuseIPDB returns
`Akamai Technologies, Inc.`, so an exact match against `akamai technologies` never
fires. Logic Apps cannot loop a parameter array inside a Filter — `item()` would be
shadowed — so the test is an `or()` chain over **ten fixed slots**, each
`contains(isp, coalesce(WhitelistedIsps?[n], '###NONE###'))`. The sentinel matters:
`contains(x, '')` is true, so an empty slot would whitelist everything.

The list stays a parameter, so entries change without touching the definition — but
**only the first ten are read**. Add an eleventh and it is silently ignored; widen the
chain in `Filter_whitelisted_isp` if the list ever needs to grow.

## Scale, and the limits that shaped it

For a ~30,000-entry blocklist, against the [Consumption
limits](https://learn.microsoft.com/azure/logic-apps/logic-apps-limits-and-config):

| Limit | Value | This playbook |
| --- | --- | --- |
| For-each array items | 100,000 | ~30,000 candidates |
| For-each concurrency | max 50 | 50 (a literal — see below) |
| Action executions / 5 min | 100,000 | ~30,000 |

**That last row is why `Enrich_candidates` contains exactly one action.** The reference
implementation in `ti_handling_automation` uses three actions per iteration, which is
right for a handful of IPs from an incident and would be ~90,000 here — close enough to
the ceiling to be throttled. Everything the extra actions did is done afterwards, in one
pass, by `Compose_lookups` (`result('Enrich_candidates')`) and `Select_enriched`.

**Three values in this definition are literals and cannot be parameters**, because
they sit in *typed* parts of the workflow schema that are deserialized at deploy time
rather than evaluated at runtime. Putting `@parameters(…)` in any of them fails the
deployment with `Could not convert string to integer`, or its equivalent:

| Where | Value |
| --- | --- |
| `Enrich_candidates.runtimeConfiguration.concurrency.repetitions` | `50` |
| `Scheduled_review.recurrence` (frequency, interval, schedule, timeZone, startTime) | weekly, Mondays 07:00 CET |
| any action's `limit.timeout` | not currently used |

Change them in **both** `playbook/workflow.json` and `playbook/azuredeploy.json`; the
acceptance `diff` is what keeps the two honest, and the lint below catches the mistake
before Azure does.

Two consequences worth knowing before changing this:

- **Adding a second action inside the loop triples the action count.** Do the work
  outside the loop instead.
- **`Filter_duplicates` splits a ~450 KB string once per distinct entry.** It is one
  billed action but not a cheap one. If a run is slow, this is the first suspect.
  `Compose_line_map` builds a string of the same order of magnitude, but only the
  findings — not every entry — are looked up in it.

Billing is now per action rather than the single asynchronous call the function
allowed: roughly 30,000 connector actions per run instead of one. At a weekly cadence
that is the trade made for a playbook that actually runs.

## The ticket

**Every run raises one**, findings or not. Project `CLOPSSEC`, issue type **id `10`**,
assigned to `secops`, created with a plain `POST /rest/api/2/issue` — no clone dance,
because this issue type has no `customfield_24305` (Assets) requirement, unlike the
OPSLSY changes the other playbooks raise.

The issue type is sent as an **id**, not a name. `"issuetype": {"name": "Task"}` is
rejected by Trackspace with `HTTP 400 You are not allowed to create this isse type.`
(sic) — the name does not resolve to a type `sentinelsvc` may create in `CLOPSSEC`.
Id `10` is what `sentinel_logs_weur3_opener` uses for its CLOPSSEC tickets, which is
the only CLOPSSEC creator in this repo proven in production. Override with the
`JiraIssueTypeId` parameter if the project's create screen changes.

**Title:** `index.html IP review` — the blob's file name plus `TicketSummarySuffix`.

**Description:**

```
Run ID: 08584512345678901234567890
Start: 2026-08-25 09:14
End: 2026-08-25 09:18
Flagged IPs: 7

Coverage: lsyweuritcsprdmspalo001/$web/index.html - 812 entr(ies) read, 809 distinct,
2 internal, 1 malformed, 3 duplicated, 2 public CIDR range(s) not checked, 806 checked
against AbuseIPDB, 0 lookup error(s).

Rules applied: internal / non-routable, malformed, duplicate entry, whitelisted ISP
below an AbuseIPDB confidence score of 80.

Raised automatically by the blob-review Logic App. Findings, with the blob line each
one sits on, are in the attachment.
```

The first four lines are the specified format. **Everything from `Coverage:` down is
an addition** — without it, a run that could not reach AbuseIPDB produces
`Flagged IPs: 0` indistinguishable from a genuinely clean scan. Times are
Central European, matching the other playbooks in this collection.

**Attachment**, only when there is something to flag:
`index.html-ip-review-20260825-091800.csv`, one row per finding, sorted by line:

| Column | |
| --- | --- |
| `ip` | The entry as it appears in the blob |
| `reason` | Which rule fired. Whitelist hits carry the matching ISP: `whitelisted ISP (Akamai Technologies Inc.) below score` |
| `line number` | **1-based line number in the blob**, counting comments and blanks |
| `abuseConfidenceScore` | AbuseIPDB score, or `n/a` |

`Create_findings_CSV` sets `columns` explicitly rather than letting the **Table**
action infer them, which would take the header names and their order from the first
object's keys.

**`n/a` is never `0`.** Internal and malformed entries are excluded from enrichment by
design and have no score to report. A *duplicate* usually does have one — it can be a
perfectly routable address that was enriched — so those rows carry the real score,
looked up from `Compose_score_map`. A lookup that failed is recorded as `n/a` there
too, rather than being coalesced to `0` and read as a clean address.

The ISP goes in `reason` with its commas stripped, because the **Table** action does
not quote fields: an unedited `Akamai Technologies, Inc.` would split the row.

### How the line number is recovered

Every filter downstream of `Distinct_entries` works on de-duplicated entry *strings*,
so by the time a finding exists its position in the file is long gone. Carrying the
index through instead would mean rewriting all seven filters to address objects, and
`union()` would no longer de-duplicate.

Instead `Number_lines` pairs `Trim_lines` — which is 1:1 with the split blob — with
`range()`, and `Compose_line_map` joins the result into one flat `[entry]=n;` string.
A lookup is then two `split()`s and no loop, so **the two extra actions are all it
costs, whether the blob has 8 lines or 30,000**. The score map works the same way.

Two consequences worth knowing:

- A repeated entry reports the line of its **first** occurrence. One row per finding
  keeps the CSV row count equal to `Flagged IPs`; the repeats are the lines after it.
- The map is delimited with `[`, `]=` and `;`. A malformed entry containing those
  characters could collide. Appending the key's own `=0` fallback before splitting
  means such an entry reports line `0` instead of failing the run.

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


## Deploy

One step, because there is nothing to publish. `deploy.sh` / `deploy.ps1` ship in this
directory and deploy the template next to them, so a clone is the whole setup.

**Every command below is one line per line** — no `\` continuations and no `&&`, which
break when pasted into PowerShell (Azure Cloud Shell's default).

```
git clone -b claude/blob-review-automation-triggers-ix9sjl https://github.com/4d4MP/azure-logic-app-collection.git
cd azure-logic-app-collection/blob_review
./deploy.sh --grant
```

PowerShell is `./deploy.ps1 -Grant`. Only this playbook? Add `--filter=blob:none
--sparse` to the clone, then `git sparse-checkout set blob_review`.

The scripts check that **`abuseipdbapi-1` exists** before deploying. It is owned by OMS
and this template does not create it; without it the deployment succeeds and every
enrichment call then fails at runtime.

They also read the live workflow back afterwards and print the Jira issue type id it
is actually running with. A redeploy from a stale checkout succeeds and changes
nothing, so without that readback a fixed bug reappears looking identical to the
original — `git pull` first, and check the printed id is the one you expect.

### One-time prerequisites

1. **Key Vault access for the Logic App**, to read the Trackspace password.
   `--grant` asks the vault for `enableRbacAuthorization` and grants accordingly —
   **Key Vault Secrets User** on an RBAC vault, a **get** access policy on a legacy
   one. Guessing wrong is silent: enabling Azure RBAC [invalidates every access
   policy](https://learn.microsoft.com/azure/key-vault/general/rbac-guide) while
   `az keyvault set-policy` still succeeds.
2. **Storage Blob Data Reader for the Logic App** on `lsyweuritcsprdmspalo001`.
   Reader is enough; this playbook never writes.
3. **The `abuseipdbapi-1` connection must exist and be authorised.** It carries the
   AbuseIPDB key. There is no AbuseIPDB secret in Key Vault for this playbook.
4. **`JiraIssueTypeId` must name a type `sentinelsvc` may create in `CLOPSSEC`.**
   Default `10`. If the ticket comes back `HTTP 400 You are not allowed to create
   this isse type.` (sic — Jira's own typo), the id is wrong for the project's
   create screen or permission scheme; nothing else in the payload is at fault, as
   the empty `errors` map shows. Ask Jira rather than guessing:

   ```
   ./jira-issue-types.ps1
   ./deploy.ps1 -IssueTypeId <id from the list>
   ```

   Bash is `./jira-issue-types.sh` and `./deploy.sh --issue-type-id <id>`. The
   lister reads the `sentinelsvc` password from Key Vault for one `createmeta`
   call and never prints it; it needs **your own** account to have `get` on that
   vault's secrets, which the Logic App's grant does not give you.

## Smoke test

```
./smoke-test.ps1 -ChecksOnly                  # preflight only, fires nothing
./smoke-test.ps1 -BlobPath test/sample.txt    # review a small seeded blob
./smoke-test.ps1                              # the full production blocklist
```

Bash is `./smoke-test.sh`, `--checks-only`, `--blob-path`. The preflight checks the
Logic App and its identity, the AbuseIPDB connection, both grants against whichever
vault model is live, and that `Scheduled_review` is armed. Anything the caller cannot
read is a **warning**, not a failure, so it stays useful run by someone without vault
visibility.

**A full run costs one AbuseIPDB lookup per distinct public single address — roughly
30,000 — and raises a real CLOPSSEC ticket.** The script confirms before firing at the
default blob; `--blob-path` at a small seeded blob skips the prompt and the quota.

## Sync / acceptance

`playbook/workflow.json` and `playbook/azuredeploy.json` must not drift:

```bash
diff <(jq -S '.definition.triggers,.definition.actions' playbook/workflow.json) \
     <(jq -S '.resources[]|select(.type=="Microsoft.Logic/workflows")|.properties.definition|.triggers,.actions' playbook/azuredeploy.json)
```

Must be empty. The only permitted residual difference is the definition parameters'
`defaultValue`s — literals in `workflow.json`, `[parameters('…')]` in ARM.

…but `./validate.py` checks that and more, offline, in under a second. **Both deploy
scripts run it before touching Azure**, and it is worth running by hand after any edit:

```
./validate.py
```

Every check in it exists because a real deployment was rejected by it:

| Check | The deployment error it prevents |
| --- | --- |
| **drift** | the two files disagreeing — no Azure error, just a silent surprise later |
| **static** | `Could not convert string to integer: @parameters('…')` |
| **refs** | `cannot reference action 'X'. Action 'X' must either be in 'runAfter' path…` |
| **rules** | `Only a single trigger with concurrency control is supported` |
| **rules** | `WorkflowUnsupportedRecurrenceTriggerForResponseAction` |
| **params** | a `parameters('…')` that is not declared — which fails at *runtime*, not deploy |

It also prints non-fatal notes: a `Foreach` with more than one action in its body (the
throughput trap above) or no concurrency setting, and declared-but-unused parameters.

Azure reports one validation error per attempt and each attempt is a round trip; this
found four of them at once.

A test blob seeded with one of each kind:

```
10.34.2.7        internal              -> flagged
172.20.5.1       internal (172.16/12)  -> flagged
999.1.1.1        malformed (octet)     -> flagged
junk             malformed (shape)     -> flagged
185.0.0.0/24     public CIDR           -> skipped, not checked
23.55.x.x        Akamai, low score     -> flagged
<known bad IP>   score >= 80           -> NOT flagged
<known bad IP>   repeat of the line above -> flagged as a duplicate
```

should raise exactly one CLOPSSEC ticket titled `sample.txt IP review`, assigned to
`secops`, `Flagged IPs: 6`, with a six-row CSV. Written with the `#` comment line
first and one blank line after the two internal addresses, that CSV is:

```
ip,reason,line number,abuseConfidenceScore
10.34.2.7,internal / non-routable,2,n/a
172.20.5.1,internal / non-routable,3,n/a
999.1.1.1,malformed,5,n/a
junk,malformed,6,n/a
23.55.1.1,whitelisted ISP (Akamai Technologies Inc.) below score,8,12
45.148.10.90,duplicate entry,9,100
```

Three things to check in it, because each one is a separate mechanism: the line
numbers **count the comment and the blank line**, so they are file positions and not
entry positions; the duplicate reports **9, the first of its two lines**, not 10; and
its score is the **real 100**, not `n/a`, because a duplicate can still be an address
that was enriched. Only the rows that were never sent to AbuseIPDB read `n/a`.

Then a clean blob: still one ticket, `Flagged IPs: 0`, **no attachment**. And two
negative tests — point `JIRAHOST` at an unreachable host and confirm the run ends
**Failed** with `Jira_health_check` red *while* enrichment is still running; and
rename `AbuseIPDBConnectionName` to something absent and confirm `./deploy.sh` refuses
before deploying.

Three Logic Apps validation rules reject this workflow the moment someone reintroduces
what they forbid — a `Response` action, a trigger `concurrency` block, or a `listKeys`
call in ARM `variables`. All three fail the deployment rather than the run, so
`./deploy.sh` is the test.
