# `blob_append` — blob line-append building block

HTTP-triggered Logic App building block. It appends lines to a text blob — one item per
line, each carrying the same optional comment — and answers synchronously: **200** when the
append landed, the mapped error code when it did not.

Written for the Palo Alto EDL blocklist (`lsyweuritcsprdmspalo001/$web/index.html`), but the
target is entirely request-driven: subscription, resource group, storage account, container
and blob all come from the request body, so one deployment serves every blob the playbook's
identity can reach.

> **This block writes.** It is the only building block here that mutates a storage account,
> and the blob it is pointed at is usually enforced by a firewall. Read *How the write
> works* before calling it.

## Request

`POST` to the `manual` trigger URL. Everything except the comment and the flags is required.

| Field | Type | Meaning |
| --- | --- | --- |
| `subscription_id` | string | Subscription GUID of the storage account. |
| `resource_group_name` | string | Resource group of the storage account. Alias: `resource_group`. |
| `storage_account_name` | string | Bare account name, no endpoint suffix. Alias: `storage_account`. |
| `container_name` | string | Container. Alias: `container`. |
| `blob_name` | string | Blob path inside the container, e.g. `index.html` or `edl/blocklist.txt`. Alias: `blob`. |
| `lines` | array\|string | Items to append. An array of strings, or one newline-separated string. Alias: `ips`. |
| `comment` | string | One comment appended to **every** line, separated by `" #"`. Optional. |
| `skip_duplicates` | boolean | Default **true**. Drops items already on the blob. |
| `create_if_missing` | boolean | Default **false**. A missing blob is a 404 unless this is true. |
| `blob_type` | string | `BlockBlob` (default) or `AppendBlob`. Only used when *creating* a blob. |
| `content_type` | string | Content type for a blob this call creates. Default `text/plain`. |
| `dry_run` | boolean | Default false. Resolve, read and de-duplicate, write nothing — **including** not creating a missing blob, which is a 404 on a dry run whatever `create_if_missing` says. |

```bash
curl -s -X POST "$BLOB_APPEND_URL" -H 'Content-Type: application/json' -d '{
  "subscription_id": "f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29",
  "resource_group_name": "LSY_WEUR_ITCS_PRD_SEC_RG_002",
  "storage_account_name": "lsyweuritcsprdmspalo001",
  "container_name": "$web",
  "blob_name": "index.html",
  "lines": ["203.0.113.7", "198.51.100.44"],
  "comment": "OPSLSY-75376 TI-handler"
}'
```

appends

```
203.0.113.7 #OPSLSY-75376 TI-handler
198.51.100.44 #OPSLSY-75376 TI-handler
```

### Line normalisation

Items are trimmed, empty items are dropped, and an item containing newlines is split into
further items — so `lines` as an array and `lines` as one newline-separated string are the
same request. Within-batch duplicates collapse to one. Nothing is parsed or validated as an
IP address: the block appends strings.

The comment is appended as `<line>` + `" #"` + `<comment>`. A leading `#` in the comment is
dropped so the separator is never doubled; a comment containing a newline is a 400.

### Duplicates

With `skip_duplicates` (the default), an item is a duplicate when it equals the part of an
existing line **before** the `" #"` separator. So `203.0.113.7 #OPSLSY-70001 old change`
already on the blob makes `203.0.113.7` a duplicate whatever comment this call carries —
the address is what is blocked, the comment is provenance. Comparison is exact and
case-sensitive.

## Response

```json
{
  "status": "ok",
  "storage_account": "lsyweuritcsprdmspalo001",
  "container": "$web",
  "blob": "index.html",
  "blob_url": "https://lsyweuritcsprdmspalo001.blob.core.windows.net/%24web/index.html",
  "blob_type": "BlockBlob",
  "blob_created": false,
  "dry_run": false,
  "comment": "OPSLSY-75376 TI-handler",
  "requested_count": 3,
  "distinct_count": 2,
  "appended_count": 1,
  "skipped_duplicate_count": 2,
  "appended_lines": ["198.51.100.44 #OPSLSY-75376 TI-handler"],
  "skipped_lines": ["203.0.113.7"],
  "attempts": 1,
  "etag": "\"0x8DD1F2A3B4C5D6E\"",
  "upstream_status_code": 200,
  "error_code": null,
  "error": null
}
```

