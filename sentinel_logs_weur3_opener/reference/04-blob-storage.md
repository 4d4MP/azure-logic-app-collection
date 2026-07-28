# Topic 04: Azure Blob Storage for Audit Logs

Generated: 2026-04-29 | Sources: 8 | Confidence: high

## Scope

Blob storage as the second sink for the Sentinel automation pipeline: how the three blob types behave, container layout for incident-correlated audit logs, append vs block trade-offs, lifecycle/retention, and how to write to it cleanly from a Logic App and from a Python Function — using managed identity, not connection strings.

Out of scope: Azure Data Lake Storage Gen2 specifics (similar API, hierarchical namespace differences), Cosmos DB, and broader log-retention compliance frameworks (PCI/SOC 2/etc. — touched in topic 06 only as it relates to architecture).

## Key entities & terms

- **Storage account**: the Azure resource that contains containers. Has a name (`mycompanyaudit01`), a region, a redundancy choice (LRS/ZRS/GRS/RA-GRS), an access tier default (Hot/Cool/Cold/Archive), and a security model (firewall rules, private endpoints, AAD auth toggle). [src 1]
- **Container**: a flat namespace inside the account. Names lowercase, 3–63 chars. Containers are the unit of public-access scoping (always set to *private* for audit logs). [src 1]
- **Blob**: a file inside a container. Path is the container plus a forward-slash-delimited name; "folders" are virtual.
- **Block blob**: optimised for streaming and random reads. Default for "upload a file" scenarios. Modify by re-uploading. Up to ~190.7 TiB. [src 2]
- **Append blob**: optimised for log-style appends. Each append is its own block (max 4 MiB). Hard caps: 50,000 blocks per blob, ~195 GiB total. [src 2]
- **Page blob**: random-access binary; backs VHDs. Not relevant here.
- **Lease**: a time-bounded write lock on a blob. 15s–60s, or infinite. Used to prevent concurrent writers. [src 3]
- **SAS (Shared Access Signature)**: a signed URL granting time-bounded scoped access. *User delegation* SAS is signed with an AAD identity (auditable) rather than the account key (not auditable). [src 4]
- **Lifecycle management policy**: account-level rules that move blobs between tiers or delete them based on age. JSON document deployed via ARM/Bicep/portal. [src 5]
- **AAD auth (a.k.a. RBAC)**: granting AAD principals (users, groups, managed identities) the **Storage Blob Data Contributor / Reader / Owner** roles on container or account scope. Replaces account-key sharing. [src 6]
- **Append position / `x-ms-blob-condition-appendpos`**: a header that lets append-blob writers say "only append if the current length is N", giving safe concurrent semantics. [src 2]

## Core facts

1. **Choose append blobs for live, concurrent log appends; block blobs for batch writes that you read whole.** Trade-off: append blobs cap at 50,000 appends and 195 GiB; block blobs are cheaper per GB and more flexible for read patterns. [src 2]
2. **Concurrent appenders to the same append blob are safe** if they use the conditional `Append Block` with `appendpos`. Without it, two writers can both succeed but with interleaved partial writes. [src 2]
3. **Block blobs are immutable for the duration of an upload.** "Modify" means stage new blocks, then `Put Block List` to commit. Concurrent re-uploads race — last writer wins. Use leases for mutual exclusion or partition by writer (one writer per blob). [src 3]
4. **Always disable account-key access on new accounts** if you can: set *Allow storage account key access* to *Disabled* and use AAD auth via managed identity. Account keys can't be audited per-call. [src 6]
5. **Container path conventions matter for query and lifecycle.** Partition by date (`yyyy/MM/dd`) for time-range queries; include incident GUID in the filename so a single grep finds all log lines for an incident. [src 5]
6. **Lifecycle rules act on blob age (last-modified or creation time)**, not access time. Define them so audit logs flip from Hot → Cool → Cold → Archive at meaningful boundaries (e.g. 30 / 90 / 365 days). [src 5]
7. **Soft delete + versioning + immutable storage** are three independent toggles. For audit logs, enable soft delete (recover from accidental delete) and immutability/legal hold if compliance requires write-once. [src 7]
8. **Storage firewall + private endpoints** isolate the account at the network layer. With private endpoints, traffic from the Logic App (Standard, VNet-integrated) or Function flows over the Azure backbone, not the internet. [src 6]
9. **AAD auth uses the OAuth `https://storage.azure.com/.default` scope** for managed-identity tokens. The Logic App fetches a token, sends `Authorization: Bearer <token>` and `x-ms-version: 2021-08-06` headers to the REST endpoint. [src 6]
10. **Storage REST endpoints**: `https://<account>.blob.core.windows.net/<container>/<blob>` for blob ops; specific verbs and headers for `Put Blob`, `Append Block`, `Put Block`, `Put Block List`. [src 1]

