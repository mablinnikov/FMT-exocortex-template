---
name: iwe-strategy-session
description: Conduct an initial, monthly, or weekly IWE strategy session in Russian. Use for strategy, dissatisfaction review, or WeekPlan decisions.
version: 1.0.0
layer: L1
status: active
triggers:
  phrases: [стратегическая сессия, давай стратегировать]
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "Operational protocol; resulting work products pass the common WP Gate"
---

# IWE Strategy Session

## When to use

Use for an initial, monthly, or weekly IWE strategy session and confirmed WeekPlan decisions.

## Algorithm

1. Read `memory/MEMORY.md`, `DS-strategy/docs/Strategy.md`, `DS-strategy/docs/Dissatisfactions.md`, and the current plans.
2. Select the existing initial, monthly, or weekly route from the strategy materials based on the actual artifacts and calendar position.
3. Distinguish the user's goals, current dissatisfaction, constraints, and focus. Ask only questions that materially change the decision.
4. Never invent goals, metrics, deadlines, commitments, or artifact names. Mark unresolved choices explicitly.
5. Update strategy documents and the WeekPlan only after the user confirms their substance.
6. Close with decisions, verification, next actions, and the context required by the next session.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
