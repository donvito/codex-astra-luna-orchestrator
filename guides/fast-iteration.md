# Fast Iteration

Choose this preset when latency matters and you want Astra to orchestrate
quickly with Luna subagents.

Start with the [Pro profile](full-orchestration.md). This optional root
preset keeps Astra `medium`; the installed Luna roles remain at `max` and
the Astra reviewer at `low`. For a Luna root, use the [Plus profile](plus-plan.md).

Add or merge this into:

`~/.codex/config.toml`

```toml
model = "gpt-6-astra"
model_reasoning_effort = "medium"
service_tier = "fast"
```

If your Codex version does not support `service_tier`, remove that line and
keep the model and reasoning settings.