## Container layout for the Sentinel pipeline

Recommended structure:

```
container: sentinel-audit
└── yyyy=2026/
    └── mm=04/
        └── dd=29/
            ├── <incident-guid>.log         # append blob, one line per playbook step
            └── playbook-runs/
                └── <run-id>.json           # block blob, full run dump on completion
```

Why this shape:

- **Time partitioning** (`yyyy=/mm=/dd=`) makes lifecycle rules trivial: "tier blobs older than 30 days to Cool", "delete blobs older than 7 years".
- **Incident GUID as filename** lets a single `Get Blob` retrieve all appended log lines for a given incident, no scanning.
- **Hive-style partition keys** (`yyyy=`) play nicely with downstream tools (ADX/Synapse external tables, Spark) that auto-discover partitions from path.
- **Separate `playbook-runs/` block blobs** for full JSON dumps on run completion give you a queryable structured record without bloating the live append log.

Avoid:

- Putting many incidents in one blob — append-blob 50,000-block cap is reached fast at ~10 incidents/day with verbose logging.
- Containers per project — containers have soft limits on count; partition by date inside one container instead.
- Slashes in incident GUIDs (they're URLs and you'll URL-encode them anyway, but kebab-case GUIDs are cleaner).

## Append blob: write pattern

Two REST calls:

1. **Create the blob** (idempotent): `PUT https://<account>.blob.core.windows.net/sentinel-audit/<path>?<sas>` with header `x-ms-blob-type: AppendBlob`, body empty. If blob exists, fail unless you explicitly use `If-None-Match: *` to mean "create only if absent".
2. **Append a block**: `PUT https://<account>.blob.core.windows.net/sentinel-audit/<path>?comp=appendblock` with body of bytes (max 4 MiB), and optionally header `x-ms-blob-condition-appendpos: <expected-length>`.

Each appended block becomes one entry in the blob's block list and one logical "log line" if you newline-terminate.

In Logic Apps:

- The **Azure Blob Storage** built-in connector has `Create blob` (creates a block blob — **wrong for append**) and there is no built-in "Append blob block" action. **Use the HTTP action with managed identity auth** for the append blob create + append. The REST API is straightforward.
- Alternatively, push the append into the Function and call it from the Logic App. This gives you concurrency control and structured retries inside Python.

In Python (Function):

```python
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from datetime import datetime, timezone

cred = DefaultAzureCredential()
svc = BlobServiceClient(account_url="https://mycompanyaudit01.blob.core.windows.net",
                        credential=cred)
container = svc.get_container_client("sentinel-audit")

def audit_path(incident_guid: str, when: datetime) -> str:
    return (f"yyyy={when.year:04d}/mm={when.month:02d}/dd={when.day:02d}/"
            f"{incident_guid}.log")

def append_audit_line(incident_guid: str, line: dict) -> None:
    when = datetime.now(timezone.utc)
    path = audit_path(incident_guid, when)
    blob = container.get_blob_client(path)
    if not blob.exists():
        blob.create_append_blob()
    line.setdefault("ts", when.isoformat())
    blob.append_block((line if isinstance(line, str) else __json__(line)) + "\n")
```

Notes:
- `DefaultAzureCredential` picks up the Function's managed identity automatically. No connection strings.
- `create_append_blob()` is idempotent against the right preconditions; if you're worried about race conditions on first-create, wrap in a try/except for `ResourceExistsError`.
- One blob per incident-day keeps appends well under the 50k cap.

## Block blob: write pattern

For the per-run dump (full JSON of the playbook run), block blob is right. Logic App's built-in connector handles this fine:

```json
"Save_run_dump": {
  "type": "ApiConnection",
  "inputs": {
    "host": { "connection": { "name": "@parameters('$connections')['azureblob']['connectionId']" } },
    "method": "post",
    "path": "/v2/datasets/.../files",
    "queries": {
      "folderPath": "/sentinel-audit/yyyy=2026/mm=04/dd=29/playbook-runs",
      "name": "@{workflow().run.name}.json",
      "queryParametersSingleEncoded": true
    },
    "body": "@string(variables('run_dump'))"
  }
}
```

For AAD auth without the connector, swap to HTTP with managed identity (same pattern as append blob). The connector defaults to account-key auth, which is what you're trying to get rid of.

## Lifecycle policy (minimum viable)

```json
{
  "rules": [
    {
      "name": "audit-tiering",
      "enabled": true,
      "type": "Lifecycle",
      "definition": {
        "filters": { "blobTypes": ["appendBlob", "blockBlob"], "prefixMatch": ["sentinel-audit/"] },
        "actions": {
          "baseBlob": {
            "tierToCool":    { "daysAfterModificationGreaterThan": 30 },
            "tierToArchive": { "daysAfterModificationGreaterThan": 365 },
            "delete":        { "daysAfterModificationGreaterThan": 2557 }
          }
        }
      }
    }
  ]
}
```

