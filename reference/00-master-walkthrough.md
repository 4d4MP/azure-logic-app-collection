# Master Walkthrough: Automating Sentinel Alerts with Azure Logic Apps

Generated: 2026-04-29 | Sources: 14 | Confidence: medium-high

This guide walks through building a complete automation pipeline that takes an alert (or "incident") raised by **Microsoft Sentinel**, runs it through an **Azure Logic App**, and produces two outcomes: (1) a ticket created (or updated) in **Jira Cloud**, and (2) a structured log line written to **Azure Blob Storage** for long-term retention and downstream analytics. Where the built-in Logic App designer cannot do something cleanly, we drop in a small piece of **Python** running in an **Azure Function** invoked from the Logic App.

Audience: a future LLM session plus a human reader with **zero prior knowledge** of Sentinel, Logic Apps, Jira's API, Azure Blob, or Key Vault. Every term is introduced before it is used.

## Scope

This file is an architectural overview and a navigation map for the topic files (01-06). It does **not** repeat the deep content of those files; it summarises the end-to-end flow, calls out the decisions you have to make, lists the trade-offs, and points you to the relevant detail file.

Out of scope: SOAR products other than Logic Apps (e.g. XSOAR, Tines), non-Jira ticketing systems, alerting *into* Sentinel from third-party sources, and the analytic-rule authoring side of Sentinel (KQL detection writing). We assume incidents already exist; we automate what happens *after* they are raised.

## Key entities & terms (introduced from zero)

- **Microsoft Sentinel**: Microsoft's cloud-native SIEM/SOAR product. A SIEM ("Security Information and Event Management") collects logs from many sources, runs detections, and surfaces *alerts*. SOAR ("Security Orchestration, Automation, and Response") is the layer that *acts* on those alerts. Sentinel is built on top of an **Azure Log Analytics workspace** — the underlying database where logs live and where **KQL** ("Kusto Query Language") runs. [src 1]
- **Alert vs Incident**: An *alert* is a single signal a detection rule fires. An *incident* groups one or more related alerts into a case an analyst works. Automation rules in Sentinel mostly operate on incidents. [src 2]
- **Azure Logic App**: a low/no-code workflow engine. You design a flow as a sequence of *triggers* and *actions*. Triggers start the workflow (e.g. "when a Sentinel incident is created"); actions perform steps (e.g. "send HTTP request", "create file in Blob"). [src 3]
- **Playbook**: a Sentinel-specific name for a Logic App that has been registered with Sentinel and exposes a Sentinel-shaped trigger ("When an incident is created" or "When an alert is triggered"). [src 2]
- **Connector**: a pre-packaged set of actions a Logic App can call against a third-party service (Jira, Blob, Teams, etc.). Connectors handle authentication and request formatting for you.
- **Managed Identity**: an Azure-managed credential attached to a resource (Logic App, Function, VM). The resource can call other Azure services without ever holding a secret. There are two kinds: *system-assigned* (lifecycle tied to the resource) and *user-assigned* (a standalone identity you can attach to many resources). [src 4]
- **Azure Key Vault**: a secrets/keys/certificates store. Managed identities pull from Key Vault, never the other way round. [src 5]
- **Azure Blob Storage**: object storage. Three blob types: *block* (default; immutable upload, mutable via re-upload), *append* (optimised for log-style appends), *page* (VHDs). [src 6]
- **Jira Cloud REST API**: Atlassian's HTTPS API for creating issues, adding comments, updating fields. Auth is either an *API token* (basic auth with email + token) or *OAuth 2.0 3LO* (three-legged, for apps acting on behalf of users). [src 7]
- **Trackspace**: the LHsystems-hosted **Jira Data Center** instance at `https://trackspace.lhsystems.com`. Same conceptual API as Cloud, but on `/rest/api/2/`, with **Bearer PAT** auth (not Basic), and plain-string descriptions (not ADF). When this guide says "Jira", read "Trackspace" for this environment. Operational project key for security automation is `CLOPSSEC`. See file 03 § *Trackspace (Jira Data Center) — actual LHsystems environment* for the full delta.

## End-to-end flow

