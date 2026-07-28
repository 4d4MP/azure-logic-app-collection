# Topic 02: Sentinel → Logic App Trigger

Generated: 2026-04-29 | Sources: 8 | Confidence: medium-high

## Scope

This file explains how Microsoft Sentinel hands an incident off to a Logic App: how playbooks are registered, the two trigger flavours (incident vs alert), the JSON payload shape, what each field means, how to test the wiring without waiting for a real attack, idempotency considerations, and the retries/timeouts that govern the handoff.

Out of scope: writing the analytics rule that *generates* the incident in the first place (that's a KQL topic, not a Logic Apps topic), and SOAR concepts beyond the Sentinel ↔ Logic App seam (covered in topic 06).

## Key entities & terms

- **Analytics rule**: a saved KQL query plus thresholds and grouping settings. When the query returns rows that match the conditions, an alert is created. [src 1]
- **Alert**: one detection event. Carries severity, tactics (MITRE ATT&CK), entities, the original event payload, and a link to the workspace.
- **Incident**: a case that bundles one or more related alerts so analysts work the case rather than each alert separately. Incidents have status (New / Active / Closed), classification (TruePositive / FalsePositive / BenignPositive), and tags. [src 2]
- **Automation rule**: an "if-this-then-that" rule that runs *on* incidents (or alerts) at create or update time. Conditions can match severity, tactics, analytics-rule ID, owner, etc. Actions can change incident properties or invoke a playbook. [src 3]
- **Playbook**: a Logic App registered with Sentinel. Two trigger flavours determine the payload: *Microsoft Sentinel incident* (post-grouping) and *Microsoft Sentinel alert* (pre-grouping). Modern best practice is incident-level. [src 4]
- **Microsoft Sentinel Responder** / **Microsoft Sentinel Playbook Operator**: RBAC roles that allow Sentinel to invoke a Logic App and let the Logic App report back to the incident. [src 5]
- **Trigger payload**: the JSON Sentinel passes into the Logic App as `triggerBody()`. Schema differs by trigger flavour and has evolved across Sentinel revisions. [src 4]

## Core facts

1. There are **two playbook trigger types**: *Microsoft Sentinel incident* and *Microsoft Sentinel alert*. The incident trigger is the modern default; the alert trigger predates incident grouping and remains for backward compatibility. [src 4]
2. A Logic App becomes a playbook the moment it has either of those triggers AND the right **RBAC** roles for Sentinel to invoke it. There is no separate "register" step beyond saving the workflow with the trigger. [src 4]
3. To run a playbook from Sentinel, the **Sentinel service principal** ("Azure Security Insights") needs the **Microsoft Sentinel Automation Contributor** role on the resource group containing the Logic App. Without this, the playbook will not appear in the Sentinel automation-rule action picker. [src 5]
4. The incident-trigger payload includes: incident ID, ARM ID, title, description, severity, status, classification, tags, owner, alerts (array), entities (array), labels, related analytic rule IDs, and a link back to the incident in the Sentinel UI. [src 4]
5. The **alert** payload (alert-trigger flavour) includes: alert display name, severity, status, tactics, techniques, entities, the source analytic rule, and the originating product (Defender for Endpoint, Sentinel-native, etc.). It does **not** include the incident envelope. [src 4]
6. The trigger is **HTTP-style**: Sentinel POSTs JSON to a per-Logic-App callback URL. Retries on failure are limited and not configurable from Sentinel's side; the playbook is responsible for being idempotent. [src 3]
7. The same playbook can be invoked from an automation rule **or** by an analyst clicking "Run playbook" on the incident. The payload shape is identical; the only difference is the run-context tag in run history. [src 4]
8. Playbook runs are visible to analysts in the **incident activity log** in Sentinel — but only when the playbook completes the call back via the *"Add comment to incident"* / *"Update incident"* actions. Otherwise the analyst sees only "playbook triggered" with no further context. [src 4]
9. Playbooks can read and update Sentinel state through the *Microsoft Sentinel* connector (incident comments, status changes, label updates). This loops back into the data plane the analyst sees. [src 6]
10. **Permissions to update incidents** are not automatic: the Logic App's managed identity needs **Microsoft Sentinel Responder** on the workspace. Read-only is **Microsoft Sentinel Reader**. Most playbooks need Responder. [src 5]
11. **Throttling**: Sentinel will not invoke the same automation rule for the same incident more than once per 5 minutes by default; this prevents loops where a playbook updates an incident which re-triggers the rule. [src 3]
12. **Time-to-trigger** is typically <30s from incident creation to Logic App first action, but can spike to several minutes during regional service load — design for late arrival, not real-time. [src 3]

## Incident-trigger payload schema (annotated)

The incident trigger delivers JSON shaped roughly like this. Fields move; treat the schema as descriptive, not authoritative — always sample a real payload before building strict parsers.

```json
{
  "object": {
    "id": "/subscriptions/.../providers/Microsoft.SecurityInsights/incidents/<guid>",
    "name": "<guid>",
    "type": "Microsoft.SecurityInsights/incidents",
    "properties": {
      "incidentNumber": 1234,
      "title": "Suspicious sign-in from impossible travel",
      "description": "User signed in from city A and city B 12 minutes apart…",
      "severity": "High",
      "status": "New",
      "classification": "Undetermined",
      "owner": { "objectId": null, "email": null, "userPrincipalName": null },
      "labels": [ { "labelName": "tactic:CredentialAccess", "labelType": "User" } ],
      "providerName": "Azure Sentinel",
      "createdTimeUtc": "2026-04-29T01:14:22Z",
      "lastModifiedTimeUtc": "2026-04-29T01:14:22Z",
      "incidentUrl": "https://portal.azure.com/#@.../resource/.../incidents/<guid>",
      "additionalData": {
        "alertsCount": 1,
        "bookmarksCount": 0,
        "commentsCount": 0,
        "alertProductNames": ["Azure Sentinel"],
        "tactics": ["CredentialAccess"]
      },
      "relatedAnalyticRuleIds": ["/subscriptions/.../alertRules/<rule-guid>"],
      "alerts": [ /* array of full alert objects */ ],
      "entities": [
        { "kind": "Account", "properties": { "name": "alice", "upnSuffix": "contoso.com" } },
        { "kind": "Ip", "properties": { "address": "203.0.113.12" } }
      ]
    }
  },
  "workspaceInfo": { "subscriptionId": "...", "resourceGroupName": "rg-soc", "workspaceName": "law-soc" },
  "workspaceId": "<guid>"
}
```

Key fields to use:

- **`object.properties.severity`**: branch logic on this. Values: Informational / Low / Medium / High.
- **`object.properties.status`**: New / Active / Closed. Most playbooks should bail if not New.
- **`object.properties.tags`** (where present): how playbooks share state across runs. Stash the Jira issue key here so a follow-up run can find it.
- **`object.properties.entities`**: array of typed entities (Account, Ip, Host, FileHash, Url, etc.). The shape of `properties` differs per `kind`.
- **`object.properties.alerts`**: full alert objects. Look here for the original event detail and the per-alert evidence.
- **`object.properties.incidentUrl`**: paste this verbatim into the Jira description so analysts can deep-link.

Always start with a **Parse JSON** action right after the trigger so subsequent expressions get typed access (`triggerBody()?.object?.properties?.severity` typed as string), not loose `Any`.

## Idempotency — the single biggest design concern

The **same incident can fire your playbook multiple times** for at least three reasons:

1. The automation rule matches on update events as well as create events.
2. An analyst clicks "Run playbook" manually after an automated run already succeeded.
3. The playbook itself updated the incident, which re-matched a rule (the 5-minute throttle helps, doesn't eliminate).

Defensive patterns:

- **Lookup-before-create.** Before posting `POST /rest/api/3/issue` to Jira, run a JQL search for `"Sentinel Incident ID" = "<incident-guid>"`. If a result exists, skip create and append a comment instead.
- **Use the incident GUID, not the incident number.** GUIDs are stable across the incident lifetime; incident numbers can be re-used in some edge cases (rare but possible).
- **Stash Jira key on incident.** Use *Update incident* (Sentinel connector) to add a tag like `jira-key:SEC-1234` after a successful create. Subsequent runs read this tag and skip create.
- **Make the audit log key the incident GUID + run ID.** That way, even with multiple Logic App runs against the same incident, you can reconstruct exactly what happened when.
- **Comment, don't recreate.** When a duplicate playbook run hits, post a comment on Jira describing what changed (status flip, severity bump, new alert added) rather than creating a new ticket.

## Retries, timeouts, and the silent-failure anti-pattern

Sentinel itself does not retry a failed playbook trigger reliably. If the Logic App returns a 5xx, Sentinel records "Failed" in the incident activity log and gives up. There is **no DLQ**.

This means the Logic App must own its own retry behaviour:

- HTTP actions inside the workflow get a **retry policy** (default: exponential, 4 retries). Tune per-action: aggressive for transient services, conservative for rate-limited ones.
- Wrap third-party calls in **`scope`** blocks so a `runAfter: { Failed: true }` branch can write to Blob and post a comment back to Sentinel saying "playbook failed, manual review needed".
- Treat **HTTP 200 with empty body** and **HTTP 200 with error JSON** as failures explicitly. Don't trust action-level success markers blindly. Use a Condition action to assert the response body is shaped right.

The biggest production trap: **a Logic App run that "Succeeded" overall but had a critical action skipped because of `runAfter`.** Treat any non-Succeeded action as a failed run from a SOC perspective, and have monitoring on action-level failure counts, not just workflow-level failure counts.

## End-to-end testing without a real incident

Three approaches in increasing fidelity:

1. **Manual trigger via the designer.** "Run with payload" — paste a JSON payload into the designer's run-with-payload box. Fast iteration; doesn't exercise Sentinel ↔ Logic App auth.
2. **Sample-incident automation rule.** Create a low-severity analytics rule scoped to a tag you control (e.g. `category=test`) and seed Log Analytics with a custom log line that triggers it. Exercises the full path including Sentinel auth and incident lifecycle. [src 7]
3. **Production rehearsal in a non-prod tenant.** Spin up a separate Sentinel workspace, mirror the rule and playbook, and inject events with `LogAnalyticsDataCollector` API. The non-prod tenant's Jira project should be a separate Atlassian project so no cross-pollination.

For CI: a small Azure DevOps pipeline can do (1) on PR — POST a known-good payload to the playbook's HTTP trigger and assert the response body. Add as a deployment gate.

## Where this commonly breaks in practice

- **Playbook isn't visible in the picker** when creating an automation rule. Cause: the *Microsoft Sentinel Automation Contributor* role isn't on the resource group. Fix: assign that role to the Sentinel-managed identity at the RG level. [src 5]
- **Playbook fires but Sentinel comments don't show up.** Cause: the Logic App's managed identity has Reader, not Responder. Fix: assign Responder on the workspace. [src 5]
- **Payload `entities` array is empty even though the incident UI shows entities.** Cause: the Sentinel connector's *Get incident* / *Entities — Get accounts* actions paginate; the trigger payload may include only the first page. Fix: in the workflow, fetch entities via the *Entities — Get* actions rather than relying on `triggerBody().object.properties.entities`. [src 6]
- **Same incident triggers the playbook twice in rapid succession.** Cause: automation rule scope includes both create and update, and the playbook's own update re-matches. Fix: scope the rule to *Created*-only, or guard the playbook with a tag check.
- **Playbook works for one analytics rule but not another.** Cause: per-rule entity mapping differs; the playbook assumes a particular entity kind exists at index 0. Fix: search the entities array by `kind`, not index.
- **Playbook completes faster than Sentinel can record the comment.** Cause: race between Sentinel API and incident UI eventual consistency. Fix: re-fetch the incident after writing a comment to confirm.

## Real-world example: CVE-2026-31431 ("Copy Fail") detection pack as upstream trigger

To make the abstract concept concrete: this is a real analytics-rule pack deployed in the LHsystems / lhsystems.int Sentinel workspace as of 2026-04-30. Each rule in the pack creates an incident that ultimately routes through the playbook described in this file family.

**Context:** CVE-2026-31431 ("Copy Fail") is a Linux kernel local privilege escalation in `algif_aead` / `authencesn(hmac(sha256),cbc(aes))`, disclosed by Theori on 2026-04-29. Public PoC exists. Approximately 2,695 Linux devices in the fleet (~90 %) are potentially exposed pre-patch. Fixed in kernel 6.18.22 / 6.19.12 / 7.0; pre-patch mitigation is `algif_aead` module blacklist.

**Detection layers (each is a separate analytics rule → incident → playbook):**

1. **Vulnerability exposure (TVM-based, scheduled daily).**
   ```kql
   DeviceTvmSoftwareVulnerabilities
   | where CveId =~ "CVE-2026-31431"
   ```
   Severity: Informational. Outcome: Trackspace ticket per-host for patch tracking. No Sentinel incident escalation; comment-only on existing ticket if re-detected.

2. **Exploitation Vector 1 — `python → su` priv-esc chain (NRT).**
   Looks for the public-PoC pattern of an unprivileged Python process spawning `su` after kernel-crypto autoload, with the resulting EUID=0 child not in a sanctioned-elevation session. Severity High, tactics Privilege Escalation + Execution, MITRE T1068 / T1059.006.

3. **Exploitation Vector 2 — `authencesn` modprobe autoload (NRT).**
   Looks for `LinuxKernelModuleLoad` events targeting the `authencesn(...)` template under non-shell, non-systemd parent processes. Baseline (90d pre-disclosure) showed zero hits across the fleet; post-disclosure validation showed 66 hits on 7 hosts during PoC testing.

**Idempotency considerations specific to this pack:**

- Vector 1 and Vector 2 can fire on the same exploit run. The playbook must dedupe by `(host, exploit-guid)` rather than by Sentinel-incident-guid alone, because each detection generates a separate incident and they all describe the same attacker action.
- Rule 1 (TVM) re-evaluates daily and creates a *new* incident every time the host appears in the inventory until patched. The playbook's lookup-before-create JQL must scope by `(host, CVE)` to avoid one Trackspace ticket per day per vulnerable device.
- Vector 2 has no user attribution at the alert level (`InitiatorUser` is `root` because the module is loaded by a `kworker` kernel thread). The playbook should fetch `DeviceLogonEvents` for a 30-minute pre-window pivot to identify the human caller before commenting on the ticket.

**Why this matters for the playbook design:**

- Severity branching: the playbook treats vector 1 / vector 2 (High) differently from rule 1 (Informational). Different Trackspace projects, different SLAs, different on-call channels.
- Per-rule entity mapping differs: vector 1 has `Account` populated, vector 2 does not. The playbook should fetch entities via the *Microsoft Sentinel — Entities — Get accounts* connector action rather than relying on `triggerBody().object.properties.entities[0]`.
- Volume planning: a campaign-style PoC sweep across many hosts could fire hundreds of vector-2 incidents in minutes. The playbook's Trackspace HTTP action retry policy and the rate-limit handling discussed in file 03 are not academic for this pack.

This example is included to anchor the abstract trigger schema above to a real rule that exists in production, and to surface the kinds of design decisions the playbook needs to make for any real detection pack — not just this one.

## Real-world example: `AUTO_TI_correlated_IPs` daily summary rule

A second production analytics rule routing through the same playbook, deployed in the LHsystems / lhsystems.int Sentinel workspace and validated as firing on schedule (2026-05-11).

**Context:** `AUTO_TI_correlated_IPs` is a **scheduled** (not NRT) analytics rule that produces a daily summary of IP addresses correlated against the threat-intelligence feed. Fires once per day at **11:01 AM local time**. One incident per run; the incident title is the rule name verbatim.

**Shape differences vs the CVE-2026-31431 pack:**

- *Scheduled, not NRT* — joins/unions across `ThreatIntelligenceIndicator` and the device/network event tables are allowed and used. The single-table constraint that shapes the CVE pack does not apply here.
- *One incident per day, predictable cadence* — the SOC expects exactly one `AUTO_TI_correlated_IPs` ticket per 24h. Absence is itself a signal that something broke upstream.
- *Low/Informational severity* — routes through different Trackspace SLA handling than the High-severity exploit-detection rules in the CVE pack. Severity branching in the playbook is what makes the same workflow handle both cleanly.
- *Entity mapping is IP-only* — no `Account` or `Host` entities populated. The playbook's per-rule branching must not assume the same entity shape as the exploit-detection incidents (reinforces the "fetch entities by `kind`, not by index" rule earlier in this file).

**Idempotency considerations specific to this rule:**

- A manual "Run playbook" on the daily incident must not create a second Trackspace ticket. The lookup-before-create JQL keyed on the Sentinel incident GUID in `customfield_10602` handles this — same pattern used everywhere — but worth verifying once for this rule because the predictable daily cadence makes any duplicate immediately visible.
- If a backfill or rule re-run produces a second incident for the same calendar day, the playbook's default behaviour creates a second ticket (different incident GUIDs → different JQL hits). Decide explicitly whether that's desired (two tickets = a visible re-run audit trail) or whether the JQL should additionally key on `(rule-name, date)` to dedupe within a day. Currently: two tickets, by default.

**Monitoring implications:**

- 11:01 AM is in business hours — a Logic App run failure surfaces within minutes via the on-call analyst noticing no morning summary ticket. Lower risk of silent failure than out-of-hours rules.
- Worth adding a "expected daily ticket present" KQL check against `SecurityIncident` filtered to `Title startswith "AUTO_TI_correlated_IPs"` over the last 25h, alerting on absence. Single query catches both Sentinel-side rule failures and playbook-side ticket-creation failures.
- Zero-correlation days: if the rule's KQL returns no rows, no incident is created and the playbook never fires. From a monitoring standpoint that's indistinguishable from a broken rule — the daily-ticket-present alert needs either a tolerance for "no-correlations" days, or the rule needs to be reshaped to always emit a summary incident (even an empty one) so the absence-of-ticket signal stays clean.

**Why this matters for the playbook design:**

- This rule is the calibration case for the "informational scheduled summary" branch of the playbook. The CVE pack exercises the high-severity, NRT, single-table, multi-rule-per-event branch; `AUTO_TI_correlated_IPs` exercises the low-severity, scheduled, joined-tables, one-rule-per-day branch. Together they cover most of the design surface — new rules tend to fit one of the two shapes with minor variation.

## See also: deployed playbook

The `TI-handler` Sentinel playbook (file 07) is the concrete production playbook this trigger schema feeds. It demonstrates the entity-by-kind fetch pattern (`Entities - Get IPs` rather than `triggerBody().entities`) explicitly recommended in this file, and the lookup-before-create idempotency pattern keyed on the Sentinel incident number in Trackspace `customfield_10602`.


2. Microsoft Learn — *Investigate incidents with Microsoft Sentinel* — https://learn.microsoft.com/azure/sentinel/investigate-cases — accessed 2026-04-29
3. Microsoft Learn — *Automate incident handling with automation rules* — https://learn.microsoft.com/azure/sentinel/automate-incident-handling-with-automation-rules — accessed 2026-04-29
4. Microsoft Learn — *Use triggers and actions in Microsoft Sentinel playbooks* — https://learn.microsoft.com/azure/sentinel/playbook-triggers-actions — accessed 2026-04-29
5. Microsoft Learn — *Roles and permissions in Microsoft Sentinel* — https://learn.microsoft.com/azure/sentinel/roles — accessed 2026-04-29
6. Microsoft Learn — *Microsoft Sentinel Logic Apps connector* — https://learn.microsoft.com/connectors/azuresentinel/ — accessed 2026-04-29
7. Microsoft Learn — *Custom logs in Azure Monitor (HTTP Data Collector API)* — https://learn.microsoft.com/azure/azure-monitor/logs/data-collector-api — accessed 2026-04-29
8. Microsoft Learn — *Azure Sentinel REST API — Incidents* — https://learn.microsoft.com/rest/api/securityinsights/ — accessed 2026-04-29