7-year retention (2557 days) is a common audit baseline; tune per your compliance regime. Cold tier (cheaper than Cool, longer access latency) is a 2024-era addition worth considering before Archive. Archive tier needs `rehydrate` to read, which takes hours.

## Idempotency and concurrency

**Append blob**: two writers appending without `appendpos` can both succeed, producing interleaved data. With `appendpos`, the second writer gets `412 Precondition Failed` and must re-fetch the blob length and retry. Worth implementing if multiple Logic App runs against the same incident race; not worth it for one-writer-per-blob designs.

**Block blob**: re-uploading the same blob from two writers is "last writer wins". To prevent this, acquire an infinite lease, do your work, release. Don't forget to release on error paths — orphaned leases leave the blob unwritable for up to 60s before lease auto-expiry kicks in (or forever if infinite).

## Access patterns and AAD wiring

Step-by-step for clean managed-identity access:

1. Create a system-assigned managed identity on the Logic App (or the Function).
2. Grant it **Storage Blob Data Contributor** at the *container* scope (not account, not subscription).
3. In the Logic App HTTP action, set `Authentication = Managed identity`, `Audience = https://storage.azure.com/`. The Logic App engine handles token acquisition and refresh.
4. In the Function, `DefaultAzureCredential()` plus the SDK does the same.

For SAS (only when MSI is impossible — rare):

- Use *user delegation* SAS, not account-key SAS. User delegation is signed with an AAD principal; account key SAS leaks the master credential into every link.
- Scope to the smallest possible (`/<container>/<prefix>/`).
- Time-bound to the operation duration plus a small buffer. Five minutes is plenty for a single playbook run.

## Where this commonly breaks in practice

- **`AuthorizationFailed` with managed identity** — RBAC is at the wrong scope. Fix: assign at container or account level explicitly. RBAC role assignments take up to 5 minutes to propagate; wait. [src 6]
- **`OperationNotAllowedOnAppendBlob`** — code calling `Put Blob` on an existing append blob. Fix: use `Append Block`, not `Put Blob`, for follow-up writes. [src 2]
- **Append blob "completed" but file looks empty in portal** — portal blob preview only shows the first 4MiB and may not refresh on append. Use `azcopy` or the SDK to download and inspect. [src 1]
- **Lifecycle policy doesn't seem to fire** — policies run once a day, not in real time. Allow 24–48 hours for new policies to take effect. [src 5]
- **Cross-region latency** — Logic App in West Europe writing to a storage account in North Europe adds ~25ms per call. Co-locate. [src 1]
- **Storage firewall blocks Logic App Consumption** — Consumption SKU uses a shared egress IP pool with thousands of IPs. You can't allowlist them all. Fix: use Standard SKU + VNet integration + private endpoint, or carve out an exception for the Logic App resource via *resource-instance rules*. [src 6]
- **Soft-delete recovery surprises** — deleted blobs are recoverable for the soft-delete window (default 7 days). Audit logs deleted by a misconfigured lifecycle rule are recoverable; act fast. [src 7]

## Sources

1. Microsoft Learn — *Azure Blob Storage overview* — https://learn.microsoft.com/azure/storage/blobs/storage-blobs-introduction — accessed 2026-04-29
2. Microsoft Learn — *Understanding block, append, and page blobs* — https://learn.microsoft.com/rest/api/storageservices/understanding-block-blobs--append-blobs--and-page-blobs — accessed 2026-04-29
3. Microsoft Learn — *Lease Blob* — https://learn.microsoft.com/rest/api/storageservices/lease-blob — accessed 2026-04-29
4. Microsoft Learn — *User delegation SAS* — https://learn.microsoft.com/azure/storage/common/storage-sas-overview — accessed 2026-04-29
5. Microsoft Learn — *Manage the Azure Blob Storage lifecycle* — https://learn.microsoft.com/azure/storage/blobs/lifecycle-management-overview — accessed 2026-04-29
6. Microsoft Learn — *Authorize access to blobs using Microsoft Entra ID* — https://learn.microsoft.com/azure/storage/blobs/authorize-access-azure-active-directory — accessed 2026-04-29
7. Microsoft Learn — *Soft delete for blobs* — https://learn.microsoft.com/azure/storage/blobs/soft-delete-blob-overview — accessed 2026-04-29
8. Microsoft Learn — *Azure Storage redundancy* — https://learn.microsoft.com/azure/storage/common/storage-redundancy — accessed 2026-04-29
