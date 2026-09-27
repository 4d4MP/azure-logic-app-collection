# `clopssec_ticket_transition` — CLOPSSEC ticket transition building block

HTTP-triggered Logic App building block (deployed as `CLOPSSEC_ticket_transition`, Consumption,
`westeurope`, `LSY_WEUR_ITCS_PRD_SEC_RG_002`). It has two modes, chosen by the request body:

* **List mode.** Send only `ticket_key`. The block returns every transition Jira offers from
  the ticket's current status. Each transition comes with its **required** and **optional**
  fields, and each field with its type, whether Jira fills in a default, and its allowed values.
  Nothing is written.
* **Transition mode.** Add `transition_id` and/or `transition_name`, plus the transition's
  `fields` if it has any. The block checks the transition against what Jira lists for the
  current status, and resolves and shapes every field against that transition's field metadata.
  If anything is wrong, it refuses the call **before any Jira write**. Otherwise it submits the
  transition once and verifies the new status. It then answers with the transitions available
  from the new status.

Same design as `clopssec_ticket_creation`, `create_subtask` and `opslsy_ticket_transition`: a
Request trigger in, a synchronous `Response` out, and the caller gets its answer as an HTTP status
code with a JSON body. Every failure path responds and then terminates the run as **Failed**. A
served list and a verified transition end the run as **Succeeded**.

## Flow

```
validate request ──400──► (nothing touched)
read request field keys ──400──►
Key Vault password ──500──►
prime affinity cookie (GET /serverInfo; failure tolerated)
GET issue ──Jira 4xx passed through / 502──►
project == JiraProjectKey? ──409──►
GET transitions?expand=transitions.fields ──Jira 4xx passed through / 502──►
build the transition catalog ──502──►
│
├─ list mode ──────────────────────────────────────────────► 200 transitions + fields
│
└─ transition mode
     pick the transition (id / name) ──409 not available / ambiguous / id-name mismatch──►
     resolve + shape every request field ──400 unknown / invalid / missing required──►
     POST transitions (no retry) ──Jira 4xx passed through──►
     poll GET issue?fields=status until status == transition.to.name
       ├─ reached ─► GET transitions (new status) ─► 200
       │   (a self-loop counts as reached only when the POST answered 2xx)
       └─ not reached ─────────────────────────────► 504 (or Jira's 5xx)
```

All Jira calls carry the Trackspace affinity cookie from `Prime_Affinity_Cookie`, so every call in
one run hits the same cluster node. Trackspace's `Set-Cookie` carries the `sentinelsvc` session
(`JSESSIONID`) next to the affinity cookie, and Jira can set a new `sentinelsvc` `JSESSIONID` on
**any** call: for example when the primer failed, timed out or returned no `JSESSIONID`, or when the
run lands on another cluster node. For that reason every Jira Http action (the primer, `Get_Ticket`,
`Get_Transitions`, `Post_Transition`, `Get_Verification_Status` and `Get_Transitions_After`) secures
its inputs **and** outputs in run history, and so does the parsed cookie (`Build_Cookie_Parts`). Every
Jira call builds its `Cookie` header straight from `Build_Cookie_Parts`. The cookie never passes
through a variable, because variable actions cannot be secured. As a result, run history does not
show Jira's raw status, headers or bodies. The caller's response and the run's Terminate error
message still carry Jira's error text. Transition ids are never hard-coded. The block acts only on
what Jira lists for the ticket's status at call time. Jira hides transitions that `sentinelsvc` is
not allowed to perform, so they never show up here.

## Request

`POST` to the `manual` trigger URL with `Content-Type: application/json`.

| Field | Type | Meaning |
| --- | --- | --- |
| `ticket_key` | string | **Required.** Trimmed and upper-cased; must be `<JiraProjectKey>-<digits>`, e.g. `CLOPSSEC-46988`. |
| `transition_id` | string \| number | Optional. Matched as a trimmed string against the transition `id`. |
| `transition_name` | string | Optional. Case-insensitive, trimmed, exact match on the transition `name`. |
| `fields` | object | Optional, transition mode only. Keys are Jira field **ids** (`resolution`, `customfield_12345`) or **display names** (`Resolution`, case-insensitive). |

No `transition_id` and no `transition_name` means **list mode**. In list mode `fields` must be
absent or `{}`. Anything else is a 400, so a caller who forgot the transition never has its field
values silently dropped. If both `transition_id` and `transition_name` are sent, they must name
the same transition (409 otherwise). An `id` also settles a name that matches several transitions.

