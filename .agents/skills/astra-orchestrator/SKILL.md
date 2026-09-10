---
name: astra-orchestrator
description: Orchestrate complex Codex coding work with the root agent as planner/integrator, Luna subagents for exploration, implementation, testing, and research, and an Astra reviewer. Use for multi-file features, debugging across components, repo-wide changes, parallelizable workstreams, or whenever the user asks to delegate or use subagents. Do not use for trivial one-file edits or simple questions.
---

# Astra Orchestrator

The user's explicit instructions take precedence over this skill.

## Goal

Use the root agent as the high-quality orchestrator.

Delegate bounded execution work to specialized subagents, then have the root integrate, verify, and present the final result.

The expected default topology is:

- root: GPT-6 Astra (Pro plan) or GPT-5.6 Luna at max reasoning (Plus plan)
- explorer: GPT-5.6 Luna
- worker: GPT-5.6 Luna
- tester: GPT-5.6 Luna
- reviewer: GPT-6 Astra
- researcher: GPT-5.6 Luna

Use Luna for all routine subagent execution.

This is a requirement, not a preference.

Only the reviewer uses Astra by default.

Do not override a Luna subagent to a more expensive model unless the user explicitly asks for escalation or a Luna worker reports that the task requires higher-level reasoning.

---

## Delegation gate

Before doing substantive repository work, classify the task into one of three tiers:

### Tier 1 — Root-only

The task is small, localized, and does not materially benefit from independent exploration, implementation, testing, research, or review.

Examples: one-file fix, config tweak, simple question.

Handle entirely in the root. Do not spawn subagents just to satisfy a delegation rule.

### Tier 2 — Lightweight delegation

The task is bounded but benefits from separation of concerns. One capable worker (or explorer + worker) is enough.

Examples: targeted fix across two files, a well-understood feature addition, a focused refactor with clear scope.

Spawn only the roles that add value. A single worker with bounded ownership is a valid orchestration. Review is optional and should be proportional to risk.

### Tier 3 — Full orchestration

The task is cross-cutting, risky, ambiguous, or parallelizable. Multiple independent workstreams exist and benefit from the full topology.

Examples: multi-component feature, cross-service bug, repo-wide migration, work requiring independent investigation before implementation.

The task MUST use Tier 3 when at least one of the following is true:

- the task spans multiple independent modules, services, or components
- there are two or more genuinely independent workstreams
- debugging requires tracing across components
- external or version-specific facts need verification
- an independent post-change review is materially useful for risk management
- the user explicitly asks for delegation, parallelism, agents, or subagents

### Routing discipline

Treat orchestration as adaptive routing, not a fixed pipeline. Start with the lightest tier that fits and expand only when the work demands it.

When a task qualifies for delegation (Tier 2 or 3), the root MUST call `spawn_agent` before performing the delegated work itself.

Do not merely describe, simulate, or internally reason about delegation.

Actual subagents must be spawned.

If `spawn_agent` is unavailable or fails, explicitly report that failure.

Do not silently fall back to doing required delegated work in the root thread.

Workers get bounded ownership and should finish their assignment rather than repeatedly handing work back to the root.

Specialists (tester, reviewer, researcher) are conditional, not mandatory pipeline stages. Invoke them when they add value, skip them when the task does not require them.

---

## Root-agent responsibilities

The root agent owns:

1. understanding the user's actual goal
2. choosing the architecture and implementation direction
3. decomposing the task
4. deciding which tasks can run in parallel
5. spawning the appropriate subagents
6. giving each subagent a bounded contract
7. resolving conflicting subagent findings
8. integrating changes
9. reviewing the final diff
10. running or coordinating final verification
11. presenting the final result to the user

Subagents provide evidence and bounded execution.

They do not own the overall direction.

The root must not offload architectural ownership to a subagent.

---

## Spawn policy

When spawning agents, use these models by default:

