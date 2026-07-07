# sentinel_logs_weur3-Opener

Private reference + working repo for the **next** Sentinel-triggered Azure Logic App:
a West-Europe ("weur3") **ticket "Opener"** that raises a Trackspace/`CLOPSSEC` issue
from a Sentinel signal.

This repo is a **fork-point from `TI-handler`** minus the parts an opener doesn't need
(no AbuseIPDB enrichment, no approval wait-loop, no blocklist blob PUT). It carries the
reusable environment constants, the Sentinel→Logic-App trigger contract, the Trackspace
create-issue pattern, the Key Vault plumbing, and the deployment discipline so a future
session (human or LLM) can build the Opener without re-deriving any of it.

## What to read first (directly relevant to an Opener)

| Priority | File | Why |
|---|---|---|
| ★★★ | `reference/02-sentinel-to-logic-app-trigger.md` | The trigger payload + automation-rule wiring — how the Opener gets invoked |
| ★★★ | `reference/03-jira-integration.md` | Trackspace create-issue (`POST /rest/api/2/issue`), Basic-auth `sentinelsvc`, plain-string descriptions |
| ★★★ | `reference/07-ti-handler-playbook.md` | The closest deployed analog. Fork this shape; delete enrichment/approval/blob |
| ★★ | `reference/05-keyvault-and-secrets.md` | MSI-backed KV connection, `sentinelsvc` secret, `parameterValueType: Alternative` gotcha |
| ★★ | `reference/06-secure-architecture-and-coding.md` | Least-privilege RBAC, IaC discipline, review checklist |
| ★ | `reference/00-master-walkthrough.md` | End-to-end architecture map, term glossary |
| ★ | `reference/01-logic-apps-fundamentals.md` | Designer basics if starting cold |
| ○ | `reference/04-blob-storage.md` | Only if the Opener also writes an audit log line |
| ○ | `reference/08-wiz.md` | Only if enriching with Wiz asset context |

Also see:
- `env/environment-constants.md` — subscription, RGs, KV, workspace, Trackspace constants (no secrets).
- `ti-handler-repo-notes.md` — pointers into the `TI_handleing_automation` repo + its reusable patterns.
- `docs/deployment-discipline.md` — the "file-07" ARM deploy rules, `jq -S` diff gate, MI-preservation.
- `playbook/` — empty scaffold to hold `workflow.json` + `azuredeploy.json` for the Opener.

## What an Opener drops vs TI-handler

```
TI-handler                                    weur3-Opener (target)
──────────────────────────────────────        ──────────────────────────────────
Sentinel trigger                       ✓  →   Sentinel trigger              keep
Entities - Get IPs                     ✓  →   (entity read as needed)       keep/adapt
Get_Jira_password (KV)                 ✓  →   Get_Jira_password (KV)        keep
AbuseIPDB health + per-IP enrichment   ✓  →   —                             DROP
Filter / Kept_IPs / MinReports         ✓  →   —                             DROP
Create_Jira_Task (POST /issue)         ✓  →   Create_Jira_Task             keep (core)
Comment_Jira_URL_on_incident           ✓  →   Comment_Jira_URL_on_incident  keep
Wait_For_Approval (Until, PT48H)       ✓  →   —                             DROP
Approval→InProgress→Resolved→Closed    ✓  →   —                             DROP
Update blocklist blob ($web/index.html)✓  →   —                             DROP
```

The Opener is essentially TI-handler's **create-ticket + comment** core with the
enrichment, approval, and remediation stages stripped out.

## Provenance

Reference docs (`reference/00..08`) are verbatim copies of the numbered knowledge-base
files from the parent Claude project (generated Apr–May 2026). The 2.1 MB
`L3_SecOps_Content.md` source dump is **not** copied here — it lives in the parent project
if deep-dive context is needed.

Nothing in this repo contains a secret value. `TRACKSPACE_PAT`, KV passwords, and CA
bundles stay in the environment / Key Vault per `.gitignore`.
