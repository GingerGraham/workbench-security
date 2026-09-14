# Copilot instructions — workbench-security

Adapted from `AGENTS.md` at the repo root — same content, with this
file's own preface and its relative links path-adjusted for its
location under `.github/`. Copilot's various surfaces (CLI, coding
agent, Chat, code review) don't uniformly discover a root `AGENTS.md`,
so this is a deliberate, maintained duplicate — see `workbench-core`'s
`docs/decisions-log.md` D32 and D58. `AGENTS.md` is always the
canonical, current version; if the two ever disagree, update this file
to match it rather than treating the drift as acceptable.

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
  this repo's manifest can and can't do, and what `module-ci.yml`'s
  "add to core" check actually verifies.
- [`README.md`](../README.md) — what this module actually
  installs/gives you.
- [`.claude/skills/conventional-commits/SKILL.md`](../.claude/skills/conventional-commits/SKILL.md) —
  read before writing any commit message or PR title in this repo.

## Non-negotiables

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
