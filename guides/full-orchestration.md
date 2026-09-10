# Full Astra + Luna Orchestration

Choose this preset when you want Astra to plan, orchestrate, and review while
Luna handles the execution roles.

The topology is:

```text
Astra root
├── Luna explorer
├── Luna worker
├── Luna tester
├── Luna researcher
└── Astra reviewer
```

Put the root settings in the project-scoped `.codex/config.toml`, or merge
them into `~/.codex/config.toml` for a personal/global setup:

```toml
model = "gpt-6-astra"
model_reasoning_effort = "medium"
service_tier = "fast"

[agents]
enabled = true
default_subagent_model = "gpt-5.6-luna"
default_subagent_reasoning_effort = "medium"
```

For the named roles, use these model settings in the corresponding files under
`.codex/agents/`:

```toml
# explorer.toml, worker.toml, tester.toml, researcher.toml
model = "gpt-5.6-luna"
model_reasoning_effort = "medium"
```

```toml
# reviewer.toml
model = "gpt-6-astra"
model_reasoning_effort = "low"
```

The role files override the inherited `[agents]` defaults. Keep those explicit
overrides when you want the topology above to remain stable. Remove them when
you want all named roles to follow the defaults in `config.toml`.

If your Codex version does not support `service_tier`, remove that line and
keep the model and reasoning settings.
