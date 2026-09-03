# Salvium RandomX tuner for Linux

`scripts/tune-salvium-randomx.sh` is the native Linux companion to the
Windows PowerShell tuner. It runs credential-free, offline XMRig `rx/0`
benchmarks to find a strong CPU affinity, scratchpad prefetch mode, yield
setting, and RandomX JIT huge-page setting before the production Salvium
configuration is changed.

Salvium uses canonical `rx/0`, so the benchmark exercises the same CPU hashing
implementation used while mining SAL.

## When the Linux tuner is useful

The tuner is useful on:

- Intel hybrid processors with performance and efficient cores;
- homogeneous Intel and AMD desktop CPUs;
- Linux servers whose effective CPU set is restricted by a container,
  service manager, batch scheduler, or cgroup;
- systems where SMT, NUMA, or cache topology makes XMRig's automatic profile
  worth comparing with a controlled physical-core profile.

Linux often gives XMRig better control over huge pages, one-gigabyte pages,
NUMA placement, CPU frequency policy, and MSR access than a virtualized
Windows host. Those system-level facilities are not changed by this script.
The tuner isolates affinity and the RandomX settings that can be compared
safely without root-level system mutation.

## Requirements

- Linux.
- Bash 4.4 or newer.
- `awk`, `grep`, `sed`, and `sort`.
- A Linux XMRig executable with CPU, RandomX, and benchmark support.
- Enough free memory for the RandomX dataset.
- Optional: Python 3 to import tuning fields from an existing `config.json`.
- Optional for temperature monitoring: a readable Linux hwmon CPU sensor or a
  command that prints one Celsius value.

Python is not needed for topology detection, benchmarking, ranking, or report
generation. When Python is unavailable, the tuner warns and continues with
safe tuning defaults rather than attempting to parse JSON with regular
expressions.

The script does not invoke `sudo`. Configure Linux huge pages, one-gigabyte
pages, locked-memory limits, and MSR access separately before benchmarking if
those facilities are intended to represent production.

## Topology discovery

The tuner reads the process's effective `Cpus_allowed_list` and intersects it
with the online CPUs exported by `/sys/devices/system/cpu`. This means a
container or systemd/cgroup CPU restriction is respected instead of
benchmarking CPUs the process cannot use.

Physical cores and SMT siblings are identified from the kernel's package,
die, core, and `core_cpus_list` topology attributes. Last-level cache capacity
is summed once per unique shared L3 domain.

Core classification is attempted in this order:

1. Explicit `--performance-cpus` and `--efficient-cpus` lists.
2. A varying Linux `topology/core_type` attribute when the kernel exports it.
3. Mixed SMT topology on Intel hybrid processors: cores with SMT are treated
   as performance cores and single-threaded cores as efficient cores.
4. A significant difference in Linux scheduler CPU capacity.
5. A significant difference in maximum per-CPU frequency.
6. Homogeneous physical-core topology.

The frequency fallback requires at least a 15-percent class difference so
minor preferred-core or boost-bin variation is not mistaken for an efficient
core class.

On a homogeneous CPU, the tuner still compares an imported baseline with one
logical CPU per physical core, and it can test all SMT siblings with
`--include-smt`. Multi-CCD and X3D-specific AMD scheduling is not yet inferred
automatically; use explicit CPU lists when a particular CCD or cache domain
must be isolated.

## Safety and privacy

Every generated benchmark configuration:

- contains no pools, wallets, passwords, or API access tokens;
- disables HTTP listening and all network pools;
- disables online benchmark submission;
- disables MSR reads and writes and cache QoS;
- disables OpenCL and CUDA;
- uses a deterministic offline RandomX benchmark;
- is removed after the child process exits.

The tuner:

- never edits the production `config.json`;
- never edits the XMRig executable;
- recognizes XMRig's benchmark completion record, then stops only the child
  process it launched because an offline XMRig benchmark otherwise waits for
  Ctrl+C;
- refuses to run beside another process whose Linux command name begins with
  `xmrig`, unless the unsafe override is explicitly supplied;
- does not change governors, CPU frequencies, cgroups, NUMA policy, huge-page
  allocation, kernel parameters, or boot options;
- leaves temperature monitoring completely disabled unless requested;
- fails before benchmarking if temperature enforcement is requested but its
  sensor cannot be read;
- stops and thermally disqualifies only its owned child at an enforced
  temperature ceiling;
- writes reports outside the repository by default;
- never applies the winning recommendation automatically.

The recommendation separates measured settings from settings held constant.
It does not recommend disabling MSR or one-gigabyte pages in production.

## Result location

