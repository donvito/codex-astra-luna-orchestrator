# Routine Coding

Choose this preset for predictable, routine coding tasks where lower cost and
faster orchestration are preferred.

This is an optional root override for the [Plus profile](plus-plan.md),
lowering its Luna root from `max` to `medium`. The installed Luna subagents
remain at `medium` and the Astra reviewer at `low`. If you adopt this override,
update the installed skill's root-reasoning wording to match.

Add or merge this into:

`~/.codex/config.toml`

```toml
model = "gpt-5.6-luna"
model_reasoning_effort = "medium"
service_tier = "fast"
```

If your Codex version does not support `service_tier`, remove that line and
keep the model and reasoning settings.
