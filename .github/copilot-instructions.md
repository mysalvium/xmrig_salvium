# Repository Safety and Branch Instructions

Read `AGENTS.md` and `docs/BRANCHING.md` before modifying code, Git history,
remotes, release automation, or pull requests.

The branch flow is:

```text
stock -> salvium  \
                    -> combined
stock -> donation /
```

- `stock` is the upstream-compatible product baseline.
- `salvium` owns public SAL support and keeps upstream donation behavior.
- `donation` owns the personal donation customization.
- `combined` is the default personal build.
- Never merge `combined` upward or `donation` into `salvium`.

## Hard upstream PR boundary

Never create, update, or retarget a pull request to `xmrig/xmrig` from
`donation`, `combined`, or any ref containing the personal donation layer.
Never push directly to `xmrig/xmrig` from this clone.

Before any explicitly authorized upstream PR action:

1. Resolve and display the exact base/head repositories and branches.
2. Use a clean topic branch based directly on `upstream/master`.
3. Run
   `git check-upstream-pr xmrig/xmrig HEAD upstream/master`.
4. Review the complete diff.
5. Obtain explicit user confirmation naming `xmrig/xmrig`.

General authorization to commit, push, publish, or open a PR is insufficient.
If any check is uncertain, do not create or modify the PR.
