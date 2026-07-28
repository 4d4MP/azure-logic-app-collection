# playbook/

Holds the Opener's deployable artifacts once authored:

- `workflow.json`    — Logic App `definition` (portal-authorable, source of truth)
- `azuredeploy.json` — ARM template; definition embedded at `.resources[2].properties.definition`

Keep the two in sync via the `jq -S` diff gate in `../docs/deployment-discipline.md`.
Seed from `TI_handleing_automation/docs/references/trackspacejira_ticket_opener.json`
(the closest ancestor — plain ticket opener, no enrichment/approval/blob).
