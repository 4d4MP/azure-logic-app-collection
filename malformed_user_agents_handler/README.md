# Malformed User Agents Incident Handler

**Logic App:** `malformed-user-agents-handler` (Consumption) in `LSY_WEUR_ITCS_PRD_SEC_RG_002`.
**Source of truth:** `playbook/workflow.json` + `playbook/azuredeploy.json`.
**Trigger:** Microsoft Sentinel incident creation (Malformed user agents detection rule).

The playbook enriches the incident's source IPs against AbuseIPDB, drops everything
below the report threshold or on the excluded-ISP list, and — when anything actionable
is left — raises an **OPSLSY Technical change**, walks it to Implementation, appends the
kept IPs to the Palo Alto blocklist blob, attaches the AbuseIPDB CSV, walks the change to
**Post implementation review**, assigns it to SecOps and closes the Sentinel incident.
**There is no human approval gate**; the change is deliberately left in Post implementation
review for a human to close.

> **History:** this playbook previously opened a **CLOPSSEC** approval Task and waited up
> to 48 h (`Wait_For_Approval`) for an analyst to move it to an approval status before
> touching the blocklist. That gate was removed and the ticket of record moved to an OPSLSY
> Technical change, mirroring the same refactor already applied to `ti_handling_automation`.
> The `Wait_For_Approval` Until loop, the `Final_Switch` approve/not-approved switch and the
> `Jira*TransitionId` / `Approval*` parameters are gone.

## Flow

```
Sentinel incident
  → Mark incident In Progress      (status → Active; tolerated failure)
  → Entities - Get IPs
  → Filter out local IPs           (RFC1918 / loopback / link-local / IPv6 local — dropped
                                    before anything is sent to AbuseIPDB)
  → Get Jira password (Key Vault)  → Jira health check      ─ fail → comment + Terminate
  → AbuseIPDB health check ─ fail → CLOPSSEC manual triage Task (raw IP CSV) + Terminate
  → Check each IP in AbuseIPDB     (totalReports >= MinReports, ISP not excluded → Kept_IPs)
  → Empty_result_gate
       ├─ no kept IPs → comment + close incident BenignPositive → Terminate Succeeded
       └─ kept IPs    → prime affinity cookie → Build_CSV
                        → Run_Change (scope — any failure inside routes to the failure handler)
                             clone OPSLSY-75376 via CloneIssueDetails.jspa
                             → find the new key by JQL search (Until)
                             → override description + Planned start/end
                             → create run-record sub-task (Operation sub-task)
                             → walk to Planning
                             → walk to Implementation  (Planned start/end recomputed fresh)
                             → append kept IPs to the blocklist blob
                             → attach the AbuseIPDB CSV
                             → walk to Post implementation review (resolution Successful)
                        → On success: assign change to SecOps, sub-task → Resolved,
                          comment + close the incident TruePositive → Terminate Succeeded
                        → On failure: sub-task → On Hold (best effort), comment on the
                          incident, Terminate Failed with the captured message
```

The AbuseIPDB-down fallback still opens a **CLOPSSEC** Task (`Create_Manual_Jira_Task`)
and is deliberately *not* repointed at OPSLSY.

### Local-IP filtering (before AbuseIPDB)

`Build_IP_Prefix_Keys` → `Filter_Out_Local_IPs` sit between `Entities - Get IPs` and
everything else, so a local address is never sent to AbuseIPDB, never enriched, never
blocked and never listed on the manual-triage CSV.

Logic Apps has no CIDR arithmetic and no higher-order functions, so "does this address
start with any of N prefixes" is inverted: `Build_IP_Prefix_Keys` projects each entity to
its own prefix keys and `Filter_Out_Local_IPs` tests those keys for membership in
`LocalIPPrefixes`.

| Key | For `192.168.1.5` | Catches |
| --- | --- | --- |
| `V4Prefix8` | `192.` | `0.` `10.` `127.` |
| `V4Prefix16` | `192.168.` | `169.254.` `172.16.`…`172.31.` `192.168.` |
| `V4Prefix24` | `192.168.1.` | room for your own /24s — add them to the parameter |
| `V6Prefix` | `19` | `::` (loopback/unspecified), `fc`/`fd` (unique-local), `fe` (link/site-local) |

