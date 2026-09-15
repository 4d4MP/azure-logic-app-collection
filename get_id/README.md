# `get_id` — Sentinel incident lookup and activation building block

HTTP-triggered Logic App building block. It finds Microsoft Sentinel incidents matching
caller-supplied criteria and answers synchronously with each match's **ARM id**, **GUID** and
**attached entities**. With `activate_incident: true` it also moves each match to **Active**.

> **Despite the name, this block writes.** It is the only building block in this collection that
> can mutate production incidents. Read the activation rules below before calling it with
> `activate_incident: true`.

Modelled on the `Find_And_Activate_Incidents` scope of `ti_handling_automation`, with the
TI-handler's fixed title filters replaced by request fields, and reworked into a synchronous
request/response block in the style of `clopssec_ticket_creation`, `create_subtask` and
`opslsy_ticket_transition`.

## Request

`POST` to the `manual` trigger URL. Every field is optional, but **at least one of
`title_prefix`, `title_suffix` or `title_exact` is required** — a block that can mutate must not
have a "match everything" default.

| Field | Type | Meaning |
| --- | --- | --- |
| `title_prefix` | string | Case-insensitive prefix the title must start with. AND-ed with `title_suffix`. |
| `title_suffix` | string | Case-insensitive suffix the title must end with. AND-ed with `title_prefix`. |
| `title_exact` | string | Case-insensitive full title. OR-ed with the prefix/suffix pair, so one call matches a templated title family and a fixed title at once. |
| `incident_status` | array\|string | `New`, `Active`, `Closed` (case-insensitive). A bare string is accepted. Omitted means every status except `Closed`. |
| `created_after` | string | `yyyy-MM-ddTHH:mm:ssZ`, exactly 20 characters. Applied server-side. |
| `created_before` | string | Same format. Applied server-side. |
| `activate_incident` | boolean | Move every eligible match to `Active`. Anything other than `true` / `"true"` is read as false. |
| `max_results` | integer | 1..16 read-only, 1..8 when activating. Defaults to that ceiling. |

```bash
curl -s -X POST "$GET_ID_URL" -H 'Content-Type: application/json' -d '{
  "title_prefix": "A network session Source address",
  "title_suffix": "matched an IoC.",
  "incident_status": ["New"],
  "created_after": "2026-09-01T00:00:00Z",
  "activate_incident": true,
  "max_results": 5
}'
```

## Response

`200` on success — **including zero matches** (`count: 0`, `incidents: []`, `status: "ok"`).

```json
{
  "status": "ok",
  "count": 1,
  "total_matched": 1,
  "limited": false,
  "activate_requested": true,
  "activated_count": 1,
  "activation_skipped_count": 0,
  "activation_refused_count": 0,
  "activation_failed_count": 0,
  "activation_unknown_count": 0,
  "entities_failed_count": 0,
  "upstream_status_code": 0,
  "incidents": [
    {
      "incident_arm_id": "/subscriptions/.../providers/Microsoft.SecurityInsights/incidents/<guid>",
      "incident_id": "<guid>",
      "incident_number": 4821,
      "title": "A network session Source address 1.2.3.4 matched an IoC.",
      "incident_status": "New",
      "severity": "Medium",
      "created_time_utc": "2026-09-15T06:14:22.1234567Z",
      "entities": [
        {
          "id": "/subscriptions/.../providers/Microsoft.SecurityInsights/Entities/<guid>",
          "name": "<guid>",
          "type": "Microsoft.SecurityInsights/Entities",
          "kind": "Ip",
          "properties": { "address": "1.2.3.4", "friendlyName": "1.2.3.4" }
        }
      ],
      "entity_count": 1,
      "entities_status_code": 200,
      "entities_error": null,
      "activation": {
        "attempted": true, "skipped": false, "refused": false, "succeeded": true,
        "resulting_status": "Active", "status_code": 200, "error": null
      }
    }
  ],
  "error": null
}
```

Every response — success or failure — carries the **complete key set**; error paths fill payload
keys with `null`, `[]`, `0` or `false`. `upstream_status_code: 0` means no upstream error code was
observed.

| Code | Meaning |
| --- | --- |
| 200 | Request served, contract honoured. Includes zero matches. |
| 400 | Request validation, and only request validation. |
| 409 | Well-formed request refused on discovered state: a matched incident was `Closed`. |
| 500 | The playbook itself failed (client-side filtering, result assembly). |
| 502 | Upstream read failed, listing truncated, or the result is incomplete. |
| 504 | The activation may have happened but its outcome could not be established. |

Upstream codes are **not** passed through as the block's own status. An ARM 400 is about this
workflow's `$filter`, not the caller's request, and an ARM 403 is about this playbook's role
assignment; either one reaching the caller as a 400 or 403 would mean something false. The real
code is in `upstream_status_code` and in the error string.

### Entities

`entities` is returned **raw**, so it can contain `SecurityAlert` and `HuntingBookmark` items
alongside `Ip`, `Account`, `Host`, `Url` and `FileHash`. Select on `kind` — this block does not
filter. Note the casing asymmetry: the request path is `.../incidents/<id>/entities`, the returned
`id` carries `/providers/Microsoft.SecurityInsights/Entities/<guid>`.

