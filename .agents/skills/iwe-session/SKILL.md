---
name: iwe-session
description: Run the IWE Open-Work-Close protocol for substantial work with Codex or Kimi. Use when opening, continuing, or closing a focused task.
version: 1.0.0
layer: L1
status: active
triggers:
  phrases: [начинаем работу, продолжай работу, закрываем задачу]
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "WP Gate and other pre-action gates are enforced by the common agent core"
---

# IWE Session

## When to use

Use for any substantial IWE task that needs an explicit Open–Work–Close cycle.

## Algorithm

1. Read `memory/MEMORY.md`, `memory/navigation.md`, the current plan, and the relevant open WP context.
2. Open through `memory/protocol-open.md`: declare the intended result, constraints, verification, and required gates before substantial work.
3. Work through `memory/protocol-work.md`. Track the steps with the current agent's native planning mechanism.
4. Preserve durable decisions in the appropriate workspace artifact, not only in chat.
5. Close through `memory/protocol-close.md`: verify the result, record unresolved items, and name the next action.
6. Do not push, publish, schedule, or contact external systems without the user's explicit authorization.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
