# Unified Eval Schema Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `validate-evals.sh` accept Anthropic's `expectations` field as a valid alternative to regex `assertions`, then convert the github-release evals to the unified format.

**Architecture:** The validator's Python block gets a new code path that checks for `expectations` (string list) when `assertions` is missing. The github-release evals.json is rewritten from the orphan format to the unified schema with both `expectations` and `assertions`.

**Tech Stack:** Bash, Python 3 (inline in validate-evals.sh), JSON

---

### Task 1: Update validate-evals.sh — accept `expectations` as alternative to `assertions`

**Files:**
- Modify: `/home/sme/p/skill-repo-skill/main/skills/skill-repo/scripts/validate-evals.sh:94-153` (Python block, per-eval validation)

- [ ] **Step 1: Create feature branch in skill-repo-skill**

```bash
cd /home/sme/p/skill-repo-skill/.bare
git worktree add ../fix/unified-eval-schema -b fix/unified-eval-schema main
cd /home/sme/p/skill-repo-skill/fix/unified-eval-schema
```

- [ ] **Step 2: Write test — validate-evals.sh accepts expectations-only eval**

Create a test fixture at `tests/evals-expectations-only.json`:

```json
{
  "skill_name": "test-skill",
  "evals": [
    {
      "id": 1,
      "prompt": "Test prompt one",
      "expected_output": "Should do X",
      "expectations": [
        "The output explains X",
        "The output recommends Y"
      ]
    },
    {
      "id": 2,
      "prompt": "Test prompt two",
      "expected_output": "Should do Y",
      "expectations": [
        "The output contains A",
        "The output avoids B"
      ]
    },
    {
      "id": 3,
      "prompt": "Test prompt three",
      "expected_output": "Should do Z",
      "expectations": [
        "First expectation",
        "Second expectation"
      ]
    },
    {
      "id": 4,
      "prompt": "Test prompt four",
      "expected_output": "Should do W",
      "expectations": [
        "First expectation",
        "Second expectation"
      ]
    },
    {
      "id": 5,
      "prompt": "Test prompt five",
      "expected_output": "Should do V",
      "expectations": [
        "First expectation",
        "Second expectation"
      ]
    },
    {
      "id": 6,
      "prompt": "Test prompt six",
      "expected_output": "Should do U",
      "expectations": [
        "First expectation",
        "Second expectation"
      ]
    },
    {
      "id": 7,
      "prompt": "Test prompt seven",
      "expected_output": "Should do T",
      "expectations": [
        "First expectation",
        "Second expectation"
      ]
    },
    {
      "id": 8,
      "prompt": "Test prompt eight",
      "expected_output": "Should do S",
      "expectations": [
        "First expectation",
        "Second expectation"
      ]
    },
    {
      "id": 9,
      "prompt": "Test prompt nine",
      "expected_output": "Should do R",
      "expectations": [
        "First expectation",
        "Second expectation"
      ]
    },
    {
      "id": 10,
      "prompt": "Test prompt ten",
      "expected_output": "Should do Q",
      "expectations": [
        "First expectation",
        "Second expectation"
      ]
    }
  ]
}
```

- [ ] **Step 3: Run test to verify it fails with current validator**

```bash
bash skills/skill-repo/scripts/validate-evals.sh tests/evals-expectations-only.json
```

Expected: FAIL — `missing assertions` for every eval.

- [ ] **Step 4: Write test fixture — unified format (both expectations and assertions)**

Create `tests/evals-unified.json`:

```json
{
  "skill_name": "test-skill",
  "evals": [
    {
      "id": 1,
      "prompt": "Test prompt one",
      "expected_output": "Should do X",
      "expectations": [
        "The output explains X",
        "The output recommends Y"
      ],
      "assertions": [
        {"type": "content", "pattern": "(?i)explains.*X"},
        {"type": "must_not", "pattern": "(?i)ignores.*X"}
      ]
    },
    {
      "id": 2,
      "prompt": "Test prompt two",
      "expected_output": "Should do Y",
      "expectations": [
        "The output contains A",
        "The output avoids B"
      ],
      "assertions": [
        {"type": "content", "pattern": "(?i)contains.*A"}
      ]
    },
    {
      "id": 3,
      "prompt": "Test prompt three",
      "expected_output": "Should do Z",
      "expectations": ["First", "Second"]
    },
    {"id": 4, "prompt": "P4", "expected_output": "E4", "expectations": ["A", "B"]},
    {"id": 5, "prompt": "P5", "expected_output": "E5", "expectations": ["A", "B"]},
    {"id": 6, "prompt": "P6", "expected_output": "E6", "expectations": ["A", "B"]},
    {"id": 7, "prompt": "P7", "expected_output": "E7", "expectations": ["A", "B"]},
    {"id": 8, "prompt": "P8", "expected_output": "E8", "expectations": ["A", "B"]},
    {"id": 9, "prompt": "P9", "expected_output": "E9", "expectations": ["A", "B"]},
    {"id": 10, "prompt": "P10", "expected_output": "E10", "expectations": ["A", "B"]}
  ]
}
```

