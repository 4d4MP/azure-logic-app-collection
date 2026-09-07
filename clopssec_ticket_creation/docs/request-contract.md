# Request / response contract

Worked payloads for `CLOPSSEC_ticket_creation`. All requests are `POST` with
`Content-Type: application/json`; all responses carry the same four keys.

## Task

The Task create screen: Summary\*, Priority\*, Component/s, Labels, Due Date,
Description\*, DoD, Linked Issues + Issue; People tab Reporter\* / Assignee\* (both
defaulted).

```json
{
  "issue_type": "Task",
  "fields": {
    "summary": "index.html IP review",
    "description": "Run ID: 08584512345678901234567890\nFlagged IPs: 7",
    "priority": "3 - Medium",
    "components": ["SecOps"],
    "labels": ["blocklist-review"],
    "due_date": "2026-09-14",
    "dod": ["Findings reviewed", "Blocklist cleaned"],
    "assignee": "secops",
    "linked_issues": { "type": "Analysis", "direction": "outward", "keys": ["CLOPSSEC-42210"] }
  }
}
```

Minimum: `summary` + `description`.

## Problem

The Problem create screen: Security Level, Summary\*, Priority, Reason for investigation,
Subscription\*, Affected item, Component/s, Labels, Description, Provider, External issue
ID.

```json
{
  "issue_type": "Problem",
  "fields": {
    "summary": "Recurring malformed user agents from partner range",
    "description": "Three incidents in seven days from 195.60.216.0/24.",
    "reason_for_investigation": "Recurring incident",
    "subscription": "SUB-1234",
    "affected_item": "LCJ-37462",
    "provider": "PRV-42",
    "external_issue_id": "4711, 4720, 4733"
  }
}
```

Minimum: `summary` + `subscription`. `subscription`, `affected_item` and `provider` take
the Insight **object key** and are sent as `[{"key": …}]`.

## Incident

The Incident create screen: Summary\*, Priority\* (default *1 - Critical*), Category,
Subscription, Affected item, External issue ID, Customer reference, Component/s, Labels,
Description\*.

```json
{
  "issue_type": "Incident",
  "fields": {
    "summary": "Suspicious sign-in from TOR exit node",
    "description": "Sentinel incident 4711\n\nhttps://portal.azure.com/#...",
    "category": "TruePositive - suspicious activity",
    "external_issue_id": "4711",
    "customer_reference": "INC0098765",
    "labels": ["sentinel", "identity"]
  }
}
```

Minimum: `summary` + `description`. Priority falls back to *1 - Critical*.

## What is sent to Trackspace

For the Incident above, with `Category` resolving to `customfield_11001` and `External
issue ID` to `customfield_11002` (illustrative ids), `Compose_issue_body` holds:

```json
{
  "fields": {
    "project": { "key": "CLOPSSEC" },
    "issuetype": { "name": "Incident" },
    "summary": "Suspicious sign-in from TOR exit node",
    "priority": { "name": "1 - Critical" },
    "description": "Sentinel incident 4711\n\nhttps://portal.azure.com/#...",
    "assignee": { "name": "-1" },
    "labels": ["sentinel", "identity"],
    "customfield_11001": { "value": "TruePositive - suspicious activity" },
    "customfield_11002": "4711",
    "customfield_XXXXX": "INC0098765"
  }
}
```

The Task example adds `"update": {"issuelinks": [{"add": {"type": {"name": "Analysis"},
"outwardIssue": {"key": "CLOPSSEC-42210"}}}]}` next to `fields`.

## Responses

**200** — created:

```json
{ "status": "ok", "ticket_key": "CLOPSSEC-42311",
  "ticket_url": "https://trackspace.lhsystems.com/browse/CLOPSSEC-42311", "error": null }
```

**400** — request rejected before any Jira call:

```json
{ "status": "error", "ticket_key": null, "ticket_url": null,
  "error": "missing mandatory field(s) for Task: description" }
```

```json
{ "status": "error", "ticket_key": null, "ticket_url": null,
  "error": "issue_type must be one of: Task, Problem, Incident (got: Bug)" }
```

```json
{ "status": "error", "ticket_key": null, "ticket_url": null,
  "error": "linked_issues.type is required when linked_issues.keys is given (or set the DefaultIssueLinkTypeName parameter)" }
```

**500** — a custom field could not be addressed (configuration, not the caller):

```json
{ "status": "error", "ticket_key": null, "ticket_url": null,
  "error": "request field(s) could not be mapped to a Jira custom field id: category (Jira field named 'Category': 2 custom field(s) with that name in /rest/api/2/field). Pin the id in the JiraCustomFields parameter of the playbook." }
```

**500** — Key Vault or the field lookup failed:

```json
{ "status": "error", "ticket_key": null, "ticket_url": null,
  "error": "the playbook failed before the ticket could be created: Get_Jira_password: Forbidden" }
```

**Jira's status (400 here)** — Trackspace refused the issue; its body is quoted:

```json
{ "status": "error", "ticket_key": null, "ticket_url": null,
  "error": "Jira did not create the issue (HTTP 400): {\"errorMessages\":[],\"errors\":{\"customfield_11001\":\"Option value 'Suspicious' is not valid\"}}" }
```

**502** — no HTTP response from Trackspace at all (DNS, TLS, timeout).

## Finding the values Trackspace expects

```bash
# custom field ids and names (what the playbook resolves by itself)
curl -sS -u "sentinelsvc:$PW" "$JIRAHOST/rest/api/2/field" | jq '.[] | select(.custom) | {id, name}'

# create screen of one issue type: required flags and allowed select values
curl -sS -u "sentinelsvc:$PW" \
  "$JIRAHOST/rest/api/2/issue/createmeta?projectKeys=CLOPSSEC&issuetypeNames=Incident&expand=projects.issuetypes.fields" \
  | jq '.projects[0].issuetypes[0].fields | to_entries[] | {id: .key, name: .value.name, required: .value.required, values: [.value.allowedValues[]?.value // .value.allowedValues[]?.name]}'

# issue link type names for linked_issues.type
curl -sS -u "sentinelsvc:$PW" "$JIRAHOST/rest/api/2/issueLinkType" | jq '.issueLinkTypes[] | {name, outward, inward}'
```
