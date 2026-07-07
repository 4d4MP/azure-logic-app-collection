# Environment constants (LSYH / West Europe)

> Resource identifiers only. **No secret values.** Passwords live in Key Vault;
> `TRACKSPACE_PAT` and `TRACKSPACE_CA` are session env vars (see `.gitignore`).

## Azure

| Aspect | Value |
|---|---|
| Subscription | `f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29` (LSY_WEUR_ITCS_PRD_001), West Europe |
| Sentinel workspace | `LSY-PRD-OMS` in RG `lsy_weur_itcs_prd_oms_rg_001` |
| Security-automation RG | `LSY_WEUR_ITCS_PRD_SEC_RG_002` (Logic Apps, KV, TI-handler) |
| Key Vault | `LSY-WEUR-ITCS-PRD-KV-02` (**access-policy mode**, `EnableRbacAuthorization=False`) |
| Shared API connections | `LSY-WEUR-ITCS-PRD-APICON-KV`, `LSY-WEUR-ITCS-PRD-APICON-SENTINEL` (all `ManagedServiceIdentity`) |
| EDL storage (TI-handler only) | `lsyweuritcsprdmspalo001`, `$web/index.html` (append-only) |

**Cloud Shell step zero:** `Set-AzContext -SubscriptionId f12b729d-7c1e-4407-bb9d-2e7ec4aa1d29`
(default context is often the wrong subscription → `ResourceGroupNotFound`).

**KV auth caveat:** access-policy mode means the `Key Vault Secrets User` RBAC role is
**inert**. Grant runtime access with `Set-AzKeyVaultAccessPolicy`, not a role assignment.

## Trackspace (Jira Data Center) — production

| Aspect | Value |
|---|---|
| Base URL | `https://trackspace.lhsystems.com` (REST API **v2**, `/rest/api/2/`) |
| Project (security automation) | `CLOPSSEC` |
| Service account | `sentinelsvc` (Basic auth for Logic Apps; KV secret name also `sentinelsvc`) |
| Local Python auth | Bearer PAT via `TRACKSPACE_PAT` env var (personal account, **not** `sentinelsvc`) |
| Descriptions | plain text (not ADF) |
| Issue type id | `10` |
| Priorities | High `10112`, Med `10113`, Low/Info `10114` |
| Sentinel incident number field | `customfield_10602` |
| Assets field (Riada Insight) | `customfield_24305` — **cannot** be set via REST; clone a template ticket instead |

**CLOPSSEC transition walk** (re-probe after each step via `GET /issue/{key}/transitions`):
`Open→Approval = 4`, `Approval→In Progress = 811`, `In Progress→Resolved = 5`,
`Resolved→Closed = 701` (close requires a `resolution` field).

**TLS:** LH internal CA — Python needs `TRACKSPACE_CA` pointing at a PEM bundle (or `--insecure`).

## Fleet / naming

- Corp domain: `lhsystems.int`; ~2,700 machines, ~90% Linux (RHEL/CentOS/Ubuntu).
- Windows servers: `dlsyw*`; Linux: `dls*/tls*/pls*`.
- Cloud admin accounts: `CA`-prefixed under `cloud.lhsystems.com`.

## Known-benign source IPs (do not block / expect as egress)

| IP | Owner | Note |
|---|---|---|
| `193.142.145.12` | AS5594 Lufthansa Systems Hungaria (LSYH1-NET), Budapest | Adam's corporate egress |
| `195.60.216.126` | `fw1.lhsystems.pl`, AS41299 Lufthansa Systems Poland | perimeter firewall source-NAT |

## People

- Emil Pollak (`u761051`) — change manager on OPSLSY tickets.
- Mate Gyorgy — Wiz architect/owner (outside SOC).
- Jacek Samujlo — detection collaborator.