The address is lower-cased and trimmed first, and empty addresses are dropped. Matching is
exact array membership on a whole octet boundary, so `1.10.0.1`, `172.15.x`, `172.32.x` and
`193.168.x` are correctly **kept** — a naive substring test would eat them.

Two deliberate non-entries: **`100.64.0.0/10`** (CGNAT) and **`224.0.0.0/4`** (multicast) are
*not* dropped — neither is "local", but add `100.64.`…`100.127.` to `LocalIPPrefixes` if your
edge NATs through shared address space. IPv4-mapped IPv6 (`::ffff:8.8.8.8`) is dropped by the
`::` entry; Sentinel does not emit that form for these entities.

### Sentinel incident lifecycle

The playbook owns the status of the single triggering incident
(`@triggerBody()?['object']?['id']` — no title lookup, no relay pattern):

| When | Action | Status |
| --- | --- | --- |
| First action of the run | `Mark_Incident_In_Progress` | **Active** |
| Enrichment kept nothing | `Close_Sentinel_no_actionable` | **Closed** — `BenignPositive - SuspiciousButExpected` |
| IPs blocked, change at Post implementation review | `Close_Sentinel_blocked` | **Closed** — `IncidentClassificationAndReason` (`TruePositive - SuspiciousActivity`) |
| Jira unreachable / AbuseIPDB unreachable / change failed | comment only | **left Active** for manual handling |

`Mark_Incident_In_Progress` runs first and its failure is **tolerated** —
`Entities - Get IPs` runs after it on `Succeeded`/`Failed`/`TimedOut`, so a Sentinel API
hiccup on a cosmetic status write never blocks the blocking mission. Both closes post a
comment naming the ticket immediately before flipping the status.

`docs/Malformed_user_agents.drawio` is the design diagram this work was built from.

## Ticket mechanics

The OPSLSY change lifecycle is a port of the canonical pattern documented in
[`../ti_handling_automation/docs/07-ti-handler-playbook.md`](../ti_handling_automation/docs/07-ti-handler-playbook.md).
Read that page for the *why*; the short version:

- **Clone, don't create.** `customfield_24305` (Affected item) is a Riada Insight/Assets
  field that no REST write shape can set, and it is required to pass *Start implementation*.
  A server-side clone of the template carries it intact, so the change is cloned via
  `POST /secure/CloneIssueDetails.jspa` (`X-Atlassian-Token: no-check`, form-encoded).
- **302 is success.** The servlet answers `302`; the Logic App HTTP action reports that as
  Failed. `Check_Clone_Status` runs on Succeeded *and* Failed and gates on
  `less(coalesce(statusCode, 599), 400)`.
- **Find the key by search, not by scraping the redirect.** `Find_Clone_Key` polls
  `GET /rest/api/2/search` (reporter + `created >= -10m`, `maxResults=1`, `retryPolicy: none`)
  every 10 s, 18×/`PT4M`. `Set_Clone_Key` sits at the loop's own top level — a value set
  inside a nested `If` is not reliably visible to the `Until` exit check.
- **Planned start/end are computed fresh at every write** (`utcNow()` / `+30 min`), on the
  override PUT *and* on the Implementation transition. Jira rejects a past Planned start and
  the fields are minute-granular, so a value pinned at run start goes stale during the walk.
  Actual start/finish (`customfield_23600`/`23601`, PIR transition) come from
  `Compute_Run_Times`, i.e. the real run start / +10 min.
- **The walk is name-driven, never by transition id.** Each step re-probes
  `GET /issue/{key}/transitions?expand=transitions.fields` and picks the transition whose
  `to.name` contains the target status, skipping revoke/withdraw/re-plan/reject/cancel/
  update-cmdb. No match → `Failure_Message` + forced failure, never an empty transition id.
  After each POST the status is polled (`Until`, 10 s, 60×/`PT10M`) — the poll runs even
  when the POST itself reported Failed/TimedOut, because heavy Trackspace transitions drop
  the connection but still commit — and a fresh `GET ?fields=status` confirms it landed.
- **Run-record sub-task.** Created before any transition; it doubles as the *Start
  implementation* "issue has a sub-task" validator. Its success transition sends Resolution
  and Planned start/end only when the transition's own field metadata offers them.
