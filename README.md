# safe-chain-action

Supply-chain PR gate built on [Aikido Safe Chain](https://github.com/AikidoSec/safe-chain).
Blocks a pull request when its dependency install pulls a package Aikido Intel flags as
malicious, or one published within the last 48 hours.

Two things live here:

| Path | What it is |
|---|---|
| `action.yml` | Composite action: installs Safe Chain from a checksum-pinned release, then **verifies the shims are live**. Drop it into any existing workflow. |
| `.github/workflows/verify-deps.yml` | Reusable workflow: the complete PR gate. This is what repositories normally call. |

## Quick start

Add `.github/workflows/supply-chain.yml` to the consuming repository:

```yaml
name: Supply chain

on:
  pull_request:          # deliberately unfiltered — see "Why no paths filter"
  schedule:
    - cron: "0 3 * * *"
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write

jobs:
  # Job id + reusable job name form the required-check string "supply-chain / safe-chain".
  supply-chain:
    uses: squadrun/safe-chain-action/.github/workflows/verify-deps.yml@<commit-sha>
    with:
      ecosystem: node
      install-command: corepack enable && yarn install --immutable
      node-version-file: .nvmrc
      dep-paths: |
        package.json
        yarn.lock
        .yarnrc.yml
```

Pin `uses:` to a **commit SHA**, not a tag. Floating a mutable tag on a supply-chain control
defeats its own purpose. Let Dependabot bump it.

## How Safe Chain works, and what follows from it

Safe Chain has **no lockfile-scan mode**. It installs PATH shims for package managers and runs
a local proxy that inspects registry downloads. Four consequences shape everything here:

1. **The install must really run.** No install, nothing scanned. There is no static mode to
   fall back on.
2. **Dependency caching must be off.** A cache hit means no registry traffic, which means Safe
   Chain inspects nothing and the job passes vacuously. The reusable workflow sets
   `enable-cache: false` and omits `setup-node`'s `cache:` key for exactly this reason. If you
   write your own workflow, do the same.
3. **Safe Chain must be installed *after* all toolchain setup.** `setup-ci` appends the shims
   directory to `$GITHUB_PATH`, and the runner gives *later* steps' entries precedence — so a
   `setup-node` or `setup-uv` step placed after Safe Chain shadows the shims and its installs
   bypass scanning. `action.yml` detects this and fails with an explicit message.
4. **`$GITHUB_PATH` only applies to later steps**, so install and verification are separate
   steps by necessity.

Points 2–4 are why this wrapper exists rather than a copied `curl` snippet. Upstream's installer
**warns instead of failing** when `setup-ci` breaks, so the natural failure mode is a green check
that protects nothing. `action.yml` turns each of those warnings into a hard failure, and
`self-test.yml` asserts on negatives — the canary must be blocked, each guard must fire — because
a passing install cannot tell working protection apart from no protection.

## Why no paths filter

The gate is meant to be a **required status check**. A workflow filtered with `paths:` never
reports a status on PRs that don't match, and a required check that never reports blocks the
merge forever. So the trigger stays unfiltered and the job early-exits green in ~15s when
`dep-paths` didn't change. Same CI savings, no deadlock.

Glob matching for `dep-paths` uses shell `case` patterns, where `*` also crosses `/`. That
over-matches slightly — a spurious scan is much cheaper than a missed one.

## What this does NOT cover

Safe Chain inspects **npm-registry and PyPI traffic only**. It is a detection tool, not a
sandbox. It does not see:

- **`git+https` dependencies.** Anything installed straight from a git repository is invisible.
- **URL and S3 tarballs.** A dependency pinned to an arbitrary HTTPS artifact is invisible.
- **Vendored or committed artifacts.**
- **Packages not yet known to Aikido Intel.** Where install scripts are enabled, such a
  package's `postinstall` still executes. Blocking is based on known-bad plus a publication-age
  heuristic, not on behavioural analysis.

Do not read a green check as full supply-chain coverage. Repositories that install from forked
git repos or unhashed remote tarballs need hash pinning or vendoring, which is a separate problem
from this one.

## `action.yml` inputs

| Input | Default | Notes |
|---|---|---|
| `require-shims` | — (required) | Space-separated managers that **must** be shimmed, e.g. `yarn`, `uv`. Missing or shadowed ⇒ the action fails. Other managers on the runner are reported informationally. |
| `version` | `1.5.14` | Safe Chain release tag. |
| `installer-sha256` | pinned | Must be updated together with `version`; a mismatch fails the build. |
| `minimum-package-age-hours` | `48` | Blocks very fresh releases. |
| `age-exclusions` | `""` | Comma-separated packages exempt from the age check. Prefer this over lowering the threshold. |
| `logging` | `verbose` | `silent` \| `normal` \| `verbose`. |
| `log-file` | `$RUNNER_TEMP/safe-chain.log` | Upload on failure. |

Standalone use, in a workflow of your own:

```yaml
- uses: actions/setup-node@v7          # toolchain FIRST
  with:
    node-version-file: .nvmrc
- uses: squadrun/safe-chain-action@<commit-sha>
  with:
    require-shims: "npm yarn"
- run: yarn install --immutable        # now scanned
```

## Handling a detection

A blocked install fails the job, uploads the Safe Chain log as an artifact, and posts a single
sticky PR comment naming the packages.

- **Real detection** — do not merge. Revert the dependency change and escalate.
- **Legitimate brand-new release** — add the package to `age-exclusions` in that repository's
  `supply-chain.yml`. Do not lower `minimum-package-age-hours`; the 48-hour window is what
  catches a compromised-maintainer publish before the ecosystem notices.

## Bumping the pinned Safe Chain version

1. Update `version` **and** `installer-sha256` in `action.yml`, and the matching defaults in
   `verify-deps.yml`.
2. Get the checksum from Aikido's release notes, or:
   `curl -fsSL <installer-url> | sha256sum`.
3. Open a PR. `self-test.yml` must stay green, and the canary job must still go red — that job
   is the regression test for upstream behaviour changes.

## Operational notes

- **Never rename** the `safe-chain` job in `verify-deps.yml`, or the caller's job id. Together
  they form the branch-protection check name; renaming either silently detaches the required
  check and every PR goes green.
- The reusable workflow checks this repository out at `job.workflow_sha`, so the action can never
  drift from the reusable workflow version a caller pinned.
- A green run whose log shows **zero packages inspected** should be treated as a failure. It
  almost always means dependency caching leaked back into the job.
