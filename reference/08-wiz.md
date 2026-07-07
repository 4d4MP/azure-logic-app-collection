# Topic 08: Wiz — Cloud Security Platform (CNAPP)

Generated: 2026-06-02 | Sources: discovery session + live tenant inspection + 8 web sources | Confidence: **high on deployed state, low on operations** (Wiz went live the day this file was written)

## Scope

This file is a **Day-1 discovery snapshot** of the Wiz deployment in the LHsystems / lhsystems.int environment. Wiz went live on **2026-06-02**; this file captures what is *deployed and permissioned* (concrete, verified against the tenant) and records what is *operationally undecided* (most of it) as an explicit open-decisions register rather than inventing process that doesn't exist yet.

It is intended to do three jobs:

1. **Record what's deployed** so it doesn't have to be re-discovered (connector topology, capability roles, owner, access details).
2. **Anchor the Defender → Wiz migration** that is the stated strategic direction — what depends on Defender today is the migration surface.
3. **Map the Wiz API** as the *intended primary interaction model*, so the automation can be stood up without re-learning the API model from scratch.

Out of scope: anything operational that hasn't been decided (suppression mechanism, triage workflow, conflict-reconciliation rules) is listed as TBD, not specified. Also out of scope: the GCP connector internals (confirmed to exist, not yet inspected) and a full Wiz Security Graph query cookbook (a follow-on once the API service account exists).

Where this file overlaps the others: it leans on file 05 (Key Vault — where the future API secret should live), file 06 (secure architecture — least-privilege, the OMS-style ownership-boundary risk), and file 02/07 (the Defender/Sentinel/TI-handler world that Wiz is positioned to eventually replace, with TI carved out).

## Key entities & terms

- **CNAPP** (Cloud-Native Application Protection Platform): the product category Wiz occupies — a single platform spanning posture, vulnerabilities, identities, data, containers, and (optionally) runtime. Wiz is multi-cloud (Azure, GCP, AWS, OCI, Kubernetes). [src 1]
- **Agentless scanning**: Wiz's default model — it connects to each cloud's control-plane APIs with read-only permissions and analyses workloads from disk snapshots, rather than running an agent inside the guest. No in-guest performance impact; provider-side snapshot/API consumption instead. [src 2]
- **Wiz Sensor**: an optional eBPF-based runtime agent deployed on hosts/containers for real-time process/network detection (the "Wiz Defend" runtime layer). **Not deployed on the LHsystems host fleet** (confirmed — see Core facts). [src 3]
- **Connector**: the per-cloud onboarding object. One connector per provider enumerates accounts/projects/subscriptions via the cloud's org construct — Azure Management Groups, GCP Folders/Organizations. [src 2]
- **Security Graph**: Wiz's internal model that relates resources, identities, vulnerabilities, exposure, and data into attack paths ("toxic combinations"). The thing the GraphQL API queries against. [src 1]
- **Issue**: a Wiz finding — a Control that matched against a resource. The primary triage unit. Has a severity, a resource, and a status (Open / Resolved / Ignored). [src 7]
- **Control**: a policy/rule that, when it matches a resource, produces an Issue. Tuning happens at the Control level; muting happens at the Issue level via an Ignore Rule.
- **Ignore Rule**: Wiz's suppression mechanism — mutes Issues matching a filter (e.g. by tag, resource group, project). The intended home for the pentest-infra suppression (see Open decisions). *Mechanism not yet confirmed in this tenant.*
- **Project**: a logical grouping of cloud resources in Wiz (by team, env, app). Service accounts and roles can be scoped to Projects. Not yet inventoried in this tenant.
- **Service Account**: a Wiz-internal API credential (Client ID + Client Secret), type *Custom Integration (GraphQL API)*. The thing the API uses to authenticate. **None provisioned as of 2026-06-02.** [src 5]
- **CSPM / CIEM / DSPM / AI-SPM**: posture management for configuration / entitlements / data / AI services respectively — Wiz capability families. The role assignments observed indicate CSPM, agentless workload+vuln, DSPM, container, and AI-SPM are all permissioned (see Capabilities).

