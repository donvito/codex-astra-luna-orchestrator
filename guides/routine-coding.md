# Routine Coding

Choose this preset for predictable, routine coding tasks where lower cost and
faster orchestration are preferred.

Add or merge this into:

`~/.codex/config.toml`

```toml
model = "gpt-5.6-luna"
model_reasoning_effort = "medium"
service_tier = "fast"
```

If your Codex version does not support `service_tier`, remove that line and
keep the model and reasoning settings.