- explorer: `gpt-5.6-luna`
- worker: `gpt-5.6-luna`
- tester: `gpt-5.6-luna`
- researcher: `gpt-5.6-luna`
- reviewer: `gpt-6-astra`

The root keeps the model configured in `config.toml`: `gpt-6-astra` on the Pro plan, `gpt-5.6-luna` at max reasoning on the Plus plan. Do not change the root model from within a session.

For every delegated task:

1. call `spawn_agent`
2. give the agent a descriptive task name using underscores
3. explicitly specify the intended model
4. give the subagent a bounded delegation contract
5. retain the returned task name or identifier
6. wait for required agents before final synthesis

Do not silently substitute the root agent for a required Luna worker.

Do not spawn Astra workers except for the `reviewer` role unless:

- the user explicitly requests Astra
- Luna reports a genuinely difficult reasoning blocker
- the root determines that a high-risk architectural or security review needs Astra

Routine execution should remain on Luna.

---

## Delegation contract

Every delegated task should include:

- Objective: one concrete outcome
- Scope: exact files, module, subsystem, or question when known
- Context: only the information needed to succeed
- Constraints: what must not change
- Deliverable: what the subagent must return or implement
- Acceptance criteria: how success will be checked

Prefer narrow tasks that can finish independently.

Bad:

> Fix the backend.

Good:

> Trace where POST /invoices validates currency. Return the responsible files, validation path, and existing tests. Do not edit files.

For implementation tasks, explicitly state file ownership when possible.

For exploration tasks, tell the agent not to edit files.

For review tasks, tell the agent to report findings rather than silently modify unrelated code.

---

## Role selection

Use `explorer` for:

- repository mapping
- tracing execution or data flow
- locating symbols and tests
- dependency inspection
- configuration inspection
- identifying implementation boundaries

Use `worker` for:

- bounded implementation
- small refactors with explicit scope
- targeted fixes
- adding requested code
- modifying clearly owned files

Use `tester` for:

- reproduction
- targeted test execution
- validation
- regression checks
- adding tests when requested or clearly required by the task

Use `reviewer` for:

- independent post-change review
- correctness checks
- security review
- regression analysis
- missing-test analysis
- architectural consistency checks

Use `researcher` for:

- current API or framework behavior
- dependency or version questions
- primary documentation verification
- external compatibility questions

---

## Parallelism

Run independent tasks in parallel.

When two or more delegated tasks are independent, spawn all of them before waiting for any one of them.

Good parallel set:

1. spawn backend explorer
2. spawn frontend explorer
3. spawn API researcher
4. wait for all three
5. synthesize findings

Do not do this:

1. spawn backend explorer
2. wait
3. spawn frontend explorer
4. wait
5. spawn researcher
6. wait

unless later tasks genuinely depend on earlier results.

Good parallel examples:

- explorer maps backend path
- explorer maps frontend path
- researcher verifies external API behavior

Serialize dependent work:

1. explore
2. decide architecture
3. implement
4. test
5. review
6. fix material findings
7. final verification

Do not send multiple workers to edit the same files unless the root explicitly coordinates ownership.

Prefer one writer per file or subsystem.

---

## Default coding workflow

Match the workflow depth to the task tier from the delegation gate.

### Tier 2 workflow (lightweight)

For bounded tasks that benefit from delegation but do not require the full topology:

1. root assesses scope (brief exploration if needed, or spawn one explorer)
2. spawn a single Luna worker with bounded ownership and clear acceptance criteria
3. wait for implementation
4. root verifies the result directly (targeted tests, diff review)
5. present the result

Skip the explorer if the root already understands the code path. Skip the reviewer for low-risk changes. A single worker finishing its assignment end-to-end is a valid and preferred orchestration for most delegated work.

### Tier 3 workflow (full orchestration)

For cross-cutting, risky, or multi-workstream tasks:

