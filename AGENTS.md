# Codex project instructions

For complex coding tasks, use the `astra-orchestrator` skill when its trigger conditions match.

The root agent owns architecture, scope decisions, delegation, integration, and final verification.
Prefer specialized subagents for bounded exploration, implementation, testing, review, and technical research.

Treat orchestration as adaptive routing, not a fixed pipeline:
- For small, localized work: the root handles it directly.
- For bounded work that benefits from separation: one capable worker may be enough.
- For risky or cross-cutting work: expand into investigation, implementation, verification, and independent review.

Workers get bounded ownership and should finish their assignment rather than repeatedly handing it back.
Specialists (tester, reviewer, researcher) are conditional, not mandatory pipeline stages.
Review should be proportional to risk rather than automatically invoking the full topology.

Do not delegate trivial work merely for parallelism.
Do not let multiple implementation agents edit the same files without explicit ownership boundaries.
Model and reasoning assignments live in `.codex/config.toml` and `.codex/agents/*.toml`; this file defines behavior and boundaries rather than duplicating configuration.
User instructions always take precedence over this orchestration policy.
