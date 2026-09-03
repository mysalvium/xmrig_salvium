# Personal Donation Layer

The `donation` branch contains the personal donation customization and is
merged with `salvium` only through the default `combined` branch.

This layer changes:

- Donation wallet destinations.
- Donation pool routing and fallback behavior.
- The minimum configurable donation level.
- Related command-line help and source comments.

## Current route order

Direct donation connections use this failover order:

1. `us2.salvium.herominers.com:1228` with the personal SAL wallet.
2. `de.salvium.herominers.com:1228` with the personal SAL wallet.
3. `pool.supportxmr.com:3333` with the personal XMR wallet.
4. `xmrpool.eu:3333` with the personal XMR wallet.

The XMR endpoints must be conventional wallet-authenticated Stratum pools.
Do not use `p2pool.io`, `mini.p2pool.io`, or another remote P2Pool node as a
wallet-directed fallback. P2Pool configures the payout wallet on the P2Pool
node and ignores a wallet supplied by XMRig, so a hard-coded XMRig login does
not control the payout destination.

Before changing an XMR fallback, verify that the endpoint resolves, accepts
the personal XMR wallet as its Stratum login, and returns a compatible
RandomX job. A login-only validation must disconnect without submitting a
share. The current SupportXMR and XMRPool.eu endpoints passed that validation
on 2026-07-24. They use keepalive, standard (non-NiceHash) nonce behavior, and
plain Stratum on port `3333`.

## Absolute upstream prohibition

Never create, update, or retarget a pull request to
`https://github.com/xmrig/xmrig` from `donation`, `combined`, or any branch,
tag, or commit containing this layer. Never push this layer directly to the
official XMRig repository under any remote name or explicit URL.

The prohibition applies even when the donation edits are not the intended
subject of the pull request. A large or unrelated diff does not make them safe
to include.

The mandatory preflight must reject this branch:

```text
git check-upstream-pr xmrig/xmrig donation upstream/master
```

An upstream contribution must instead be reconstructed on a clean,
disposable topic branch based directly on `upstream/master`, contain no
donation-layer ancestry or files, pass the preflight, and receive explicit
user confirmation naming `xmrig/xmrig`. General permission to commit, push,
publish, or open a PR is never sufficient.

It does not own Salvium coin registration, address parsing, block-template
parsing, SAL configuration defaults, or release automation.

Do not merge this branch into `salvium`, and do not create release artifacts
directly from `donation`. SAL-only binaries come from `salvium`. The normal
personal release comes from `combined` after this layer has been merged with
the Salvium branch, and its release notes must disclose the personal donation
behavior.

When donation behavior changes:

1. Make and validate the change on `donation`.
2. Commit it on `donation`.
3. Merge `donation` into `combined`.
4. Build and validate `combined`.

The wallet destinations themselves remain visible in `src/donate.h` and
`src/net/strategies/DonateStrategy.cpp` so the compiled behavior can be
audited directly.
