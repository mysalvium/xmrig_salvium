# Branching, Integration, and Release Guide

This document is the authoritative description of the repository topology.
It applies to humans, Codex, Claude Code, and other automation working in this
repository.

## Goals

The repository must support three independently understandable code variants
and one integration branch:

1. An upstream-compatible XMRig build.
2. A distributable XMRig build with public Salvium support.
3. A personal donation customization that remains isolated from Salvium
   protocol work.
4. A default personal build containing both custom layers.

The design deliberately prevents donation policy from leaking into the public
SAL branch and prevents either customization from obscuring the upstream
baseline.

## Topology

```text
upstream/xmrig release
          |
          v
        stock
       /     \
      v       v
 salvium    donation
      \       /
       v     v
       combined
```

`combined` is the GitHub default branch and the normal local build target.
It is an integration branch, not the source of either customization.

## Branch responsibilities

### `stock`

`stock` follows a stable official XMRig release. Product source, defaults, and
runtime behavior must match that upstream release.

The only repository-specific files permitted on `stock` are repository-management
documents and safety tooling such as:

- `AGENTS.md`
- `CLAUDE.md`
- `docs/BRANCHING.md`
- `.github/copilot-instructions.md`
- `.github/PULL_REQUEST_TEMPLATE.md`
- `.gitattributes`
- `.githooks/pre-push`
- `scripts/check-upstream-pr.sh`
- `scripts/install-repository-safety.ps1`

These files do not affect the compiled miner. To compare product code with
upstream, exclude the management and safety files:

```powershell
git diff upstream/master..stock -- . `
    ':(exclude)AGENTS.md' `
    ':(exclude)CLAUDE.md' `
    ':(exclude)docs/BRANCHING.md' `
    ':(exclude).github/copilot-instructions.md' `
    ':(exclude).github/PULL_REQUEST_TEMPLATE.md' `
    ':(exclude).gitattributes' `
    ':(exclude).githooks/pre-push' `
    ':(exclude)scripts/check-upstream-pr.sh' `
    ':(exclude)scripts/install-repository-safety.ps1'
```

That command should be empty when `stock` follows `upstream/master`. During a
release upgrade, compare against the selected upstream tag instead.

Do not commit fixes directly to `stock`. Either obtain the fix from upstream
or place a repository-specific fix on the branch that owns the behavior.

### `salvium`

`salvium` starts from `stock` and owns the public Salvium adaptation:

- `Coin::SALVIUM` metadata and `SAL` selection.
- Salvium legacy and Carrot address prefixes and daemon ports.
- Salvium miner and protocol transaction parsing.
- Salvium output variants, asset identifiers, unlock times, tags, and anchors.
- Salvium transaction-tree construction.
- Salvium fixtures and regression tests.
- SAL-facing configuration and user documentation.
- SAL-only build and release automation.

`salvium` must keep the upstream donation implementation. A change to donation
wallets, donation pools, or personal donation policy does not belong here.

A release advertised as SAL-only or intended to retain upstream donation
behavior must be built from a commit contained in `salvium`.

### `donation`

`donation` starts from `stock` and owns only the personal donation layer:

- Personal SAL and XMR donation destinations.
- Personal donation pool routing and fallback behavior.
- Personal donation-level policy and related help text.

It must not contain Salvium coin registration, wallet decoding, block-template
parsing, SAL defaults, or public release workflow changes. The branch is
independently buildable for structural verification, even though its intended
runtime is the merged `combined` branch.

This branch is personal policy, but it is retained on the public `origin`
remote so the public default `combined` branch can merge it reproducibly.
Assume its wallet addresses and implementation are visible. Never create a
public release from `donation` or treat it as the distributable SAL variant.

### `combined`

`combined` merges both customization branches and is the GitHub default:

```text
combined = merge(salvium, donation) + narrowly scoped build-integration glue
```

It is the normal branch to compile when no variant is explicitly requested.
Feature implementation must not begin here:

- A Salvium fix goes to `salvium`, then is merged into `combined`.
- A donation change goes to `donation`, then is merged into `combined`.
- An upstream release enters through `stock`, then flows independently through
  both customization branches before both are merged into `combined`.

Integration-only conflict resolutions may be committed on `combined`, but
those commits should be exceptional and must not become the canonical
implementation of a feature.

Never merge `combined` back into a component branch.

`combined` also owns the automatic personal release integration used by this
fork. A push to `combined` may build the complete platform matrix and publish
a numbered Salvium release candidate containing both customization layers.
Those releases are not SAL-only artifacts and must state that they include the
personal donation behavior.

At the 2026-07-23 split, `combined` retained five pre-existing,
platform-compatibility edits from the former mixed default branch:

- `CMakeLists.txt` — OpenBSD system libraries.
- `cmake/cpu.cmake` — Visual Studio ARM64 target detection.
- `src/3rdparty/argon2/CMakeLists.txt` — avoid x86 feature libraries on ARM.
- `src/base/io/Signals.cpp` — guard `SIGPIPE` by availability.
- `src/crypto/ghostrider/ghostrider.cpp` — MSVC ARM64 SIMD compatibility.

These are build portability changes, not Salvium or donation behavior. Keep
them out of `stock`, `salvium`, and `donation`. Re-evaluate them during each
upstream update and remove a patch once upstream absorbs it or the supported
build matrix no longer needs it. A build change required for SAL-only
artifacts belongs on `salvium`; a change needed only to compile, package, or
publish the personal merged variant may remain on `combined`.

## Absolute upstream donation firewall

The personal donation implementation must never appear in a pull request
whose base repository is `https://github.com/xmrig/xmrig`. This prohibition
applies to humans, Codex, Claude Code, GitHub Copilot, scripts, connectors, the
GitHub CLI, and any future automation.

