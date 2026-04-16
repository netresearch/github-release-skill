# Unified Eval Schema Design

**Date**: 2026-04-16
**Scope**: Eval format standardization across Netresearch skill repos
**Status**: Approved

## Problem

Three incompatible eval formats exist across ~37 Netresearch skill repos:

1. **Skill-repo format** (~18 repos): `name`/`prompt`/`assertions[{type,pattern}]` — regex-based
2. **Anthropic-like format** (~12 repos): `id`/`eval_name`/`prompt`/`expected_output`/`files`/`assertions` — mixed
3. **Orphan formats** (~2 repos): ad-hoc schemas that match neither

Anthropic's official skill-creator plugin defines a schema (`id`/`prompt`/`expected_output`/`expectations`/`files`) that none of our repos fully match. The skill-repo `validate-evals.sh` rejects Anthropic-format evals, and the `run-ab-evals.sh` runner only understands regex assertions.

## Decision

Adopt Anthropic's skill-creator schema as the canonical format. Extend it with optional regex assertions for fast/cheap automated checks. Support legacy formats during transition.

## Unified Schema

```json
{
  "skill_name": "example-skill",
  "evals": [
    {
      "id": 1,
      "prompt": "User's task prompt",
      "expected_output": "Human-readable description of correct behavior",
      "files": [],
      "expectations": [
        "The output explains why X is dangerous",
        "The output recommends Y as an alternative",
        "The output does not execute Z"
      ],
      "assertions": [
        {"type": "content", "pattern": "(?i)dangerous"},
        {"type": "content", "pattern": "(?i)recommend.*alternative"},
        {"type": "must_not", "pattern": "(?i)executed.*Z"}
      ]
    }
  ]
}
```

### Required Fields (Anthropic base)

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Unique, sequential (1-based) |
| `prompt` | string | The user input to evaluate |
| `expected_output` | string | Human-readable success description (for LLM grader and humans reading the eval) |
| `expectations` | string[] | Natural language verifiable statements (for LLM-as-judge grading) |

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `files` | string[] | Input fixture paths relative to skill root (Anthropic standard) |
| `assertions` | object[] | Regex patterns for fast automated checks (Netresearch extension) |

### Assertion Object

When `assertions` is present, each element has:

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | `"content"` (must match) or `"must_not"` (must not match) |
| `pattern` | string | Regex pattern to test against output |

### Wrapper Object

The top-level object has:

| Field | Type | Required |
|-------|------|----------|
| `skill_name` | string | Recommended (matches SKILL.md frontmatter `name`) |
| `evals` | array | Required |

A top-level array (no wrapper) is accepted for backward compatibility but deprecated for new evals.

## Grading Modes

The runner selects grading mode based on which fields are present:

| Fields present | Grading mode | Speed | Cost |
|----------------|-------------|-------|------|
| `assertions` only | Regex matching | Instant | Free |
| `expectations` only | LLM-as-judge | ~5s/eval | API call |
| Both | Regex + LLM | ~5s/eval | API call |

When both are present, regex assertions run first (fast fail). LLM grading runs only if regex passes, providing qualitative assessment on top of the deterministic checks.

## Validation Rules (validate-evals.sh)

### Format Detection

The validator accepts three input shapes:

1. **Unified/Anthropic** (recommended): `{"skill_name": "...", "evals": [...]}`
2. **Legacy object**: `{"evals": [...]}` (no `skill_name`)
3. **Legacy array**: `[...]` (top-level array, deprecated)

### Per-Eval Validation

| Check | Rule |
|-------|------|
| Identity | Must have `id` (integer) OR `name`/`eval_name` (string) |
| Prompt | `prompt` must be non-empty string |
| Grading | Must have `expectations` (string[], 2+ items) OR `assertions` (object[], 2+ items) — or both |
| Expected output | `expected_output` recommended (warn if missing) |
| Assertions format | If `assertions` present, each must have `type` and `pattern` |
| Expectations format | If `expectations` present, each must be a non-empty string |

### Global Validation

| Check | Rule |
|-------|------|
| Minimum count | 10+ evals required, 15+ recommended |
| Unique identifiers | No duplicate `id` or `name` values |
| Sequential IDs | If using integer `id`, must be sequential (1-based) |

### Legacy Field Mapping

During transition, the validator maps legacy fields:

| Legacy field | Maps to | Notes |
|-------------|---------|-------|
| `name` | `id` (as string) | Accepted as identifier |
| `eval_name` | display name | Accepted as identifier |
| `input` | `prompt` | Rare orphan format |
| `expected.assertions` | `expectations` | Rare orphan format |

## Migration Path

### Phase 1: Immediate

- Update `validate-evals.sh` to accept `expectations` as valid alternative to `assertions`
- Convert github-release evals to unified format (both `expectations` and `assertions`)
- Document the unified schema in skill-repo SKILL.md

### Phase 2: Gradual (when skills are touched)

- New skills use Anthropic format with optional `assertions`
- Existing skills add `expectations` alongside `assertions` when modified
- A/B runner gains LLM grader path for `expectations`

### Phase 3: Eventual

- `assertions`-only evals emit deprecation warning in validator
- Both assertion types remain functional indefinitely
- Regex assertions remain useful for deterministic checks even in fully migrated evals

## Affected Repos

| Repo | Change |
|------|--------|
| `skill-repo-skill` | Update `validate-evals.sh`, `run-ab-evals.sh`, SKILL.md docs |
| `github-release-skill` | Convert evals to unified format |
| All other skill repos | No immediate changes required — migrate when touched |

## Rationale

1. **Anthropic is upstream** — their skill-creator is the official tool for building and testing skills. Alignment means their tooling (grader, viewer, benchmarks) works with our evals.
2. **LLM-as-judge is more robust** — regex patterns are fragile against LLM output variance (word order, phrasing, synonyms). Natural language expectations handle this naturally.
3. **Regex still has value** — deterministic checks ("did it run command X", "did it NOT execute Y") are faster and cheaper via regex. The unified schema supports both.
4. **Already split** — ~12 repos are close to Anthropic's format. Consolidating toward it is less migration than away from it.
5. **Backward compatible** — the validator supports all existing formats. No repo breaks.