## Core facts (verified against the tenant)

1. **Wiz is onboarded at the management-group root**, not at a single subscription. The connector's role assignments all sit at `/providers/Microsoft.Management/managementGroups/LH_Systems`, so Wiz enumerates **everything under `LH_Systems`**, not just the prod SOC subscription. This means the connector's blast radius spans other teams' subscriptions — relevant for the ownership boundary (see Where this breaks).
2. **Three Wiz service principals exist in Entra ID**, telling two different stories:
   - One **org-level connector SP** (`wiz-…dea`) carrying all the capability roles at MG scope.
   - Two **in-cluster AKS SPs** (`WIZ-CONTROL-…`, `WIZ-WORKER-…`) with **no Azure RBAC at all** — the classic Wiz Kubernetes in-cluster deployment (controller + worker pods authenticating via workload identity / in-cluster RBAC, not ARM role assignments).
3. **The host fleet is agentless-only.** MDE telemetry confirms zero Wiz runtime sensor across the ~2,700-server fleet (`DeviceProcessEvents | where … has "wizsensor"` → 0 hosts). Wiz has **no host-level runtime visibility** today; on hosts it sees disk-snapshot posture and vulnerabilities only.
4. **Multiple capabilities are permissioned, not just basic posture.** The connector SP's role set (see Capabilities table) indicates CSPM, agentless workload/disk scanning, DSPM (data), container/AKS, and **AI-SPM** (Azure OpenAI / Cognitive Services) are all switched on. AI-SPM in particular is easy to miss — worth confirming it was an intentional enablement.
5. **It is a standalone console.** No findings forwarded to Sentinel, no tickets opened in Trackspace `CLOPSSEC`, no Teams/email/webhook integration. Analysts (such as they are during test) log into Wiz directly.
6. **No API service account / credential exists** as of 2026-06-02. The Wiz Settings → Access Management → Service Accounts page is empty. The three Entra SPs are *cloud-connector* identities, which are distinct from API service accounts. [src 5]
7. **TI handling is explicitly NOT a Wiz migration target.** Wiz has no threat-intelligence feed in this tenant, so the TI-handler playbook (file 07) and the Sentinel TI correlation stay on Defender/Sentinel until that capability exists. The "move everything to Wiz" direction has this carve-out.

## LHsystems environment — actual deployment

| Aspect | Value |
|---|---|
| Product | Wiz CNAPP (agentless-first) |
| Portal | `app.wiz.io` (generic host; tenant-specific API endpoint differs — see API section) |
| Login | SSO via Microsoft Entra ID (tenant `842859f5-a99d-4366-8f8d-dde69b67a4d7`) |
| Data region | **West Europe (weur)** — relevant for the GDPR/PII posture in file 06; scanned metadata held in-region |
| Owner | **Mate Gyorgy** (Wiz architect) — distinct principal from SOC and from OMS (`lsyh.sysops@lhsystems.com`) |
| Status | **Live 2026-06-02**, under test; intended to be treated as prod with Defender as backup |
| Azure subscription in scope | `f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29` (LSY_WEUR_ITCS_PRD_001) and all others under the MG |
| Azure onboarding scope | Management group `LH_Systems` (org-level) |
| Clouds connected | Azure + GCP (GCP connector confirmed to exist, internals not yet inspected) |
| Runtime sensor | None on the host fleet (agentless-only) |
| API service account | **None provisioned** as of 2026-06-02 |

### Connector topology

```
                         +---------------------+
                         |      Wiz SaaS       |
                         |  (app.wiz.io, weur) |
                         +----------+----------+
                                    |
                 +------------------+------------------+
                 v                                     v
   +-----------------------------+          +----------------------+
   | Azure — MG LH_Systems       |          | GCP                  |
   |  (org-level, agentless)     |          |  service account     |
   |                             |          |  (details TBD)       |
   |  +-----------------------+  |          +----------------------+
   |  | Org connector SP      |  |
   |  | wiz-...dea            |  |
   |  | Reader+WizCustomRole  |  |
   |  | + DSPM/AKS/AI-SPM     |  |   <-- all roles at MG scope
   |  +-----------------------+  |
   |                             |
   |  +-----------------------+  |
   |  | AKS in-cluster        |  |
   |  | WIZ-CONTROL + WORKER  |  |   <-- no Azure RBAC; workload identity
   |  | (VULN-PRD-AKS-001)    |  |
   |  +-----------------------+  |
   +-----------------------------+

   Host fleet ~2,700 servers — agentless only, no runtime sensor (MDE confirms 0)
```