Any other top-level property (e.g. `transitionId`, `transition`, a top-level `comment`) is a 400
that names the unrecognised properties. A misspelled transition key is never answered with a 200
list, and a misplaced value is never dropped without an error.

```bash
# list
curl -s -X POST "$TRANSITION_URL" -H 'Content-Type: application/json' \
  -d '{"ticket_key": "CLOPSSEC-46988"}'

# transition
curl -s -X POST "$TRANSITION_URL" -H 'Content-Type: application/json' -d '{
  "ticket_key": "CLOPSSEC-46988",
  "transition_name": "Close Issue",
  "fields": { "resolution": "Done", "comment": "Closed by automation" }
}'
```

### How `fields` are resolved and shaped

Each key must resolve to **exactly one** field of the selected transition. An exact id match wins.
Otherwise the key is matched against the field display names, case-insensitively, and that match
must be unique. Keys that resolve to nothing, or to a display name shared by several fields, are
reported in `unknown_fields`.

Each value is then turned into the Jira REST shape, using the field's metadata from
`expand=transitions.fields`. The first rule that applies wins:

| Value / field | Sent as |
| --- | --- |
| `null` or a blank string | clears the field: sent as `null` (`[]` for `array` fields); does not satisfy a required field; a blank `comment` adds no comment; a field whose Jira `operations` lack `set` (e.g. `worklog`) cannot be cleared → `invalid_values` |
| field id `comment` or schema type `comment` | `update.comment = [{"add": {"body": "<text>"}}]`, never `fields.comment` (an array is sent as the `update.comment` list as-is; an object that already has `add`, `edit` or `remove` as its single entry; any other object, e.g. `{"body": "...", "visibility": {"type": "role", "value": "Administrators"}}`, as `{"add": <object>}`) |
| field whose Jira `operations` has `add` but not `set` (e.g. `worklog`, `issuelinks`) | `update.<id> = [{"add": <value>}]` (an array is sent as the op list as-is, an object that already has `add` as its single entry; worklog text → `{"add": {"timeSpent": "<text>"}}`) |
| field whose Jira `operations` has neither `set` nor `add` | `invalid_values` |
| value is already a JSON object or array | passed through unchanged (the caller sent Jira shape) |
| field has `allowedValues` | the text is matched case-insensitively against the `id` and `name` of each entry in the field's listed `allowed_values` (the `name` there falls back to Jira's `value`) → `{"id": "<id>"}`; an allowed value that Jira lists as a plain string (no id) is sent as the matched string; either is wrapped in an array when `schema.type` is `array`; no match → `invalid_values` |
| `schema.type` `user` or `group` | `{"name": "<text>"}` |
| `schema.type` `array`, items `user` or `group` | `[{"name": "<text>"}]` |
| other `schema.type` `array` | `[<value>]` |
| anything else | the scalar as given (numbers stay numbers) |

A field for which Jira lists no `operations` follows the `fields` rules. `update` operations are
not shaped further: Jira validates them, and a 4xx is passed through.

Then the **mandatory check**: every field Jira marks `required` must have been supplied in the
request body, unless Jira reports `hasDefaultValue: true` for it. The block never copies a value
from the issue. A `null` or blank value clears the field but does not count as supplied, so a
required field sent that way is reported missing. A field that is supplied with an invalid value
appears only in `invalid_values`, not also as missing. A field addressed twice, by its id and by
its display name, is an `invalid_values` entry.

If `unknown_fields`, `invalid_values` or `missing_required_fields` is not empty, the answer is
**400**. Nothing has been sent to Jira at that point.

## Responses

Every body carries `status` (`ok` | `error`), `mode` (`list` | `transition`, or `null` when the
request body could not be read), `ticket_key` (the trimmed, upper-cased key, or `null` when the body
could not be read or `ticket_key` was missing or blank), `current_status` (string, or `null` before
it is known) and `error` (`null` on success).

### 200, list mode