- **Session affinity.** `Prime_Affinity_Cookie` collects the Application Gateway's
  `Set-Cookie` (INT Trackspace `307`s cookie-less calls); every Jira call in the branch
  replays it. Harmless where the gateway has no affinity.

## Parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `JIRAHOST` | `https://trackspace.lhsystems.com` | INT is `https://int-trackspace.lhsystems.com` |
| `JIRAUserName` / `JiraKeyVaultSecretName` | `sentinelsvc` | Basic auth; secret read from Key Vault |
| `JiraProjectKey` | `CLOPSSEC` | **AbuseIPDB-down fallback Task only** — not the change ticket |
| `JiraIssueTypeName` | `Task` | Same fallback Task only |
| `JiraChangeProjectKey` | `OPSLSY` | Project of the Technical change and its sub-task |
| `TemplateIssueKey` | `OPSLSY-75376` | The change cloned on every run |
| `ChangeTicketSummary` | `Malformed user agent related IP blocking` | ` - yyyy.MM.dd` is appended for uniqueness |
| `SubtaskIssueTypeName` | `Operation sub-task` | |
| `SubtaskPriorityName` | `4 - Normal` | |
| `SubtaskAssigneeName` | `sentinelsvc` | Jira **login**, not an email |
| `SubtaskSuccessStatusName` / `SubtaskFailureStatusName` | `Resolved` / `On Hold` | |
| `SubtaskSuccessResolutionName` | `Successful` | Matched against the transition's allowed values |
| `MainTicketAssigneeName` | `secops` | Change assignee at Post implementation review |
| `StatusPlanningName` / `StatusImplementationName` / `StatusPostImplReviewName` | `Planning` / `Implementation` / `Post implementation review` | |
| `IncidentClassificationAndReason` | `TruePositive - SuspiciousActivity` | Close reason on the blocked path |
| `StorageAccountName` / `BlocklistContainer` / `BlocklistBlobPath` | `lsyweuritcsprdmspalo001` / `$web` / `index.html` | |
| `MinReports` | `100` | AbuseIPDB `totalReports` threshold |
| `ExcludedISPs` | Akamai, Google, Palo Alto, Shadowserver, Censys | Lower-case substring match |
| `LocalIPPrefixes` | RFC1918 + `0.` + `127.` + `169.254.` + `::` `fc` `fd` `fe` | Dropped **before** AbuseIPDB — see above |

ARM-only: `PlaybookName`, `Location`, `KeyVaultName`, `AbuseIPDBCustomApiResourceId`,
`AbuseIPDBConnectionResourceId`.

## Deploy

The deploy **must pass `PlaybookName` explicitly** (it is in
`playbook/azuredeploy.parameters.json`) so a redeploy updates this Logic App instead of
standing up a parallel one with a fresh managed identity.

```bash
RG=LSY_WEUR_ITCS_PRD_SEC_RG_002
az deployment group create \
  --resource-group "$RG" \
  --template-file playbook/azuredeploy.json \
  --parameters @playbook/azuredeploy.parameters.json
```

Managed-identity RBAC: **Microsoft Sentinel Responder** on the workspace, **Key Vault
Secrets User** on `LSY-WEUR-ITCS-PRD-KV-02`, **Storage Blob Data Contributor** on the
blocklist storage account. The AbuseIPDB connection is OMS-owned and referenced, never
created by this template.

Logic App runs are immutable: after a redeploy, cancel any stuck in-flight runs and fire
fresh ones.

### Sync / acceptance

```bash
diff <(jq -S '.definition.actions' playbook/workflow.json) \
     <(jq -S '.resources[]|select(.type=="Microsoft.Logic/workflows")|.properties.definition.actions' playbook/azuredeploy.json)
diff <(jq -S '.definition.triggers' playbook/workflow.json) \
     <(jq -S '.resources[]|select(.type=="Microsoft.Logic/workflows")|.properties.definition.triggers' playbook/azuredeploy.json)
```

Both must be empty. The only permitted residual `jq -S` difference between the two files is
the parameter `defaultValue`s — literals in `workflow.json`, `[parameters('…')]` in ARM.

A test run should produce exactly one OPSLSY Technical change titled
`Malformed user agent related IP blocking - <yyyy.MM.dd>` with one `Operation sub-task`,
reaching **Post implementation review** with resolution **Successful**, the CSV attached,
the blocklist blob appended, and the Sentinel incident closed **TruePositive**.