- [ ] **Step 5: Write test fixture — legacy format still works**

Create `tests/evals-legacy-regex.json`:

```json
[
  {"name": "test_1", "prompt": "Do X", "assertions": [{"type": "content", "pattern": "X"}, {"type": "content", "pattern": "Y"}]},
  {"name": "test_2", "prompt": "Do Y", "assertions": [{"type": "content", "pattern": "A"}, {"type": "content", "pattern": "B"}]},
  {"name": "test_3", "prompt": "Do Z", "assertions": [{"type": "content", "pattern": "C"}, {"type": "content", "pattern": "D"}]},
  {"name": "test_4", "prompt": "P4", "assertions": [{"type": "content", "pattern": "E"}, {"type": "content", "pattern": "F"}]},
  {"name": "test_5", "prompt": "P5", "assertions": [{"type": "content", "pattern": "G"}, {"type": "content", "pattern": "H"}]},
  {"name": "test_6", "prompt": "P6", "assertions": [{"type": "content", "pattern": "I"}, {"type": "content", "pattern": "J"}]},
  {"name": "test_7", "prompt": "P7", "assertions": [{"type": "content", "pattern": "K"}, {"type": "content", "pattern": "L"}]},
  {"name": "test_8", "prompt": "P8", "assertions": [{"type": "content", "pattern": "M"}, {"type": "content", "pattern": "N"}]},
  {"name": "test_9", "prompt": "P9", "assertions": [{"type": "content", "pattern": "O"}, {"type": "content", "pattern": "P"}]},
  {"name": "test_10", "prompt": "P10", "assertions": [{"type": "content", "pattern": "Q"}, {"type": "content", "pattern": "R"}]}
]
```

- [ ] **Step 6: Update the Python validation block in validate-evals.sh**

Replace the per-eval validation section (lines 94-153) in `skills/skill-repo/scripts/validate-evals.sh`. The key change: the `assertions` check becomes "must have `expectations` OR `assertions` (or both)":

```python
for i, ev in enumerate(evals):
    label = f"eval[{i}]"

    if not isinstance(ev, dict):
        print(f"FAIL|{label}: not an object")
        continue

    # Name/ID check (supports 'name', 'eval_name', or 'id')
    name = ev.get("name") or ev.get("eval_name") or ""
    has_id = "id" in ev
    if has_id:
        has_ids = True
        ids_found.append(ev["id"])
        if not name:
            name = str(ev["id"])
    if not name and not has_id:
        print(f"FAIL|{label}: missing name/eval_name/id")
    elif name:
        names.append(str(name).strip())

    # Prompt check (supports 'prompt' and legacy 'input')
    prompt = ev.get("prompt") or ev.get("input") or ""
    if not prompt or not str(prompt).strip():
        print(f"FAIL|{label} ({name}): missing or empty prompt")
    else:
        print(f"PASS|{label} ({name}): has prompt")

    # expected_output check (recommended, not required)
    if not ev.get("expected_output"):
        print(f"WARN|{label} ({name}): missing expected_output (recommended)")

    # Grading check: must have expectations OR assertions (or both)
    expectations = ev.get("expectations")
    assertions = ev.get("assertions")
    has_expectations = isinstance(expectations, list) and len(expectations) > 0
    has_assertions = isinstance(assertions, list) and len(assertions) > 0

    if not has_expectations and not has_assertions:
        print(f"FAIL|{label} ({name}): missing both expectations and assertions (need at least one)")
        continue

    # Validate expectations (natural language strings)
    if has_expectations:
        if len(expectations) < 2:
            print(f"FAIL|{label} ({name}): has {len(expectations)} expectations, need >= 2")
        else:
            empty_exp = sum(1 for e in expectations if not isinstance(e, str) or not e.strip())
            if empty_exp > 0:
                print(f"FAIL|{label} ({name}): {empty_exp} empty/invalid expectation(s)")
            else:
                print(f"PASS|{label} ({name}): {len(expectations)} valid expectations")

    # Validate assertions (regex patterns)
    if has_assertions:
        if len(assertions) < 2:
            print(f"FAIL|{label} ({name}): has {len(assertions)} assertions, need >= 2")
        else:
            empty_assertions = 0
            for j, a in enumerate(assertions):
                if isinstance(a, str):
                    if not a.strip():
                        empty_assertions += 1
                elif isinstance(a, dict):
                    if "type" not in a:
                        print(f"FAIL|{label} ({name}): assertion[{j}] missing 'type'")
                    val = a.get("value") or a.get("pattern") or ""
                    if not str(val).strip():
                        print(f"FAIL|{label} ({name}): assertion[{j}] missing 'value' or 'pattern'")
                else:
                    print(f"FAIL|{label} ({name}): assertion[{j}] invalid type (not string or object)")

            if empty_assertions > 0:
                print(f"FAIL|{label} ({name}): {empty_assertions} empty string assertion(s)")
            else:
                print(f"PASS|{label} ({name}): {len(assertions)} valid assertions")
```