```json
{
  "status": "ok",
  "mode": "list",
  "ticket_key": "CLOPSSEC-1",
  "current_status": "Resolved",
  "transitions": [
    {
      "id": "701",
      "name": "Close Issue",
      "to_status": "Closed",
      "required_fields": [
        { "id": "resolution", "name": "Resolution", "type": "resolution", "required": true,
          "has_default_value": false, "operations": [ "set" ],
          "allowed_values": [ { "id": "1", "name": "Done" }, { "id": "10000", "name": "Won't Do" } ] },
        { "id": "customfield_12345", "name": "Category", "type": "option", "required": true,
          "has_default_value": true, "operations": [ "set" ],
          "allowed_values": [ { "id": "20001", "name": "Network" }, { "id": "20002", "name": "Identity" } ] }
      ],
      "optional_fields": [
        { "id": "comment", "name": "Comment", "type": "comment", "required": false,
          "has_default_value": false, "operations": [ "add", "edit", "remove" ], "allowed_values": [] },
        { "id": "fixVersions", "name": "Fix Version/s", "type": "array:version", "required": false,
          "has_default_value": false, "operations": [ "set", "add", "remove" ],
          "allowed_values": [ { "id": "10001", "name": "v1" }, { "id": "10002", "name": "v2" } ] },
        { "id": "worklog", "name": "Log Work", "type": "array:worklog", "required": false,
          "has_default_value": false, "operations": [ "add" ], "allowed_values": [] }
      ]
    },
    { "id": "3", "name": "Reopen Issue", "to_status": "Open", "required_fields": [], "optional_fields": [] }
  ],
  "error": null
}
```

`type` is `schema.type`, or `array:<items>` for arrays. `operations` is Jira's list of edit
operations for the field, or `[]` when Jira gives none. A field with `add` but not `set`, such as
`worklog` above, is sent as an `update` operation (see the shaping table). `allowed_values` reduces
each Jira allowed value to `id` + `name`, falling back to `value` for select options, and is `[]`
when Jira gives none. An allowed value that Jira lists as a plain string (e.g. `["red", "blue"]` on a
multi-select) becomes `{ "id": "", "name": "red" }`. Fields keep the order in which Jira returns them. `Category` above is
required but has a default, so a transition request may leave it out.

### 200, transition mode

```json
{
  "status": "ok",
  "mode": "transition",
  "ticket_key": "CLOPSSEC-1",
  "transition": { "id": "701", "name": "Close Issue" },
  "previous_status": "Resolved",
  "current_status": "Closed",
  "available_transitions": [ { "id": "3", "name": "Reopen Issue", "to_status": "Open" } ],
  "error": null
}
```

The transition has happened and has been verified by the time this arrives. If the final
`GET transitions` for the new status fails, the answer is still **200**, because the mutation
succeeded, with `available_transitions: null` and an `available_transitions_error` string. A caller
that retried on that would try the same transition again from the wrong status.

### 400, field problems

```json
{
  "status": "error",
  "mode": "transition",
  "ticket_key": "CLOPSSEC-1",
  "current_status": "Resolved",
  "transition": { "id": "701", "name": "Close Issue", "to_status": "Closed" },
  "unknown_fields": [ "Nope" ],
  "invalid_values": [
    { "field": "resolution", "name": "Resolution", "key": "resolution", "value": "Fixed",
      "allowed_values": [ { "id": "1", "name": "Done" }, { "id": "10000", "name": "Won't Do" } ],
      "message": "'Fixed' is not an allowed value for Resolution (resolution)" }
  ],
  "missing_required_fields": [],
  "error": "Unknown field(s) for transition 'Close Issue': Nope (use a field id, or a display name that matches exactly one field of the transition). Invalid value(s): 'Fixed' is not an allowed value for Resolution (resolution)."
}
```

### 409, transition not available

```json
{
  "status": "error",
  "mode": "transition",
  "ticket_key": "CLOPSSEC-1",
  "current_status": "Resolved",
  "requested_transition": { "id": null, "name": "Start Progress" },
  "available_transitions": [
    { "id": "701", "name": "Close Issue", "to_status": "Closed" },
    { "id": "3", "name": "Reopen Issue", "to_status": "Open" }
  ],
  "error": "Transition 'Start Progress' is not available from status 'Resolved'."
}
```

