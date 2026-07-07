# Topic 06: Secure Architecture & Coding Checklist

Generated: 2026-04-29 | Sources: 10 | Confidence: high

## Scope

The cross-cutting security concerns for the Sentinel ↔ Logic App ↔ Jira ↔ Blob ↔ Key Vault pipeline. Covers identity boundaries (who can do what to whom), network isolation (private endpoints, VNet integration, allowlists), input validation and the Sentinel-payload-as-untrusted-data mindset, logging and PII handling, infrastructure-as-code for reproducibility, and a code-review checklist for the Python pieces.

This file is the one to read when you've built the pipeline once and want to harden it. Pair it with topic 05 (Key Vault) and topic 02 (idempotency) — those are the load-bearing security topics.

Out of scope: corporate compliance frameworks (SOC 2, ISO 27001, PCI DSS) by name; we point at controls, not certifications. Also out of scope: red-teaming SOAR pipelines (a real exercise but a different doc).

## Key entities & terms

- **Trust boundary**: a logical line where data crosses from one principal/zone of trust to another. Each crossing is a place to authenticate, authorise, validate, and log. [src 1]
- **Least privilege**: every principal (user, service, identity) gets the smallest permission set sufficient for its job. Reviewed periodically. [src 2]
- **Defense in depth**: multiple independent controls so a single failure doesn't compromise the system. RBAC + network ACL + secret rotation + audit logging.
- **Private endpoint**: an Azure construct that gives a service (KV, Storage, etc.) a private IP inside a VNet, so traffic never traverses the public internet. [src 3]
- **VNet integration**: outbound integration of an App Service / Logic App Standard / Function App with a VNet, so its outbound calls appear from a known IP range. [src 4]
- **Service tag**: a Microsoft-maintained named group of IP ranges (e.g. `AzureCloud`, `Storage.WestEurope`) usable in NSG rules. Avoids hardcoding IP ranges. [src 5]
- **Defender for Cloud**: continuous-assessment service that flags misconfigurations against MS-provided baselines. Free-tier covers the basics; paid tiers add Defender for Storage / Key Vault / etc. [src 6]
- **Bicep / ARM / Terraform**: IaC dialects for Azure. Bicep is Microsoft's preferred (compiles to ARM); Terraform is cross-cloud. [src 7]
- **PII**: personally identifiable information — names, email addresses, IP addresses (in EU+EEA contexts), device identifiers. Sentinel incident payloads frequently contain PII; treat as such. [src 8]

## Core security principles for this pipeline

1. **Every principal authenticates with managed identity.** No connection strings, no API keys baked into Logic App / Function source. The exception is the Jira token (Atlassian's API doesn't support AAD); that one secret lives in Key Vault.
2. **Every authorization is at the smallest possible scope.** Vault scope, not subscription. Container scope, not account. Single workspace, not all workspaces.
3. **Every external call is over a private network where possible.** KV, Storage, Sentinel: private endpoints in production. Jira is the exception — Atlassian Cloud is internet-only; pin egress IPs and allowlist on Jira's side if you can.
4. **Every secret is rotatable without code changes.** KV references resolve at runtime; rotation updates the secret value, not the config.
5. **Every action leaves an audit trail.** Logic App run history + Function App Insights + Sentinel incident comments + Blob audit log. Four independent surfaces.
6. **Every input from Sentinel is treated as untrusted.** Validate types, lengths, formats. Reject or quarantine malformed payloads.
7. **Every PII field that leaves Sentinel for Jira/Blob is intentional.** Default-deny in serialisation; explicitly opt-in fields you want to share.

## Identity boundaries — the picture

Three principals, three roles:

| Principal | Identity type | Scopes granted |
|---|---|---|
| Logic App (playbook) | System-assigned MSI | `Microsoft Sentinel Responder` on workspace; `Key Vault Secrets User` on vault; `Storage Blob Data Contributor` on `sentinel-audit` container |
| Azure Function (Python helpers) | System-assigned MSI | `Key Vault Secrets User` on vault; `Storage Blob Data Contributor` on `sentinel-audit` container; nothing on Sentinel (Function shouldn't write back to incidents directly) |
| Deploy pipeline | User-assigned MSI or service principal | `Contributor` at resource group during deploy; `Key Vault Secrets Officer` on vault for rotation |

Not:
- One identity for everything. Compromise of one workload becomes compromise of all.
- Account keys, anywhere. They can't be audited per call.
- Subscription-scoped roles. Scope creep without anyone noticing.

## Network isolation

For **production**, the topology is:

```
[Sentinel] -- (Microsoft backbone) --> [Logic App Standard, VNet-integrated]
                                             |
                              private endpoint v
[Function App, VNet-integrated] --> [Key Vault, Storage]  (private IPs only)
                                             |
                                public egress v
                                          [Jira Cloud over TLS]
```

Specifics:

- **Logic App Standard + VNet integration**: outbound traffic from the playbook flows through the VNet's NAT, giving you a stable egress IP. Allowlist that IP at Jira's side.
- **Private endpoints for KV and Storage**: deny public access on those resources entirely. Private DNS zones (`privatelink.vaultcore.azure.net`, `privatelink.blob.core.windows.net`) wired to the VNet so name resolution works.
- **NSG rules**: restrict egress from the VNet to only the service tags you need (`AzureKeyVault`, `Storage`, `AzureMonitor`, plus the Jira FQDN).
- **TLS everywhere**: minimum TLS 1.2 on storage and Logic App. KV is TLS 1.2+ by default.

For **dev/test**, you can skip private endpoints and use the storage / KV firewall with allowed IP ranges. Don't skip everything; the easiest production regression is "we hardened only prod and dev was a copy of prod that wasn't".

## Input validation

The Sentinel incident payload comes from Microsoft's service, but the entities inside it (account name, IP, file hash, URL) come from arbitrary upstream data. Treat them like form input from the internet:

- **Length-cap every string before it goes into a Jira summary.** Jira's summary cap is 255 chars; truncate with an ellipsis at 252.
- **Reject control characters** (`\x00-\x1f` except `\t\n\r`) in any field that lands in ADF — they're invalid and produce 400s.
- **JSON-encode anything that ends up inside a JSON string.** Don't string-concat; use the SDK's serialisation.
- **Treat URLs as opaque strings.** Don't fetch them, don't parse them beyond syntax validation. Especially don't follow Sentinel-supplied URLs from inside the Function — that's a server-side request forgery (SSRF) vector.
- **Reject payloads where required fields are absent.** Don't paper over a missing `incident_guid` with a fallback; it means upstream is broken.
- **Use a schema validator (pydantic, jsonschema) at the Function entrypoint.** Cheaper to fail at the door than two API calls in.

## PII and logging discipline

The Sentinel payload commonly contains: user UPNs, IP addresses, device names, sometimes email subject lines, sometimes file paths from EDR. All count as PII or PII-adjacent in EU/EEA contexts.

- **Don't log raw payloads at INFO.** Use DEBUG with a flag for development, structured fields with redaction at INFO/ERROR.
- **Hash where possible.** If you need a stable identifier for an account in Blob audit logs but don't need the UPN itself, store `sha256(upn)` not the UPN. Reversible only with a salt held by the SOC team.
- **Pseudonymise IP addresses.** A `/24` truncation is often enough for analytics and removes per-host attribution.
- **Set blob lifecycle in line with retention policy.** GDPR/EU data-protection law typically caps how long you keep PII; align lifecycle delete with that.
- **Apply Microsoft Purview / sensitivity labels** on the storage account if your tenant has them — they propagate through downstream readers.

For the Logic App: enable **Secure Inputs / Secure Outputs** on any action that handles secrets or PII. The action input/output is then redacted in the run history (visible only with explicit unmask permission).

## Infrastructure-as-code

Manual portal clicks don't scale and don't survive restoration. Everything in this pipeline should be in IaC:

- **Bicep** is Microsoft-native, Azure-only, and has the cleanest support for Logic Apps Standard, Sentinel resources, and Key Vault. [src 7]
- **Terraform** if you have multi-cloud or a strong existing TF practice. The `azurerm_logic_app_workflow` resource handles Consumption; Standard is via `azurerm_logic_app_standard`.
- **ARM** as the lowest common denominator; readable, but verbose.

What the IaC repo should contain:

- `main.bicep` (or `main.tf`) wiring resource group, KV, storage, Logic App, Function App, role assignments.
- `workflow.json` for each Logic App workflow definition. Source-controlled. Diffable.
- `function/` directory with the Function App's code, `requirements.txt`, `host.json`.
- `parameters.<env>.json` for environment-specific values (vault name, subscription).
- A pipeline (`azure-pipelines.yml` or `.github/workflows/`) that lints, deploys to a non-prod subscription, runs smoke tests, then promotes to prod.

Critical rule: **the IaC pipeline does not have a copy of the secrets**. It deploys references to KV; the secret values are seeded into KV out-of-band by a separate, more privileged process.

## Code review checklist for the Python Function

Before merging any change to the Function, check:

- [ ] No secrets in code, config files, or test fixtures. (`git grep -i 'token\|password\|secret'` finds nothing committed.)
- [ ] All external calls have explicit timeouts (`requests.request(..., timeout=20)`). No naked `requests.get(url)`.
- [ ] All HTTP error handling distinguishes transient (retry) from permanent (fail). 429 honours `Retry-After`.
- [ ] All input from the request body is validated (pydantic or equivalent) before use.
- [ ] No `eval` / `exec` / `subprocess` calls. If subprocess is unavoidable, no shell=True.
- [ ] No `requests` calls to URLs from input. (SSRF defense.)
- [ ] No PII in `logging.info(...)`. PII only at `logging.debug` and only with explicit redaction toggle.
- [ ] Tests run offline (no network calls in unit tests). Use `responses` or `httpretty` for mocking.
- [ ] `requirements.txt` pins exact versions. `pip-audit` or `safety` clean in CI.
- [ ] Function App `httpAuthLevel` is `function` or `anonymous + Easy Auth`, never `anonymous` without auth.
- [ ] No fallback paths that disable auth ("if no token, allow"). Fail closed.
- [ ] Errors return a JSON body with a stable error code; no stack traces leak to callers.
- [ ] Cold-start path doesn't reach external services without timeouts (a slow Sentinel API at startup can render the Function unresponsive for minutes).
- [ ] Application Insights instrumented; trace IDs propagated from Logic App caller.
- [ ] Function-level dependencies (`azure-keyvault-secrets`, `azure-identity`, `azure-storage-blob`, `requests`) are LTS-supported versions.

## Operational hygiene

- **Defender for Cloud**: enable on the resource group. It will flag missing things (TLS settings, managed identity not used, etc.). [src 6]
- **Diagnostic settings**: every resource (Logic App, Function App, KV, storage) sends logs to a central Log Analytics workspace. Run KQL queries weekly: failure rates, identity changes, secret access from unexpected sources. [src 9]
- **Alerts**: KV `SecretGet` from an IP outside the VNet → alert. Logic App run failure rate >5% over 1h → alert. Function App 5xx rate >2% → alert. Storage account `AnonymousSuccess` → alert (should never happen). 
- **Periodic access review**: every quarter, list all role assignments on the resource group and prove each is still needed.
- **Disaster recovery**: KV soft-delete with 90-day retention, geo-redundant storage, Logic App + Function in source control. Verify restore quarterly.

## Where this commonly breaks in practice

- **Production hardening drifts.** A dev test enabled a public IP rule and it landed in prod via copy-paste. Fix: deploy via IaC; manual portal changes show up in `az resource lock` violations and PR diff reviews.
- **A new service account gets created with broad permissions because nobody's sure exactly what it needs.** Fix: start with no permissions, add only what fails, document each addition.
- **Secret rotation runs but consumers don't refresh.** Fix: KV runtime fetch in critical paths; alert on `Get secret` calls returning the same version for >X days when rotation should have happened.
- **PII slips into Jira summaries.** Fix: a `summary` formatter that strips known sensitive patterns (UPNs, emails) and replaces with hashes; tested.
- **The Function's outbound traffic is routed via the wrong NAT after a VNet topology change.** Jira's allowlist breaks. Fix: subnet-level NSG rules pinned in IaC; alert on egress IP changes.
- **Sentinel automation rule grants overly broad scope to the Logic App identity.** Fix: scope role assignments at workspace, not subscription. Periodic scan to detect creep.

## Confidence rating notes

This file is **high confidence** on principles (least privilege, MSI, private endpoints) which are stable Microsoft guidance. **Medium-high** on specific role-assignment names — Microsoft has been renaming roles every few years; verify against current Azure docs at deploy time. **High** on the Python code-review checklist — these are language-level concerns and don't drift.

## Sources

1. Microsoft Learn — *Azure security baseline for Logic Apps* — https://learn.microsoft.com/security/benchmark/azure/baselines/logic-apps-security-baseline — accessed 2026-04-29
2. Microsoft Learn — *Best practices for Azure RBAC* — https://learn.microsoft.com/azure/role-based-access-control/best-practices — accessed 2026-04-29
3. Microsoft Learn — *Private endpoints overview* — https://learn.microsoft.com/azure/private-link/private-endpoint-overview — accessed 2026-04-29
4. Microsoft Learn — *VNet integration for Azure Functions / Logic Apps Standard* — https://learn.microsoft.com/azure/azure-functions/functions-networking-options — accessed 2026-04-29
5. Microsoft Learn — *Service tags overview* — https://learn.microsoft.com/azure/virtual-network/service-tags-overview — accessed 2026-04-29
6. Microsoft Learn — *Microsoft Defender for Cloud overview* — https://learn.microsoft.com/azure/defender-for-cloud/defender-for-cloud-introduction — accessed 2026-04-29
7. Microsoft Learn — *Bicep language reference* — https://learn.microsoft.com/azure/azure-resource-manager/bicep/ — accessed 2026-04-29
8. EDPB — *Guidelines on personal data breaches under GDPR* — https://www.edpb.europa.eu/our-work-tools/our-documents/guidelines/guidelines-92022-personal-data-breach-notification_en — accessed 2026-04-29
9. Microsoft Learn — *Azure Monitor diagnostic settings* — https://learn.microsoft.com/azure/azure-monitor/essentials/diagnostic-settings — accessed 2026-04-29
10. OWASP — *API Security Top 10 (2023)* — https://owasp.org/API-Security/editions/2023/en/0x00-introduction/ — accessed 2026-04-29
