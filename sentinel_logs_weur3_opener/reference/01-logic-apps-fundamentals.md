# Topic 01: Azure Logic Apps Fundamentals

Generated: 2026-04-29 | Sources: 9 | Confidence: high

## Scope

This file covers Azure Logic Apps from zero: what they are, the moving parts, how the designer maps to JSON, the difference between the two hosting modes, when to escape into an Azure Function, and the common-sense gotchas that bite first-time users.

It does **not** cover Sentinel-specific playbook wiring (file 02), Jira-specific actions (file 03), Blob actions (file 04), or Key Vault references (file 05). It also avoids deep CI/CD topics (Bicep / ARM / Terraform deployment); those are in file 06.

## Key entities & terms

- **Workflow**: a single Logic App definition, a directed graph starting at one *trigger* and proceeding through *actions*. Stored as JSON. [src 1]
- **Trigger**: the thing that starts a workflow. Three categories: *recurrence* (timer), *poll* (Logic App polls an endpoint), *push* (an external service calls a webhook). Sentinel playbooks use a push-style trigger registered through Sentinel. [src 1]
- **Action**: a step in the workflow. Built-in actions (HTTP, parse JSON, condition, switch, for-each, until, parallel) plus connector actions (Blob "create blob", Key Vault "get secret", Outlook "send email", etc.). [src 1]
- **Connector**: a packaged set of actions for a third-party (or first-party) service. Two flavours: *built-in* (run in the Logic App host process, fastest) and *managed* (run on a Microsoft-managed connector backend, may add latency). Some connectors exist in both forms — pick built-in when available. [src 2]
- **Designer view**: the visual editor in the Azure portal. Drag triggers + actions onto a canvas.
- **Code view**: the underlying JSON. Anything you do in the designer is editable as JSON; anything you do in JSON appears in the designer (mostly — some advanced expressions render as "?" in the designer).
- **Workflow Definition Language (WDL)**: the DSL inside the JSON for expressions. Looks like `@{parameters('foo')}`, `@triggerBody()?.properties?.severity`, `@if(equals(...), 'a', 'b')`. [src 3]
- **Run**: a single execution of the workflow. Each run has an ID, a status (Succeeded, Failed, Cancelled), a duration, and a step-by-step trace you can inspect.
- **Consumption SKU**: serverless, multi-tenant, per-execution billing. One workflow per Logic App resource.
- **Standard SKU**: App-Service-style, single-tenant, runs on the Functions runtime under the hood. Multiple workflows per app, supports VNet integration, App Service Plans, slots, and local dev. [src 4]

## Core facts

1. A Logic App workflow is fundamentally **JSON**. The designer is sugar — you can author and version the JSON directly. [src 1]
2. **Triggers and actions return JSON**. Every step has an output; subsequent steps reference earlier outputs via expressions like `@body('Step_Name')` or `@outputs('Step_Name').headers`. [src 3]
3. There is exactly one **trigger** per workflow. If you need two triggers, you build two workflows. [src 1]
4. The **HTTP action** is the universal escape hatch — it can call any REST endpoint, with or without auth, with timeouts and retries configurable per call. Most third-party integrations boil down to "use HTTP action with the right headers and body". [src 1]
5. **Expressions vs values**: in the designer, you toggle between literal text and expression mode. The JSON encodes expressions as strings starting with `@`. [src 3]
6. **Loops**: `for-each` parallelises by default (up to 20 concurrent iterations on Consumption); `until` is sequential and bounded by `count` or `timeout`. Loop bodies have access to `items('Loop_Name')` for the current item. [src 1]
7. **Error handling** is configured per action via *runAfter* — you can route a step to run only if the previous step *Failed*, *Skipped*, or *Succeeded*. This replaces try/catch. [src 5]
8. **Retry policy** defaults to 4 retries with exponential backoff. You can change it per HTTP-style action: `none`, `fixed`, or `exponential` with custom interval and count. [src 1]
9. **Run history retention**: 90 days on Consumption, configurable on Standard. Failed runs can be *resubmitted* from the portal — the trigger payload is replayed. [src 1]
10. **Parameters** are declared at the workflow level (string, secureString, object, array, bool, int) and referenced via `@parameters('name')`. *secureString* hides the value in the run history and JSON exports. [src 6]
11. **Connections** are separate Azure resources from the Logic App itself. A connection is "the Outlook account this Logic App uses"; the Logic App references the connection by name. Rotating creds means updating the connection, not the Logic App. [src 2]
12. **Managed identity** can be assigned to a Logic App. With a managed identity, the workflow can call Azure resources (Key Vault, Storage, etc.) without a connection — the identity itself is the auth. Available on both Consumption and Standard, but slightly different to wire up. [src 7]
13. **Inline Code (JavaScript) action** runs Node 12 (Consumption) / Node 18 (Standard at time of writing) in a sandbox. 5-second timeout, 1024-character source limit, no external network calls. Suitable for `JSON.parse` / regex tweaks; not for real logic. [src 8]
14. **Limits worth memorising**: HTTP request size 100MB; HTTP timeout 230s on Consumption (configurable up to 4 minutes on Standard); single action output ≤100MB; for-each iterations ≤100k. [src 9]