- [ ] **Step 7: Update the header comment in validate-evals.sh**

```bash
# validate-evals.sh - Structural validation of evals.json files
# Supports three formats:
#   Unified (recommended): {"skill_name": "...", "evals": [{id, prompt, expected_output, expectations, assertions?}]}
#   Legacy A: {"evals": [{eval_name, prompt, assertions}]}
#   Legacy B: [{name, prompt, assertions: [{type, pattern}]}]
#
# Grading fields: expectations (natural language, for LLM grading) and/or assertions (regex, for automated checks)
# At least one of expectations or assertions is required per eval.
```

- [ ] **Step 8: Run all three test fixtures**

```bash
bash skills/skill-repo/scripts/validate-evals.sh tests/evals-expectations-only.json
# Expected: PASS (all expectations valid)

bash skills/skill-repo/scripts/validate-evals.sh tests/evals-unified.json
# Expected: PASS (both expectations and assertions valid)

bash skills/skill-repo/scripts/validate-evals.sh tests/evals-legacy-regex.json
# Expected: PASS (legacy format still works)
```

- [ ] **Step 9: Run against existing skill-repo evals to verify no regression**

```bash
bash skills/skill-repo/scripts/validate-evals.sh skills/skill-repo/evals/evals.json
# Expected: PASS (existing evals unchanged)
```

- [ ] **Step 10: Commit**

```bash
git add skills/skill-repo/scripts/validate-evals.sh tests/
git commit -m "feat: accept expectations as alternative to assertions in eval validation

Implements the unified eval schema (spec: 2026-04-16). The validator
now accepts Anthropic's expectations field (natural language strings
for LLM-as-judge grading) as an alternative to regex assertions.
Both can coexist in the same eval. Legacy formats remain supported."
```

---

### Task 2: Convert github-release evals to unified format

**Files:**
- Rewrite: `/home/sme/p/github-release-skill/fix/release-description-overhaul/skills/github-release/evals/evals.json`

- [ ] **Step 1: Write a conversion script**

Create `/home/sme/p/github-release-skill/fix/release-description-overhaul/scripts/convert-evals.py`:

```python
#!/usr/bin/env python3
"""Convert github-release evals from orphan format to unified schema."""
import json
import re
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

converted = []
for i, e in enumerate(data["evals"], 1):
    new_eval = {
        "id": i,
        "prompt": e.get("input", e.get("prompt", "")),
        "expected_output": e.get("expected", {}).get("behavior", ""),
        "expectations": [],
        "assertions": [],
    }

    # Convert expected.assertions -> expectations (natural language)
    for text in e.get("expected", {}).get("assertions", []):
        new_eval["expectations"].append(text)

    # Convert expected.must_not -> expectations with "does NOT" phrasing
    for text in e.get("expected", {}).get("must_not", []):
        new_eval["expectations"].append(f"Does NOT: {text}")

    # Generate regex assertions from the natural language expectations
    # These are best-effort deterministic checks alongside the expectations
    skip_words = {
        "mentions", "explains", "uses", "creates", "checks", "reports",
        "identifies", "detects", "recommends", "provides", "shows",
        "includes", "lists", "finds", "reads", "extracts", "compares",
        "blocks", "follows", "marks", "recognizes", "covers", "verifies",
        "discusses", "updates", "ensures", "the", "a", "an", "and", "or",
        "for", "with", "that", "is", "in", "of", "to", "all", "as",
    }

    for text in e.get("expected", {}).get("assertions", []):
        clean = re.sub(r"[^a-zA-Z0-9 _-]", "", text.lower())
        words = [w for w in clean.split() if w not in skip_words and len(w) > 2]
        if len(words) >= 2:
            pattern = "(?i)" + ".*".join(words[:3])
        elif words:
            pattern = "(?i)" + words[0]
        else:
            continue
        new_eval["assertions"].append({"type": "content", "pattern": pattern})

    for text in e.get("expected", {}).get("must_not", []):
        clean = re.sub(r"[^a-zA-Z0-9 _-]", "", text.lower())
        words = [w for w in clean.split() if w not in skip_words and len(w) > 2]
        if len(words) >= 2:
            pattern = "(?i)" + ".*".join(words[:3])
            new_eval["assertions"].append({"type": "must_not", "pattern": pattern})

    converted.append(new_eval)

output = {"skill_name": "github-release", "evals": converted}
print(json.dumps(output, indent=2))
```

