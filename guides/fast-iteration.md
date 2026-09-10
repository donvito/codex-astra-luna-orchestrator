# Fast Iteration

Choose this preset when latency matters and you want Astra to orchestrate
quickly with Luna subagents.

Add or merge this into:

`~/.codex/config.toml`

```toml
model = "gpt-6-astra"
model_reasoning_effort = "medium"
service_tier = "fast"
```

If your Codex version does not support `service_tier`, remove that line and
keep the model and reasoning settings.