### Counter invariant

When `activate_requested` is true:

```
activated_count + activation_skipped_count + activation_refused_count
  + activation_failed_count + activation_unknown_count == count
```

`activated_count` counts only real writes; incidents already `Active` are counted once, under
`activation_skipped_count`.

## Activation rules

* **Already `Active` → skipped, not re-written.** A redundant PUT still bumps
  `lastModifiedTimeUtc`, writes a `SecurityIncident` row and fires incident-update automation
  rules. This is a shared block, so that is a live feedback-loop hazard.
* **`Closed` → refused per incident, never reopened.** Reopening a closed incident is the one
  transition that reliably corrupts: the connector merges the stored `classification` forward and
  Sentinel answers 400. A request combining `incident_status: ["Closed"]` with
  `activate_incident: true` is refused at validation; a closed incident that turns up under any
  other request is refused individually and lifts the answer to 409.
* **The write goes through the azuresentinel managed connector**, `PUT /Incidents` with
  `incidentArmId` + `status`. That is a delta update — it cannot blank `severity`, `owner`,
  `description`, `labels` or `firstActivityTimeUtc`. A direct ARM `PUT` is create-or-update and
  would need a full read-modify-write with etag handling; raw ARM is used only for the two read
  paths.
* **Success is asserted on the returned body**, not the HTTP code: the connector returns the
  updated incident and `properties.status` is the evidence.
* Nothing retries. `retryPolicy: none` everywhere — a mutating call must never silently
  double-fire, and the platform default (up to 4 exponential retries) alone exceeds this block's
  whole synchronous budget.

## Limits

The Consumption inbound request limit is **120 seconds**, and everything here happens before the
`Response`. `max_results` is therefore capped at **16** read-only and **8** when activating:

```
read-only:  2 pages x PT10S  +  16 x PT5S  = 100 s
activating: 2 pages x PT10S  +   8 x PT5S (entities) + 8 x PT5S (activation) = 100 s
```

**Redo this arithmetic before changing `MaxResultsCeilingRead`, `MaxResultsCeilingActivate`,
`IncidentRequestTimeout`, `ListRequestTimeout` or `MaxIncidentPages`.** Overrunning the window does
not merely time out: with `activate_incident: true` it activates incidents and then hands the
caller a bare gateway timeout naming none of them.

Listing pages at `$top=500` up to `MaxIncidentPages` (2) — the same 1,000-incident ceiling Sentinel
documents for a list request. Reaching either cap is a loud `502 IncidentListTruncated` **before
any mutation**, never a silent truncation.

## Known edges

* **Title matching is client-side.** The incidents endpoint implements only a partial OData
  `$filter` and rejects string functions, so status and the created-time window go server-side and
  titles are filtered on the returned page. A very broad title with a narrow status/time window
  works well; the reverse can hit the page cap.
* **Page accumulation uses `union()`**, which dedupes on the whole projected element. An incident
  whose `status` changes between two page fetches can therefore appear twice and inflate
  `total_matched`. `lastModifiedTimeUtc` is deliberately not projected for the same reason.
* **`incident_status` in the response is the pre-activation value**, read by the list call;
  `activation.resulting_status` is the value after. Same pairing as
  `opslsy_ticket_transition`'s `requested_status` / `resulting_status`.
* **Staleness between the list read and the PUT** is bounded (tens of seconds at these ceilings)
  but not zero. An incident closed by an analyst inside that window is still activated, because
  the `Closed` guard tests the status read at list time. Closing the window would need a
  per-incident GET immediately before each PUT and would halve the activation ceiling.
* **No by-id lookup.** `incident_id` / `incident_number` are returned but cannot be searched on;
  resolving a known incident number to its ARM id is a v2 candidate, not a current capability.

## Deploy

```bash
az deployment group create \
  --resource-group LSY_WEUR_ITCS_PRD_SEC_RG_002 \
  --template-file playbook/azuredeploy.json \
  --parameters @playbook/azuredeploy.parameters.json
```

The template creates the `azuresentinel-get_id` API connection (managed identity auth, no
interactive consent) and the Logic App with a system-assigned identity. Afterwards grant that
identity **Microsoft Sentinel Responder** on the workspace — Reader is not sufficient, because the
entities call is a `POST` under `/incidents` and the activation is a write:

```bash
az role assignment create \
  --assignee "$(az deployment group show -g LSY_WEUR_ITCS_PRD_SEC_RG_002 \
      -n azuredeploy --query properties.outputs.logicAppPrincipalId.value -o tsv)" \
  --role "Microsoft Sentinel Responder" \
  --scope "<LogAnalyticsResourceID>"
```

Callers get the trigger URL at their own deploy time with
`listCallbackUrl(concat(resourceId('Microsoft.Logic/workflows', 'get_id'), '/triggers/manual'), '2019-05-01').value`
into a `SecureString` parameter, the way `dev_tool` does. The template deliberately publishes no
`triggerUrl` output: it contains the trigger SAS signature, and an ARM output writes it into the
deployment history in cleartext.