The same shape is used when a name matches several transitions ("… matches 2 transitions … send
transition_id instead") and when `transition_id` and `transition_name` disagree.

### Jira refused the transition

When the POST itself returns a 4xx, the block answers with **Jira's status code**. The `error` is
built from Jira's `errorMessages` and `errors`, and both are returned raw:

```json
{
  "status": "error", "mode": "transition", "ticket_key": "CLOPSSEC-1", "current_status": "Resolved",
  "transition": { "id": "701", "name": "Close Issue", "to_status": "Closed" },
  "jira_error_messages": [ "Workflow validator failed." ],
  "jira_errors": { "customfield_12345": "Category is required." },
  "error": "Jira rejected the transition (HTTP 400): Workflow validator failed.; customfield_12345: Category is required."
}
```

A non-JSON 4xx body, such as an HTML page from a proxy, is returned as the first 1,000 characters
of raw text in `error`. Nothing is polled after a 4xx.

### 400, unreadable body

A JSON array, a bare JSON string or a non-JSON body cannot be read as a request object:

```json
{ "status": "error", "mode": null, "ticket_key": null, "current_status": null,
  "error": "The request body could not be read: send a JSON object with ticket_key and, optionally, transition_id, transition_name and fields." }
```

### Status codes

| Code | Meaning |
| --- | --- |
| 200 | List served, or transition done **and** verified. |
| 400 | Request problem (key format, types, `fields` without a transition, unrecognised top-level properties, unreadable body or `fields` keys), or field problems (`unknown_fields`, `invalid_values`, `missing_required_fields`). Nothing was sent to Jira. |
| 404 / other 4xx | Jira's own answer on the issue lookup (e.g. the ticket does not exist), passed through. |
| 409 | Ticket outside `JiraProjectKey` (e.g. moved to another project), transition not available from the current status, ambiguous name, or `transition_id` and `transition_name` disagree. |
| 4xx from the POST | Jira refused the transition (validator, condition, bad field value, 404 for a transition no longer valid). Passed through; not mutated. |
| 500 | Key Vault read failed, or the playbook failed while preparing the transition (before any write). |
| 502 | Jira answered 5xx or malformed data on a read, or the field metadata could not be interpreted. |
| 504 | The transition was submitted but the new status was not observed in the window, a self-loop transition's POST was not answered with 2xx (5xx or timeout), or verification failed. **Outcome unverified**: list the ticket before retrying. When Jira's POST itself returned a 5xx, that code is returned instead of 504. |

Jira 401/403 on a read or on the POST is passed through as is. It is about the `sentinelsvc`
service account, not the caller.

## Parameters

| Workflow parameter | Default | Meaning |
| --- | --- | --- |
| `$connections` | Key Vault connection `keyvault-CLOPSSEC_ticket_transition` | Managed-identity Key Vault API connection (created by the template). |
| `JIRAHOST` | `https://trackspace.lhsystems.com` | Trackspace base URL (`https://int-trackspace.lhsystems.com` for INT). |
| `JIRAUserName` | `sentinelsvc` | Basic-auth user. |
| `JiraKeyVaultSecretName` | `sentinelsvc` | Secret holding the Trackspace password (vault `LSY-WEUR-ITCS-PRD-KV-02`). |
| `JiraProjectKey` | `CLOPSSEC` | Required `ticket_key` prefix and the only project the block acts on. |
| `VerificationPollAttempts` | `8` | Maximum status polls after the POST. |
| `VerificationPollDelaySeconds` | `3` | Delay between polls; the first poll is immediate. |
| `VerificationTimeout` | `PT40S` | Overall timeout of the poll loop. |

The ARM template additionally takes `PlaybookName` (`CLOPSSEC_ticket_transition`), `Location`
(`westeurope`) and `KeyVaultName` (`LSY-WEUR-ITCS-PRD-KV-02`).

## Limits

Everything happens before the `Response`, and a Consumption Request trigger must answer within
**120 seconds**. Every Jira call and the Key Vault read has an explicit timeout and **no retry
policy**, so the worst case is bounded:

```
Key Vault read          10 s
Prime_Affinity_Cookie    5 s
Get_Ticket               8 s
Get_Transitions          8 s
Post_Transition         25 s
poll loop               40 s  (+ one in-flight poll: 5 s GET + 3 s delay)
Get_Transitions_After    8 s
-----------------------------
                       112 s  + a few seconds of in-process work (catalog, field loop)
```

The catalog's work is linear in the size of the ticket's transition metadata. It converts and parses
the metadata a fixed number of times per field and transition, and reads all allowed values from
one node-set, so large select lists (for example 1,000 versions or components) add work in
proportion to their size only. This holds in list mode too.

**Redo this arithmetic before raising `VerificationTimeout`, `VerificationPollDelaySeconds` or any
action timeout.** An overrun does not merely time out. The caller gets a bare gateway timeout,
possibly after the ticket has already moved.

## Known edges

* **Field keys are read through `xml()`/`xpath()`.** The Workflow Definition Language has no
  `keys()` function. The same technique enumerates the field ids in Jira's transition metadata.
  `:`, `@`, `$`, `#` and `?` are protected while the keys are listed, so display names such as
  `Root Cause: Category` work. A key that the listing cannot reproduce exactly (for example one
  containing control characters) is reported in `unknown_fields` (400) and is never matched to a
  different field. A key starting with `:` makes the call a 400 "keys could not be read". Values
  may hold any character, including control characters such as pasted ANSI
  escapes: the key copy writes those as plain text, and the values sent to Jira are the ones from
  the request body, unchanged.
* **Control characters in Jira's transition metadata** (for example a vertical tab in a version
  description pasted from Word) are handled the same way: they are written as plain text before
  the metadata goes through `xml()`. An allowed value whose `id` or `name` contains one is listed
  with the character spelled out (`v3\u000bbeta` is listed as `v3u000bbeta`); send its `id`. **Known
  limitation:** `string()` is capped at 131,072 characters. When the ticket's transition metadata is
  larger than that, the block falls back to the unmodified metadata. If that metadata contains a
  control character other than tab, LF or CR, the answer is **502** "The transitions returned by
  Jira could not be interpreted", in both modes, for every ticket in that status.
