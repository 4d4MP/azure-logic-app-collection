# Topic 03: Jira Integration

Generated: 2026-04-29 | Sources: 9 | Confidence: high

## Scope

How a Logic App (and, where richer logic is needed, a Python Azure Function) talks to Jira. The main flow describes **Jira Cloud** (modern Atlassian-hosted) — auth, the create/comment/update flows, Atlassian Document Format (ADF), error and rate-limit handling, and the idempotency pattern that prevents duplicate tickets.

The **actual ticketing system in the LHsystems / lhsystems.int environment is Trackspace**, which is **Jira Data Center** (self-hosted, on-prem). Path prefixes, auth model, and description format differ. See the dedicated section *"Trackspace (Jira Data Center) — actual LHsystems environment"* below for the deltas; everything else (idempotency patterns, error handling, rate-limit philosophy) carries over essentially unchanged.

Out of scope: Jira project schema design (custom field design is a JSON-by-tenant decision), and Jira automation rules ("Jira-side workflows", a different product feature).

## Key entities & terms

- **Jira Cloud REST API**: Atlassian's HTTPS API at `https://<tenant>.atlassian.net/rest/api/3/`. Version `3` is the JSON-with-ADF version; version `2` accepts plain-text descriptions but is being phased out. [src 1]
- **API token**: a 24-character secret tied to an Atlassian account, generated at `id.atlassian.com/manage-profile/security/api-tokens`. Auth header is `Basic base64(<email>:<token>)`. [src 2]
- **OAuth 2.0 (3LO)**: three-legged OAuth where a user consents per-app. Used when an Atlassian app acts on behalf of users. Overkill for service automation. [src 2]
- **Service account**: a dedicated Atlassian account (e.g. `sentinel-bot@yourcompany.com`) whose API token the playbook uses. Tickets show "created by sentinel-bot", which is what you want for audit clarity.
- **Project key**: short prefix on issue keys (e.g. `SEC` → tickets numbered `SEC-1`, `SEC-2`). Decided when the project is created; changing it later breaks links. [src 3]
- **Issue type**: `Bug`, `Task`, `Story`, `Incident`, etc. Custom issue types are common; reference by name in API calls. [src 3]
- **ADF (Atlassian Document Format)**: a JSON tree that Jira renders as the issue description. Block-level (`paragraph`, `heading`, `codeBlock`) and inline marks (`strong`, `em`, `link`). REST v3 requires ADF for description and comment bodies. [src 4]
- **JQL (Jira Query Language)**: `project = SEC AND "Sentinel Incident ID" = "<guid>"`. Used to look up an existing issue before creating a duplicate. [src 5]
- **Webhook**: a Jira-side outbound HTTP call when an issue changes state. Useful for closing the loop (close Sentinel incident when Jira issue is closed). Not strictly part of this topic but the natural pair. [src 6]

## Core facts

1. **Use API tokens for service automation.** OAuth 3LO is the right choice for Marketplace apps acting on behalf of users; for a Sentinel playbook, a dedicated service-account token is simpler and equally secure if rotated. [src 2]
2. **Auth is Basic, base64-encoded.** Header value is `Basic <base64('<email>:<token>')>`. Common bug: people base64 only the token, or forget the colon. [src 2]
3. **Issue creation is `POST /rest/api/3/issue`** with a body of `{"fields": {"project": {"key": "SEC"}, "summary": "...", "issuetype": {"name": "Incident"}, "description": <ADF tree>, ...}}`. Response includes `id`, `key`, `self` URL. [src 3]
4. **Comments are `POST /rest/api/3/issue/{key}/comment`** with `{"body": <ADF tree>}`. Response includes the comment id and a self URL. [src 3]
5. **Field updates are `PUT /rest/api/3/issue/{key}`** with `{"fields": {...}}`. Custom fields use IDs like `customfield_10042`; a separate call to `GET /rest/api/3/field` enumerates them. [src 3]
6. **Status changes go through transitions, not field updates.** `POST /rest/api/3/issue/{key}/transitions` with `{"transition": {"id": "31"}}`. Get available transitions for an issue from `GET /rest/api/3/issue/{key}/transitions`. [src 3]
7. **Rate limits are per-tenant and per-token.** Atlassian's documented baseline is 10 calls/sec sustained, with burst tolerance; specific limits are published per tier and via response headers (`X-RateLimit-Remaining`, `Retry-After` on 429). [src 7]
8. **429 responses include a `Retry-After` header in seconds.** Always honour this rather than backing off blindly. [src 7]
9. **Idempotency is your responsibility.** Jira will not deduplicate `POST /issue` calls. Use JQL to look up before creating. [src 5]
10. **ADF is mandatory for v3 description and comment bodies.** Sending a plain string fails with 400 "Operation value must be an Atlassian Document". [src 4]