Every response — success or failure — carries the **complete key set**; error paths fill
payload keys with `null`, `[]`, `0` or `false`.

`skipped_duplicate_count` is `requested_count - appended_count`, so within-batch duplicates
and lines already on the blob both land in it; `skipped_lines` names only the latter. On a
dry run `appended_lines` means *would append*.

| Code | Meaning |
| --- | --- |
| 200 | The append landed — including "nothing to append, every line was already there". |
| 400 | Request validation, and only request validation. |
| 404 | The storage account is not in that subscription/resource group, or the blob does not exist and `create_if_missing` is false. |
| 409 | The target cannot be appended to: page blob, `application/json` content type, or a create that raced another writer. |
| 412 | The blob changed under every write attempt. Nothing was appended; retry. |
| 413 | The blob is larger than `MaxBlobBytes` (4 MiB by default). |
| 500 | The playbook itself failed. Whether the write landed is unknown. |
| 502 | Storage or ARM refused or failed. The real code is in `upstream_status_code`. |
| 504 | The write was sent but its outcome could not be established. |

**Storage's status code is not passed through as the block's own**, with two exceptions
(404 and the conflict cases) where it means the same thing to the caller. A storage `403` is
about *this playbook's* role assignment, not about the caller's request, so it answers 502
with `upstream_status_code: 403` — the same reasoning as `get_id`. `upstream_status_code: 0`
means no status was observed at all (timeout).

## How the write works

1. **Resolve.** `subscription_id` + `resource_group_name` + `storage_account_name` are
   resolved through ARM, and the account's own `primaryEndpoints.blob` becomes the base URL.
   That is what those two locator fields buy: a wrong subscription or resource group is a
   clean 404 instead of a write into a same-named account somewhere else, and the endpoint is
   never guessed. Set `ResolveEndpointViaArm: false` at deploy time to skip the call (and its
   Reader requirement) and build the URL from `BlobEndpointSuffix` instead.
2. **Inspect.** A `HEAD` establishes existence, blob type, content type, size and etag before
   anything is read or written.
3. **Read, merge, write — under optimistic concurrency.** The blob is read, the new lines are
   merged, and the write is conditional on the etag from *that* read (`If-Match`). A
   concurrent appender therefore cannot be silently overwritten: the write fails 412 and the
   loop re-reads and re-merges, up to `MaxWriteAttempts` (3). Exhausting them is a 412 to the
   caller, never a lost update.
4. **Block blob vs append blob.** A `BlockBlob` is rewritten whole (`PUT`, `If-Match`,
   preserving its stored content type — an EDL stays `text/html`). An `AppendBlob` gets a
   `comp=appendblock` write, which is atomic; it only carries the read's etag when
   `skip_duplicates` is on, because that is the only case where the write depends on what was
   read.
5. **Line endings.** A blob whose last line has no trailing newline gets one before the first
   appended line, so a half-written file cannot glue two entries together. `\r\n` on the blob
   is tolerated on read; what this block writes is `\n`.

Nothing retries at the HTTP layer — `retryPolicy: none` everywhere. The platform default (up
to 4 exponential retries) on a mutating call can double-write and alone exceeds the whole
synchronous budget. The only retry here is the deliberate, etag-guarded one above.

## Limits

The Consumption inbound request limit is **120 seconds**, and everything happens before the
`Response`:

```
ArmRequestTimeout  PT10S
HeadRequestTimeout PT10S
WriteLoopTimeout   PT80S   (3 attempts x (PT15S read + PT15S write) fits inside it)
                   -----
                   100 s
```

**Redo this arithmetic before changing any of those parameters or `MaxWriteAttempts`.**
Overrunning the window does not merely time out: the append may land and the caller is handed
a bare gateway timeout that names none of it.

