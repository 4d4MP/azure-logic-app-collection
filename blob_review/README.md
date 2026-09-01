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
                                 → Filter_whitelisted_isp
            → Rows_* → Compose_findings → Create_findings_CSV → Capture_run_end
            → Create_CLOPSSEC_ticket   ALWAYS, findings or not
            → Parse_ticket_response → Findings_attachment_gate → Assign_ticket
            → Guard_lookup_errors
                 ├─ errors > MaxLookupErrors → Terminate Failed
                 └─ Compose_run_result
```

`Get_Jira_password` → `Jira_health_check` runs as its own branch alongside the whole
review and joins at `Create_CLOPSSEC_ticket`, so a broken Trackspace credential shows
up in seconds rather than after the scan.

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

**Whitelisted ISP** runs after enrichment: `isp` in `WhitelistedIsps` (lower-cased)
**and** `abuseConfidenceScore` below `WhitelistedIspMaxScore` (80).

## Scale, and the limits that shaped it

For a ~30,000-entry blocklist, against the [Consumption
limits](https://learn.microsoft.com/azure/logic-apps/logic-apps-limits-and-config):

| Limit | Value | This playbook |
| --- | --- | --- |
| For-each array items | 100,000 | ~30,000 candidates |
| For-each concurrency | max 50 | 50 (`EnrichmentParallelism`) |
| Action executions / 5 min | 100,000 | ~30,000 |

**That last row is why `Enrich_candidates` contains exactly one action.** The reference
implementation in `ti_handling_automation` uses three actions per iteration, which is
right for a handful of IPs from an incident and would be ~90,000 here — close enough to
the ceiling to be throttled. Everything the extra actions did is done afterwards, in one
pass, by `Compose_lookups` (`result('Enrich_candidates')`) and `Select_enriched`.

Two consequences worth knowing before changing this:

- **Adding a second action inside the loop triples the action count.** Do the work
  outside the loop instead.
- **`Filter_duplicates` splits a ~450 KB string once per distinct entry.** It is one
  billed action but not a cheap one. If a run is slow, this is the first suspect.

Billing is now per action rather than the single asynchronous call the function
allowed: roughly 30,000 connector actions per run instead of one. At a weekly cadence
that is the trade made for a playbook that actually runs.

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

should raise exactly one CLOPSSEC Task titled `sample.txt IP review.`, assigned to
`secops`, `Flagged IPs: 6`, with a CSV of six rows and `n/a` in the AbuseIPDB columns
of every row except the Akamai one.

Then a clean blob: still one ticket, `Flagged IPs: 0`, **no attachment**. And two
negative tests — point `JIRAHOST` at an unreachable host and confirm the run ends
**Failed** with `Jira_health_check` red *while* enrichment is still running; and
rename `AbuseIPDBConnectionName` to something absent and confirm `./deploy.sh` refuses
before deploying.

Three Logic Apps validation rules reject this workflow the moment someone reintroduces
what they forbid — a `Response` action, a trigger `concurrency` block, or a `listKeys`
call in ARM `variables`. All three fail the deployment rather than the run, so
`./deploy.sh` is the test.
