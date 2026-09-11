# Complex Repository Work

Choose this preset for architecture changes, difficult debugging, and work
where higher-confidence reasoning matters more than latency.

This is an optional root override for the [Pro profile](full-orchestration.md),
whose default is Astra `medium`. It leaves the installed Luna `max` roles
and Astra `low` reviewer in place. If you adopt this override, update the
installed skill's root-reasoning wording to match.

Add or merge this into:

`~/.codex/config.toml`

```toml
model = "gpt-6-astra"
model_reasoning_effort = "high"
service_tier = "standard"
```

If your Codex version does not support `service_tier`, remove that line and
keep the model and reasoning settings.
