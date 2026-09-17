# npm staged publishing

`npm stage publish` puts a version into npm's staging area instead of the
registry. It is not installable there. A maintainer approves it later with 2FA,
which is the point: an automated workflow can produce a release without holding
a credential that can publish on its own.

Everything below is from `npm-stage(1)` as shipped with npm 12.0.2, and from
`lib/commands/stage/` in the same installation. Read the page in your own npm
before relying on a detail — this is a young feature.

## Which npm, which Node

`npm stage` first shipped in **npm 11.15.0**. Nothing older has the command at
all, under any auth mode.

A CI job usually does not install npm separately, it uses whatever Node bundles.
That bundled version is what decides:

| Node | bundled npm | `npm stage` |
| --- | --- | --- |
| 22.23.2 (latest v22) | 10.9.8 | absent |
| 24.18.0 | 11.16.0 | present |
| 24.21.0 (latest v24) | 11.19.0 | present |

npm 11.15.0 itself runs on Node `^20.17.0 || >=22.9.0`, so "Node 22 cannot stage"
is a statement about the bundled npm, not about npm. Say it that way — a caller
reading the other version will try to fix it by upgrading npm inside a Node 22
job, which also works and is a different change.

Two floors, not one, if the same job also publishes over OIDC: Trusted
Publishing needs npm >= 11.5.1 on Node >= 22.14, which is stricter than npm's
own engine range. A workflow doing both is governed by whichever floor is
higher, and on the usual Node 24 default both are satisfied without thinking
about it.

Version data above is from `https://nodejs.org/dist/index.json`, which carries
an `npm` field per release. Re-derive it rather than trusting this table.

## The two states a release workflow walks into

**A package that does not exist cannot be staged.** `npm-stage(1)` lists under
Prerequisites: *"Package must exist: The package you're configuring must already
exist on the npm registry."* So the first-ever publish of a new package has to
go out directly, and staging starts with the second release. A workflow that
stages by default needs an opt-out for that one run, and is friendlier if it
says so before the publish rather than letting the registry refuse.

The check is an unauthenticated GET of `https://registry.npmjs.org/<name>` —
200 means it exists, 404 means it does not. Treat every other status as "the
registry did not answer", never as "the package is new": a rate limit or a 5xx
otherwise turns into an error message telling the maintainer their package does
not exist.

**That probe is only valid for a public package.** A restricted one is not
publicly readable, so the unauthenticated request returns 404 for a package that
exists — and the guard then tells the maintainer to do a first-ever direct
publish of something already published. Gate the check on the access level and
skip it where the package is restricted, or authenticate the request. Skipping
loses nothing that matters: the guard exists to turn npm's refusal into a
clearer message, and without it the refusal still arrives, just less legibly.

**A version that is already staged cannot be staged again.** *"Staged packages
share the same semver version unique index as published packages — you cannot
publish a version that already exists as a staged version for that package."*
This collides with the usual "skip if already published" guard, which probes the
public registry and cannot see a staged version. So re-running a release whose
approval is still pending fails, and the failure looks like an ordinary publish
error.