By default, results are written under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/xmrig-salvium-tuner/runs/<timestamp>
```

Each run directory contains:

- raw standard-output and standard-error logs;
- one live `<candidate>.temperature.csv` per candidate when monitoring is
  enabled;
- `measurements.tsv`;
- `measurements.csv`;
- `rankings.tsv`;
- `report.md`;
- `recommended-settings.json`.

XMRig writes its raw log incrementally, so the standard-output log grows
while a benchmark is initializing and running instead of appearing only
after the child exits. Temporary benchmark configurations and owned child
processes are cleaned up on completion, failure, timeout, or interruption.

## Inspect the plan

From a release directory containing `xmrig` and the tuner:

```bash
./tune-salvium-randomx.sh \
  --xmrig ./xmrig \
  --plan-only
```

If the executable is not beside its configuration:

```bash
./tune-salvium-randomx.sh \
  --xmrig /opt/xmrig/xmrig \
  --baseline-config /etc/xmrig/config.json \
  --plan-only
```

When Python 3 is installed, only these fields can be imported:

- the `rx/0`, `rx`, or wildcard CPU affinity;
- CPU huge pages, JIT huge pages, memory pool, yield, assembly, and AES mode;
- RandomX initialization, mode, NUMA, one-gigabyte pages, and scratchpad
  prefetch mode.

MSR and cache-QoS values are intentionally ignored.

## Smoke test

Stop the production miner normally, then run one 250K benchmark:

```bash
./tune-salvium-randomx.sh \
  --xmrig ./xmrig \
  --smoke-test
```

The smoke test uses the imported baseline affinity when available, otherwise
one allowed Linux CPU from each physical/performance core.

## Tuning presets

Quick uses 250K hashes and a reduced affinity search:

```bash
./tune-salvium-randomx.sh \
  --xmrig ./xmrig \
  --preset quick
```

Standard is the recommended first complete run. It uses 1M hashes per
measurement, advances the two strongest affinities through the prefetch
stage, tests yield and JIT huge pages, and confirms the two leaders:

```bash
./tune-salvium-randomx.sh \
  --xmrig ./xmrig \
  --preset standard
```

Thorough uses 2M hashes by default, tests every efficient-core count up to the
approximate two-megabytes-of-L3-per-thread limit, advances the three strongest
affinities, and repeats the final leaders twice:

```bash
./tune-salvium-randomx.sh \
  --xmrig ./xmrig \
  --preset thorough
```

Override the preset size with `--benchmark-size`. Supported XMRig release
sizes are `250K`, `500K`, and `1M` through `10M`.

## CPU temperature monitoring and enforcement

Temperature support is opt-in. When no temperature option is present, the
tuner does not discover or read sensors, create temperature logs, wait for a
thermal cooldown, or use temperature in candidate eligibility.

### Automatic Linux sensor discovery

The tuner searches `/sys/class/hwmon/hwmon*` and considers CPU sensors from:

- Intel `coretemp`;
- AMD `k10temp`;
- AMD `zenpower`.

It prefers package-level labels such as `Package id 0`, followed by Core Max,
Tctl/Tdie, Tdie, Tctl, and other CPU/core readings. The exact driver, label,
and resolved `temp*_input` path are printed before XMRig starts and recorded
in the report.

Use monitor-only mode to verify the selected sensor without changing which
candidate can win:

```bash
./tune-salvium-randomx.sh \
  --xmrig ./xmrig \
  --preset thorough \
  --monitor-cpu-temperature
```

Every candidate receives a live temperature CSV with UTC timestamps and
Celsius values. The measurement and ranking reports include mean,
95th-percentile, and maximum temperature. Monitor-only temperatures do not
alter the hashrate ranking.

If auto-detection chooses the wrong package or die, provide the exact hwmon
input:

```bash
./tune-salvium-randomx.sh \
  --xmrig ./xmrig \
  --monitor-cpu-temperature \
  --temperature-sensor /sys/class/hwmon/hwmon3/temp1_input
```

Because hwmon numbers can change after reboot, verify the associated `name`
and `temp*_label` files rather than permanently assuming that `hwmon3` is the
same device.

`--temperature-command` integrates another trusted sensor provider. The
command is evaluated for every sample and must print exactly one numeric
Celsius value:

```bash
./tune-salvium-randomx.sh \
  --xmrig ./xmrig \
  --monitor-cpu-temperature \
  --temperature-command "sensors -j | jq -r '.\"coretemp-isa-0000\".\"Package id 0\".temp1_input'"