- [ ] **Step 2: Run conversion**

```bash
cd /home/sme/p/github-release-skill/fix/release-description-overhaul
python3 scripts/convert-evals.py skills/github-release/evals/evals.json > /tmp/evals-converted.json
```

- [ ] **Step 3: Validate converted output against updated validator**

```bash
bash /home/sme/p/skill-repo-skill/fix/unified-eval-schema/skills/skill-repo/scripts/validate-evals.sh /tmp/evals-converted.json
```

Expected: PASS

- [ ] **Step 4: Review and hand-edit the converted evals**

Open `/tmp/evals-converted.json` and review:
- Are the auto-generated regex assertions reasonable? Remove any that are too vague.
- Are the expectations clear natural language? Edit any that read awkwardly.
- Verify the `expected_output` field captures the intent.

Copy the reviewed file into place:

```bash
cp /tmp/evals-converted.json skills/github-release/evals/evals.json
```

- [ ] **Step 5: Validate the final evals in-place**

```bash
bash /home/sme/p/skill-repo-skill/fix/unified-eval-schema/skills/skill-repo/scripts/validate-evals.sh skills/github-release/evals/evals.json
```

Expected: PASS

- [ ] **Step 6: Clean up conversion script**

```bash
rm scripts/convert-evals.py
```

- [ ] **Step 7: Commit**

```bash
git add skills/github-release/evals/evals.json
git commit -m "feat: convert evals to unified schema (Anthropic + regex)

Evals now use the unified format with both expectations (natural
language for LLM grading) and assertions (regex for fast checks).
Converted from orphan format (id/input/expected) to Anthropic-
compatible schema (id/prompt/expected_output/expectations)."
```

---

### Task 3: Push and verify CI for both repos

- [ ] **Step 1: Push skill-repo-skill branch**

```bash
cd /home/sme/p/skill-repo-skill/fix/unified-eval-schema
git push origin fix/unified-eval-schema
```

- [ ] **Step 2: Push github-release-skill branch (already exists)**

```bash
cd /home/sme/p/github-release-skill/fix/release-description-overhaul
git push origin fix/release-description-overhaul
```

- [ ] **Step 3: Create PR for skill-repo-skill**

```bash
cd /home/sme/p/skill-repo-skill/fix/unified-eval-schema
gh pr create --title "feat: accept expectations field in eval validation" --body "$(cat <<'EOF'
## Summary

- `validate-evals.sh` now accepts `expectations` (string list) as an alternative to `assertions` (regex objects)
- Both can coexist in the same eval — the unified schema from the design spec
- Legacy formats (skill-repo regex, Anthropic-like) continue to pass
- Adds test fixtures for expectations-only, unified, and legacy formats

## Context

Design spec: github-release-skill docs/superpowers/specs/2026-04-16-unified-eval-schema-design.md

## Test plan

- [ ] Expectations-only evals pass validation
- [ ] Unified evals (both expectations + assertions) pass validation
- [ ] Legacy regex evals still pass (no regression)
- [ ] Existing skill-repo evals still pass
EOF
)"
```

- [ ] **Step 4: Verify CI passes on both PRs**

```bash
cd /home/sme/p/skill-repo-skill/fix/unified-eval-schema
gh run list --limit 3

cd /home/sme/p/github-release-skill/fix/release-description-overhaul
gh pr checks 2
```
