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