```
+-----------------------+     +--------------------------+     +-----------------------+
|  Data sources         | --> | Microsoft Sentinel       | --> | Automation rule       |
|  (firewalls, EDR,     |     | (Log Analytics + rules)  |     | "if severity >= High" |
|   Entra ID logs, ...) |     | -> alert -> incident     |     +-----------+-----------+
+-----------------------+     +--------------------------+                 |
                                                                            v
                                                          +-----------------------------+
                                                          |  Logic App (Playbook)        |
                                                          |  Trigger: incident created   |
                                                          |  1. Get IPs from entities    |
                                                          |  2. Get sentinelsvc from KV  |
                                                          |  3. AbuseIPDB enrichment     |
                                                          |  4. HTTP -> Trackspace ticket|
                                                          |  5. Wait for analyst approval|
                                                          |  6. Walk ticket through      |
                                                          |     Approval→InProgress→     |
                                                          |     Resolved→Closed          |
                                                          |  7. Update blocklist blob    |
                                                          |  8. Comment on incident      |
                                                          +-----------------------------+
                                                                            |
                                                                            v
                                          +------------------+   +--------------------------+
                                          |  Trackspace      |   |  Azure Blob Storage      |
                                          |  (Jira DC)       |   |  yyyy=/mm=/dd= partition |
                                          |  ticket          |   |                          |
                                          +------------------+   +--------------------------+
```

The Logic App is the orchestrator. Python only enters where the work is awkward in the designer: complex transforms, multi-step API negotiation, regex, parsing nested JSON beyond what Logic App expressions handle cleanly. The Function is invoked over HTTP from the Logic App. Identity is **always** managed identity; secrets are **always** in Key Vault.

## Decision points and trade-offs

**Logic Apps Consumption vs Standard.** Consumption is per-execution billing, single workflow per resource, runs in a Microsoft-managed multi-tenant environment, and is what Sentinel "playbook" tooling assumes by default. Standard is App-Service-style hosting (single-tenant), supports multiple workflows per app, allows local dev with VS Code, integrates more cleanly with VNets and private endpoints, and tends to be cheaper at high volume. Pick **Consumption** for your first playbook; move to **Standard** when you need VNet integration, predictable cost at scale, or local CI/CD. [src 3]

**Logic App vs Azure Function for the same step.** Use Logic App when the action is one of: HTTP call with simple JSON, built-in connector (Blob, Key Vault, Teams, Outlook), conditional/loop with shallow logic. Use a **Function** when you need: regex, recursive JSON walking, library code (e.g. `tldextract`, `ipaddress`, `pandas`), retries with custom backoff, or anything that exceeds Logic App's 100MB action output / 100k loop iterations. The boundary is fuzzy; default to "do it in Logic App until it gets ugly, then refactor that step into a Function". [src 8]

**Append blob vs block blob for logs.** Append blobs are designed for the log case (concurrent writers, idempotent writes via append position). Block blobs are simpler and cheaper to read, but require you to download-modify-upload, which races. Use **append blob** for the running write of Logic App execution lines; use **block blob** with daily-rolling filenames if you'd rather batch writes (e.g. one file per incident) and read whole-file later. [src 6]

**API token vs OAuth 2.0 vs PAT for Jira.** On Jira **Cloud**: API token is one secret per Atlassian user account; the issue is created as that user. OAuth 3LO is a per-tenant app registered in Atlassian's marketplace flow and is what you need if you want to act *as the analyst who triggered the incident* rather than as a service account. On **Trackspace (Jira Data Center)** — the actual environment here — neither applies: auth is **Bearer Personal Access Token** issued from the user's profile page. Default to **PAT + dedicated bot service account** ("sentinel-automation" or similar) for simplicity and audit clarity. [src 7]

**Where to put the Python.** Two viable patterns:
1. *In-line in the Logic App via the "Inline Code" action* — JavaScript only, 5-second timeout, 1024-character source limit. **Skip this** for anything beyond a one-line transform.
2. *Out-of-process in an Azure Function (HTTP trigger)* — proper Python, full library support, its own Application Insights, its own managed identity. **Default to this** whenever Python is needed. [src 8]

## How the topic files connect

- File **01** (`logic-apps-fundamentals.md`) is for someone who has never opened the Logic App designer. Read it before file 02 if you don't already know what a "trigger" or "designer view" is.
- File **02** (`sentinel-to-logic-app-trigger.md`) explains how Sentinel actually invokes the Logic App, what JSON it passes in, how to test the connection without waiting for a real alert.
- File **03** (`jira-integration.md`) covers both the Logic App HTTP-action pattern and the equivalent Python pattern in a Function. Includes auth, error handling, and rate-limit behaviour.
- File **04** (`blob-storage.md`) covers the write side — partition layout, append blob semantics, lifecycle policies for log retention.
- File **05** (`keyvault-and-secrets.md`) is the security underpinning: how secrets get from Key Vault to the Logic App and Function without ever appearing in source.
- File **06** (`secure-architecture-and-coding.md`) ties it all together with a code-review checklist, network-isolation guidance, and a list of things that commonly break in the wild.
- File **07** (`ti-handler-playbook.md`) documents the deployed `TI-handler` playbook concretely — resource IDs, RBAC, the Trackspace transition chain, the deployment-session lessons. Read this when working on TI-handler specifically; read 00–06 for the broader design space.

