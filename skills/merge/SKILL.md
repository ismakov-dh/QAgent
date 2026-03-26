---
name: merge
description: Merge discovered test cases from a feature branch into a target branch's qagent.json. Handles deduplication, scope classification, and interactive approval.
argument-hint: [target-branch]
allowed-tools: Read, Write, Bash, Grep, Glob
---

# QAgent Merge — Branch-Aware Test Case Merging

You merge test cases discovered on a feature branch into a target branch's test suite. You handle deduplication, scope classification, and interactive approval.

## Input

Arguments: `$ARGUMENTS`
- If a branch name is provided, use it as the target branch
- If no arguments, detect the default branch:
  1. Try `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'`
  2. Fall back to `main` (check with `git rev-parse --verify main 2>/dev/null`)
  3. Fall back to `master` (check with `git rev-parse --verify master 2>/dev/null`)
  4. If none exist, output error: "Could not determine target branch. Provide it as an argument: /qagent:merge <branch>" and stop.

## Phase 1: Pre-checks

### 1.1 Check dirty working tree

```bash
git diff --name-only -- qagent.json
git diff --cached --name-only -- qagent.json
```

If `qagent.json` has uncommitted changes, warn:
```
⚠ qagent.json has uncommitted changes. Continue anyway? [y/n]
```
If the user says no, stop.

### 1.2 Load current config

Read `qagent.json` from the current branch. Config discovery order: (1) current working directory, (2) nearest ancestor with `.git`.

### 1.3 Identify discovered flows

Get the current branch name:
```bash
git branch --show-current
```

Filter flows from `qagent.json` that have `branch` metadata matching the current branch name — these are flows discovered during this branch's development.

**Fallback:** If no flows match by `branch` field, find the merge-base commit date:
```bash
git log -1 --format=%cI $(git merge-base HEAD {target-branch})
```
Then check for flows with `discovered_at` timestamps after that date.

If no flows are found by either method:
```
No test cases discovered on this branch. Nothing to merge.
```
Stop.

### 1.4 Read target flows

Load the target branch's `qagent.json`:
```bash
git show {target-branch}:qagent.json 2>/dev/null
```

If that fails (branch not available locally):
```bash
git show origin/{target-branch}:qagent.json 2>/dev/null
```

If both fail, treat the target as having an empty `flows` array and inform the user:
```
Could not read qagent.json from {target-branch}. Treating target as empty (all flows will be added).
```

Parse the JSON and extract the `flows` array.

### 1.5 Check for non-flow config changes

Compare the current `qagent.json` against the target's version. If there are differences outside the `flows` array (e.g., `app.url`, `reporters`, `auth` changed), warn:
```
⚠ qagent.json has config changes beyond flows (app, reporters, etc.).
  These will be included when the branch merges. Review them separately.
```

## Phase 2: Classify & Deduplicate

### 2.1 Classify by scope

For each discovered flow:

| Scope | Action |
|-------|--------|
| `"general"` | Include in merge plan — this flow is useful everywhere |
| `"feature"` | Ask: "'{name}' is feature-scoped. Will it still be relevant after merge? [y/n/re-scope to general]" |
| No scope (default `"general"`) | Include in merge plan |

If the user says `n` to a feature-scoped flow, drop it from the merge plan.
If the user says `re-scope`, change its scope to `"general"`.

### 2.2 Deduplicate against target

Compare each flow proposed for merge against the target's existing flows:

- **Same `name`**: Skip. Inform: "'{name}' already exists in {target}, skipping."
- **Semantic similarity**: Judge whether two flows test the same behavior by comparing their step intents and overall purpose. If a discovered flow appears to duplicate an existing flow (same user journey, same verifications), flag it:
  ```
  '{discovered-name}' appears to test the same behavior as existing '{target-name}'.
  Replace / Skip / Add both?
  ```

## Phase 3: Present & Apply

### 3.1 Present merge plan

```
Merging test cases: {current-branch} → {target-branch}

Add ({N} general):
  1. "{name}" — {step count} steps, discovered by {discovered_by}
  2. ...

{If any feature-scoped decisions were made:}
Dropped ({N} feature-scoped):
  3. "{name}" — dropped by user

{If any duplicates were found:}
Skipped ({N} duplicates):
  4. "{name}" — duplicate of "{existing-name}"

Apply merge? [y/n]
```

If the user says no, stop without changes.

### 3.2 Clean up metadata

For each flow being merged, update metadata:
- `branch` → clear (set to `null` or remove the field — the flow now belongs to the target)
- `scope` → set to `"general"` (feature-scoped flows were either re-scoped or dropped)
- `discovered_by` → preserve (for history)
- `discovered_at` → preserve (for history)

### 3.3 Apply

Read current `qagent.json`, append the merged flows to the `flows` array, and write back. Only modify `flows` — never touch other config sections.

Output:
```
Merged {N} test cases into qagent.json.
{If on feature branch:} These will be included when {current-branch} merges into {target-branch}.
{If on target branch:} Test cases are now part of {target-branch}.
```

## Important Rules

- **NEVER** log or output secret values from `qagent.json`
- Only modify `flows` — never touch `app`, `auth`, `secrets`, `reporters`, or other config
- Always show the merge plan and get user approval before writing
- Semantic deduplication is a judgment call — when in doubt, flag it for the user
- If `qagent.json` doesn't exist, stop with error: "No qagent.json found."
