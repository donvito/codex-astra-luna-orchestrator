# Token Usage

There is no single token number for this setup. Usage depends on repository
size, task shape, how many subagents the root actually spawns, and how much
of each subagent's context is served from cache. What this guide gives you
instead is a repeatable way to measure your own runs, one sample run for
scale, and the caveats needed to read the numbers correctly.

## What Codex records

Codex writes one rollout file per thread under
`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Root and subagent threads
each get their own file. The relevant fields are:

- `session_meta` (line 1): `id`, `session_id` (the root thread id, shared by
  every subagent), `parent_thread_id`, `cwd`, `cli_version`, and
  `source.subagent.thread_spawn.agent_role` for spawned agents.
- `turn_context`: the `model` and `effort` in force for the turn. Subagent
  threads start with the parent's settings, so the last `turn_context` is the
  authoritative one.
- `token_usage_record`: one per model response, with per-response
  `input_tokens`, `cached_input_tokens`, `output_tokens`,
  `reasoning_output_tokens`, and `total_tokens`.
- `token_count` (inside `event_msg`): cumulative totals for the thread plus
  `rate_limits.primary` (5-hour window) and `rate_limits.secondary` (7-day
  window) as `used_percent`, and `plan_type`.

Grouping every rollout by `session_id` therefore gives the full cost of one
orchestrated task, split by thread, role, and model, with no instrumentation.

## Measuring a run

`scripts/token_usage.py` does the grouping. It is standard-library Python and
read-only.

```bash
# Which sessions spawned subagents today?
scripts/token_usage.py --list --date 2026-09-07

# Report on one session (any unique id prefix works)
scripts/token_usage.py --root 01a079f2 --date 2026-09-07

# Report on the most recent session that used subagents
scripts/token_usage.py --latest --date 2026-09-07

