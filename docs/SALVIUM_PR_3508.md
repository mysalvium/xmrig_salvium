# Salvium upstream PR #3508 reconciliation

This document records how the public `salvium` layer accounts for the work in
[xmrig/xmrig PR #3508](https://github.com/xmrig/xmrig/pull/3508), authored by
GitHub user `somerandomcryptoguy`.

## Snapshot and scope

The upstream repository was rechecked on 2026-07-24. Searches of both open and
closed pull requests found one pull request by that exact author:

- PR #3508, **Add support for Salvium (SAL) coin & wallet**
- State: open and not merged
- Upstream merge state: conflicting
- Head: `bc08e8a3b825aef4b03095cd1f2cfb43ed790450`
- Eight commits changing nine files

This is a semantic reconciliation. The original commits are not expected to
be ancestors of `salvium`: the fork adapted the proposal to the current XMRig
base, corrected parser behavior against public Salvium mainnet blocks, and
kept unrelated or incomplete changes out.

## Disposition by proposal area

| Proposal area | Disposition in `salvium` |
| --- | --- |
| `Coin::SALVIUM`, `SAL`, 120-second target, and 8-decimal units | Incorporated. Salvium remains mapped to canonical `Algorithm::RX_0`. |
| Legacy mainnet, testnet, and stagenet address prefixes and ports | Incorporated. |
| Carrot mainnet, testnet, and stagenet address prefixes and ports | Incorporated. |
| Miner transaction parsing for Salvium outputs and metadata | Incorporated and mainnet-tested. |
| Salvium `protocol_tx` parsing | Incorporated and superseded by layout corrections and stricter bounds checks. |
| Carrot and Tokens protocol transaction versions | Incorporated and mainnet-tested. |
| Transaction-tree and hashing-blob construction | Incorporated and superseded by correct Merkle-path tracking and legacy-v1 transaction-count handling. |
| Temporary diagnostic logging | Omitted. The proposal itself removes it in its following commit. |
| Historical merge of upstream XMRig | Omitted. Official updates enter through `stock`, preserving the branch topology. |
| `APP_ID` change from `xmrig` to `xmrig-salvium` | Deliberately omitted to avoid an unnecessary core branding delta. |
| `rx/salvium`, `randomx/salvium`, and `randomsalvium` names | Incorporated as aliases that resolve to the existing `RX_0` identifier. |
| Separate `RX_SALVIUM` algorithm identifier | Deliberately not incorporated. Salvium uses the reference `rx/0` configuration, and the proposed identifier was not wired through every backend. |
| Standalone `ALGO_RX_SALVIUM` OpenCL constant | Deliberately not incorporated. Mapping aliases to `RX_0` keeps CPU and OpenCL on the same established RandomX configuration path. |

## Disposition by upstream commit

| Commit | Subject | Disposition |
| --- | --- | --- |
| `c8d9bc56` | Initial Salvium coin and wallet details | Incorporated. |
| `e0d9b0c1` | Diagnostic logging and initial parsing | Functional parsing incorporated; temporary logging omitted. |
| `a80fb235` | Remove diagnostic logging | Net state preserved: the fork contains no temporary diagnostic logging. |
| `303f15d6` | Protocol transaction output fix | Incorporated and superseded by the current bounded parser. |
| `347d0a1b` | Carrot/Token support | Protocol and address support incorporated; `APP_ID` branding change omitted. |
| `a8bbb27c` | Merge upstream `master` | Not cherry-picked; the `stock` branch supplies a newer reviewed XMRig base. |
| `05109471` | Add `RX_SALVIUM` identifier | Intent incorporated through aliases; the separate identifier and OpenCL constant are rejected. |
| `bc08e8a3` | Add Salvium algorithm aliases | Incorporated as aliases of `RX_0`, not as a new algorithm variant. |

## Why the aliases resolve to `RX_0`

The proposal describes Salvium as using `rx/0`, and its own `Coin::SALVIUM`
entry selects `Algorithm::RX_0`. A separate identifier would describe a
different RandomX variant even though no different RandomX configuration is
provided.

The proposed OpenCL change added an `ALGO_RX_SALVIUM` constant but did not add
that value to the OpenCL RandomX constant-selection condition. Copying it
literally could therefore produce backend-specific behavior or an OpenCL
compile failure when the new name was selected.

The fork instead accepts the user-facing names while immediately resolving
all of them to `Algorithm::RX_0`. The canonical serialized and displayed name
remains `rx/0`, and every mining backend follows its existing `RX_0` path.

## Validation

The `WITH_SALVIUM_TESTS` CMake option builds two offline tests:

- `salvium-mainnet-block-templates` validates the production parser and
  transaction tree against eight immutable public mainnet fixtures spanning
  legacy, Carrot, Tokens, and current v13 blocks.
- `salvium-randomx-aliases` proves every accepted Salvium algorithm name,
  including case-insensitive input, resolves to canonical `RX_0`.

The normal Release build retains OpenCL support, so it also compiles the
existing `RX_0` OpenCL path used by these aliases.

## Future re-audit

Before claiming the fork is current with this author again, re-run both the
open and closed PR searches and compare the live PR head with this snapshot.
New upstream commits must be reviewed by behavior and file, not merged
wholesale. Update this document when a disposition changes.