`MaxLines` (1000) caps one request. `MaxBlobBytes` (4 MiB) caps the target, because the block
reads the whole blob to de-duplicate and, for a block blob, to rewrite it.

## Known edges

* **The whole blob is read on every call**, even for an append blob and even with
  `skip_duplicates: false`. That is what bounds the target at `MaxBlobBytes` and what makes
  the etag precondition possible. A pure, unconditional, unbounded appender would be a
  different block.
* **JSON targets are refused** (409). Logic Apps parses an `application/json` response body
  into an object, and re-serialising it would rewrite the blob's formatting. This block
  appends lines to text.
* **`create_if_missing` defaults to false** on purpose: a typo in `blob_name` that silently
  created a second, empty blocklist — while the real one stopped being updated — is a worse
  failure than a 404. A dry run never creates either, so `dry_run` against a blob that does
  not exist yet is a 404 and not a preview of the create.
* **No line-level validation.** `lines` takes any string. A malformed address is appended as
  faithfully as a good one; `blob_review` is the block that finds those afterwards.
* **Duplicate matching is exact.** `203.0.113.7` and `203.0.113.007` are two different lines,
  and a CIDR that already covers an address is not a duplicate.
* **A 504 is genuinely unknown.** If a write times out after being sent, read the blob before
  retrying — a retry could double-append.
* **`ti_handling_automation` and `malformed_user_agents_handler` still carry their own
  read-modify-write** of the EDL blob, without an etag precondition. Moving them onto this
  block is the reason it exists, but that port is not done; until it is, a TI-handler run
  overlapping a `blob_append` call can still lose one side's lines.

## Deploy

```bash
az deployment group create \
  --resource-group LSY_WEUR_ITCS_PRD_SEC_RG_002 \
  --template-file playbook/azuredeploy.json \
  --parameters @playbook/azuredeploy.parameters.json
```

No API connections are created — every call is a raw REST call authenticated with the Logic
App's system-assigned identity. Afterwards grant that identity, **on every storage account it
will be asked to write to**:

```bash
PRINCIPAL=$(az deployment group show -g LSY_WEUR_ITCS_PRD_SEC_RG_002 \
    -n azuredeploy --query properties.outputs.logicAppPrincipalId.value -o tsv)
SCOPE=$(az storage account show -g LSY_WEUR_ITCS_PRD_SEC_RG_002 \
    -n lsyweuritcsprdmspalo001 --query id -o tsv)

# data plane: read and write the blob
az role assignment create --assignee "$PRINCIPAL" \
  --role "Storage Blob Data Contributor" --scope "$SCOPE"

# management plane: resolve the account and its blob endpoint
az role assignment create --assignee "$PRINCIPAL" \
  --role "Reader" --scope "$SCOPE"
```

`Storage Blob Data Contributor` can be scoped to the single container instead of the account.
`Reader` is only needed while `ResolveEndpointViaArm` is true; the account's network rules
must also admit the Logic App.

## Testing it

`dev_tool` exercises this block over real HTTP as its third step. It posts the
`BlobAppendRequest` workflow parameter verbatim — a single JSON object holding the whole
request body, editable in the portal under *Logic App Designer → Parameters*, so the target,
the lines and the comment change without redeploying anything — and asserts
`appended_count == distinct_count`. It then calls the block a **second** time with
`skip_duplicates` forced true and asserts `appended_count: 0` with every line counted as a
duplicate, because "200 with nothing appended" is a legitimate answer and only the second call
tells the two apart.

`dev_tool` reads this block's trigger URL with `listCallbackUrl` at *its* deploy time, so
deploy `blob_append` first and redeploy `dev_tool` afterwards. Its default target is
`blob-append-test.txt` in the `dev-tool` container, never the EDL.

Callers get the trigger URL at their own deploy time with
`listCallbackUrl(concat(resourceId('Microsoft.Logic/workflows', 'blob_append'), '/triggers/manual'), '2019-05-01').value`
into a `SecureString` parameter, the way `dev_tool` does. The template deliberately publishes
no `triggerUrl` output: it contains the trigger SAS signature, and an ARM output writes it
into the deployment history in cleartext.