# Machine-readable output
scripts/token_usage.py --root 01a079f2 --format json
```

Omitting `--date` scans the whole sessions directory, which is slower.
Codex auto-review (guardian) threads are listed but excluded from totals by
default; add `--include-guardian` to count them.

If you have a plain root-only session to compare against, run the same
command with its id. The script works for sessions with zero subagents.

## Benchmark protocol

If you want numbers that are comparable across configurations:

1. Pick three or four representative tasks in one repository: a single-file
   fix, a multi-file feature, a cross-component bug, and a research-heavy
   change. Write the prompts down and reuse them verbatim.
2. Run each task in at least two configurations:
   - Baseline: Astra root only, `[agents] enabled = false`, no skill.
   - Orchestrated: this setup as installed.
   - Optional floor: Luna root only, to see the cheapest possible run.
3. Record for every run: per-model uncached input, cached input, output and
   reasoning tokens; number of subagents spawned; wall time; and the change
   in 5-hour and 7-day `used_percent`.
4. Repeat each cell two or three times. Variance between runs of the same
   prompt is large enough that a single sample misleads.
5. Note the Codex version. Caching behaviour and subagent context handling
   change between releases.

Suggested results table:

| Task | Config | Astra uncached / cached / out | Luna uncached / cached / out | Subagents | Wall | 5h delta | 7d delta |
|---|---|---|---|---:|---:|---:|---:|

## Reading the numbers

Cached input dominates. In the sample below 96% of input tokens were cache
hits. A raw `total_tokens` figure therefore overstates cost by more than an
order of magnitude. Always look at uncached input and output separately.

Rate-limit percentages are what Plus and Pro users actually pay with. The
plan is metered on the 5-hour and 7-day windows, not on raw tokens, and the
mapping from tokens to window usage is not published and may differ by
model. The `used_percent` delta is the
most honest single number for "how much of my plan did this task cost". Note
that the window is account-wide, so other Codex sessions running at the same
time inflate the delta.

The root thread is the largest line item even at `low` reasoning. It stays
alive for the whole task, polls subagents, and re-reads its context on every
response. Parallelism trades tokens for latency: every spawned subagent
re-reads its own context on every response.

The auto-review guardian threads are Codex's own approval reviewer, not part
of this setup. They are small but not free.

## Sample run

One run, one repository, one Codex version. Treat it as a scale reference,
not a benchmark.

- Task: cross-component bug fix (file-watcher refresh on external rename) in
  a small TypeScript desktop app, about 16 source files and 6k lines.
- Config: this setup as shipped. Astra root at `low`, Luna subagents at
  `medium`, Astra reviewer at `low`.
- Codex `0.153.4`, Plus plan, 2026-09-07.
- Agents spawned: explorer, worker, tester, reviewer (4). Three guardian
  threads excluded.
- Wall time: 13m49s.
- Rate limit: 5h window 0% to 66%, 7d window 31% to 42%.

| Thread | Role | Model / effort | Responses | Uncached in | Cached in | Output | Reasoning | Total | Duration |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| `01a079f2` | root | gpt-6-astra / low | 83 | 118,590 | 4,668,928 | 6,860 | 900 | 4,794,378 | 13m49s |
| `01a079f4` | explorer | gpt-5.6-luna / medium | 11 | 50,574 | 538,880 | 2,701 | 727 | 592,155 | 1m34s |
| `01a079f5` | tester | gpt-5.6-luna / medium | 27 | 56,318 | 1,313,024 | 5,329 | 1,918 | 1,374,671 | 11m05s |
| `01a079f5` | worker | gpt-5.6-luna / medium | 34 | 67,089 | 1,842,688 | 8,868 | 1,599 | 1,918,645 | 7m12s |
| `01a079fa` | reviewer | gpt-6-astra / low | 16 | 47,797 | 588,928 | 2,214 | 172 | 638,939 | 3m35s |

| Model | Threads | Responses | Uncached in | Cached in | Output | Reasoning | Total |
|---|---:|---:|---:|---:|---:|---:|---:|
| gpt-5.6-luna | 3 | 72 | 173,981 | 3,694,592 | 16,898 | 4,244 | 3,885,471 |
| gpt-6-astra | 2 | 99 | 166,387 | 5,257,856 | 9,074 | 1,072 | 5,433,317 |
| all | 5 | 171 | 340,368 | 8,952,448 | 25,972 | 5,316 | 9,318,788 |

Cache hit rate on input: 96.3%.

Takeaways from this single run:

- About 340k uncached input tokens and 26k output tokens did the real work.
  The 9.3M total is almost entirely cache hits.
- The Astra root alone accounted for roughly half of all usage while only
  emitting 6.9k output tokens. Orchestration overhead is mostly the root
  staying in the loop.
- One medium-sized task consumed two thirds of a fresh Plus 5-hour window.
  If you are on Plus, expect one or two orchestrated tasks per window, and
  use the `routine-coding.md` preset or root-only mode for small edits.

## Reducing usage

In rough order of impact:

- On Plus, move the root to Luna. The root is the largest line item in every
  orchestrated session, so this saves more than any subagent change. The
  installer does this when you select the Plus plan; for manual setups see
  `plus-plan.md`:

  ```toml
  # Root
  model = "gpt-5.6-luna"
  model_reasoning_effort = "max"
  ```

- Do not orchestrate small tasks. The skill's delegation gate already says
  this; enforce it by not invoking `$astra-orchestrator` for one-file edits.
- Keep `max_concurrent_threads_per_session` low. Each extra concurrent
  subagent is a second full context being re-read on every response.
- Ask subagents for short reports. The skill's "cost and context discipline"
  section exists because raw logs pasted into the root are re-read by the
  root on every subsequent response.
- Skip the reviewer for low-risk changes. It is Astra, and it re-reads the
  diff and surrounding context.
- Lower Luna to `low` reasoning for explorer and tester roles; output and
  reasoning tokens are a small share of the total, so this mainly shortens
  wall time.

## Contributing results

If you run the protocol on your own projects, open a pull request adding a
row to the table above with the task description, repository size, Codex
version, plan type, and the script output. Please redact repository paths
you do not want published.
