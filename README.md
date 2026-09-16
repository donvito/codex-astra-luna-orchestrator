# Codex Astra Orchestrator + Luna Subagents

A configurable Codex setup where GPT-6 Astra is the root/orchestrator and reviewer, while GPT-5.6 Luna is the default and pinned model for execution subagents.

The installer asks which Codex plan you are on. Pro uses GPT-6 Astra at medium reasoning to orchestrate and GPT-5.6 Luna at max reasoning for execution subagents. Plus uses GPT-5.6 Luna at max reasoning to orchestrate and medium reasoning for execution subagents. Both plans retain the separate GPT-6 Astra reviewer at low reasoning.

## Layout

```text
.
├── profiles/
│   ├── pro/
│   │   ├── codex/           (config.toml and agents/*.toml)
│   │   └── agents/          (skills/astra-orchestrator/SKILL.md)
│   ├── plus/
│   │   ├── codex/           (config.toml and agents/*.toml)
│   │   └── agents/          (skills/astra-orchestrator/SKILL.md)
│   ├── pro-max-2-subagents/  (Pro with a concurrent subagent limit of 2)
│   │   ├── codex/           (config.toml and agents/*.toml)
│   │   └── agents/          (skills/astra-orchestrator/SKILL.md)
│   └── plus-max-2-subagents/ (Plus with a concurrent subagent limit of 2)
│       ├── codex/           (config.toml and agents/*.toml)
│       └── agents/          (skills/astra-orchestrator/SKILL.md)
├── guides/
│   ├── fast-iteration.md
│   ├── complex-repo-work.md
│   ├── routine-coding.md
│   ├── full-orchestration.md
│   ├── plus-plan.md
│   └── token-usage.md
├── scripts/
│   ├── release-update.sh
│   └── token_usage.py
├── AGENTS.md
├── setup.sh
├── setup.ps1
├── update.sh
├── update.ps1
├── VERSION
└── LICENSE
```

## Current Plus and Pro configuration

| Role or setting | Plus | Pro | plus-max-2-subagents | pro-max-2-subagents |
|---|---|---|---|---|
| Orchestrator | GPT-5.6 Luna — max | GPT-6 Astra — medium | GPT-5.6 Luna — max | GPT-6 Astra — medium |
| Explorer, worker, tester, researcher | GPT-5.6 Luna — medium | GPT-5.6 Luna — max | GPT-5.6 Luna — medium | GPT-5.6 Luna — max |
| Default subagent | GPT-5.6 Luna — medium | GPT-5.6 Luna — max | GPT-5.6 Luna — medium | GPT-5.6 Luna — max |
| Independent reviewer | GPT-6 Astra — low | GPT-6 Astra — low | GPT-6 Astra — low | GPT-6 Astra — low |
| Concurrent subagent limit | 4 | 4 | 2 | 2 |

### Pro — `profiles/pro/codex/config.toml`

```toml
model = "gpt-6-astra"
model_reasoning_effort = "medium"

approval_policy = "on-request"
sandbox_mode = "workspace-write"

[agents]
enabled = true
max_concurrent_threads_per_session = 4
default_subagent_model = "gpt-5.6-luna"
default_subagent_reasoning_effort = "max"
```

### Plus — `profiles/plus/codex/config.toml`

```toml
model = "gpt-5.6-luna"
model_reasoning_effort = "max"

approval_policy = "on-request"
sandbox_mode = "workspace-write"

[agents]
enabled = true
max_concurrent_threads_per_session = 4
default_subagent_model = "gpt-5.6-luna"
default_subagent_reasoning_effort = "medium"
```

The installer copies `profiles/<plan>/codex` to `.codex` and
`profiles/<plan>/agents` to `.agents` in the target repository. Each profile
is ready to copy, with no configuration rewriting during setup.

Each role file is explicitly pinned to its intended model: Luna for explorer, worker, tester, and researcher; Astra for reviewer. This means changing only `default_subagent_model` will affect generic spawned agents, but not the named roles.

The four Luna role files explicitly set `model_reasoning_effort = "max"` in the Pro profile and `"medium"` in the Plus profile. The reviewer keeps its explicit `low` effort in both.