### Service principals (Entra ID)

| Display name | Object Id | App Id | RBAC |
|---|---|---|---|
| `wiz-1ae0d087-d048-4b86-be80-8baed66de7ae` | `5b56e035-3763-4886-baf8-99ccd8a940e4` | `a0a19bf8-fe0a-4f95-85cf-64b9fb405dea` | 7 roles at MG `LH_Systems` (see below) |
| `WIZ-CONTROL-LSY-WEUR-VULN-PRD-AKS-001` | `511593df-83ac-4a29-b04e-990b9bbdd21e` | `3a5012f1-a63a-4e01-a975-427cda5e7edc` | none (in-cluster / workload identity) |
| `WIZ-WORKER-LSY-WEUR-VULN-PRD-AKS-001` | `6ed09462-2507-400a-a561-0e5e3944cf4c` | `d7afb86e-c4bf-4a64-b933-2ae7c21fe648` | none (in-cluster / workload identity) |

*To confirm the AKS SP identity model (federated workload-identity credentials + which cluster), run `Get-AzADAppFederatedCredential -ApplicationObjectId <appObjectId>` per app. Not yet done.*

## Capabilities — what the role set implies is enabled

The org connector SP holds these roles at MG `LH_Systems`. The role is the tell for which Wiz capability is switched on:

| Role assigned | Wiz capability it enables |
|---|---|
| `Reader` | CSPM / configuration posture + inventory baseline |
| `WizCustomRole` (custom) | Agentless workload + disk scanning (permissions built-ins don't cover, e.g. snapshot) |
| `Storage Blob Data Contributor` | **DSPM** — reading blob contents to classify sensitive data |
| `Azure Kubernetes Service Cluster User Role` | Container / Kubernetes posture (control-plane access) |
| `Azure Kubernetes Service RBAC Reader` | Container / Kubernetes posture (in-cluster read) |
| `Cognitive Services Data Reader` | **AI-SPM** — Azure Cognitive Services posture |
| `Cognitive Services OpenAI User` | **AI-SPM** — Azure OpenAI posture |

Notes:
- **Agentless on hosts means no runtime.** Posture + vulnerabilities from disk snapshots, yes. Process/network runtime detection, no — that needs the Wiz Sensor, which isn't deployed. This is the single most important capability gap vs Defender/MDE (see Migration surface).
- **`WizCustomRole` contents not yet dumped.** To see exactly what it grants: `Get-AzRoleDefinition -Name 'WizCustomRole'`. Worth recording in a future revision.
- **AI-SPM is permissioned** — confirm with Mate whether the Cognitive Services / OpenAI scanning was an intentional enablement or a default that came with the connector template.

## API access — intended primary interaction model

**Status: not yet provisioned (no service account as of 2026-06-02).** This section maps the model so it can be stood up cleanly. The API — Wiz's **GraphQL** interface — is the intended *primary* way of interacting with Wiz (queries for inventory/issues/vulns, mutations for ignore rules, etc.), analogous to how `daily.py` / `work.py` drive Trackspace via PAT.

### Auth model

Two endpoints, do not conflate them [src 5][src 6]:

1. **OAuth token endpoint** (tenant-agnostic): `POST https://auth.app.wiz.io/oauth/token` with `grant_type=client_credentials`, `client_id`, `client_secret`, `audience=wiz-api` → returns a time-limited Bearer token.
2. **GraphQL endpoint** (region-specific): `https://api.<region>.app.wiz.io/graphql`. The weur shard's exact host is shown in the portal at **Profile → Tenant Info** — grab it there rather than guessing the region suffix.

Then every GraphQL request carries `Authorization: Bearer <token>`.

```python
# Sketch — the eventual Wiz API client (mirrors the Trackspace PAT pattern)
import os, requests

WIZ_AUTH = "https://auth.app.wiz.io/oauth/token"
WIZ_API  = os.environ["WIZ_API_URL"]          # from Tenant Info, weur shard
CLIENT_ID     = os.environ["WIZ_CLIENT_ID"]
CLIENT_SECRET = os.environ["WIZ_CLIENT_SECRET"]   # KV reference at runtime

def _token() -> str:
    r = requests.post(WIZ_AUTH, data={
        "grant_type": "client_credentials",
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "audience": "wiz-api",
    }, timeout=20)
    r.raise_for_status()
    return r.json()["access_token"]

def gql(query: str, variables: dict | None = None) -> dict:
    r = requests.post(WIZ_API, json={"query": query, "variables": variables or {}},
                      headers={"Authorization": f"Bearer {_token()}"}, timeout=30)
    r.raise_for_status()
    return r.json()["data"]
```

### Where the credential should live

Following the same discipline as the Trackspace `sentinelsvc` secret (file 05): the Wiz Client Secret belongs in **Key Vault `LSY-WEUR-ITCS-PRD-KV-02`**, fetched at runtime, never in source. Naming suggestion: `wiz-client-secret` (+ `wiz-client-id` if you'd rather not treat the ID as non-secret). Same KV-firewall caveat applies — Cloud Shell can't read it; portal or runtime fetch only.

A `Where-Object { $_.Name -match 'wiz' }` over the vault is the quick check for whether anyone's pre-staged it (returns nothing today).

### What the API exposes

The GraphQL API gives flexible read access to the Security Graph plus mutations for issue/user lifecycle [src 4][src 6][src 8]:

- **Inventory / graph resources** — `CloudResources`, the full asset graph with relationships.
- **Issues** — the triage units (filter by severity, status, project, resource type).
- **Vulnerability findings** — filterable by detection method (`PACKAGE`, `OS`, `LIBRARY`, `CONFIG_FILE`, `OPEN_PORT`, …), `HasFix`, CISA-KEV / exploit availability. This is the agentless analogue of `DeviceTvmSoftwareVulnerabilities`.
- **Configuration findings** — control matches / misconfigurations.
- **Detections** — runtime/threat detections (only meaningful where the sensor exists; N/A on the agentless host fleet today).
- **Audit logs** — Wiz-side activity, streamable.
- **SBOM artifacts** — software bill of materials per asset.
- **Mutations** — create/update Ignore Rules (suppression), user lifecycle (`createUser`/`updateUser`), etc.

### Scoping the service account (least privilege)

When provisioned, type = **Custom Integration (GraphQL API)**. Grant only the scopes the automation needs — start with `read:inventory`, `read:issues`, `read:vulnerabilities`, `read:projects`, add `read:sbom_artifacts` if SBOM pulls are needed, and only add write scopes (ignore-rule mutations) when an automation genuinely needs them [src 5][src 8]. Leave the expiration empty unless policy requires rotation cadence; scope to specific Projects only once Projects are defined.

### Rate-limit & query hygiene

GraphQL-general guidance that applies [src 4]: paginate with small `first` values and follow cursors (`endCursor`), request only the fields you need (don't over-select), avoid deeply nested queries, and avoid concurrent mutations (space mutative requests). For bulk/continuous pulls, prefer scheduled paginated reads over tight polling. A mutation gotcha to remember: a malformed mutation can return a **GraphQL error inside an HTTP 200**, not a 4xx — assert on the response body, don't trust the status code (same fail-loud discipline as the Trackspace integration in file 03).

## Ownership & operating model

- **Owner: Mate Gyorgy (Wiz architect).** This is a *different* ownership boundary from both SOC (CLOPSSEC / TI-handler) and OMS (AbuseIPDB connection, `lsy-prd-oms` workspace). Treat Wiz like the OMS-owned AbuseIPDB connection in one respect: **changes to the connector, projects, or service accounts are made by someone outside the SOC's control**, so any future SOC automation against Wiz inherits a cross-team dependency that can break without notice (cf. file 07's note on the OMS-owned shared connection).
- **Triage owner: undecided.** No defined day-to-day triage owner during the test phase.
- **Wiz-vs-Defender conflict reconciliation: undecided**, leaning toward **manual review** when the two disagree. Recorded as an open question, not a rule.

## Defender → Wiz migration surface

The stated direction is to **move every process from Defender to Wiz** — making Wiz the eventual system of record. Several existing docs lean on Defender as authoritative; those are the migration surface:

| Defender dependency today | What it underpins | Wiz replacement path | Gap / blocker |
|---|---|---|---|
| MDE `DeviceInfo` | Canonical live fleet inventory & OS rollup (the "authoritative running versions" claim) | Wiz agentless inventory / `CloudResources` | Wiz disk-snapshot cadence vs MDE live telemetry — validate freshness before trusting it as canonical |
| `DeviceTvmSoftwareVulnerabilities` | CVE exposure tracking (e.g. CVE-2026-31431 kernel pack) | Wiz vulnerability findings (agentless) | Detection-method differences; confirm kernel-version reporting matches MDE before cutover |
| MDE `DeviceProcessEvents` / eBPF runtime | Runtime detections (Linux priv-esc, `authencesn` autoload) | Wiz Sensor / Wiz Defend | **Hard blocker — no sensor deployed.** Agentless Wiz cannot replace runtime detections. Either deploy the sensor or keep MDE for runtime. |
| Sentinel + TI-handler (file 07) | TI triage & IP blocklist automation | — | **Carved out.** No Wiz TI feed → TI stays on Defender/Sentinel indefinitely until Wiz gains the capability. |

Sequencing is **directional, not funded/scheduled** as of this writing. The sane order given the gaps: posture/CSPM first (lowest risk, agentless covers it), then vulnerability management (validate parity against TVM), and **runtime last / not at all** until the sensor question is resolved. The runtime gap and the TI carve-out are the two things most likely to be forgotten in a "just move it all to Wiz" push — they are the reason a wholesale cutover is not currently possible.

## Open decisions register

Things explicitly undecided as of 2026-06-02 (the honest value of this file is not letting these get lost):

1. **Suppression mechanism** — how pentest infra (`_pent_rg_` resource groups / `HostType: Kalilinux` tag) gets suppressed. Candidate is a Wiz **Ignore Rule** scoped by tag/RG, but the mechanism is not confirmed and nothing is implemented. *Downgraded from a prior assumption that this was planned/live — it is neither.*
2. **Wiz-vs-Defender conflict reconciliation** — leaning manual review; no rule.
3. **Triage ownership & workflow** — who works Wiz Issues day-to-day, and to what SLA.
4. **Noise profile** — none yet (nothing has accumulated on Day 1). Revisit after the first scan cycles; watch AKS/ephemeral nodes and any AI-SPM findings.
5. **API service account provisioning** — when, with what scopes, secret in KV.
6. **GCP connector internals** — confirmed to exist; not inspected.
7. **Migration sequencing** — directional only; no funded plan or first-mover process chosen.
8. **AI-SPM intent** — confirm the Cognitive Services/OpenAI scanning enablement was deliberate.

## Day-1 state snapshot (2026-06-02)

A single-glance record of "what was true on the day it went live":

- Live, standalone, under test; intent = Wiz primary / Defender backup.
- Azure onboarded org-level at MG `LH_Systems`; GCP connected (uninspected).
- Capabilities permissioned: CSPM, agentless workload/disk, DSPM, container, AI-SPM.
- Host fleet agentless-only (0 sensor).
- In-cluster AKS footprint present (CONTROL/WORKER).
- No integration to Sentinel/Trackspace/Teams.
- No API service account.
- Owner: Mate Gyorgy.
- Region weur, Entra SSO, `app.wiz.io`.

## Where this commonly breaks in practice (anticipated)

These haven't bitten yet (Day 1) — they're the predictable failure modes given the architecture:

- **OAuth vs GraphQL endpoint confusion.** `auth.app.wiz.io` mints the token; `api.<region>.app.wiz.io/graphql` answers queries. Pointing client_credentials at the GraphQL host (or vice versa) is the most common first-integration failure. Get the API URL from Tenant Info.
- **Wrong region shard.** weur tenant → the API host is a specific EU shard, not a generic one. Hardcoding the wrong shard 404s/401s.
- **Mutation errors hidden in HTTP 200.** GraphQL returns errors in the body; assert on `errors`/`data`, not status code.
- **MG-scoped connector = broad blast radius.** The connector reads every subscription under `LH_Systems`, including other teams'. A capability change (e.g. enabling DSPM tenant-wide) touches resources the SOC doesn't own. Coordinate with Mate before assuming scope.
- **Cross-team ownership drift.** Mate owns the connector, projects, and service accounts. A rename/rescope/secret-rotation on his side silently breaks any SOC automation built against Wiz — same class of risk as the OMS-owned AbuseIPDB connection (file 07). Pin the dependency and monitor for it.
- **Agentless ≠ runtime.** Expecting Wiz to catch a live priv-esc on a host will fail — no sensor. Don't decommission MDE runtime detections on the assumption Wiz covers them.
- **KV firewall blocks Cloud Shell** for the future `wiz-client-secret` the same way it does for `sentinelsvc` — portal or runtime fetch only (file 05).
- **Snapshot freshness vs live telemetry.** Before treating Wiz inventory as canonical (replacing `DeviceInfo`), confirm the scan cadence is fresh enough for the use case — agentless snapshots lag live telemetry.

## Cross-references

- **File 02** — the Sentinel/MDE detection world (CVE-2026-31431 pack, runtime detections) that Wiz is positioned to eventually replace; the runtime-detection gap lives here.
- **File 05** — Key Vault: where the future `wiz-client-secret` should live, the RBAC/firewall discipline, runtime-fetch pattern.
- **File 06** — secure architecture: least-privilege scoping for the service account, the cross-team ownership-boundary risk, PII/region (weur) considerations.
- **File 07** — TI-handler: explicitly **out of scope** for the Wiz migration (no TI feed); also the canonical example of the OMS-owned-dependency risk that Wiz's Mate-owned model mirrors.

## Sources

1. Wiz — *Cloud security platform overview (CNAPP, multi-cloud, Security Graph)* — https://www.wiz.io/ — accessed 2026-06-02
2. Wiz — *Agentless scanning best practices (connector model, Azure service principal, GCP service account, org-level onboarding)* — https://www.wiz.io/academy/cloud-security/agentless-scanning — accessed 2026-06-02
3. Wiz — *Agentless vs agent-based scanning (optional eBPF runtime sensor)* — https://www.wiz.io/academy/cloud-security/agentless-scanning-vs-agent-based-scanning — accessed 2026-06-02
4. AWS — *Source configuration for Wiz CNAPP (GraphQL API: issues, vulnerability findings, configuration findings, detections, audit logs)* — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/wizcnapp-source-setup.html — accessed 2026-06-02
5. Microsoft Learn — *Wiz data connector (service account creation, scopes, Tenant Info / API endpoint URL)* — https://learn.microsoft.com/en-us/security-exposure-management/wiz-data-connector — accessed 2026-06-02
6. Stitchflow — *Wiz user management API guide (auth.app.wiz.io OAuth, audience=wiz-api, GraphQL endpoint separation, HTTP 200 GraphQL errors)* — https://www.stitchflow.com/user-management/wiz/api — accessed 2026-06-02
7. Safe Security — *Wiz integration (Issue status: Open/Resolved/Ignored, project scoping)* — https://docs.safe.security/docs/wizio — accessed 2026-06-02
8. Port — *Wiz integration (service account type Custom Integration (GraphQL API), least-privilege read scopes)* — https://docs.port.io/build-your-software-catalog/sync-data-to-catalog/code-quality-security/wiz/ — accessed 2026-06-02