## Designer vs code: a worked mapping

In the designer, the simplest possible workflow is:
1. Trigger: "When a HTTP request is received".
2. Action: "Response", returning whatever you want.

In code view, that becomes (abridged):

```json
{
  "definition": {
    "triggers": {
      "manual": { "type": "Request", "kind": "Http", "inputs": { "schema": {} } }
    },
    "actions": {
      "Response": {
        "type": "Response",
        "inputs": { "statusCode": 200, "body": { "ok": true } },
        "runAfter": {}
      }
    },
    "$schema": "https://schema.management.azure.com/.../workflowdefinition.json#"
  }
}
```

Adding an HTTP call to Jira:

```json
"Create_Jira_issue": {
  "type": "Http",
  "inputs": {
    "method": "POST",
    "uri": "https://yourcompany.atlassian.net/rest/api/3/issue",
    "headers": { "Content-Type": "application/json" },
    "authentication": {
      "type": "Basic",
      "username": "@parameters('jira_user')",
      "password": "@parameters('jira_token')"
    },
    "body": {
      "fields": {
        "project": { "key": "SEC" },
        "summary": "@triggerBody()?.properties?.title",
        "issuetype": { "name": "Incident" }
      }
    }
  },
  "runAfter": {}
}
```

Note three things: (a) the `@parameters(...)` references — secrets never live in the body literally; (b) the `@triggerBody()?.properties?.title` expression — null-safe via `?.`; (c) `runAfter: {}` means "first action".

## Consumption vs Standard — when each makes sense

Consumption is the default Sentinel-playbook target and is what every Microsoft Learn tutorial assumes. It's the right choice when:
- You're prototyping or running low-volume (<10k executions/month).
- You don't need VNet integration (no private endpoints, no on-prem connectors via ISE alternative).
- You want zero infra to manage.

Standard is worth the migration effort when:
- You need VNet integration to reach private resources (e.g. an on-prem Jira behind a firewall).
- Your monthly executions are high enough that Standard's flat hosting cost wins (rule of thumb: >50k/month).
- You want to host multiple workflows together for shared connections / shared App Service Plan.
- You want local development with VS Code and proper source control.

Standard runs on the Functions runtime, which means: cold starts apply (mitigatable with Premium plan / always-on), file system access exists for stateful workflow data, and local dev is `func start`-style. [src 4]

## When to leave Logic App and call a Function

Heuristics for "this should be in a Function instead":

- The transformation needs a real library (`pandas`, `requests` with custom retries, `cryptography`, anything with state).
- You find yourself nesting three levels of Logic App expressions or using `@xpath` against JSON.
- You need precise rate-limit handling (e.g. token-bucket with persistent state).
- The action takes >5 seconds in the inline-code action and there's no built-in for it.
- You want a unit-tested step. (Logic App workflows are testable, but unit testing a Function is far easier.)

Pattern: Function exposes an HTTPS endpoint with `authLevel = function` (key in header) or — preferably — `authLevel = anonymous` plus **Easy Auth / managed identity**. Logic App calls it with HTTP action + `Managed Identity` authentication. The Function reads its own config from Key Vault using its own managed identity. Two identities, two scopes, no secrets in either source. [src 7]

