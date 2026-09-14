## Summary

<!-- What does this change do, and why? -->

## Related

<!-- Issue link, and/or the workbench-core docs/decisions-log.md decision
     this implements or requires. Leave blank if neither applies. -->

## Type of change

- [ ] `feat` — new capability (minor bump)
- [ ] `fix` / `perf` — bug fix or performance fix (patch bump)
- [ ] `refactor` / `docs` / `test` / `chore` / `ci` / `build` — no version effect
- [ ] Breaking change (`!` after type, or a `BREAKING CHANGE:` footer)

## Checklist

- [ ] Every commit follows Conventional Commits, and the **PR title**
      itself parses too — this repo squash-merges, and
      `module-pr-check.yml`'s `pr-title-format` job fails the PR
      otherwise. See [`CONTRIBUTING.md`](../CONTRIBUTING.md).
- [ ] If this is user-facing, `CHANGELOG.md`'s `## [Unreleased]` has a
      new entry under the right heading — `release.yml` refuses to cut
      a release with an empty one.
- [ ] `tests/check-*.sh` pass locally, if this module has any, and a
      new/updated suite exists if behaviour changed.
- [ ] `shellcheck shell/**/*.sh` is clean.
- [ ] Everything under `shell/`, `tests/` stays Bash 3.2
      compatible — see [`CONTRIBUTING.md`](../CONTRIBUTING.md#bash-32-compatibility).
- [ ] If this touches repo structure, the manifest schema, or the sync
      engine, `workbench-core`'s
      [`docs/decisions-log.md`](https://github.com/GingerGraham/workbench-core/blob/main/docs/decisions-log.md)
      has been checked for an existing decision.
- [ ] `README.md` updated if behaviour changed.

## How was this tested?

<!-- Manual steps, or "covered by tests/check-whatever.sh" -->