* **`comment` works only when the transition lists it.** That means the transition has a screen
  that includes the comment field. Otherwise `comment` is an unknown field.
* **An allowed-value text matching several entries** (for example the id of one and the name of
  another) picks the first match in Jira's order. Send the id to be exact.
* **Self-loop transitions**, where `to` equals the current status, count as done only when Jira's
  POST answered 2xx. If the POST returned 5xx or timed out, the block answers that 5xx or 504
  (outcome unverified) and the run fails.
* **Staleness**: transitions are read once. If someone else moves the ticket between that read and
  the POST, Jira rejects the POST (400/404), and that answer is passed through.
* **`previous_status`** is the status read at the start of the run.

## Deploy

PowerShell (Az module):

```powershell
Set-AzContext -SubscriptionId f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29

$deployment = New-AzResourceGroupDeployment `
  -ResourceGroupName LSY_WEUR_ITCS_PRD_SEC_RG_002 `
  -TemplateFile clopssec_ticket_transition/playbook/azuredeploy.json `
  -TemplateParameterFile clopssec_ticket_transition/playbook/azuredeploy.parameters.json

# The new Logic App has its own system-assigned identity: give it secret 'get' on the vault.
Set-AzKeyVaultAccessPolicy `
  -VaultName LSY-WEUR-ITCS-PRD-KV-02 `
  -ObjectId $deployment.Outputs.logicAppPrincipalId.Value `
  -PermissionsToSecrets get `
  -BypassObjectIdValidation
```

Azure CLI equivalent:

```bash
az deployment group create \
  --resource-group LSY_WEUR_ITCS_PRD_SEC_RG_002 \
  --template-file clopssec_ticket_transition/playbook/azuredeploy.json \
  --parameters @clopssec_ticket_transition/playbook/azuredeploy.parameters.json

az keyvault set-policy --name LSY-WEUR-ITCS-PRD-KV-02 \
  --object-id "$(az deployment group show -g LSY_WEUR_ITCS_PRD_SEC_RG_002 \
      -n azuredeploy --query properties.outputs.logicAppPrincipalId.value -o tsv)" \
  --secret-permissions get
```

The template creates the `keyvault-CLOPSSEC_ticket_transition` API connection (managed identity,
no interactive consent) and the Logic App with a system-assigned identity. The vault is in
**access-policy** mode, so the `Key Vault Secrets User` RBAC role would have no effect: grant the
access policy. Until you do, every call answers 500 ("Failed to retrieve Jira credentials from Key
Vault"). The access policy is a control-plane change, so the vault firewall does not block it.

When redeploying with `Deploy-AzLogicApp.ps1`, the `definition` in `azuredeploy.json` must stay
identical to `workflow.json`. Only the ARM-expression parameter defaults may differ. Change both
files together.

Callers read the trigger URL at their own deploy time with
`listCallbackUrl(concat(resourceId('Microsoft.Logic/workflows', 'CLOPSSEC_ticket_transition'), '/triggers/manual'), '2019-05-01').value`
into a `SecureString` parameter, the way `dev_tool` does. The template publishes no trigger URL
output, because it contains the SAS signature.
