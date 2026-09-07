# CLOPSSEC ticket creation

**Logic App:** `CLOPSSEC_ticket_creation` (Consumption) in `LSY_WEUR_ITCS_PRD_SEC_RG_002`.
**Source of truth:** `playbook/workflow.json` + `playbook/azuredeploy.json`.
**Trigger:** HTTP request (`POST`), called by other playbooks as a nested workflow. No
Sentinel connection, no schedule.

One job: take an issue type and its fields from the request body, check the fields the
CLOPSSEC create screen marks mandatory, raise the ticket with a single
`POST /rest/api/2/issue`, and answer **synchronously** with the key. Every other playbook
in this collection that wants a CLOPSSEC ticket can call this one instead of carrying its
own copy of the Trackspace create action.

## Flow

```
HTTP POST { "issue_type": "...", "fields": { ... } }
  → Prepare (scope)
       → Filter_allowed_issue_types        Task | Problem | Incident, case-insensitive
       → Filter_missing_mandatory_fields   per-type list from MandatoryFieldsByType
       → Compose_normalized_lists          components / labels / link keys → arrays
       → Compose_issue_links               link type, direction, keys
       → Compose_validation_errors
       → Check_request_valid
            └─ errors → Respond 400 + Terminate Failed          (no Jira call made)
       → Get_Jira_password                 Key Vault, secured in + out
       → Filter_requested_custom_fields    which JiraCustomFields the request actually uses
       → Resolve_custom_field_ids          only when at least one custom field is given
            → Get_field_list               GET /rest/api/2/field, once
            → Foreach_requested_custom_field (sequential)
                 name → customfield_* id, value shaped by kind → Custom_Fields
                 no or ambiguous match     → Unresolved_Fields
            → Check_unresolved_fields
                 └─ any → Respond 500 + Terminate Failed        (no ticket raised)
       → Compose_resolved_defaults         priority / assignee / security level defaults
       → Select_components, Select_issue_links
       → Build_core_fields → Build_optional_fields → Compose_issue_body
  → Create_issue                           POST /rest/api/2/issue, retryPolicy none
       ├─ Succeeded → Parse_create_response → Set_Ticket_Key → Respond 200
       └─ Failed    → Handle_create_failure: Respond <Jira status> + Terminate Failed
  → Handle_prepare_failure                 anything unexpected in Prepare → Respond 500
```

The caller always gets a JSON body in the same shape. The run is marked **Failed** on
every non-200 path so a bad call is visible in the run history, not only in the caller.

## Request

```json
{
  "issue_type": "Incident",
  "fields": {
    "summary": "Suspicious sign-in from TOR exit node",
    "description": "Sentinel incident 4711\n\nhttps://portal.azure.com/...",
    "priority": "1 - Critical",
    "category": "TruePositive - suspicious activity",
    "labels": ["sentinel", "auto"],
    "external_issue_id": "4711"
  }
}
```

`issue_type` is one of `AllowedIssueTypes` (`Task`, `Problem`, `Incident`). The keys of
`fields` follow the create screens field for field:

| Request key | Jira field | On which screen | Sent as |
| --- | --- | --- | --- |
| `summary` | Summary | all | string |
| `description` | Description | all | string, newlines honoured |
| `priority` | Priority | all | `{"name": …}`; default per type from `DefaultPriorityByType` |
| `security_level` | Security Level | Task, Problem | `{"name": …}`; omitted by default so Jira applies the project default (*Reporter only*) |
| `reporter` | Reporter | Task | `{"name": <login>}`; omitted by default, so the ticket is reported by `sentinelsvc` |
| `assignee` | Assignee | Task | `{"name": <login>}`; default `-1` = *Automatic* |
| `components` | Component/s | all | `[{"name": …}]` |
| `labels` | Labels | all | `[…]`; Jira rejects labels containing spaces |
| `due_date` | Due Date | Task | `yyyy-MM-dd`, passed through |
| `category` | Category | Incident | `{"value": …}` |
| `reason_for_investigation` | Reason for investigation | Problem | `{"value": …}` |
| `subscription` | Subscription | Problem, Incident | `[{"key": <object key>}]` |
| `affected_item` | Affected item | Problem, Incident | `[{"key": <object key>}]` |
| `provider` | Provider | Problem | `[{"key": <object key>}]` |
| `external_issue_id` | External issue ID | Problem, Incident | string, comma-separated ids |
| `customer_reference` | Customer reference | Incident | string |
| `dod` | DoD (Definition of Done) | Task | `[{"name": …, "checked": false}]` per item |
| `linked_issues` | Linked Issues + Issue | Task | `update.issuelinks`, see below |

Array-valued keys (`components`, `labels`, `dod`, `linked_issues.keys`) also accept a
single string. Unknown keys are ignored. Attachments are not supported: attach to the
returned key afterwards with `POST /rest/api/2/issue/{key}/attachments`.

