---
name: iwe-day-close
description: Close the IWE workday and preserve context. Use when the user asks to summarize the day or prepare tomorrow's handoff.
version: 1.0.0
layer: L1
status: active
triggers:
  phrases: [закрывай день, итоги дня]
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "Operational protocol; repository safety is enforced by the common agent core"
---

# IWE Day Close

## When to use

Use when the user asks to close the IWE day, summarize results, or prepare tomorrow's handoff.

## Algorithm

1. Read `memory/protocol-close.md`, today's DayPlan, the current WeekPlan, and the files changed during the day.
2. Separate completed results, unfinished work, decisions, captures, blockers, and tomorrow's first action.
3. Update or archive the DayPlan according to the existing `DS-strategy` structure.
4. Update `memory/MEMORY.md` only with durable context required by future sessions.
5. If `params.yaml` enables the IWE multiplier, obtain today's WakaTime total without exposing credentials. If data is unavailable or zero, say so and do not invent a value.
6. Stage only reviewed files by exact path. Commit or push only when the user has authorized that action; preserve unrelated changes.
7. Close with verification, unresolved items, and the next action.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
