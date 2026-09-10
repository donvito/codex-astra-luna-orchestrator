# Plus Plan

Choose this preset if you are on a Plus plan and want to keep orchestration
within the 5-hour window. The root runs on Luna at maximum reasoning instead
of Astra, so the largest thread in the session is on the cheaper model while
still planning carefully.

The installers (`setup.sh`, `setup.ps1`) ask for your plan and install this
variant automatically when you select `Plus`; the full file is
`.codex/config.plus.toml`. For a manual or global setup, add or merge this
into:

`~/.codex/config.toml`

```toml
# Root
model = "gpt-5.6-luna"
model_reasoning_effort = "max"
```

Subagents keep their pinned models from `.codex/agents/*.toml`. Explorer,
worker, tester, and researcher run on Luna. The reviewer stays on GPT-6 Astra
on the Plus plan too: it is a single, read-only, `low`-effort thread, and it
gives you an independent review by a different model than the one that
planned and wrote the change. If you want the whole session on Luna, change
`model` in `.codex/agents/reviewer.toml` as well.

See `token-usage.md` for how to measure the difference on your own tasks.