## Logic App pattern (HTTP action)

The minimum viable "create incident ticket" step:

```json
"Create_Jira_issue": {
  "type": "Http",
  "inputs": {
    "method": "POST",
    "uri": "https://yourtenant.atlassian.net/rest/api/3/issue",
    "headers": { "Content-Type": "application/json", "Accept": "application/json" },
    "authentication": {
      "type": "Basic",
      "username": "sentinel-bot@yourcompany.com",
      "password": "@parameters('jira_token')"
    },
    "body": {
      "fields": {
        "project": { "key": "SEC" },
        "issuetype": { "name": "Incident" },
        "summary": "@{triggerBody()?.object?.properties?.title}",
        "labels": "@{triggerBody()?.object?.properties?.additionalData?.tactics}",
        "description": {
          "type": "doc",
          "version": 1,
          "content": [
            { "type": "paragraph", "content": [
                { "type": "text", "text": "Severity: " },
                { "type": "text", "text": "@{triggerBody()?.object?.properties?.severity}", "marks": [{"type": "strong"}] }
            ]},
            { "type": "paragraph", "content": [
                { "type": "text", "text": "Sentinel link: " },
                { "type": "text", "text": "Open incident", "marks": [
                  { "type": "link", "attrs": { "href": "@{triggerBody()?.object?.properties?.incidentUrl}" } }
                ]}
            ]}
          ]
        },
        "customfield_10042": "@{triggerBody()?.object?.name}"
      }
    },
    "retryPolicy": {
      "type": "exponential",
      "interval": "PT5S",
      "count": 5,
      "minimumInterval": "PT5S",
      "maximumInterval": "PT60S"
    }
  },
  "runAfter": { "Get_jira_token_from_KV": ["Succeeded"] }
}
```

Notes:

- `customfield_10042` is the place to stash the Sentinel incident GUID for later JQL lookup. Use whichever custom field your Jira admin has provisioned for "External Incident ID".
- The retry policy retries on 408/429/5xx automatically. 4xx other than 408/429 is a permanent failure — handle it with a `runAfter: Failed` branch.
- The `password` references a Logic App parameter populated from Key Vault at deploy time *or* a `Get secret` action output (see topic 05).

## Idempotency: the lookup-before-create pattern

```
1. Parse incident → Sentinel incident GUID = X
2. Search Jira: GET /rest/api/3/search?jql=project=SEC AND "External Incident ID" ~ "X"
3. If issues.length > 0:
     a. Comment on issues[0] with the new context.
     b. Stash issues[0].key in the Sentinel incident tag (if not already there).
     c. Skip Create.
4. Else:
     a. POST /rest/api/3/issue …
     b. Tag the Sentinel incident with the returned key.
```

JQL detail: `~` is "contains" for text, `=` is exact match. For a GUID, prefer `=`.

The lookup costs one extra round trip per playbook run. At Sentinel's typical incident rate this is negligible.

## ADF crash course

ADF (Atlassian Document Format) is the JSON-tree equivalent of Markdown. The minimum valid description is:

```json
{ "type": "doc", "version": 1, "content": [
  { "type": "paragraph", "content": [{"type": "text", "text": "Hello"}] }
] }
```

Block types you'll use most:
- `paragraph` — most prose.
- `heading` — `attrs.level` 1–6.
- `bulletList` / `orderedList` → contain `listItem` → contain `paragraph`.
- `codeBlock` — `attrs.language` (e.g. `kql`), `content: [{"type":"text","text":"<your code>"}]`.
- `blockquote` — for source-quote blocks.
- `panel` — `attrs.panelType` (`info`/`warning`/`error`/`success`/`note`); great for severity callouts.

