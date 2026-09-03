# XMRig w/ Salvium Support

Note about this project.  This is specifically for people that are trying to mine Salvium.  I am not rigourously testing this against other coins.  I mean, it **should** work, but I am only worried about XMR and SAL.

If Salvium is not a coin you are interested in, I suggest you head to the official [XMRig repository](https://github.com/xmrig/xmrig). It works great for everything else.

## Repository variants

This repository separates official XMRig, public Salvium support, personal
donation behavior, and the normal combined build:

```text
stock
├── salvium
├── donation
└── combined
```

`combined` is the default branch and normal personal build. Public SAL-only
artifacts must be built from `salvium`; the `donation` customization is not
part of the public SAL variant. See [the branching guide](docs/BRANCHING.md)
for the complete maintenance, integration, build, and release workflow.

## Salvium Coin Configuration

The supplied configuration explicitly selects Salvium and RandomX, keeps the
pool connection alive, and provides an independently operated fallback:

```json
{
    "pools": [
        {
            "algo": "rx/0",
            "coin": "SAL",
            "url": "sal-us.kryptex.network:7028",
            "user": "YOUR_PRIMARY_SC1_CARROT_ADDRESS.YOUR_WORKER_NAME",
            "pass": "x",
            "keepalive": true
        },
        {
            "algo": "rx/0",
            "coin": "SAL",
            "url": "stratum-eu.rplant.xyz:7130",
            "user": "YOUR_PRIMARY_SC1_CARROT_ADDRESS.YOUR_WORKER_NAME",
            "pass": "x",
            "keepalive": true
        }
    ]
}
```

Replace both placeholder usernames before mining. The primary
`sal-us.kryptex.network:7028` endpoint and the independent
`stratum-eu.rplant.xyz:7130` fallback accepted `rx/0` login-only checks with a
valid mainnet Carrot address on 2026-07-24; no hashing or shares were
submitted. Both operators appear in the
[official Salvium pool directory](https://salvium.io/pools/). Pool ownership,
fees, payment rules, and endpoints can change, so review the
[Kryptex SAL page](https://pool.kryptex.com/sal) and
[Rplant SAL page](https://pool.rplant.xyz/#salvium#connect) before committing
substantial hash power.

The Windows examples copied beside Release builds use the same settings:

- `pool_mine_example.cmd` configures both pool endpoints.
- `solo_mine_example.cmd` connects to a local Salvium mainnet daemon on
  `127.0.0.1:19081`.

### What `"coin": "SAL"` does

The coin setting controls how the miner identifies and interacts with the Salvium network. Its behavior differs depending on the mining mode.

#### Pool / Stratum Mode

In pool mode, the coin setting serves one purpose: **algorithm selection**. When the pool sends a job without an explicit `algo` field, the miner uses the coin identity to determine that Salvium uses `rx/0` (RandomX). This is the only effect in pool mode — the pool handles block template parsing and validation on its side.

`rx/0` remains the canonical algorithm name and backend identifier. For
configuration compatibility, `rx/salvium`, `randomx/salvium`, and
`randomsalvium` are accepted as aliases, but all three resolve to the existing
`RX_0` implementation. They do not select a separate RandomX variant.

#### Daemon / Solo Mode

In daemon mode (`"daemon": true`), the coin identity activates the full Salvium protocol support:

- **Block template parsing** — Salvium blocks contain a `protocol_tx` between the miner transaction and the regular transaction hashes, including the v1 mainnet era. The parser uses the coin identity to detect and correctly parse this extra transaction, which does not exist in Monero or other CryptoNote coins.
- **Output type handling** — Salvium supports output types `txout_to_key` (2), `txout_to_tagged_key` (3), and `txout_to_carrot_v1` (4), and allows multiple outputs per miner transaction. The parser enables these when the coin is SAL.
- **Transaction metadata** — Salvium miner transactions contain
  protocol-specific metadata that is parsed only when the selected coin is
  SAL.
- **Merkle root computation** — The Salvium block hash tree includes both the miner transaction and the protocol transaction as base entries. The v1 hashing blob retains Salvium's historical transaction-count value of 1; v2 and later use 2 base transactions.
- **Hardfork-aware protocol versioning** — The parser validates the protocol transaction version against the block's major version, supporting legacy (v1 through v9), Carrot (HF 10+), and Tokens (HF 11+) eras.
- **Wallet address decoding** — Salvium legacy (`SaLv*`) and Carrot (`SC1*`) address prefixes are recognized for mainnet, testnet, and stagenet, along with their corresponding RPC (19081/29081/39081) and ZMQ (19082/29082/39082) ports.

#### Coin Metadata


| Property     | Value                   |
| -------------- | ------------------------- |
| Code         | `SAL`                   |
| Name         | `Salvium`               |
| Algorithm    | `rx/0` (RandomX)        |
| Block target | 120 seconds             |
| Coin units   | 10^8 (8 decimal places) |

### Mainnet block-template regression tests

The `salvium` and `combined` branches include an offline C++ regression suite
that runs the production `BlockTemplate` parser against immutable public
mainnet blocks. The fixtures cover v1, the v2 protocol boundary, a legacy
block with several transaction hashes, the Carrot and Tokens boundaries,
protocol outputs, six miner outputs, the v13 boundary, and a dated current
v13 sample.

The suite verifies parser fields, miner and protocol transaction hashes, the
Merkle root through the canonical public block ID, and rejection of truncated
or structurally invalid blobs. It does not need a wallet, daemon, network
connection, or testnet:

```powershell
cmake -S . -B build-salvium-tests -DWITH_SALVIUM_TESTS=ON
cmake --build build-salvium-tests --config Release --target salvium_block_template_tests salvium_algorithm_tests --parallel
ctest --test-dir build-salvium-tests -C Release --output-on-failure
```

The captured blobs and their provenance are in
[`tests/fixtures/salvium-mainnet-blocks.json`](tests/fixtures/salvium-mainnet-blocks.json).
The disposition of every commit and changed area in SomeRandomCryptoGuy's
upstream proposal is recorded in
[`docs/SALVIUM_PR_3508.md`](docs/SALVIUM_PR_3508.md).

### RandomX CPU tuners

The credential-free Windows
[`scripts/tune-salvium-randomx.ps1`](scripts/tune-salvium-randomx.ps1)
benchmark controller can compare P-core/E-core affinities, RandomX scratchpad
prefetch modes, CPU yield behavior, and JIT huge pages without changing the
production miner configuration. It uses offline `rx/0` benchmarks, disables
networking and MSR access, and writes a ranked report outside the repository.
Its Rigorous preset adds temperature-aware affinity exploration,
deterministically randomized repeated measurements, benchmark-validity
checks, reference drift, statistical diagnostics, and resumable manifests.
Read the [Windows tuner guide](docs/SALVIUM_RANDOMX_TUNER.md) and run its
plan-only or smoke-test mode before starting a complete session.

Linux releases include the native Bash
[`scripts/tune-salvium-randomx.sh`](scripts/tune-salvium-randomx.sh)
controller. It respects online and cgroup-allowed CPUs, reads physical-core,
SMT, hybrid-class, and shared-L3 topology from Linux sysfs, and provides the
same staged offline tuning, temperature ceiling, Rigorous experiment, resume
support, and credential isolation. Read the
[Linux tuner guide](docs/SALVIUM_RANDOMX_TUNER_LINUX.md) before running it.

For More information on Salvium:

- Salvium project: [https://salvium.io/](https://salvium.io/)
- Salvium: [https://github.com/salvium/salvium](https://github.com/salvium/salvium "https://github.com/salvium/salvium")
- P2Pool Salvium Info: [https://whiskymine.io/p2pool-setup.html](https://whiskymine.io/p2pool-setup.html)
- P2Pool Salvium Fork: [https://gitlab.com/whiskyrelaxing-group/p2pool-salvium-releases](https://gitlab.com/whiskyrelaxing-group/p2pool-salvium-releases)

## Original Readme

[![Github All Releases](https://img.shields.io/github/downloads/xmrig/xmrig/total.svg)](https://github.com/xmrig/xmrig/releases)
[![GitHub release](https://img.shields.io/github/release/xmrig/xmrig/all.svg)](https://github.com/xmrig/xmrig/releases)
[![GitHub Release Date](https://img.shields.io/github/release-date/xmrig/xmrig.svg)](https://github.com/xmrig/xmrig/releases)
[![GitHub license](https://img.shields.io/github/license/xmrig/xmrig.svg)](https://github.com/xmrig/xmrig/blob/master/LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/xmrig/xmrig.svg)](https://github.com/xmrig/xmrig/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/xmrig/xmrig.svg)](https://github.com/xmrig/xmrig/network)

XMRig is a high performance, open source, cross platform RandomX, KawPow, CryptoNight and [GhostRider](https://github.com/xmrig/xmrig/tree/master/src/crypto/ghostrider#readme) unified CPU/GPU miner and [RandomX benchmark](https://xmrig.com/benchmark). Official binaries are available for Windows, Linux, macOS and FreeBSD.

## Mining backends

- **CPU** (x86/x64/ARMv7/ARMv8/RISC-V)
- **OpenCL** for AMD GPUs.
- **CUDA** for NVIDIA GPUs via external [CUDA plugin](https://github.com/xmrig/xmrig-cuda).

## Download

* **[Salvium-enabled binary releases](https://github.com/mysalvium/xmrig_salvium/releases)**
* **[Official stock XMRig releases](https://github.com/xmrig/xmrig/releases)**
* **[Build from source](https://xmrig.com/docs/miner/build)**

## Usage

The preferred way to configure the miner is the [JSON config file](https://xmrig.com/docs/miner/config) as it is more flexible and human friendly. The [command line interface](https://xmrig.com/docs/miner/command-line-options) does not cover all features, such as mining profiles for different algorithms. Important options can be changed during runtime without miner restart by editing the config file or executing [API](https://xmrig.com/docs/miner/api) calls.

* **[Wizard](https://xmrig.com/wizard)** helps you create initial configuration for the miner.
* **[Workers](http://workers.xmrig.info)** helps manage your miners via HTTP API.

## Donations

* Default donation 1% (1 minute in 100 minutes) can be increased via option `donate-level` or disabled in source code.
* XMR: `48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD`

## Developers

* **[xmrig](https://github.com/xmrig)**
* **[sech1](https://github.com/SChernykh)**

## Contacts

* support@xmrig.com
* [reddit](https://www.reddit.com/user/XMRig/)
* [twitter](https://twitter.com/xmrig_dev)
