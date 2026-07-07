# Deployment discipline ("file-07")

Same rules that governed TI-handler. Apply to the Opener from commit one.

## Golden rules

1. **Repo is source of truth.** All changes go through `playbook/workflow.json` +
   `playbook/azuredeploy.json`. Never portal-paste as the authoritative change — portal
   edits are dropped the next time someone runs `New-AzResourceGroupDeployment`.
2. **Keep the two definitions in sync**, verified with a `jq -S` diff before every deploy:
   ```bash
   jq -S '.definition' playbook/workflow.json > /tmp/wf.json
   jq -S '.resources[2].properties.definition' playbook/azuredeploy.json > /tmp/arm.json
   diff /tmp/wf.json /tmp/arm.json   # MUST be empty
   ```
3. **Redeploy via ARM with an explicit playbook name.** Never deploy without the explicit
   name parameter — an implicit/blank name risks creating a second resource.
   ```bash
   # PowerShell (from a Linux pwsh session, after Set-AzContext)
   New-AzResourceGroupDeployment `
     -ResourceGroupName LSY_WEUR_ITCS_PRD_SEC_RG_002 `
     -TemplateFile playbook/azuredeploy.json `
     -PlaybookName '<OpenerName>' `
     -WhatIf        # drop -WhatIf only after the plan looks right
   ```
4. **Read-only diagnostics + `-WhatIf` before any production write.** Confirmation gate
   before the real deploy. Azure production writes stay under the operator's direct control.

## Renaming ≠ in-place

The resource name **is** the URL identity. Renaming a Logic App is delete-and-recreate →
**fresh MI, fresh API connections, fresh RBAC**. Decide the Opener's final name *before*
first deploy to avoid an MI churn.

## MI + RBAC after (re)create

A recreated Logic App gets a new system-assigned MI principalId — re-grant every role:
```powershell
(Get-AzResource -ResourceType Microsoft.Logic/workflows `
  -ResourceGroupName LSY_WEUR_ITCS_PRD_SEC_RG_002 -Name '<OpenerName>').Identity.PrincipalId
```
Least-privilege set an Opener typically needs:
- **Microsoft Sentinel Responder** on workspace `lsy-prd-oms` (read entities, comment on incident).
- **Key Vault Secrets User** on `LSY-WEUR-ITCS-PRD-KV-02` — **but** the vault is access-policy
  mode, so also/instead run `Set-AzKeyVaultAccessPolicy` (the RBAC role is inert here).
- **Microsoft Sentinel Automation Contributor** for the Azure Security Insights SP on
  `SEC_RG_002` (playbook-picker visibility) — grant to the SP, not the MI.

*(An Opener does not need Storage Blob Data Contributor unless it also writes an audit blob.)*

## KV from Cloud Shell

Interactive `Get-AzKeyVaultSecret` from Cloud Shell may hit `Forbidden` (KV firewall blocks
Cloud Shell egress). This does **not** affect the playbook — MSI-backed connections reach KV
fine at runtime. Validate via the portal or a Logic App test run, not the interactive session.