The following are forbidden as heads for an `xmrig/xmrig` pull request:

- `donation`
- `combined`
- Any topic branch based on either branch.
- Any ref containing `donation` as an ancestor.
- Any ref carrying `docs/DONATION_LAYER.md`.
- Any ref that changes the donation-owned source files relative to the
  proposed upstream base.

Before any upstream PR-writing action, resolve and display:

```text
base repository
base branch
head repository
head branch
```

Then run the fail-closed safety check:

```text
git check-upstream-pr xmrig/xmrig HEAD upstream/master
```

The check passing is necessary but not sufficient. Review the complete diff
and obtain a new, explicit user confirmation that names `xmrig/xmrig`. Earlier
or general permission to commit, push, publish, or create a PR does not count.
If any identity, ancestry, base ref, or diff cannot be verified, do not create
or modify the PR.

If an upstream contribution is explicitly desired, create a disposable clean
topic branch directly from `upstream/master` and cherry-pick only the reviewed
non-donation change. Do not merge or branch from `donation` or `combined`. Do
not use `salvium` wholesale as the PR head.

This clone also has layered transport safeguards:

- `remote.pushDefault` and every long-lived branch's `pushRemote` point to
  `origin`.
- GitHub CLI defaults to `mysalvium/xmrig_salvium`, and each non-default
  long-lived branch uses `combined` as its CLI merge base.
- `upstream` has a deliberately disabled push URL while retaining its official
  fetch URL.
- `.githooks/pre-push` rejects every direct push to the official XMRig URL.
- The same hook rejects donation-bearing refs pushed anywhere except the
  trusted `origin`.

Install or restore these local settings after a fresh clone with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/install-repository-safety.ps1
```

Because `origin` is a public GitHub repository, GitHub may still display a browser
**Contribute** button that proposes the parent repository. No local Git hook
can intercept a deliberate browser/API action. Never use that button from
`donation`, `combined`, or their descendants. The PR template and agent
instructions repeat this boundary, and any upstream PR still requires the
explicit preflight and confirmation above.

## Upstream remote

The remotes have distinct purposes:

```text
origin    git@github-salvium:mysalvium/xmrig_salvium.git
upstream  https://github.com/xmrig/xmrig.git
```

Fetch official releases with:

```powershell
git fetch upstream --tags
```

Advance `stock` only to a reviewed stable upstream tag or stable upstream
commit.

## Updating to a new XMRig release

For a hypothetical `v6.27.0`:

```powershell
git switch stock
git merge --ff-only v6.27.0

git switch salvium
git merge --no-ff stock
# Resolve only Salvium-owned conflicts, then build and test.

git switch donation
git merge --no-ff stock
# Resolve only donation-owned conflicts, then build.

