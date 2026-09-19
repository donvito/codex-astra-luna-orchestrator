---
name: astra-luna-setup
description: Set up the Astra/Luna Codex orchestrator in an existing target repository with project-local scope and conflict checks. Use when someone asks to install or prepare this orchestrator; do not use for ordinary coding tasks.
---

# Astra/Luna setup

Use the official repository as the source of the selected profile:
`https://github.com/donvito/codex-astra-luna-orchestrator`.

## Scope and safety

- The target must be an existing repository and must be different from the
  setup source repository.
- Keep the installation project-local. Never merge the profile into the
  user's global `~/.codex`, global agents, or global `AGENTS.md`.
- Inspect the target's `.codex/`, `.agents/`, `AGENTS.md`, hooks, symlinks, and
  working-tree status before running the installer.
- Show the selected profile and every existing path that could be changed.
  Preserve incompatible files and unrelated work; do not bypass the setup
  script's confirmation prompts.
- Do not copy credentials or provider configuration into the target.

## Procedure

1. Determine the target path and the user's Codex plan. If the plan is unknown,
   ask before selecting `pro` or `plus`.
2. If the current directory is the checked-out source repository, run its
   `setup.sh` or `setup.ps1`. Otherwise clone the official repository into a
   temporary directory, pin the inspected revision, and run the matching setup
   script from there.
3. Prefer the two-subagent profile for a first pilot. Do not silently choose a
   high-cost profile or enable a global installation.
4. Let the installer handle its existing-file checks. If the target already
   has project instructions, show the proposed `AGENTS.md` append before
   accepting it.
5. Validate the resulting TOML, role files, skill frontmatter, and
   `git diff --check`. State that a new Codex task started in the target repo is
   still required to prove runtime loading.
6. Keep the generated setup files in the target repository and suggest a small
   commit. Push only when the user explicitly asks.

## Contribution mode

If the user asks for an upstream contribution, inspect the repository's current
README, tests, and contribution rules first. Prefer a small skill/documentation
addition that wraps the existing installer. Test the skill metadata and any
changed scripts, create a local branch, and report a paste-ready PR title and
body. Do not push or open a pull request without explicit authorization.