## Common gotchas

- **`triggerBody()` returns string-typed values when the schema isn't declared.** Always add a "Parse JSON" step right after the trigger and feed it the schema (the designer can infer from a sample payload). After that, downstream expressions get typed correctly. [src 3]
- **`runAfter` defaults to `Succeeded` only.** If you want a step to run on failure of a previous step (for an error branch), you must edit the action's *Configure run after* in the designer — easy to miss.
- **`for-each` parallelism + shared variables = bugs.** Logic App variables (`Initialize variable`, `Increment variable`) are not loop-safe. If you need to accumulate inside a loop, set parallelism to 1 or use the `compose` action's outputs.
- **HTTP action treats 4xx and 5xx as failures by default**, but **only at the runtime level** — the action shows red, but the workflow advances to the next step's `runAfter: Succeeded`, which doesn't run, leaving the workflow "stuck" Succeeded with a Failed step. Read the run history carefully; "Succeeded" overall doesn't mean every step succeeded.
- **Connection drift** — the connection resource can be modified independently of the Logic App. Someone rotates a credential, the Logic App keeps "passing" but with a stale connection that fails at runtime.
- **Secure inputs / outputs**: a per-action toggle hides the input/output JSON from run history. Forgotten secrets get logged to history (visible to anyone with reader on the resource). When in doubt, mark inputs and outputs secure. [src 6]
- **Designer caches schemas**. After updating a Parse JSON sample, save and reopen the workflow; expressions referring to the old schema may not refresh until then.

## Where this commonly breaks in practice

Three failure modes account for most production incidents:

1. **Connection auth expires.** Managed (OAuth) connectors hold a refresh token; when revoked or rotated, the connector silently fails on next call. Mitigation: monitor "Failed runs in last 24h" on the Logic App and alert. [src 1]
2. **Trigger payload changes shape.** Sentinel updates its incident schema; workflows pinned to the old schema parse fine but produce empty fields. Mitigation: fail-loud — assert key fields are present and non-null with a Condition action right after Parse JSON, and route to an error branch that emails the SecOps team if the assertion fails. [src 5]
3. **Throttling.** A burst of incidents (e.g. a campaign-style spam wave) hits Jira's rate limit. Without explicit handling, half the tickets succeed and half fail. Mitigation: HTTP action with retry policy = exponential, max retries 5, and a fallback that writes to Blob with a "queued for retry" tag. [src 1]

## Sources

1. Microsoft Learn — *What is Azure Logic Apps?* — https://learn.microsoft.com/azure/logic-apps/logic-apps-overview — accessed 2026-04-29
2. Microsoft Learn — *Connectors overview for Logic Apps* — https://learn.microsoft.com/azure/connectors/introduction — accessed 2026-04-29
3. Microsoft Learn — *Workflow Definition Language schema* — https://learn.microsoft.com/azure/logic-apps/logic-apps-workflow-definition-language — accessed 2026-04-29
4. Microsoft Learn — *Single-tenant vs multi-tenant Logic Apps* — https://learn.microsoft.com/azure/logic-apps/single-tenant-overview-compare — accessed 2026-04-29
5. Microsoft Learn — *Run-after and error handling* — https://learn.microsoft.com/azure/logic-apps/logic-apps-exception-handling — accessed 2026-04-29
6. Microsoft Learn — *Secure access and data in Logic Apps* — https://learn.microsoft.com/azure/logic-apps/logic-apps-securing-a-logic-app — accessed 2026-04-29
7. Microsoft Learn — *Authenticate Logic Apps with managed identities* — https://learn.microsoft.com/azure/logic-apps/authenticate-with-managed-identity — accessed 2026-04-29
8. Microsoft Learn — *Inline code action* — https://learn.microsoft.com/azure/logic-apps/logic-apps-add-run-inline-code — accessed 2026-04-29
9. Microsoft Learn — *Logic Apps limits and configuration* — https://learn.microsoft.com/azure/logic-apps/logic-apps-limits-and-config — accessed 2026-04-29
