# Topic 07: TI-handler — Deployed IP-Abuse Triage Playbook

Generated: 2026-05-12 | Sources: deployment session + repo `TI_handleing_automation` | Confidence: high (deployed and smoke-tested)

## Scope

This file documents the actual production Sentinel playbook deployed in the LHsystems environment as `TI-handler` (resource type `Microsoft.Logic/workflows`). It's the concrete realisation of the abstract patterns in files 00–06: a Sentinel-incident-triggered Logic App that enriches IP entities via AbuseIPDB, opens an approval ticket in Trackspace `CLOPSSEC`, polls for analyst approval, walks the ticket through `Approval → In Progress → Resolved → Closed` around a static-site blocklist update.

Where this file contradicts the earlier topic files, **this file wins** for the TI-handler specifically — the earlier files describe the design space, this one describes the chosen point.

Out of scope: the repo's reference workflows (`docs/references/abuseipdb_enrichment.json` etc.) which are illustrative ancestors, not deployed code.

## Resources (production)

| Aspect | Value |
|---|---|
| Subscription | `f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29` (LSY_WEUR_ITCS_PRD_001) |
| Logic App | `TI-handler` (renamed from initial `Sentinel-IPAbuse-TriageAndBlock`) |
| Logic App RG | `LSY_WEUR_ITCS_PRD_SEC_RG_002` (westeurope) |
| Logic App MI principalId | `d3676c47-5dff-492b-aecb-fb229a20fcfa` (system-assigned, fresh from redeploy) |
| Sentinel API connection | `azuresentinel-TI-handler` (MSI-backed, kind `V1`) — **NEW**, deployed alongside the playbook |
| Key Vault API connection | `keyvault-TI-handler` (MSI-backed) — **NEW**, deployed alongside the playbook |
| AbuseIPDB connection | `abuseipdb-connection-AbuseIPDB-EnrichIncidentByIPInfo` in `LSY_WEUR_ITCS_PRD_OMS_RG_001` — **OMS-owned, referenced not created** |
| Key Vault | `LSY-WEUR-ITCS-PRD-KV-02` in `SEC_RG_002` |
| KV secret consumed | `sentinelsvc` (password for the Trackspace service account) |
| Sentinel workspace | `lsy-prd-oms` in `lsy_weur_itcs_prd_oms_rg_001` (cross-RG, same subscription) |
| Storage account | `lsyweuritcsprdmspalo001` in `LSY_WEUR_ITCS_PRD_SEC_RG_001` (note: **_001**, different from playbook's **_002**) |
| Blocklist blob | `$web/index.html` (static-site container, served as text/html) |

Important deviations from the fleet's "shared API connections" pattern: this playbook deploys **its own** `azuresentinel-*` and `keyvault-*` connections rather than reusing the production-shared `LSY-WEUR-ITCS-PRD-APICON-SENTINEL` / `LSY-WEUR-ITCS-PRD-APICON-KV` connections. This was a conscious accepted divergence: the ARM template is self-contained and reproducible, at the cost of one extra Sentinel connection in the RG. The OMS-owned AbuseIPDB connection is the only resource not duplicated.

## RBAC granted to the playbook's MI

Three role assignments, at the smallest meaningful scope:

| Role | Scope | Why |
|---|---|---|
| Microsoft Sentinel Responder | workspace `lsy-prd-oms` | Read incident entities; post comments on incidents |
| Key Vault Secrets User | vault `LSY-WEUR-ITCS-PRD-KV-02` | Read the `sentinelsvc` secret |
| Storage Blob Data Contributor | storage account `lsyweuritcsprdmspalo001` | GET + PUT `$web/index.html` |

Plus one role for **Sentinel itself** (the "Azure Security Insights" first-party SP, AppId `98785600-1bb7-4fb9-b9fa-19afe2c8a360`) at the playbook's RG scope, required for the playbook to appear in the Sentinel portal's playbook picker:

| Role | Scope |
|---|---|
| Microsoft Sentinel Automation Contributor | RG `LSY_WEUR_ITCS_PRD_SEC_RG_002` |

This second role caught us out during smoke test: the playbook deployed cleanly, the MI had its three roles, but the playbook didn't show up in `Actions → Run playbook` on a closed incident. Sentinel scans for playbooks in RGs where its own SP has Automation Contributor, not via any registry inside Sentinel itself.

## End-to-end flow

```
Sentinel incident (trigger)
  │
  ├─► Entities - Get IPs
  │
  ├─► Get_Jira_password (KV, secureData)
  ├─► AbuseIPDB_health_check (GET /check?ipAddress=8.8.8.8)
  │       ├─(Failed/TimedOut/Skipped)─► [manual-Jira fallback path]
  │       │     ├─ Build_raw_IP_array + Build_raw_CSV (no enrichment)
  │       │     ├─ Create_Manual_Jira_Task → Attach_raw_CSV_to_Jira
  │       │     └─ Comment_Manual_Jira_URL_on_incident
  │       │     (workflow ends; no blocklist update, manual analyst review)
  │       │
  │       └─(Succeeded)─►
  │
  ├─► Jira_health_check (GET /rest/api/2/myself, Basic sentinelsvc)
  │       ├─(Failed/TimedOut/Skipped)─► Comment_Jira_unreachable + Terminate_Jira_unreachable
  │       └─(Succeeded)─►
  │
  ├─► Initialize Kept_IPs, Report_Rows
  │
  ├─► Check_each_IP_in_AbuseIPDB (sequential foreach, repetitions=1)
  │       per IP: HTTP_Check_IP → Append_Report_Row → Filter_Condition → Append_to_Kept_IPs
  │
  └─► Empty_result_gate
      (runAfter: Check_each_IP_in_AbuseIPDB ∧ Get_Jira_password)
        │
        ├─[Kept_IPs is empty]─►
        │     ├─ Comment_No_Actionable_IPs
        │     └─ Terminate (Succeeded)
        │
        └─[else]─►
              ├─ Build_CSV (Table action, format=CSV)
              ├─ Create_Jira_Task (POST /rest/api/2/issue, Basic auth)
              ├─ Parse_Create_Jira_Task_Body
              ├─ Attach_CSV_to_Jira (POST /attachments, multipart)
              ├─ Comment_Jira_URL_on_incident
              │
              ├─ Wait_For_Approval (Until loop)
              │     every PT5M:
              │       Delay_Between_Polls → HTTP_Get_Jira_Issue → Parse_Jira_Status
              │     exit when toLower(status.name) == toLower(JiraApprovalStatusName)
              │     cap: 576 iterations OR PT48H
              │
              └─ Final_Switch on (approved | not_approved)
                    │
                    ├─ approved:
                    │     ├─ Approve_Jira_Ticket  (POST /transitions id 811: Approval → In Progress)
                    │     │       └─[Failed]─► Comment_Approve_Failed (blocklist NOT touched)
                    │     ├─ Append_IPs_to_Blocklist  (Scope)
                    │     │       ├─ Get_blob_content → Compose_existing_content → Compose_existing_lines
                    │     │       ├─ Filter_Unique_New_IPs (line-level dedupe)
                    │     │       └─[if anything new]─► Compose_new_blocklist_content → Update_blob (PUT)
                    │     ├─ Comment_Approved_on_incident
                    │     ├─ Resolve_Jira_Ticket  (POST /transitions id 5: In Progress → Resolved)
                    │     ├─ Close_Jira_Ticket    (POST /transitions id 701: Resolved → Closed)
                    │     └─[Resolve/Close Failed]─► Comment_PostBlob_Transition_Failed
                    │
                    └─ default (timeout / not approved):
                          └─ Comment_Not_Approved_on_incident
```

Three things to note about the shape:

1. **`AbuseIPDB_health_check` and `Get_Jira_password` run in parallel** after `Entities - Get IPs` — `Empty_result_gate` is the merge point and explicitly `runAfter` both. This is the layout that survived ARM validation; an earlier attempt had `Create_Jira_Task` referencing `Get_Jira_password` without the latter being on its runAfter ancestry, which Logic Apps rejects at deploy time with `cannot reference action 'Get_Jira_password'`.
2. **Manual-Jira fallback when AbuseIPDB is unreachable** doesn't try to triage anything — it just opens a Trackspace ticket with the raw IP list (no enrichment) so analysts still have a queue item. The blocklist is not modified.
3. **Approve → blob → Resolve → Close**, not blob → close. The transition to In Progress runs *before* the blob update, so the ticket state reflects what the playbook is doing. If `Approve_Jira_Ticket` fails, `Append_IPs_to_Blocklist` does not run — the workflow refuses to act on the blocklist without first acknowledging the approval on the ticket.

## Trackspace transition chain (CLOPSSEC workflow)

Probed against `CLOPSSEC-42210` on 2026-05-12. CLOPSSEC's Jira workflow doesn't have a single Approval→Closed transition; the playbook walks three sequential transitions:

| From | To | Transition id | Transition name |
|---|---|---|---|
| Approval | In Progress | `811` | "Approve" |
| In Progress | Resolved | `5` | "Resolve issue" |
| Resolved | Closed | `701` | "Close" |

All three are parameterised in the workflow:

- `JiraApproveTransitionId` (default `"811"`)
- `JiraResolveTransitionId` (default `"5"`)
- `JiraCloseTransitionId` (default `"701"`)

The transition workflow is **state-dependent**: the set of transitions available from a ticket changes based on its current status. The IDs above were confirmed via `GET /rest/api/2/issue/{key}/transitions` on a ticket actually in each state. If the CLOPSSEC workflow ever changes, re-probe and update the parameter values — code change not required.

How to probe (using a personal PAT for diagnostics; the playbook uses Basic auth with the service account):

```bash
# Pull a ticket currently in the source state
curl -sS -H "Authorization: Bearer $TRACKSPACE_PAT" \
  'https://trackspace.lhsystems.com/rest/api/2/search?jql=project%3DCLOPSSEC%20AND%20status%3D%22approval%22&fields=key,status&maxResults=1' \
  | python3 -m json.tool

# List transitions available from that state
curl -sS -H "Authorization: Bearer $TRACKSPACE_PAT" \
  "https://trackspace.lhsystems.com/rest/api/2/issue/<KEY>/transitions" \
  | python3 -m json.tool
```

The "Approve" transition from Approval is named honestly (Approval → In Progress is exactly what an analyst-approval should look like). Earlier exploration noted that the only direct Approval → Resolved transition is named `"Reject"` (id `821`) — semantically wrong for our use case. The In Progress detour preserves accurate audit-log semantics: every state change is named for what it actually means.

## Approval polling semantics

The Until loop runs while `toLower(coalesce(fields.status.name, '')) != toLower(parameters('JiraApprovalStatusName'))`, where `JiraApprovalStatusName` defaults to `"approval"`. Comparison is case-insensitive so "Approval", "APPROVAL", and "approval" all match.

`Wait_For_Approval` limits: 576 iterations × PT5M poll interval = PT48H timeout. If the loop times out, the Until action ends in `Failed` / `TimedOut`; the downstream `Final_Switch` is wired with `runAfter: ["Succeeded","Failed","TimedOut"]` so it still runs, lands in the `default` branch, and posts "approval not received" — the blocklist is **not** modified.

## Blocklist update semantics

1. `GET https://lsyweuritcsprdmspalo001.blob.core.windows.net/$web/index.html` using MI (`audience=https://storage.azure.com/`). Direct HTTP, not the Azure Blob connector — the V2 connector double-URL-encodes the `$web` container path.
2. Split content on `\n` after stripping `\r`; filter `Kept_IPs` against the resulting array via exact-equality line membership. `1.1.1.1` is not "already present" merely because `1.1.1.10` is. This is line-level dedupe.
3. If new IPs remain, build `<existing>[<\n if needed>]<joined-new>\n` and `PUT` back as `BlockBlob` with `x-ms-blob-content-type: text/html` (preserves the static-site MIME).
4. If nothing new, skip the PUT but still comment on the incident.

### Known race window — concurrent approvals

The PUT is unconditional (no `If-Match`, no blob lease). If two playbook runs reach `Update_blob` simultaneously, the later writer wins and the earlier writer's IPs are lost. Window is a few seconds between `Get_blob_content` and `Update_blob` per run, so collisions require analysts to approve two tickets within roughly that window.

Mitigation is operational: re-run the playbook on each affected incident — the line-level dedupe makes re-runs idempotent. Lost IPs get re-appended on retry.

If collisions are observed in practice, switch `Update_blob` to use the `ETag` from `Get_blob_content` as an `If-Match` header with an Until-retry on `412 Precondition Failed`. The current design accepted this trade-off to stay simple.

## Failure-comment design — fail-loud, two distinct messages

The APPROVED branch has two separate failure-handler actions because the remediation differs:

- **`Comment_Approve_Failed`** — fires when `Approve_Jira_Ticket` fails. Tells the analyst the blocklist was NOT modified and to fix the ticket-side issue + re-run.
- **`Comment_PostBlob_Transition_Failed`** — fires when either `Resolve_Jira_Ticket` or `Close_Jira_Ticket` fails. Tells the analyst the blocklist WAS modified, the ticket is stuck in In Progress or Resolved, manual transition needed.

The blocklist update is the actual security action; ticket housekeeping is cosmetic. The playbook never rolls back the blocklist when later transitions fail — that's a deliberate design choice. The Sentinel incident comment always tells the truth about what actually happened.

## Parameter reference

Tunable in the portal (`Logic app → Edit → ⚙ Parameters`) without redeploying ARM:

| Parameter | Default | Purpose |
|---|---|---|
| `JIRAHOST` | `https://trackspace.lhsystems.com` | Trackspace base URL |
| `JIRAUserName` | `sentinelsvc` | Service account for Basic auth |
| `JiraKeyVaultSecretName` | `sentinelsvc` | KV secret name (value = password) |
| `JiraProjectKey` | `CLOPSSEC` | Trackspace project for new tickets |
| `JiraIssueTypeName` | `Task` | Issue type — must exist in CLOPSSEC |
| `JiraApprovalStatusName` | `approval` | Wait-loop exit status (case-insensitive) |
| `JiraApproveTransitionId` | `811` | Approval → In Progress |
| `JiraResolveTransitionId` | `5` | In Progress → Resolved |
| `JiraCloseTransitionId` | `701` | Resolved → Closed |
| `StorageAccountName` | `lsyweuritcsprdmspalo001` | Static-site account |
| `BlocklistContainer` | `$web` | Container name |
| `BlocklistBlobPath` | `index.html` | Blob path |
| `MinReports` | `100` | AbuseIPDB `totalReports` threshold (lower = more aggressive) |
| `ExcludedISPs` | `["akamai technologies","google","palo alto networks","the shadowserver foundation","censys"]` | ISPs always dropped, lower-case |
| `ApprovalPollIntervalMinutes` | `5` | Wait-loop poll cadence |
| `ApprovalMaxIterations` | `576` | Wait-loop iteration cap |
| `ApprovalTimeout` | `PT48H` | Wait-loop wall-clock cap |

Keep `ApprovalMaxIterations × ApprovalPollIntervalMinutes ≈ ApprovalTimeout`.

## Deployment session — lessons captured

Lessons that surfaced during the actual deployment session, May 2026:

- **ARM `runAfter` validation is strict.** Every action in the workflow has to be reachable from every action that references its body via `runAfter` chains. The first deploy attempt failed because `Create_Jira_Task` referenced `body('Get_Jira_password')` while the runAfter ancestry only reached `AbuseIPDB_health_check`. Fix: add `Get_Jira_password` to `Empty_result_gate.runAfter`. Same pattern used in the upstream reference `trackspacejira_ticket_opener.json`.
- **Wrong subscription = `ResourceGroupNotFound`.** Cloud Shell opens with a default context that may not be `LSY_WEUR_ITCS_PRD_001`. `Set-AzContext -SubscriptionId f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29` is step zero.
- **KV firewall blocks Cloud Shell egress.** Listing secrets via `Get-AzKeyVaultSecret` from Cloud Shell hits `Forbidden`; portal verification or runtime test from the Logic App is the only validation path. MSI-backed connections reach KV fine at runtime — the firewall block only affects the operator's interactive session, not the playbook.
- **Renaming a Logic App is delete-and-recreate.** The resource name IS the URL identity. We deployed first as `Sentinel-IPAbuse-TriageAndBlock`, then deleted and redeployed as `TI-handler` — fresh MI, fresh API connections, fresh RBAC needed. The PowerShell `Remove-AzLogicApp` + `Remove-AzResource` flow handles cleanup.
- **`New-AzRoleAssignment` returns `Conflict` after success.** Az cmdlet quirk: the role assignment lands, but the cmdlet's read-after-write check returns 409 because the assignment already exists when it re-checks. Verify with `Get-AzRoleAssignment -ObjectId $miPrincipalId` rather than trusting the cmdlet's surface error.
- **`Microsoft Sentinel Automation Contributor` is a separate role assignment.** Sentinel needs this on the playbook's RG to surface the playbook in the picker. Distinct from the three roles the MI itself needs to do its work. Easy to miss because the playbook seemingly "deploys clean" without it.
- **MSI-backed connections auto-authorise.** Unlike OAuth-backed connectors, MSI-backed ones (`parameterValueType: Alternative`) don't need a portal "Authorize" click. They bind to the Logic App MI on first runtime use. Status `Ready` at first inspection is normal.

## When this playbook is wrong for the use case

Cases where the IP-Abuse Triage shape doesn't fit and a different playbook is the answer:

- **Per-IP tickets needed.** This playbook opens one aggregated ticket per Sentinel incident. If your workflow needs one ticket per IP, the create-or-comment loop has to move into the foreach — different shape, different failure modes.
- **Real-time block, no approval.** The Wait_For_Approval loop assumes there's an analyst willing to gate the block. For automatic blocking (e.g. known-bad TI feed, no human in the loop), the playbook should skip the Wait_For_Approval + Final_Switch entirely and run `Append_IPs_to_Blocklist` directly after the foreach.
- **Non-IP entities.** The trigger explicitly calls `Entities - Get IPs`. Account, Host, FileHash, and URL entities need different enrichment paths and a different playbook.
- **High-throughput campaign-style alerts.** Sequential foreach + 5-minute polling per ticket doesn't scale to 100+ incidents/hour. Consider coalescing on the Sentinel rule side (analytics rule grouping) or refactor the enrichment loop into a Function with per-IP parallelism.

## Maintenance notes

- **Source of truth is the repo** (`TI_handleing_automation/playbook/`). `workflow.json` and the `definition` block in `azuredeploy.json` are kept in sync by hand. Verify after every change:
  ```bash
  jq -S '.definition' playbook/workflow.json > /tmp/wf.json
  jq -S '.resources[2].properties.definition' playbook/azuredeploy.json > /tmp/arm.json
  diff /tmp/wf.json /tmp/arm.json   # must be empty
  ```
- **Re-deploy via ARM, not portal paste.** Portal code-view paste works for definition-only changes but drops portal changes the next time someone runs `New-AzResourceGroupDeployment`. Always mirror back to the repo files and redeploy.
- **Transition IDs are CLOPSSEC-workflow-specific.** If you fork the playbook for another Trackspace project, re-probe `GET /rest/api/2/issue/{key}/transitions` for that project's workflow and override the three transition parameters.
- **MI rotation.** If the Logic App is ever recreated (rename, restore, etc.), the system-assigned MI gets a new principalId — re-grant the four role assignments. Capture from `(Get-AzLogicApp -ResourceGroupName $RG -Name 'TI-handler').Identity.PrincipalId`.

## Cross-references

- **File 02** — Sentinel→Logic-App trigger payload, automation-rule wiring, the per-rule entity-mapping pitfall this playbook avoids by calling `Entities - Get IPs` rather than reading `triggerBody().object.properties.entities`.
- **File 03** — Trackspace integration patterns. The Basic-auth-with-`sentinelsvc` flow this playbook uses; the Bearer-PAT flow used by local Python scripts is described there too but is **not** the production playbook's pattern.
- **File 05** — KV API connection plumbing, the `parameterValueType: Alternative` MSI gotcha, RBAC verification.
- **File 06** — broader security architecture (least-privilege scoping, IaC discipline, code-review checklist) — applied by this playbook through the four narrow role assignments and the parameterised transition IDs.
