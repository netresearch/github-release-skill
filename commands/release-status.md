---
name: release-status
description: "Check release health: tag types, release assets, workflow status, version sync"
---

# Release Health Check

Inspect the current project's release infrastructure and report overall health.

## Steps

### 1. List recent releases

Run:
```bash
gh release list --limit 10
```

Report each release with its tag, title, date, and asset count.

### 2. Check tag types

Run:
```bash
git for-each-ref refs/tags/v* --format='%(objecttype) %(refname:short)'
```

Flag any tags with objecttype `commit` -- these are **lightweight** (unsigned) tags,
which is a problem. Tags should have objecttype `tag` (annotated/signed).

### 3. Check release workflow runs

Run:
```bash
gh run list --workflow=release.yml --limit 5
```

Report status of recent release workflow runs. Flag any failures.

### 4. Check version file sync

Run `detect-ecosystem.sh` from the skill's scripts directory. Compare the version
reported across all detected version files. Flag any mismatches.

### 5. Validate CI setup

Run `check-release-workflow.sh` from the skill's scripts directory to verify the
release workflow exists and is properly configured.

### 6. Check for burned tags

Look for draft releases that reference tags already pushed. These represent
"burned" tags where the release cannot simply be re-published -- the tag would
need to be deleted and recreated, which causes problems for anyone who already
fetched it.

```bash
gh release list --limit 20 | grep -i draft
```

### 7. Report overall health

Summarize findings with an overall status:

- **GREEN**: All checks pass. Tags are signed, versions are in sync, CI is healthy.
- **YELLOW**: Warnings present. Some lightweight tags, minor version drift, or
  workflow warnings exist but releases are functional.
- **RED**: Broken. Missing release workflow, failed runs, version mismatches
  across files, or burned tags that need manual intervention.

List specific action items for any YELLOW or RED findings.