```

That command is illustrative because lm-sensors chip names vary. The command
runs with the tuner's privileges and must not come from an untrusted source.

`--hwmon-root` supplies an alternate hwmon tree for containers, chroots, and
tests. Normal host use should retain `/sys/class/hwmon`.

### Enforce a maximum temperature

Specifying a maximum implies monitoring and turns the ceiling into a hard
candidate constraint:

```bash
./tune-salvium-randomx.sh \
  --xmrig ./xmrig \
  --preset thorough \
  --max-cpu-temperature 80
```

The tuner then:

1. verifies the sensor and initial value before creating a result directory;
2. waits for a stable cool starting condition before every candidate;
3. samples and appends temperature while XMRig runs;
4. stops only its owned child at the first sample at or above the ceiling;
5. records the candidate as thermally limited instead of a generic failure;
6. excludes thermally limited candidates from adaptive and final rankings;
7. waits for temperature-conditioned cooldown before another candidate; and
8. writes measurements and an explanatory report, but no recommendation, if
   no candidate complies.

For an 80 C ceiling, the defaults are:

- resume at or below 75 C (`--temperature-cooldown-margin 5`);
- remain there for 20 seconds (`--temperature-stable-seconds 20`);
- sample every second (`--temperature-sample-seconds 1`);
- wait at most 1800 seconds for cooldown
  (`--temperature-cooldown-timeout-seconds 1800`);
- continue treating `--cooldown-seconds` as a minimum delay between
  candidates.

An enforced run fails closed if the sensor disappears, cannot be read,
returns multiple lines, returns non-numeric output, or produces an implausible
temperature. Monitor-only mode warns, retains samples already written, and
allows the benchmark itself to complete.

The ceiling is a tuning policy and not a replacement for firmware thermal
protection. Sampling and process termination have finite latency. Choose a
ceiling with a safety margin below any physical temperature that must never
be crossed.

`--plan-only` displays the requested thermal policy without requiring a live
sensor. Sensor preflight occurs when an actual benchmark run begins.

Temperature enforcement finds a continuously compliant configuration. It
does not switch dynamically between hot and cool configurations during
production mining.

## Manual topology

When firmware, virtualization, CPU hotplug, or a kernel configuration hides
hybrid-core information, supply both primary CPU lists:

```bash
./tune-salvium-randomx.sh \
  --xmrig ./xmrig \
  --performance-cpus 0,2,4,6,8,10,12,14 \
  --efficient-cpus 16-31 \
  --plan-only
```

The lists must be inside the process's effective allowed CPU set and must not
overlap on a physical core.

`--allowed-cpus` further restricts discovery. It is useful for deliberate
container/cgroup experiments:

```bash
./tune-salvium-randomx.sh \
  --xmrig ./xmrig \
  --allowed-cpus 0-15 \
  --plan-only
```

`--sysfs-cpu-root` exists for containers, chroots, and diagnostic fixtures.
Normal host use should keep the default `/sys/devices/system/cpu`.

## Interpreting the result

The final report ranks successful, temperature-compliant configurations by
median hash rate and uses the mean as a secondary key. Temperature-disabled
and monitor-only runs retain the existing hashrate-only ordering.

Before changing the production miner:

1. Prefer repeated measurements over a single maximum.
2. Treat differences below roughly one percent cautiously.
3. Run the candidate on the SAL pool for several hours.
4. Compare accepted shares, not only console hash rate.
5. Watch temperature, sustained clocks, package power, and throttling.
6. Keep background and virtual-machine/container workloads consistent.
7. Validate MSR and one-gigabyte pages as separate experiments.

The default CPU priority is 2 and is held constant. No-yield may win the
offline benchmark while making the host or colocated workloads less
responsive.

## Current scope

The Linux tuner supports CPU numbers larger than 63 and can observe multiple
packages, dies, cache domains, and NUMA-aware XMRig operation. Its automatic
candidate generation remains intentionally conservative:

- Intel hybrid P/E progression is supported when Linux exposes enough class
  information.
- Homogeneous physical-core and optional-SMT profiles are supported.
- Container and cgroup CPU allowances are respected.
- AMD CCD, CCX, X3D V-Cache preference, and per-NUMA core-count sweeps are not
  automatically generated yet; use explicit CPU lists for those cases.

The script is Linux-only. Use `tune-salvium-randomx.ps1` and the Windows guide
on Windows.

## Regression test

The lightweight test uses a mock XMRig process and fake `coretemp` hwmon tree
to verify disabled, monitor-only, compliant, thermally limited, cooldown,
sensor-failure, report, and owned-child-cleanup behavior without running
RandomX:

```bash
bash tests/test_salvium_tuner_temperature.sh
```