`linked_issues` is `{"type": "<link type name>", "direction": "outward" | "inward",
"keys": ["CLOPSSEC-1", …]}`. `type` is the **link type name** (`GET
/rest/api/2/issueLinkType` lists them), not the *analyses* / *is analysed by* label the
form shows; `direction` defaults to `outward`. Leave `type` out only if the
`DefaultIssueLinkTypeName` parameter is set.

### Mandatory fields

Checked **before any Jira call**, from the `MandatoryFieldsByType` parameter, which
mirrors the asterisks on the create screens:

| Issue type | Must be non-empty in the request |
| --- | --- |
| Task | `summary`, `description` |
| Problem | `summary`, `subscription` |
| Incident | `summary`, `description` |

Priority, Reporter and Assignee are required by Jira as well but always carry a default,
so they are not in the list. Whitespace-only values count as empty. A miss answers
**400** naming every missing field at once, and the run terminates Failed with the same
message.

## Response

Success, **200**:

```json
{
  "status": "ok",
  "ticket_key": "CLOPSSEC-42311",
  "ticket_url": "https://trackspace.lhsystems.com/browse/CLOPSSEC-42311",
  "error": null
}
```

Every failure uses the same four keys with `status: "error"`, the ticket fields `null`
and `error` carrying the reason:

| Status | When | `error` |
| --- | --- | --- |
| 400 | unknown `issue_type`, a mandatory field missing, or `linked_issues.keys` without a link type | all validation errors, `; `-separated |
| 500 | a requested custom field could not be mapped to a `customfield_*` id | the field, its Jira name and how many candidates were found |
| 500 | Key Vault or `GET /rest/api/2/field` failed | the failed action and its error message |
| Jira's own 4xx/5xx (502 when there was no HTTP response) | Trackspace refused the issue | `Jira did not create the issue (HTTP 400): {"errorMessages":[],"errors":{"labels":"The label 'a b' contains spaces"}}` |

Jira's error body is echoed verbatim (first 1000 characters). It names the offending
field, so a wrong select value, an unknown user or an unsettable Insight object is
diagnosable from the caller's run history alone.

## How the custom fields are addressed

The create screens carry eight custom fields and this repository does not know their
`customfield_*` ids, which also differ between INT and PRD Trackspace. So the playbook
resolves them **at run time by display name**: one `GET /rest/api/2/field`, then for each
custom field the request uses, the custom field whose name matches case-insensitively.
Exactly one match resolves; zero or several is an error (500, above) rather than a guess.

The `JiraCustomFields` parameter drives this — one entry per request key:

```json
{ "key": "subscription", "name": "Subscription", "id": "", "kind": "insight" }
```

- `name` — the display name to look up.
- `id` — set it to pin the id (`customfield_12345`). Skips the lookup for that field and
  is the fix for a duplicated name.
- `kind` — how the value is shaped: `text` (string), `select` (`{"value": …}`),
  `insight` (`[{"key": …}]`), `checklist` (`[{"name": …, "checked": false}]`), anything
  else passes the value through as given (`raw`).

The lookup only runs when the request carries at least one custom field, so a plain Task
costs no extra Jira call.

**Insight fields (Subscription, Affected item, Provider).** These are Riada Insight /
Assets object pickers. `[{"key": …}]` is the documented REST shape and the only one that
fails loudly instead of silently leaving the field empty; whether Trackspace accepts it
depends on the object type being inside the field's key-resolver scope.
`ti_handling_automation/docs/07-ti-handler-playbook.md` records that the OPSLSY *Affected
item* is **not** — which is why that playbook clones a template instead of creating. If a
Problem or Incident comes back with *Could not find Assets object/s*, the CLOPSSEC field
has the same limitation and a clone-based path is needed for that type; the error is
surfaced to the caller as-is.

**DoD.** `[{"name": …, "checked": false}]` is the Issue Checklist REST shape. If the
instance rejects it, switch the entry to `"kind": "raw"` and send whatever the plugin
version expects.

## Calling it from another Logic App

As a nested workflow — no SAS URL to manage, and the parent's managed identity is not
involved:

```json
"Create_CLOPSSEC_ticket": {
  "type": "Workflow",
  "inputs": {
    "host": {
      "triggerName": "manual",
      "workflow": {
        "id": "/subscriptions/f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29/resourceGroups/LSY_WEUR_ITCS_PRD_SEC_RG_002/providers/Microsoft.Logic/workflows/CLOPSSEC_ticket_creation"
      }
    },
    "body": {
      "issue_type": "Task",
      "fields": {
        "summary": "@{triggerBody()?['object']?['properties']?['title']}",
        "description": "@{triggerBody()?['object']?['properties']?['description']}"
      }
    }
  },
  "runAfter": {}
}
```

Then `body('Create_CLOPSSEC_ticket')?['ticket_key']` and `?['ticket_url']`. A non-200
answer makes the action **fail**, so the parent's `runAfter: ["Failed"]` branch sees it
and `body('Create_CLOPSSEC_ticket')?['error']` holds the reason.

Or over plain HTTP with the trigger URL (carries a SAS signature — treat it as a
credential):