## "What does success look like?"

A working pipeline has all of these properties:
- **No secret in source code.** Greppable proof: nothing in the Logic App definition, the Function source, or any deployment script contains an API token, connection string, or password.
- **One identity per workload.** The Logic App has its own managed identity; the Function has its own. Cross-permissions are explicit (Function can read its KV; Logic App can read its KV; neither can read the other's).
- **Idempotent writes.** Re-running the playbook on the same incident does not create a duplicate Trackspace ticket. Use the incident's GUID as a search key (JQL on the dedicated `customfield_XXXXX` "External Incident ID" field) before creating.
- **Observable.** Every run shows up in Logic App run history *and* in Application Insights *and* as a log line in Blob. You can answer "did this incident get a ticket?" three independent ways.
- **Recoverable.** When Jira is down, the Logic App retries with exponential backoff and ultimately writes a "needs manual review" entry to Blob and comments on the Sentinel incident.

If any of these is missing, treat the pipeline as draft.

## Common failure modes (preview — details in topic files)

- Managed identity has the right RBAC role on the *subscription*, not the *resource*, and doesn't actually work at runtime. (File 05.)
- Logic App designer "expression preview" lies about types — `triggerBody()?.object?.properties?.severity` returns string but JSON viewer shows it as int. (File 02.)
- Trackspace (Jira DC) rate limits are tenant-configured and not always documented per environment; Logic App HTTP action treats 429 as success unless explicitly handled. You have to add explicit status-code handling. (File 03.)
- Append blob has a 50,000-block limit per blob; long-running daily logs eventually fail without rotation. (File 04.)
- Key Vault references in Logic App Standard work; in Consumption you have to use the Key Vault connector explicitly. (File 05.)
- Python Function `requirements.txt` gets cached aggressively; a bumped library version isn't picked up until you flush deployment. (File 06.)
- Renaming a deployed Logic App is delete-and-recreate, not in-place. The resource name is the URL identity; renaming means fresh MI + fresh RBAC. (File 07.)
- ARM `runAfter` validation rejects bodies referencing actions not on the runAfter ancestry path. Common when an action runs in parallel with the action being referenced. (File 07.)
- Sentinel doesn't show a playbook in the portal picker unless its own first-party SP (Azure Security Insights) has `Microsoft Sentinel Automation Contributor` on the playbook's RG. This is a separate role from the three roles the MI itself needs. (File 07.)

## Sources

1. Microsoft Learn — *What is Microsoft Sentinel?* — https://learn.microsoft.com/azure/sentinel/overview — accessed 2026-04-29
2. Microsoft Learn — *Automate threat response with playbooks in Microsoft Sentinel* — https://learn.microsoft.com/azure/sentinel/automate-responses-with-playbooks — accessed 2026-04-29
3. Microsoft Learn — *Logic Apps overview* — https://learn.microsoft.com/azure/logic-apps/logic-apps-overview — accessed 2026-04-29
4. Microsoft Learn — *Managed identities for Azure resources* — https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview — accessed 2026-04-29
5. Microsoft Learn — *Azure Key Vault basic concepts* — https://learn.microsoft.com/azure/key-vault/general/basic-concepts — accessed 2026-04-29
6. Microsoft Learn — *Understanding block, append, and page blobs* — https://learn.microsoft.com/rest/api/storageservices/understanding-block-blobs--append-blobs--and-page-blobs — accessed 2026-04-29
7. Atlassian Developer — *Jira Cloud REST API authentication* — https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro/#authentication — accessed 2026-04-29
8. Microsoft Learn — *Compare Azure Functions and Azure Logic Apps* — https://learn.microsoft.com/azure/azure-functions/functions-compare-logic-apps-ms-flow-webjobs — accessed 2026-04-29
9. Microsoft Learn — *Sentinel automation rules* — https://learn.microsoft.com/azure/sentinel/automate-incident-handling-with-automation-rules — accessed 2026-04-29
10. Microsoft Learn — *Logic Apps Standard vs Consumption* — https://learn.microsoft.com/azure/logic-apps/single-tenant-overview-compare — accessed 2026-04-29
11. Atlassian Developer — *Jira Cloud REST API rate limiting* — https://developer.atlassian.com/cloud/jira/platform/rate-limiting/ — accessed 2026-04-29
12. Microsoft Learn — *Azure Functions Python developer guide* — https://learn.microsoft.com/azure/azure-functions/functions-reference-python — accessed 2026-04-29
13. Microsoft Learn — *Sentinel data connectors* — https://learn.microsoft.com/azure/sentinel/connect-data-sources — accessed 2026-04-29
14. Microsoft Learn — *Logic Apps connectors reference* — https://learn.microsoft.com/connectors/connector-reference/ — accessed 2026-04-29
