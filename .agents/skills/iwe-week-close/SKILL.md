---
name: iwe-week-close
description: Close the IWE week with a seven-day review and carry-over into the next WeekPlan. Use when the user asks to close the week.
version: 1.0.0
layer: L1
status: active
triggers:
  phrases: [закрывай неделю, итоги недели]
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "Operational protocol; new work products still pass the common WP Gate"
---

# IWE Week Close

## When to use

Use when the user asks to close the IWE week and carry confirmed work into the next plan.

## Algorithm

1. Read `memory/protocol-close.md`, the current WeekPlan, the previous seven DayPlans or close results, and relevant repository history.
2. Compare intended and actual results. Separate completed outcomes, carry-over, dropped work, decisions, and blockers.
3. Verify active WP statuses against their physical artifacts before changing the registry or plan.
4. Prepare the next WeekPlan from confirmed priorities. Do not invent commitments, metrics, dates, or artifact names.
5. Run the repository's existing verification and backup steps that are available in the current environment; report unavailable integrations explicitly.
6. Stage only reviewed files by exact path. Commit or push only with the user's explicit authorization.
7. Close with the week's result, carry-over, risks, and the next action.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
