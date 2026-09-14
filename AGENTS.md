# Agent instructions — workbench-security

This file is the canonical, tool-agnostic entry point for any AI coding
agent working in this repo — Claude Code reads it via `CLAUDE.md`'s
`@AGENTS.md` import, GitHub Copilot discovers it directly as a
repository-root `AGENTS.md`. Keep this file itself short; anything
substantial belongs in the docs it points to.

This is a `workbench` ecosystem module — it's meaningless standalone.
It exists to be installed by `workbench-core`'s `wb add <module>`.

## Read first

- [`workbench-core`'s `docs/architecture.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/architecture.md) —
  full design rationale, repo topology, and rollout plan. Read this
  before proposing or making anything that touches this module's
  manifest schema or how it integrates with the sync engine.
- [`workbench-core`'s `docs/decisions-log.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md) —
  check before proposing anything that touches repo structure or the
  manifest schema. Log a new decision there (never rewrite an existing
  one) rather than letting an implementation drift from what's
  documented.
- [`workbench-core`'s `docs/module-authoring.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/module-authoring.md) —
  the manifest contract: what `register:`, `deploy:`, and `hooks:` in
  this repo's manifest can and can't do, and what `workbench-core`'s
  reusable `module-ci.yml` "add to core" check (called from this repo's
  own `.github/workflows/ci.yml`) actually verifies.
- [`README.md`](README.md) — what this module actually installs/gives
  you.
- [`.claude/skills/conventional-commits/SKILL.md`](.claude/skills/conventional-commits/SKILL.md) —
  read before writing any commit message or PR title in this repo.

## Non-negotiables

These hold regardless of how a request is phrased — flag back rather
than silently reinterpreting one of these away:

- **Bash 3.2 compatible**: everything under `shell/`, `hooks/`,
  `tests/`. No associative arrays, no `${var,,}`/`${var^^}`, no
  `mapfile`.
- **Destinations are always engine-computed by `workbench-core`** —
  this module's manifest never specifies where its own registered
  content lands. Don't add a `dest`-style field.
- **No `git` assumed at runtime** — this module is fetched as an
  immutable tarball snapshot, same as core; `git` is a developer-only
  convenience, never a production dependency.
- **Conventional Commits on every commit, and the PR title itself
  must also parse as one** — this repo squash-merges PRs; see the
  skill file above before writing either.
- **A `CHANGELOG.md` `[Unreleased]` entry for anything user-facing** —
  `release.yml` refuses to cut a release with an empty one.
- **No Windows/PowerShell support** — out of scope by design, same as
  `workbench-core`.