It cannot be pre-empted from an OIDC job: *"Shortlived tokens cannot run `npm
stage` subcommands"*, so `npm stage list` is unavailable exactly where the guard
would run. The honest handling is to catch the failure and name the cause —
approve or reject the pending stage, do not re-run — rather than to pattern-match
npm's error body for a code nobody has measured.

## Auth

Staging works with every token type. The page is explicit: *"The act of staging
does not prompt for 2FA and can be done with any token type"*, and its table
lists GAT with bypass, GAT without bypass, session token and trust token (OIDC)
as all able to stage. Only `npm stage approve` and `npm stage reject` require
2FA.

What a trusted publisher permits is a per-publisher setting, and the two answers
differ by age. A publisher created in the npmjs.com UI today shows, verbatim:
*"npm stage publish is always allowed. Choose whether this trusted publisher can
also publish directly."* — with the direct-publish box unchecked and annotated
*"Not recommended. For stronger security, leave unchecked to allow staged
publishing only."* Configurations that predate staging allow `npm publish`
instead, so an older publisher behaves the opposite way. Do not infer either
from the other: open the publisher and read its allowed actions.

A stage-only publisher — direct publish not allowed — fails a direct publish
with:

```
E403 … OIDC permission denied for this action
```

That message reads like a misconfigured publisher and is not one. Staging is not
unconditional in principle either — `npm trust <provider>` has `--allow-publish`
and `--allow-stage-publish` — but the UI's default is stage-only.

## Parity with `npm publish`

`StagePublish extends Publish` and sets `static stage = true`, inheriting
`static params` wholesale (`lib/commands/stage/publish.js`). `--access`,
`--provenance` and the OIDC exchange behave identically; provenance is signed
and logged to the transparency log at stage time, not at approval.

Prerelease versions need an explicit `--tag`, and the page says this works *"just
as `npm publish` would"* — so a workflow that already handles it needs no change,
and one that does not was already broken for prereleases.

The tag is immutable once staged. Re-staging the same version under a different
tag means rejecting the staged one first.

## Getting the stage id out

The maintainer who approves needs the id. On success npm prints:

```
+ <pkg>@<version> (staged with id <uuid>)
```

— but only in text mode. Under `--json` the id arrives as the `stageId` field of
the JSON object instead (`lib/commands/publish.js` puts it there and suppresses
the human line), so a regex written for the text form silently yields nothing on
a publish that succeeded. Pin the output format for this one command rather than
inheriting whatever the caller's argument list carries, or parse both shapes.

The id is a UUID (`lib/utils/validate-uuid.js`). Capture it from that line and
hand it on — a notice, a job summary with the ready-to-run command, a job
output. `npm stage list <pkg>` finds it afterwards, but not from the job that
staged it, because of the shortlived-token restriction above.

**Capturing it must not be able to fail the step.** This is the trap worth
stating on its own:

```bash
if OUT="$(npm stage publish "${ARGS[@]}" 2>&1)"; then
  printf '%s\n' "$OUT"
  # `|| true` is load-bearing: grep exits 1 when it matches nothing, and under
  # `set -o pipefail` that aborts the step AFTER the version was staged — the
  # one moment a re-run cannot recover from, because it cannot stage again.
  STAGE_ID="$(printf '%s' "$OUT" | grep -oE 'staged with id [0-9a-f-]{36}' \
    | awk '{ print $NF }' | head -n1 || true)"
  …
fi
```

The general form: any extraction placed after an irreversible action must be
unable to abort the step. Write the branch where the extraction finds nothing,
then exercise it — a stub that prints the success line without an id is enough,
and it is how this defect was found rather than argued.

## What staging changes about the release, and what it does not

A workflow that creates a GitHub Release after the publish job now creates it
when the version is **staged**, before it is installable. GitHub releases are
immutable, so a stage that is never approved — or one that is rejected — leaves
the tag burned with nothing on the registry. Recovery is a new version.

GitHub Packages has no staging. It is an npmjs.com feature, so a second publish
pass against `npm.pkg.github.com` stays a plain `npm publish`, and that
asymmetry is deliberate.

The npmjs.com package page is CDN-cached and can keep showing the previous
version for a while after an approval. The registry is authoritative:
`npm view <pkg> version`, or `https://registry.npmjs.org/<pkg>`.

## Approval

```bash
npm stage list <pkg>            # find the id
npm stage view <stage-id>       # inspect
npm stage download <stage-id>   # fetch the tarball before approving
npm stage approve <stage-id>    # 2FA
npm stage reject <stage-id>     # 2FA
```

`approve` routes through `otplease()` (`lib/commands/stage/approve.js`), so the
registry's 2FA challenge is what makes it interactive. `--otp` takes a code
non-interactively, which is a way to move the credential into CI and give up the
property staging exists for. It is not automation, it is the same bypass under a
different name.
