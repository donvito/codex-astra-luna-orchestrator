# Complex Repository Work

Choose this preset for architecture changes, difficult debugging, and work
where higher-confidence reasoning matters more than latency.

Add or merge this into:

`~/.codex/config.toml`

```toml
model = "gpt-6-astra"
model_reasoning_effort = "high"
service_tier = "standard"
```

If your Codex version does not support `service_tier`, remove that line and
keep the model and reasoning settings.