Inline marks: `strong`, `em`, `link` (with `attrs.href`), `code` (inline), `subsup`, `textColor`. Marks live on `text` nodes as `marks: [{"type":"strong"}]`.

The `Compose` action in Logic Apps is your friend for building ADF — assemble piece by piece with `concat()` and `setProperty()` then feed the final object to the HTTP action's `body.fields.description`.

For non-trivial ADF (escaping, embedded code, mentions), build it in the Function — it's tedious in Logic App expressions.

## Python pattern (Azure Function)

When you need ADF assembly with logic, retries with state, or library code, do it in a small HTTP-triggered Function. Sketch:

```python
import os, base64, json, logging, time
from typing import Any, Dict, Optional

import azure.functions as func
import requests

JIRA_BASE = os.environ["JIRA_BASE_URL"].rstrip("/")  # https://tenant.atlassian.net
JIRA_USER = os.environ["JIRA_USER"]                  # sentinel-bot@yourcompany.com
JIRA_TOKEN = os.environ["JIRA_TOKEN"]                # populated from Key Vault reference
PROJECT_KEY = os.environ.get("JIRA_PROJECT_KEY", "SEC")
EXTERNAL_ID_FIELD = os.environ.get("JIRA_EXTERNAL_ID_FIELD", "customfield_10042")

def _auth_header() -> Dict[str, str]:
    raw = f"{JIRA_USER}:{JIRA_TOKEN}".encode("utf-8")
    return {"Authorization": f"Basic {base64.b64encode(raw).decode('ascii')}",
            "Content-Type": "application/json", "Accept": "application/json"}

def _request(method: str, path: str, body: Optional[dict] = None,
             max_attempts: int = 5) -> requests.Response:
    url = f"{JIRA_BASE}{path}"
    backoff = 1.0
    for attempt in range(max_attempts):
        resp = requests.request(method, url, headers=_auth_header(), json=body, timeout=20)
        if resp.status_code == 429:
            wait = float(resp.headers.get("Retry-After", backoff))
            logging.warning("Jira 429; sleeping %.1fs (attempt %d)", wait, attempt + 1)
            time.sleep(wait); backoff *= 2; continue
        if 500 <= resp.status_code < 600:
            logging.warning("Jira %d; sleeping %.1fs (attempt %d)", resp.status_code, backoff, attempt + 1)
            time.sleep(backoff); backoff *= 2; continue
        return resp
    raise RuntimeError(f"Jira request failed after {max_attempts} attempts")

def find_existing_issue(incident_guid: str) -> Optional[str]:
    jql = f'project = "{PROJECT_KEY}" AND "{EXTERNAL_ID_FIELD}" = "{incident_guid}"'
    resp = _request("GET", f"/rest/api/3/search?jql={requests.utils.quote(jql)}&fields=key&maxResults=1")
    resp.raise_for_status()
    issues = resp.json().get("issues", [])
    return issues[0]["key"] if issues else None

def create_issue(payload: Dict[str, Any]) -> str:
    body = {"fields": {
        "project": {"key": PROJECT_KEY},
        "issuetype": {"name": "Incident"},
        "summary": payload["title"][:255],
        "labels": payload.get("tactics", []),
        EXTERNAL_ID_FIELD: payload["incident_guid"],
        "description": _build_adf(payload),
    }}
    resp = _request("POST", "/rest/api/3/issue", body)
    resp.raise_for_status()
    return resp.json()["key"]

def add_comment(issue_key: str, text_blocks: list) -> None:
    body = {"body": {"type": "doc", "version": 1, "content": text_blocks}}
    resp = _request("POST", f"/rest/api/3/issue/{issue_key}/comment", body)
    resp.raise_for_status()

def main(req: func.HttpRequest) -> func.HttpResponse:
    payload = req.get_json()
    incident_guid = payload["incident_guid"]
    existing = find_existing_issue(incident_guid)
    if existing:
        add_comment(existing, _build_update_comment(payload))
        return func.HttpResponse(json.dumps({"key": existing, "action": "commented"}),
                                 mimetype="application/json", status_code=200)
    key = create_issue(payload)
    return func.HttpResponse(json.dumps({"key": key, "action": "created"}),
                             mimetype="application/json", status_code=201)
```

