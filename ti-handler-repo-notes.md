# TI-handler repo — pointers & reusable patterns

Source of truth for the deployed analog. Clone alongside this repo when building the Opener.

- Org / GitOps: `https://github.com/lsy-gac-gitops/lsy-tcoe-secops`
- TI-handler repo: `TI_handleing_automation`

## Layout worth reusing

```
TI_handleing_automation/
├── playbook/
│   ├── workflow.json        # the Logic App `definition` (portal-authorable)
│   └── azuredeploy.json     # ARM template; definition embedded at .resources[2].properties.definition
└── docs/
    └── references/          # illustrative ancestors, NOT deployed code:
        ├── abuseipdb_enrichment.json
        └── trackspacejira_ticket_opener.json   ← closest ancestor to the Opener
```

`docs/references/trackspacejira_ticket_opener.json` is the **most directly relevant**
artifact for this project — it is a plain Trackspace ticket-opener without the enrichment
or approval stages. Start there, not from the full TI-handler workflow.

## Reusable production facts (from reference/07)

- **MI principalId to preserve on redeploy:** `d3676c47-5dff-492b-aecb-fb229a20fcfa`
  (in-place modify keeps its RBAC intact). A *new* Opener Logic App gets its **own** MI —
  do not reuse this one; grant the Opener its own least-privilege roles.
- TI-handler deploys its **own** `azuresentinel-*` / `keyvault-*` API connections (self-contained
  ARM) rather than the fleet-shared ones. Accepted divergence; mirror it for the Opener or wire
  the shared `APICON-*` connections — pick one and document it.
- **Sentinel picker role:** the Azure Security Insights first-party SP
  (AppId `98785600-1bb7-4fb9-b9fa-19afe2c8a360`) needs **Microsoft Sentinel Automation
  Contributor** on the playbook's RG, or the playbook won't appear under *Actions → Run playbook*.
  Separate from the MI's own roles. Easy to miss — "deploys clean" without it.

## Clone-a-ticket mechanism (OPSLSY, if the Opener needs Change tickets)

- `POST /secure/CloneIssueDetails.jspa` with template `OPSLSY-75376`.
- Response is a **302 redirect = success**; find the new key via JQL search (not progress-page scraping).
- Until-loop exit: `@not(empty(variables('CloneKey')))` **only** — no timestamp guard.
- **Jira timestamp pitfall:** server returns `+0200` offset; `utcNow()` comparisons cause
  infinite loops. Never put timestamp guards in Until loops.

## Logic App gotchas carried forward

- `runAfter` must include **every** ancestor whose `body()` an action references, or ARM
  validation rejects the template.
- Self-referencing variable assignment (`Set x = union(x, …)`) is forbidden — use
  `AppendToArrayVariable` inside a **sequential** foreach.
- In-flight runs are immutable — cancel + re-trigger after any definition change.
- `Get-AzLogicApp` doesn't reliably hydrate `.Identity`; read the MI principalId via
  `Get-AzResource -ResourceType Microsoft.Logic/workflows`.
- `New-AzRoleAssignment` returning **`Conflict` = success** — verify with `Get-AzRoleAssignment -ObjectId <mi>`.
- Consumption Logic Apps bill per action/trigger execution, not wall-clock.
