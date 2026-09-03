# CLAUDE.md - XMRig Development Guide

## Repository Branch Model

Before modifying code or Git history, read `docs/BRANCHING.md`. The short
version is:

```text
stock
├── salvium
├── donation
└── combined  (merges salvium and donation; GitHub default)
```

- `stock` preserves official XMRig product source.
- `salvium` owns public Salvium support and SAL releases.
- `donation` owns only the personal donation customization.
- `combined` is the normal personal build and compile/package integration
  branch. Do not implement features directly on it; make changes on the
  owning branch and merge them into `combined`. Any combined-only build
  compatibility delta must be documented in `docs/BRANCHING.md`.
- Never merge `combined` upward, and never merge `donation` into `salvium`.
- When asked to compile the customized miner without another qualifier, merge
  both component branches into `combined` and build `combined`.
- Build public SAL artifacts from `salvium`, not `combined`.
- Do not commit local `.claude/` or `.codex/` workspace state.

## Absolute Upstream PR Prohibition

Never create, update, or retarget a pull request to `xmrig/xmrig` from
`donation`, `combined`, or any branch containing the personal donation layer.
Never push directly to `xmrig/xmrig` from this clone.

Before using `gh pr create`, a GitHub connector, or any other PR-writing tool,
resolve the exact base and head repositories and branches. For an explicitly
authorized `xmrig/xmrig` contribution, run:

```text
git check-upstream-pr xmrig/xmrig HEAD upstream/master
```

Then inspect the full diff and ask for explicit confirmation that names
`xmrig/xmrig`. General permission to commit, push, publish, or open a PR does
not authorize an upstream XMRig PR. If any check is uncertain, fail closed and
do not create or modify the PR.

## Project Overview

XMRig is a high-performance, cross-platform cryptocurrency miner supporting RandomX, KawPow, CryptoNight, and GhostRider algorithms. Written in C++11 (no RTTI), licensed under GPLv3.

## Build System

CMake-based (minimum 3.10). Standard build:

```bash
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

On Windows with MSVC:
```bash
mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A x64
cmake --build . --config Release
```

### Key CMake Options

All ON by default unless noted:
- `WITH_RANDOMX`, `WITH_CN_LITE`, `WITH_CN_HEAVY`, `WITH_CN_PICO`, `WITH_CN_FEMTO`, `WITH_ARGON2`, `WITH_KAWPOW`, `WITH_GHOSTRIDER` — algorithm families
- `WITH_OPENCL`, `WITH_CUDA` — GPU backends
- `WITH_TLS` — OpenSSL support
- `WITH_HWLOC` — hardware topology
- `WITH_HTTP` — HTTP API
- `WITH_ASM` — assembly optimizations
- `WITH_SSE4_1`, `WITH_AVX2`, `WITH_VAES` — x86 SIMD features
- `WITH_BENCHMARK` — built-in RandomX benchmark
- `WITH_MSR`, `WITH_DMI` — hardware access
- `BUILD_STATIC` — static linking (OFF by default)
- `WITH_DEBUG_LOG` — debug output (OFF by default)

### Dependencies

- **libuv** — required, async I/O
- **OpenSSL** — optional, TLS support
- **hwloc** — optional, NUMA/topology awareness

Scripts in `scripts/` build dependencies: `build_deps.sh`, `build.openssl.sh`, `build.hwloc.sh`, `build.uv.sh`.

## Source Layout

```
src/
├── 3rdparty/          # Vendored libraries (rapidjson, fmt, argon2, llhttp, etc.)
├── backend/           # Mining backends (cpu/, opencl/, cuda/)
├── base/              # Core infrastructure (api/, crypto/, io/, kernel/, tools/)
├── core/config/       # Configuration system
├── crypto/            # Algorithm implementations (randomx/, cn/, kawpow/, ghostrider/, argon2/)
├── hw/                # Hardware info (dmi/, msr/)
├── net/               # Pool networking and strategies
├── App.h/.cpp         # Application coordinator
├── Summary.h/.cpp     # Startup summary display
├── donate.h           # Donation config
├── version.h          # Version defines
└── xmrig.cpp          # main() entry point
```

## Coding Conventions

- **C++ standard:** C++11, no RTTI (`-fno-rtti`), exceptions enabled
- **Namespace:** All code in `namespace xmrig { }`
- **Indentation:** 4 spaces
- **Braces:** K&R style (opening brace on same line)
- **Classes:** PascalCase (`CpuBackend`, `Controller`)
- **Member variables:** `m_` prefix (`m_controller`, `m_miner`)
- **Accessor methods:** camelCase, no `get` prefix (`hashrate()`, `strategy()`)
- **Constants/macros:** `UPPER_CASE`, macros prefixed with `XMRIG_`
- **Include guards:** `#ifndef XMRIG_CLASSNAME_H` / `#define XMRIG_CLASSNAME_H`
- **Copy/move control:** Use project macros `XMRIG_DISABLE_COPY_MOVE_DEFAULT()` and `XMRIG_DISABLE_COPY_MOVE()`
- **Namespace closing:** Comment with `} // namespace xmrig`

### File Header

Every source file must have the GPLv3 copyright header:
```cpp
/* XMRig
 * Copyright (c) 2018-2026 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2026 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
```

## Architecture Notes

- **Backends** (CPU, OpenCL, CUDA) implement a common interface in `backend/common/`
- **CPU workers** are templated by intensity: `CpuWorker<N>` where N=1..8
- **Algorithm selection** is compile-time via CMake options and runtime via JSON config
- **Configuration** supports JSON files, CLI arguments, and environment variable expansion
- **HTTP API** provides runtime monitoring and control when `WITH_HTTP` is enabled
- **CUDA** support loads an external plugin rather than compiling CUDA code directly

## Platforms

Windows, Linux, macOS, FreeBSD, OpenBSD, Android, iOS, Haiku.
Architectures: x86, x86-64, ARMv7, ARMv8, RISC-V (rv64gc).

## Testing

General validation includes:

- Built-in algorithm self-tests (`src/crypto/cn/CryptoNight_test.h`)
- Built-in benchmark mode (`-DWITH_BENCHMARK`)
- CPU feature detection tests (`src/3rdparty/argon2/arch/x86_64/src/test-feature-*.c`)

The `salvium` and `combined` branches also own a focused production-parser
regression suite backed by sanitized, immutable Salvium mainnet block blobs:

```bash
cmake -S . -B build-salvium-tests -DWITH_SALVIUM_TESTS=ON
cmake --build build-salvium-tests --config Release --target salvium_block_template_tests salvium_algorithm_tests --parallel
ctest --test-dir build-salvium-tests -C Release --output-on-failure
```

The suite and fixture provenance are in
`tests/salvium_block_template_tests.cpp` and
`tests/fixtures/salvium-mainnet-blocks.json`. It must remain offline and must
not contain wallet addresses, credentials, private keys, or donation-layer
data. Refresh fixtures only from public mainnet `get_block` responses and
retain the canonical block and transaction hashes as assertions.

The same CMake option builds `salvium_algorithm_tests`. The accepted names
`rx/salvium`, `randomx/salvium`, and `randomsalvium` are compatibility aliases
for canonical `Algorithm::RX_0`; they are not a separate RandomX variant.
Keep every backend on the existing `RX_0` path.

The complete review of SomeRandomCryptoGuy's upstream work is recorded in
`docs/SALVIUM_PR_3508.md`. Recheck the live open and closed PR inventory
before claiming that reconciliation is current.