git switch combined
git merge --no-ff salvium
git merge --no-ff donation
# Build and run the combined validation set.
```

If `stock` contains a documentation commit after the old release point, a
strict fast-forward to a new tag may not be possible. In that case merge the
new upstream release into `stock` with a dedicated upstream-update merge
commit, leaving the management documents intact.

Enable recorded conflict resolution locally:

```powershell
git config rerere.enabled true
git config rerere.autoupdate true
```

## Day-to-day change flow

Before editing, identify the current branch:

```powershell
git branch --show-current
git status --short
```

For Salvium work:

```powershell
git switch salvium
# edit, test, and commit
git switch combined
git merge --no-ff salvium
```

For donation work:

```powershell
git switch donation
# edit, test, and commit
git switch combined
git merge --no-ff donation
```

For a default build after both layers have moved:

```powershell
git switch combined
git merge --no-ff salvium
git merge --no-ff donation
cmake --build build --config Release --parallel
```

Do not cherry-pick the same customization into multiple branches. Commit it
once on the owning branch and merge through the documented topology.

## Worktrees and build directories

Use separate worktrees to prevent stale objects or the wrong executable from
crossing branch boundaries:

```text
E:\xmrig-dev\xmrig-stock       branch: stock
E:\xmrig-dev\xmrig-salvium    branch: salvium
E:\xmrig-dev\xmrig-donation    branch: donation
E:\xmrig-dev\xmrig             branch: combined
```

Each worktree owns its own `build` directory. Do not share a CMake build tree
between variants.

Example creation commands, run from an existing worktree:

```powershell
git worktree add E:\xmrig-dev\xmrig-stock stock
git worktree add E:\xmrig-dev\xmrig-salvium salvium
git worktree add E:\xmrig-dev\xmrig-donation donation
```

## Validation

At minimum, validate:

### `stock`

- Product-code diff against the selected official XMRig release is empty.
- Release build succeeds.
- `xmrig --version` succeeds.

### `salvium`

- Release build succeeds.
- `xmrig --version` succeeds.
- SAL pool configuration dry-run succeeds.
- Salvium block-template fixtures pass.
- Monero/FCMP behavior remains aligned with the upstream base.
- Donation source matches `stock`.

Verify the last invariant with:

```powershell
git diff --exit-code stock...salvium -- `
    src/donate.h `
    src/net/strategies/DonateStrategy.cpp `
    src/net/strategies/DonateStrategy.h
```

### `donation`

- Release build succeeds.
- The diff from `stock` is limited to donation-owned files and documentation.

### `combined`

- Both `salvium` and `donation` are ancestors:

```powershell
git merge-base --is-ancestor salvium combined
git merge-base --is-ancestor donation combined
```

- Release build succeeds.
- SAL configuration dry-run succeeds.
- Donation destinations match the personal configuration.

## Release channels

### SAL-only releases

SAL-only releases must come from `salvium`, not the GitHub default `combined`
branch. They retain upstream donation behavior.

Use an unambiguous SAL tag convention, for example:

```text
sal-v6.26.0-rc2
sal-v6.26.0-1
```

Release automation should accept only `sal-v*` tags and must verify that the
tagged commit is contained in `origin/salvium`. A tag on `combined` or
`donation` must fail the release eligibility check.

### Personal combined releases

The normal sidebar release for this repository is built from `combined` after a
successful full-platform build. It contains both Salvium support and the
personal donation layer. Every push to `combined` should start that build and,
when all required jobs succeed, publish the next release candidate as the
repository's Latest release.

Use the XMRig application version and a monotonically increasing release
candidate number:

```text
v6.26.0_Salvium-rc2
v6.26.0_Salvium-rc3
```

Combined release automation must:

- Run only for a push to `combined`.
- Verify that the release commit contains both `origin/salvium` and
  `origin/donation`.
- Build and upload the complete supported artifact matrix.
- State in the release notes that the artifacts contain the personal donation
  layer.
- Publish only to this repository's `origin`.

Never create a release directly from `donation`.

Do not move or rewrite a published release tag.

## Historical preservation

The repository was split into this model on 2026-07-23. The prior mixed
history is preserved by annotated archive tags:

- `archive/pre-split-master-20260723`
- `archive/pre-split-salvium-20260723`
- `archive/pre-split-cicd-20260723`

Use those tags for archaeology only. Do not resume development from them.