```bash
az rest --method post --query value -o tsv --url \
  "https://management.azure.com/subscriptions/f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29/resourceGroups/LSY_WEUR_ITCS_PRD_SEC_RG_002/providers/Microsoft.Logic/workflows/CLOPSSEC_ticket_creation/triggers/manual/listCallbackUrl?api-version=2016-06-01"

curl -sS -X POST "<trigger-url>" -H 'Content-Type: application/json' \
  -d '{"issue_type":"Task","fields":{"summary":"Test","description":"Created by CLOPSSEC_ticket_creation"}}'
```

Worked examples for all three types and every error path are in
`docs/request-contract.md`.

## Design notes

- **`Create_issue` has `retryPolicy: none`.** The default policy would re-POST on a
  timeout and could raise two tickets for one request. The call is made exactly once; the
  caller decides whether to retry a 5xx.
- **Nothing is deduplicated.** Two calls with the same summary produce two tickets. Put
  the idempotency key (Sentinel incident number, run id) in `external_issue_id` and search
  before calling if you need lookup-before-create.
- **The response is synchronous.** The whole path is a handful of Jira calls, well inside
  the Request trigger's limit. There is no 202/poll pattern.
- **Secrets never reach the run history.** `Get_Jira_password` secures inputs and outputs;
  every action carrying Basic auth secures its inputs. The issue body is visible on
  `Compose_issue_body` for debugging — it holds no credential.
- **Values are trimmed**, except `description`, which is sent exactly as given.

## Parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `PlaybookName` | `CLOPSSEC_ticket_creation` | ARM only. Pass explicitly on every deploy |
| `Location` | `westeurope` | ARM only |
| `KeyVaultName` | `LSY-WEUR-ITCS-PRD-KV-02` | ARM only |
| `JIRAHOST` | `https://trackspace.lhsystems.com` | INT is `https://int-trackspace.lhsystems.com`; also the base of `ticket_url` |
| `JIRAUserName` / `JiraKeyVaultSecretName` | `sentinelsvc` / `sentinelsvc` | Basic auth; password read from Key Vault |
| `JiraProjectKey` | `CLOPSSEC` | |
| `AllowedIssueTypes` | `["Task", "Problem", "Incident"]` | Matched case-insensitively; sent to Jira in this casing |
| `MandatoryFieldsByType` | see *Mandatory fields* | Request keys that must be non-empty, per type |
| `DefaultPriorityByType` | Task / Problem `3 - Medium`, Incident `1 - Critical` | The create screen defaults |
| `DefaultAssigneeName` | `-1` | `-1` is Jira's *Automatic*; empty omits the field |
| `DefaultSecurityLevelName` | `""` | Empty omits the field → project default level |
| `DefaultIssueLinkTypeName` | `""` | Used when `linked_issues.type` is absent |
| `JiraCustomFields` | see *How the custom fields are addressed* | key → name / id / kind |

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

The template creates the Key Vault API connection `keyvault-<PlaybookName>` (managed
identity) and the Logic App, both tagged `CostCenter=S60019`,
`Owner=lsyh.sysops@lhsystems.com`, `assessment-id=1`. It outputs `logicAppPrincipalId`
and `logicAppResourceId` (the id the nested-workflow action needs).

One-time access: the vault is in **access-policy mode**, so the `Key Vault Secrets User`
RBAC role is inert. Grant the identity secret `get` with an access policy:

```bash
az keyvault set-policy --name LSY-WEUR-ITCS-PRD-KV-02 \
  --object-id "<logicAppPrincipalId>" --secret-permissions get
```

No Sentinel role is needed: the playbook never touches an incident.

Logic App runs are immutable: after a redeploy, cancel any stuck in-flight runs and fire
fresh ones.

### Sync / acceptance

```bash
diff <(jq -S '.definition.actions' playbook/workflow.json) \
     <(jq -S '.resources[]|select(.type=="Microsoft.Logic/workflows")|.properties.definition.actions' playbook/azuredeploy.json)
diff <(jq -S '.definition.triggers' playbook/workflow.json) \
     <(jq -S '.resources[]|select(.type=="Microsoft.Logic/workflows")|.properties.definition.triggers' playbook/azuredeploy.json)
```

Both must be empty. The only permitted residual `jq -S` difference between the two files
is the parameter `defaultValue`s — literals in `workflow.json`, `[parameters('…')]` in
ARM.

Acceptance, against INT first:

1. `{"issue_type":"Task","fields":{"summary":"x"}}` → **400**, `error` names
   `description`, no ticket, run Failed.
2. `{"issue_type":"Bug", …}` → **400** listing the allowed types.
3. A Task with summary + description → **200**, key + URL; the ticket is reported by
   `sentinelsvc`, assigned automatically, priority *3 - Medium*.
4. An Incident with `category` → **200** and the Category set. If instead it answers
   500 *could not be mapped*, the field is named differently on that instance: pin the id
   in `JiraCustomFields`.
5. A Problem with `subscription` → either **200**, or a Jira 400 quoting the Insight
   resolver — the latter means the field needs the clone path (see above).
6. Point `JIRAHOST` at an unreachable host → **502** with `status: "error"`, run Failed.
