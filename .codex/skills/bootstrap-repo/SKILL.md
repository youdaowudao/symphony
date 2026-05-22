---
name: bootstrap-repo
description: Use when a repository has just been forked or cloned and you need to verify initialization completeness.
---

# Bootstrap Repo

Use this skill for first-day repository setup and initialization audits.

## Core rule

Treat examples as examples. Inspect the real repository layout first; do not rewrite example paths into "real" paths unless those paths actually exist.

## What to check

1. Repo identity
   - `pwd`
   - `git status --short --branch`
   - `git remote -v`
   - `git branch -vv`
   - `git rev-parse --short HEAD`

2. Top-level inventory
   - `find . -maxdepth 2 -type f | sort`
   - confirm whether `README.md`, `AGENTS.md`, `SPEC.md`, `docs/README.md`, `docs/governance/README.md`, and `.codex/` exist
   - if the repo has a primary runtime directory (for example `elixir/`), inspect its own README and setup docs

3. Governance/docs chain
   - read the repo root docs first
   - then read `docs/README.md`
   - then read `docs/governance/README.md` and any governance rules the repo already has
   - confirm that docs entry points point to real files in this repository

4. Toolchain trust and setup
   - if `mise.toml` exists, run `mise trust` before `mise exec`
   - verify runtime versions with the repo's own documented commands
   - use the repo's own setup helper if one exists before inventing a new one

5. Integrations and helpers
   - locate repo-local helpers under `.codex/`
   - check whether the repo expects issue tracker, CI, or deployment credentials
   - record what is already configured versus what is still missing

## Completion states

Report one of these outcomes:

- `complete` - identity, docs entry points, toolchain, and setup path are all confirmed
- `partial` - the repo is bootstrapped but some items are unverified or missing
- `blocked` - a required secret, toolchain trust step, remote, or repo-specific setup step cannot be confirmed

## Output format

Return a short matrix with:

- confirmed
- missing
- blocked

Then list the next concrete action for each missing or blocked item.

## Do not do

- Do not assume a path exists because a template mentions it.
- Do not rename example directories just to match a template.
- Do not claim initialization is complete until remote, branch, docs entry points, and toolchain trust are actually checked.
