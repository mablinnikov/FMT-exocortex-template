---
name: iwe-day-open
description: Open the IWE workday and prepare today's plan. Use when the user asks to open the day or choose today's priorities.
version: 1.0.0
layer: L1
status: active
triggers:
  phrases: [открывай день, план на сегодня]
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "Operational protocol; the common agent core applies pre-action gates to resulting work"
---

# IWE Day Open

## When to use

Use when the user asks to open the IWE day or choose today's priorities.

## Algorithm

1. Read `memory/protocol-open.md`, `memory/MEMORY.md`, the current WeekPlan, and the latest DayPlan or close result.
2. Determine carry-over work, blockers, deadlines, and the smallest useful result for today.
3. Ask only about choices that materially change the plan; put non-critical uncertainty under attention items.
4. Create or update `DS-strategy/current/DayPlan YYYY-MM-DD.md` using the existing day-plan template and repository naming rules.
5. Finish with today's priorities, the first action, and explicit verification criteria.
6. Do not create calendar events or external reminders unless the user explicitly requests them.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
