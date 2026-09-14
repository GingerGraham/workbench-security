---
name: conventional-commits
description: Use before writing any commit message or PR title in this module repo. Covers Conventional Commit grammar, why the PR title matters (squash-merge), and what type maps to what version-bump severity.
---

# Conventional Commits & PR titles — workbench module repos

This repo's release pipeline (`module-release.yml`, `workbench-core`'s
`.github/scripts/module-release/`) parses every commit and the PR title
as a Conventional Commit and takes the highest severity of any commit
since the last tag. There's a single overall module version — no
per-file versions, no `core` scope (those are `workbench-core`-only
concepts; see `workbench-core`'s `docs/decisions-log.md` D40).

## Type → severity

| `type` | Severity | Notes |
|---|---|---|
| `feat` | minor | |
| `fix`, `perf` | patch | |
| `refactor`, `docs`, `test`, `chore`, `ci`, `build` | none | informational only, no version effect |
| any type + `!` after type/scope, or a `BREAKING CHANGE:` footer | major | overrides the type's own severity |

Scope is optional and, unlike `workbench-core`, unvalidated — there's no
registered-file list to check it against. Omit it unless it genuinely
clarifies the subject.

## The PR title matters as much as the commit message

This repo squash-merges every PR. GitHub's squash commit message is the
PR *title*, not any individual commit's message — so the title needs
`type[(scope)][!]: subject` grammar too. A perfectly-formatted commit
inside a badly-titled PR still lands on `main` unparseable, and that
merge's severity is silently dropped — no version bump, no release, for
a real change. `pr-check.yml`'s "PR title format" job catches this
before merge; don't rely on it as the first time you check the title.

## Before opening the PR

- [ ] Every commit follows `type[(scope)][!]: subject`.
- [ ] The PR title itself is a valid Conventional Commit header.
- [ ] `CHANGELOG.md`'s `[Unreleased]` section has an entry for anything
      user-facing — the release workflow refuses to cut a release with
      an empty one.

Full mechanics live in `workbench-core`'s `docs/release-process.md` and
`docs/decisions-log.md` (D40, D47, D57).