Caveats:
- `JIRA_TOKEN` is provided by a Key Vault reference (`@Microsoft.KeyVault(...)`) — never inline.
- `requests` retries on 429/5xx with `Retry-After` honoured; on 4xx other than 429, fail loud.
- All summaries are truncated at 255 chars (Jira's hard limit).
- The `_build_adf` and `_build_update_comment` helpers assemble ADF — keep them pure-functional and unit-testable.

## Rate-limit handling

Jira's public guidance: **respect `Retry-After`**, back off exponentially otherwise, and keep your sustained rate under the published per-tenant limit. [src 7]

For Sentinel automation, the realistic risk isn't sustained throughput — playbooks fire at incident rate, which is bursty but small. The risk is a *campaign-style alert storm* (e.g. password-spray hitting many users) producing 100 incidents in 60 seconds. Patterns:

- **Token bucket in the Function.** A simple in-process bucket capped at 8 req/s (give yourself headroom under 10) keeps you well under the limit.
- **Coalesce on Sentinel side.** Use Sentinel's *grouping* settings on the analytics rule to merge many alerts into one incident. The playbook fires once per incident, not per alert.
- **Throttle per project.** Different Jira projects (e.g. `SEC` and `OPS`) have separate rate budgets — split workloads if total volume is high.

## Error handling

Three classes of error and the right response:

- **Transient (429, 502, 503, 504):** retry with backoff (Logic App built-in retry policy or Function loop). Eventually surface to a Failed branch if exhausted.
- **Permanent (400, 401, 403, 404):** fail-fast. Write to Blob with the request/response pair (redact the token!), comment on the Sentinel incident with "Jira call failed: <status> — see audit log <blob URL>", route to manual review.
- **Logical (200 with unexpected body):** assert response shape with a Condition action / Pydantic model. Treat as permanent.

Never swallow errors silently. The "Succeeded with skipped step" failure mode is the worst SOC experience.

## Where this commonly breaks in practice

- **Custom field IDs differ between sandbox and prod tenants.** Hard-coding `customfield_10042` works in dev and 404s in prod. Fix: look up via `GET /rest/api/3/field` at startup and cache the mapping. [src 3]
- **403 with no body when creating an issue.** The service account isn't a member of the project. Fix: add it as a project role member, not just a tenant user. [src 3]
- **400 "issuetype 'Incident' not found".** The project uses a Scrum/Kanban template that doesn't include `Incident`. Fix: pick the right template at project creation, or change the issue type to one the template supports.
- **ADF rejected with "value must be an Atlassian Document".** Old code passing string descriptions to v3. Fix: rewrite to ADF, or temporarily hit v2 (not recommended).
- **JQL search returns 200 but no results, even though the issue exists.** Index lag — Jira's full-text index is eventually consistent. Use the explicit `=` operator on the custom field rather than `~`, which uses the lagging index. [src 5]
- **Token rotated, playbook silently using the old token.** The Logic App parameter was set at deploy time and the deploy didn't re-run. Fix: switch to runtime KV fetch (see topic 05) or wire deployment to KV change events.

## Trackspace (Jira Data Center) — actual LHsystems environment

Everything above describes Jira **Cloud**. The local environment uses **Trackspace**, a self-hosted **Jira Data Center** instance at `https://trackspace.lhsystems.com`. The Logic App / Function patterns are conceptually identical (HTTP action with auth, idempotent create-or-comment, exponential retry on 429/5xx); the surface details that differ are listed below.

### Deltas vs Jira Cloud

| Aspect | Jira Cloud (this file's main flow) | Trackspace (Jira Data Center) |
|---|---|---|
| Base URL | `https://<tenant>.atlassian.net` | `https://trackspace.lhsystems.com` |
| REST API version | `v3` (ADF) | `v2` (plain-text descriptions) |
| Issue endpoint | `POST /rest/api/3/issue` | `POST /rest/api/2/issue` |
| Comment endpoint | `POST /rest/api/3/issue/{key}/comment` | `POST /rest/api/2/issue/{key}/comment` |
| Worklog endpoint | `POST /rest/api/3/issue/{key}/worklog` | `POST /rest/api/2/issue/{key}/worklog` |
| Auth header | `Authorization: Basic <base64(email:api_token)>` | `Authorization: Bearer <PAT>` |
| Token issued by | `id.atlassian.com` API tokens | Trackspace user profile → *Personal Access Tokens* (`/secure/ViewProfile.jspa`) |
| Description body | ADF JSON tree (mandatory in v3) | Plain string (Jira wiki markup if you want formatting) |
| Comment body | ADF JSON tree | `{ "body": "<plain string>" }` |
| Project key in this env | (varies) | `CLOPSSEC` (security operations) |
| External-incident-ID custom field | tenant-specific `customfield_XXXXX` | look up via `GET /rest/api/2/field` per environment |

### Production credentials (LHsystems)

Two completely separate Trackspace credentials are in use, owned by different principals and stored in different places. **Do not conflate them.**

| Caller | Credential | Where it lives | Auth pattern |
|---|---|---|---|
| Production Logic App `TI-handler` and similar Sentinel→Trackspace playbooks | Password for service account `sentinelsvc` | Key Vault `LSY-WEUR-ITCS-PRD-KV-02`, secret name `sentinelsvc` | **Basic** (`sentinelsvc` + KV password) |
| Local Python automation (`daily.py`, `work.py`, ad-hoc scripts) | Personal Access Token issued under Adam's personal Trackspace account | `TRACKSPACE_PAT` environment variable on the operator's machine | **Bearer** (PAT) |

So the auth header sent to Trackspace is environment-dependent:

- **Logic App** → `Authorization: Basic <base64('sentinelsvc:' + KV-password)>`. The HTTP action's `authentication.type` is `Basic`, `username = sentinelsvc`, `password = @body('Get_sentinelsvc_secret').value` (or `@parameters('sentinelsvc_password')` for deploy-time-baked).
- **Python Function / local script** → `Authorization: Bearer ${TRACKSPACE_PAT}`. PAT is scoped to the issuing user account and inherits that user's permissions.

Tickets created by the Logic App show "created by sentinelsvc"; tickets / worklogs from local scripts show as Adam's personal account. This is intentional: it's the audit boundary between automated and human action.

### Auth — Bearer PAT pattern (local automation)

Trackspace's Server/DC PAT auth header is `Authorization: Bearer <token>`, no email, no base64. PATs are scoped to the issuing user account and inherit that user's permissions; rotate from the user profile page (`/secure/ViewProfile.jspa`).

This is the pattern used by `daily.py` / `work.py` and any other script run under a personal account:

- **Python script**: `headers={"Authorization": f"Bearer {os.environ['TRACKSPACE_PAT']}"}`.
- **Hypothetical Logic App calling Trackspace as a human user** (rare; not the production pattern): HTTP action → `headers.Authorization = "Bearer @{body('Get_trackspace_pat').value}"`.

### Logic App pattern (Trackspace HTTP action)

```json
"Create_Trackspace_issue": {
  "type": "Http",
  "inputs": {
    "method": "POST",
    "uri": "https://trackspace.lhsystems.com/rest/api/2/issue",
    "headers": {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "Authorization": "Bearer @{body('Get_trackspace_pat').value}"
    },
    "body": {
      "fields": {
        "project": { "key": "CLOPSSEC" },
        "issuetype": { "name": "Task" },
        "summary":   "@{triggerBody()?.object?.properties?.title}",
        "labels":    "@{triggerBody()?.object?.properties?.additionalData?.tactics}",
        "description": "Severity: @{triggerBody()?.object?.properties?.severity}\nSentinel link: @{triggerBody()?.object?.properties?.incidentUrl}",
        "customfield_XXXXX": "@{triggerBody()?.object?.name}"
      }
    },
    "retryPolicy": {
      "type": "exponential",
      "interval": "PT5S",
      "count": 5,
      "minimumInterval": "PT5S",
      "maximumInterval": "PT60S"
    }
  },
  "runAfter": { "Get_trackspace_pat": ["Succeeded"] }
}
```

Notes:

- `description` is a plain string. Newlines (`\n`) are honoured. Jira wiki markup (`*bold*`, `{code}...{code}`, `||header||...||`) renders fine on Trackspace.
- The `customfield_XXXXX` ID for "Sentinel Incident GUID" is environment-specific. Look it up once via `GET /rest/api/2/field` and cache the mapping (don't hardcode in source).
- Retry policy carries over verbatim from the Cloud pattern.

### CLOPSSEC workflow transition chain

The CLOPSSEC project uses a multi-step transition workflow. There is no single Approval → Closed transition. Tickets walk:

| From | To | Transition id | Name |
|---|---|---|---|
| Open | Approval | `4` | Start Progress |
| Approval | In Progress | `811` | Approve |
| Approval | Resolved (direct) | `821` | Reject |
| In Progress | Resolved | `5` | Resolve issue |
| Resolved | Closed | `701` | Close |
| Closed | Open | (varies) | Reopen |

Probed against `CLOPSSEC-42210` on 2026-05-12. Transitions are **state-dependent**: the set of available transitions changes based on the ticket's current status. Always re-probe with `GET /rest/api/2/issue/{key}/transitions` against a ticket in the source state before hard-coding a transition id.

The "Approve" transition (id 811, Approval → In Progress) is the right honest path for a SOAR-approved ticket: it advances the ticket forward through normal workflow rather than via the "Reject" shortcut. The TI-handler playbook (file 07) uses three sequential transitions (`811 → 5 → 701`) to walk the ticket all the way from Approval to Closed around its blocklist update, preserving accurate audit-log semantics at each step.

### Python pattern (Trackspace)

```python
import os, json, logging, time
from typing import Any, Dict, Optional
import requests

JIRA_BASE = os.environ.get("JIRA_BASE_URL", "https://trackspace.lhsystems.com").rstrip("/")
JIRA_PAT  = os.environ["TRACKSPACE_PAT"]              # Key Vault reference at runtime
PROJECT_KEY = os.environ.get("JIRA_PROJECT_KEY", "CLOPSSEC")
EXTERNAL_ID_FIELD = os.environ["JIRA_EXTERNAL_ID_FIELD"]   # customfield_XXXXX

def _headers() -> Dict[str, str]:
    return {
        "Authorization": f"Bearer {JIRA_PAT}",
        "Content-Type":  "application/json",
        "Accept":        "application/json",
    }

def _request(method: str, path: str, body: Optional[dict] = None,
             max_attempts: int = 5) -> requests.Response:
    url, backoff = f"{JIRA_BASE}{path}", 1.0
    for attempt in range(max_attempts):
        resp = requests.request(method, url, headers=_headers(), json=body, timeout=20)
        if resp.status_code == 429:
            wait = float(resp.headers.get("Retry-After", backoff))
            logging.warning("Trackspace 429; sleeping %.1fs (attempt %d)", wait, attempt + 1)
            time.sleep(wait); backoff *= 2; continue
        if 500 <= resp.status_code < 600:
            time.sleep(backoff); backoff *= 2; continue
        return resp
    raise RuntimeError(f"Trackspace request failed after {max_attempts} attempts")

def find_existing_issue(incident_guid: str) -> Optional[str]:
    jql = f'project = "{PROJECT_KEY}" AND "{EXTERNAL_ID_FIELD}" = "{incident_guid}"'
    resp = _request("GET", f"/rest/api/2/search?jql={requests.utils.quote(jql)}"
                           f"&fields=key&maxResults=1")
    resp.raise_for_status()
    issues = resp.json().get("issues", [])
    return issues[0]["key"] if issues else None

def create_issue(payload: Dict[str, Any]) -> str:
    body = {"fields": {
        "project":       {"key": PROJECT_KEY},
        "issuetype":     {"name": "Task"},
        "summary":       payload["title"][:255],
        "labels":        payload.get("tactics", []),
        EXTERNAL_ID_FIELD: payload["incident_guid"],
        "description":   _build_description_text(payload),    # plain string
    }}
    resp = _request("POST", "/rest/api/2/issue", body)
    resp.raise_for_status()
    return resp.json()["key"]

def add_comment(issue_key: str, text: str) -> None:
    resp = _request("POST", f"/rest/api/2/issue/{issue_key}/comment",
                    {"body": text})
    resp.raise_for_status()
```

### Status polling via `expand=changelog` (validated pattern)

Approval-style flows where the Logic App needs to wait for an analyst to transition a Trackspace ticket can poll a single endpoint that returns both current status and the full transition history:

```python
import os, requests
r = requests.get(
    "https://trackspace.lhsystems.com/rest/api/2/issue/CLOPSSEC-41456",
    headers={"Authorization": f"Bearer {os.environ['TRACKSPACE_PAT']}"},
    params={"fields": "status,summary,updated", "expand": "changelog"},
    timeout=30,
)
issue = r.json()
current = issue["fields"]["status"]["name"]
transitions = [
    {"when": h["created"], "who": h["author"]["displayName"],
     "from": i["fromString"], "to": i["toString"]}
    for h in issue["changelog"]["histories"]
    for i in h["items"] if i["field"] == "status"
]
```

In the Logic App, this is an `Until` loop with delay (60s per iteration is the validated cadence), max iterations capped (60 = 1h timeout), exit condition on status ∈ {target_states}. On timeout, comment on the ticket and route to the manual-review branch — never let the loop exit silently.

`changelog` returns up to ~100 history entries by default; for long-lived tickets, paginate via `GET /rest/api/2/issue/{key}/changelog`.

### Worklog endpoint (validated pattern)

For automated worklog creation (e.g. recurring meeting logging), `POST /rest/api/2/issue/{key}/worklog` accepts:

```json
{
  "timeSpentSeconds": 1800,
  "started":          "2026-04-21T15:30:00.000+0200",
  "comment":          "SecOps Internal Sync"
}
```

The `started` field requires the `+HHMM` timezone offset (not `Z`, not `+02:00` with colon). Successful response is `201 Created` with the worklog `id`. The endpoint is **not idempotent** — re-running creates duplicates; dedupe upstream by checking existing worklogs via `GET /rest/api/2/issue/{key}/worklog` if needed.

### Common pitfalls specific to Trackspace

- **Sending ADF to v2** → `400 Bad Request`. v2 wants plain strings; only v3 (Cloud) takes ADF.
- **Bearer token leaked into v2 Basic-auth header** → `401`. Don't mix patterns.
- **JQL with custom-field name string** (`"Sentinel Incident ID"`) works in Cloud's UI but is unreliable in DC's REST search; always reference custom fields by ID (`customfield_XXXXX`) in JQL.
- **Trailing slash on base URL** → some endpoints 404 silently. Always `.rstrip("/")` the base.
- **PAT inherits user permissions, not service permissions.** A PAT issued by an account that loses project access stops working without warning. Use a dedicated service account (e.g. a Sentinel automation user) and document its permission scope.
- **Browse Projects + View All Worklogs** are the two permissions that catch out worklog-reporting tools that work for the script author but return empty for colleagues.


2. Atlassian Developer — *Basic auth for REST APIs* — https://developer.atlassian.com/cloud/jira/platform/basic-auth-for-rest-apis/ — accessed 2026-04-29
3. Atlassian Developer — *Issue endpoints* — https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/ — accessed 2026-04-29
4. Atlassian Developer — *Atlassian Document Format* — https://developer.atlassian.com/cloud/jira/platform/apis/document/structure/ — accessed 2026-04-29
5. Atlassian Support — *Advanced searching with JQL* — https://support.atlassian.com/jira-software-cloud/docs/use-advanced-search-with-jira-query-language-jql/ — accessed 2026-04-29
6. Atlassian Developer — *Webhooks* — https://developer.atlassian.com/cloud/jira/platform/webhooks/ — accessed 2026-04-29
7. Atlassian Developer — *Rate limiting* — https://developer.atlassian.com/cloud/jira/platform/rate-limiting/ — accessed 2026-04-29
8. Microsoft Learn — *HTTP action retry policies in Logic Apps* — https://learn.microsoft.com/azure/connectors/connectors-native-http — accessed 2026-04-29
9. Microsoft Learn — *Azure Functions Python developer guide* — https://learn.microsoft.com/azure/azure-functions/functions-reference-python — accessed 2026-04-29
10. Atlassian — *Jira Data Center REST API (v2)* — https://docs.atlassian.com/software/jira/docs/api/REST/latest/ — applicable to Trackspace
11. Atlassian — *Personal Access Tokens (Server / Data Center)* — https://confluence.atlassian.com/enterprise/using-personal-access-tokens-1026032365.html — applicable to Trackspace