1. spawn one or more Luna explorers if repository understanding is needed
2. wait for exploration results
3. root decides implementation direction
4. spawn Luna worker or workers with bounded ownership
5. wait for implementation
6. spawn Luna tester when the change is non-trivial or touches critical paths
7. wait for validation
8. spawn Astra reviewer when an independent review is materially useful (high risk, security, architecture)
9. resolve material findings
10. run final verification
11. present the result

### General rules

Do not spawn every role mechanically.

Use only the roles that materially improve the task.

Once the delegation gate places a task in Tier 2 or 3, at least one real subagent must be spawned.

Review should be proportional to risk rather than automatically invoking the full topology.

---

## Debugging workflow

For cross-component bugs:

1. spawn explorers for independent suspected areas
2. reproduce the issue when possible
3. collect evidence before selecting a fix
4. root determines the likely root cause
5. assign a bounded Luna worker to implement the fix
6. assign Luna tester to reproduce the original failure and validate the fix
7. use Astra reviewer for high-risk or non-obvious fixes

Do not let multiple workers independently attempt competing fixes unless the root intentionally requests alternative approaches.

---

## Research workflow

When current or version-specific external information matters:

1. spawn a Luna researcher
2. require primary or authoritative sources when possible
3. return concise findings and compatibility implications
4. let the root decide how those findings affect implementation

Do not mix speculative external claims into implementation decisions without verification.

---

## Cost and context discipline

Use Luna for routine subagent execution.

Keep the root context focused on:

- architectural decisions
- summarized evidence
- important diffs
- test results
- reviewer findings
- unresolved risks

Do not paste large raw logs or entire files back into the root when a concise evidence summary is enough.

Subagents should return:

- conclusions
- relevant file paths
- important line or symbol references
- commands run
- test results
- risks or blockers

Avoid returning large amounts of irrelevant raw output.

---

## Escalation behavior

A subagent should report back instead of expanding scope when it encounters:

- an architectural decision
- a breaking API or schema change
- a new dependency
- a security-sensitive design choice
- unclear requirements with materially different outcomes
- unexpected changes outside its assigned scope
- changes that affect another worker's ownership
- a blocker that requires substantially broader reasoning

The root decides what to do next.

Luna should not independently escalate itself to a more expensive model.

The root owns model escalation decisions.

---

## Failure handling

If a subagent fails:

1. inspect the failure reason
2. decide whether the task should be retried, narrowed, reassigned, or handled by the root
3. do not silently ignore the failed delegation
4. do not claim the delegated work completed successfully

If `spawn_agent` itself fails, explicitly note the failure.

If a required worker fails repeatedly, the root may continue directly when reasonable, but should record that the fallback occurred.

---

## Delegated-task completion gate

Before producing the final answer for a delegated task, confirm that:

- every required subagent was actually spawned
- every required subagent either completed or explicitly failed
- material findings were integrated
- conflicting findings were resolved
- required verification was performed
- no required agent is still running

Do not finish while required subagents are still running.

Do not claim delegation occurred unless `spawn_agent` was actually called successfully.

---

## Final verification

Before claiming completion, the root should:

1. inspect the final diff
2. confirm the requested behavior is actually implemented
3. check material reviewer findings
4. run or confirm the highest-value tests
5. verify that delegated results were integrated correctly
6. state any validation that could not be performed

For implementation tasks, prefer checking:

- syntax or type checks
- targeted unit tests
- integration tests where relevant
- build success where relevant
- the original reproduction path
- final diff for unintended changes

---

## User-facing behavior

Do not narrate every subagent action unless the user asks for detailed orchestration visibility.

The final answer should focus on:

- what changed
- what was verified
- important findings
- remaining risks or limitations

When useful, briefly mention which agents contributed.

If the user explicitly asks to see delegation, report:

- subagent name
- model
- assigned task
- completion status

Do not claim a Luna agent was used unless the trace contains a successful `spawn_agent` call using `gpt-5.6-luna`.
