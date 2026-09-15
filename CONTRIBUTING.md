# Contributing to workbench-security

This is a `workbench` ecosystem module — it doesn't stand alone. It's
installed into a machine via `workbench-core`'s `wb add security`. Full
design rationale lives in `workbench-core`'s
[`docs/architecture.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/architecture.md)
and [`docs/decisions-log.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md)
— check both before proposing anything that touches this module's
manifest schema or how it integrates with the sync engine.

## Non-negotiables

- **Bash 3.2 compatible** — see [below](#bash-32-compatibility).
- **Destinations are always engine-computed by `workbench-core`** — this
  module's manifest never specifies where its own registered content
  lands. Don't add a `dest`-style field to `register.shell[]` entries.
- **No `git` assumed at runtime** — this module is fetched as an
  immutable tarball snapshot; `git` is a developer-only convenience.
- **No Windows/PowerShell support** — out of scope by design, same as
  `workbench-core`.

## Dev setup

This repo isn't installed standalone. To develop against your own
working branch, from a machine that already has `workbench-core`
installed:

```sh
git clone https://github.com/GingerGraham/workbench-security.git
cd workbench-security

# if not already registered on this machine:
wb add security

# point this module's tracking at your working branch:
wb dev security
# — or directly:
wb track security --branch <your-branch>
```

`wb dev`/`wb track --branch` fetches a **separate**, independently
synced snapshot of your branch — your own editing clone and
workbench's fetched snapshot are two copies on disk by design, not
drift. See `workbench-core`'s `docs/architecture.md` §9.6.

## Making a change

### Commit messages

Every commit is [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>[!]: <subject>

[optional body]

[BREAKING CHANGE: <description>]
```

- `type` is one of `feat` (minor bump), `fix`/`perf` (patch bump), or
  `refactor`/`docs`/`test`/`chore`/`ci`/`build` (no version effect).
- A `!` right after `type`, or a `BREAKING CHANGE:` footer, forces
  **major** regardless of `type`.
- No `scope` convention here — unlike `workbench-core`, this repo has no
  per-file registered-script version to bump individually, so there's
  nothing for a scope to disambiguate.
- This repo squash-merges PRs, and the **PR title itself** must also
  parse as Conventional Commits — `module-pr-check.yml`'s
  `pr-title-format` job fails the PR otherwise.

### CHANGELOG

Add an entry to `CHANGELOG.md`'s `## [Unreleased]` section, under the
[Keep a Changelog](https://keepachangelog.com/) heading it belongs
under, in the same PR that makes the change. `release.yml` refuses to
cut a release if a real version bump is pending but `[Unreleased]` is
still empty.

### Tests

If this module has a `tests/` suite, run its `check-*.sh` scripts
directly before pushing — `module-ci.yml` runs the same suite on
`ubuntu-latest` and `macos-latest`. Validate the manifest with
`lib/manifest/validate.sh` from a `workbench-core` checkout (or let CI
do it for you).

### Bash 3.2 compatibility

Everything under `shell/`, `tests/` must run under Bash 3.2:
no associative arrays, no `${var,,}`/`${var^^}`, no `mapfile`. This
mirrors `workbench-core`'s own constraint — see its `CONTRIBUTING.md`
for the full rationale.