To update an existing project from a published release, use the [release updater](#release-updates). For manual updates, copy the role files along with `config.toml` from the selected profile. Replace `<plan>` below with `pro` or `plus`.

If you want all named roles, including the reviewer, to follow the `[agents]` defaults, remove both the `model` and `model_reasoning_effort` overrides from their role files.

## Project setup

Clone this repository:

```bash
git clone https://github.com/donvito/codex-astra-luna-orchestrator.git
cd codex-astra-luna-orchestrator
```

The target project must already exist and must be different from this setup
repository.

### macOS and Linux

Run the shell installer:

```bash
./setup.sh
```

### Windows

Run the PowerShell installer from Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

With PowerShell 7, you can use:

```powershell
pwsh -File .\setup.ps1
```

### Installer prompts

When asked for the target repository, enter its absolute or relative path. For
example:

```text
Target repository path: ../my-project
```

Next, choose your Codex plan:

```text
Choose Profile to install
  1) Pro  - GPT-6 Astra (medium) orchestrates, GPT-5.6 Luna (max) executes, GPT-6 Astra (low) reviews
  2) Plus - GPT-5.6 Luna (max) orchestrates, GPT-5.6 Luna (medium) executes, GPT-6 Astra (low) reviews
  3) Pro (max 2 subagents) - GPT-6 Astra (medium) orchestrates, GPT-5.6 Luna (max) executes, GPT-6 Astra (low) reviews
  4) Plus (max 2 subagents) - GPT-5.6 Luna (max) orchestrates, GPT-5.6 Luna (medium) executes, GPT-6 Astra (low) reviews
Select plan [1-4] (default 1):
```

The selected configuration sets both the root and default subagent reasoning.
Agent role files are shared between plans: explorer, worker, tester, and
researcher use Luna at the plan's default effort; the reviewer uses Astra at low
effort on both plans.

The installer then asks whether to install each component:

- `profiles/<plan>/codex` contains the root configuration and agent role profiles, installed as `.codex`.
- `profiles/<plan>/agents` contains the `astra-orchestrator` skill, installed as `.agents`.
- `AGENTS.md` gives Codex the project-level orchestration instructions. If it
  already exists, setup appends the instructions and preserves its contents.
  Re-running setup skips the append when the same instructions are already
  present. Symbolic links and incompatible targets are skipped.

Press Enter or answer `y` to install a component; answer `n` to skip it. All
three components are selected by default.

If a component already exists, the installer lists the exact paths that would
be overwritten and asks again before making changes:

```text
WARNING: the following existing files will be overwritten:
  - .codex/config.toml
Update .codex? New files will be added; only paths listed above will be replaced. [y/N]
```

Existing-file updates default to `n`. If approved, missing files are added and
only the listed paths are replaced. Other files already present in the target
component remain untouched.

After setup, launch Codex from the target repository. Project-scoped `.codex`
configuration is loaded only for trusted projects.

See `guides/` for copy-paste model presets and the Astra + Luna topology. The
guides are intentionally separate from the installers so you can review and
adapt settings for your Codex version without changing a global config
automatically.

## Release updates

Each run of `setup.sh` or `setup.ps1` checks GitHub for a newer stable release before starting local setup. When one is available, setup shows its version and release link and asks whether to download and run that release's installer. The answer defaults to **no**. If the check fails, local setup continues with a warning.

You can also check for releases without installing anything:

```sh
./update.sh --check
```

```powershell
powershell -ExecutionPolicy Bypass -File .\update.ps1 -Check
```

To install or update a project using the latest published release:

```sh
./update.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File .\update.ps1
```

The updater asks before downloading and running the release installer. Enter the existing project's path, select its profile, and choose the components to update. Existing-file replacements still require the installer's separate confirmation, which defaults to **no**. Review the listed paths before approving: selected profile files replace those paths, so merge any customizations you want to keep. Other project files are preserved, and `AGENTS.md` retains its existing append-and-deduplicate behavior.

Release archives are downloaded into a temporary directory and removed afterward. The updater works from a clone or extracted source archive and leaves that source directory unchanged. A check compares the setup source's `VERSION` with the latest release; it does not track versions installed in individual projects. Running the updater explicitly lets you install the latest release even when the setup source is already current.

Checks run only when setup or the updater is invoked. No background service, scheduled task, or Codex startup hook is installed. Existing installations need a copy of these new scripts once to use this flow. Personal/global installations still use the manual merge instructions below.

To use only local files and skip the network check:

```sh
./setup.sh --offline
```

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Offline
```

The shell updater requires `curl`, `tar`, and standard POSIX utilities. Windows uses built-in PowerShell and .NET functionality. Checks use GitHub's public latest-release endpoint and require no GitHub login. A missing release, network failure, or rate limit makes an explicit update/check command fail with a diagnostic; it does not trigger installation from `main`.

Maintainers: update `VERSION` to the release number (for example, `0.2.0`) before publishing the matching `v0.2.0` release. Stable tags use `vMAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH`. GitHub's generated source archives are sufficient; no extra release assets are required.

## Personal/global setup

For agents, copy the TOML files from `profiles/<plan>/codex/agents/` to:

```text
~/.codex/agents/
```

For the skill, copy `profiles/<plan>/agents/skills/astra-orchestrator/` to:

```text
~/.agents/skills/astra-orchestrator/
```

Merge the settings from `profiles/pro/codex/config.toml` (Pro) or `profiles/plus/codex/config.toml`
(Plus) into your existing:

```text
~/.codex/config.toml
```

Do not blindly overwrite your existing global config if you already have MCP servers, providers, permissions, or other settings.

## Using the skill

Codex may select the skill automatically when the task matches its description.

You can also invoke it explicitly from Codex CLI or the IDE extension with:

```text
$astra-orchestrator
```

Example prompt:

```text
$astra-orchestrator

Implement the new invoice export endpoint.
Have explorer map the existing invoice/export path first.
Use workers for bounded implementation, tester for verification,
and reviewer for an independent final review.
```

## Suggested topology

```text
                 GPT-6 Astra
             root / orchestrator
                      |
      +---------------+---------------+
      |               |               |
   explorer          worker         researcher
     Luna             Luna             Luna
      |               |
      +-------+-------+
              |
           tester
            Luna
              |
          reviewer
           Astra
              |
              v
         GPT-6 Astra
      integrate + verify
```

## Tuning

For cheaper/faster runs:
- lower Pro's Astra reasoning from `medium` to `low`
- set Luna reasoning to `low` or `medium`
- use 3-4 concurrent threads

For larger codebases:
- consider raising Pro's Astra reasoning to `high`
- start with your plan's Luna default and adjust based on results
- use 6-8 concurrent threads, only when tasks are actually independent

For strict parent/child separation:
- keep explorer/reviewer/researcher read-only
- keep worker/tester workspace-write
- leave the root in workspace-write so it can integrate changes

## Token usage

Orchestration is not free: the root stays in the loop for the whole task and
every subagent carries its own context. Usage depends on repository size and
task shape, so there is no single number. `scripts/token_usage.py` reads the
rollout logs Codex already writes under `~/.codex/sessions` and reports usage
per thread, role, and model, plus the change in your 5-hour and 7-day rate
limit windows:

```bash
scripts/token_usage.py --list --date 2026-09-07
scripts/token_usage.py --latest --date 2026-09-07
```

See [`guides/token-usage.md`](guides/token-usage.md) for a measurement
protocol, one sample run with real numbers, and tips for reducing usage.

Plus users: the root thread is the largest line item, so running it on Luna
saves the most. Selecting `Plus` in the installer does this for you; for a
manual or global setup see [`guides/plus-plan.md`](guides/plus-plan.md):

```toml
# Root
model = "gpt-5.6-luna"
model_reasoning_effort = "max"
```

## Important behavior

Explicit model choices during a spawn override `[agents]` defaults. Custom agent files that specify `model` or `model_reasoning_effort` also take precedence over inherited defaults.

The execution role files are pinned to Luna intentionally, while the reviewer is pinned to Astra for independent final review. Astra remains the orchestrator unless you deliberately change the role configuration.

## License

Licensed under the [Apache License 2.0](LICENSE).
