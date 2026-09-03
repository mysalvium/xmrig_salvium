# Repository Branch Model

Read `docs/BRANCHING.md` before changing source code, Git history, build
automation, or release configuration.

This repository intentionally separates upstream code, Salvium support,
personal donation behavior, and the normally compiled integration branch:

```text
stock
├── salvium
├── donation
└── combined  (merges salvium and donation; GitHub default)
```

The actual merge flow is one-way:

```text
stock -> salvium  \
                    -> combined
stock -> donation /
```

## Absolute upstream pull-request safety rule

Never create, open, update, or retarget a pull request to
`https://github.com/xmrig/xmrig` from `donation`, `combined`, or any branch,
tag, or commit containing the personal donation layer. This is a hard safety
boundary, not a preference.

Before any tool call that can create or change a pull request:

1. Resolve and state the exact base repository, base branch, head repository,
   and head branch.
2. If the base repository is `xmrig/xmrig`, run:

   ```text
   git check-upstream-pr xmrig/xmrig HEAD upstream/master
   ```

3. Inspect the complete outgoing diff and obtain explicit user confirmation
   naming `xmrig/xmrig` after the check passes. A generic request to commit,
   push, publish, or "open a PR" is not authorization for an upstream XMRig
   pull request.
4. If the target or donation status cannot be proven, stop. Do not create or
   modify the pull request.

All direct pushes to `xmrig/xmrig` are forbidden from this clone. The
versioned pre-push hook enforces that transport boundary. If an upstream
contribution is ever explicitly authorized, prepare a clean topic branch
directly from `upstream/master`, cherry-pick only reviewed non-donation
changes, and pass the mandatory check above. Never use a long-lived fork
branch as the upstream PR head. Local hooks cannot intercept GitHub's browser
UI, so never use the fork's **Contribute** button from `donation`,
`combined`, or a descendant of either.

## Non-negotiable rules

- `stock` contains official XMRig source plus repository-management
  documentation only. Do not add product code, configuration defaults, or
  build behavior directly to `stock`.
- `salvium` contains only public Salvium support, Salvium documentation,
  tests, and SAL-only release automation. It must retain upstream donation
  behavior.
- `donation` contains only the personal donation customization. It must not
  contain Salvium protocol or release changes.
- `combined` is the normal personal build and GitHub default branch. It merges
  `salvium` and `donation` and may retain narrowly scoped build-integration
  compatibility and personal release-automation changes documented in
  `docs/BRANCHING.md`. Do not develop feature code directly on `combined`;
  make feature changes on the owning branch and merge them into `combined`.
- Never merge `combined` back into `salvium`, `donation`, or `stock`.
- Never merge `donation` into `salvium`.
- SAL-only release artifacts must be built from `salvium`, never from
  `combined` or `donation`.
- Personal combined releases may be built from `combined` and published only
  to this fork. They must use the documented Salvium release-candidate naming
  convention and disclose that they contain the personal donation layer.
- Never create release artifacts directly from `donation`.
- Never push any donation-bearing commit to a remote other than this repository's
  `origin`, `git@github-salvium:mysalvium/xmrig_salvium.git`.
- Local `.claude/` and `.codex/` directories are workspace state and must not
  be committed.

## Default build behavior

When the user asks to update, integrate, or compile the customized miner
without naming a variant:

1. Put Salvium changes on `salvium`.
2. Put donation changes on `donation`.
3. Merge both branch heads into `combined`.
4. Compile and validate `combined` in its own worktree/build directory.

Use the `salvium` worktree explicitly when producing a distributable SAL-only
binary. Use the `stock` worktree explicitly when validating untouched XMRig
behavior.

