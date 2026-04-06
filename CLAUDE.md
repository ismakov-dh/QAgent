# QAgent — Agent Instructions

## Version Management

Every change that modifies plugin behavior must include a version bump in `.claude-plugin/plugin.json`. Follow [semver](https://semver.org/):

- **MAJOR** (1.0.0) — breaking changes to config format, removed skills, renamed fields
- **MINOR** (0.X.0) — new skills, new config options, new features
- **PATCH** (0.0.X) — bug fixes, doc updates that fix incorrect behavior, wording fixes in skills that change runtime behavior

Do NOT bump for: README changes, spec/plan docs, comments-only changes, .gitignore updates.

Bump in a separate commit: `chore: bump version to X.Y.Z` with a one-line summary of what changed.
