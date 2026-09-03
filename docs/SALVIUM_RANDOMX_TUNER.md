# Salvium RandomX tuner

`scripts/tune-salvium-randomx.ps1` is a Windows benchmark controller for
finding a strong RandomX CPU configuration before changing a production
Salvium miner. Salvium uses canonical `rx/0`, so the tuner exercises the same
CPU hashing path with XMRig's offline benchmark.

The tuner is most useful on hybrid processors such as Intel Core CPUs with
performance and efficient cores. It reads Windows CPU-set `EfficiencyClass`
data, creates cache-conscious affinity candidates, and narrows the search in
four stages:

1. Compare performance-core and performance-plus-efficient-core profiles.
2. Test scratchpad prefetch modes 0 through 3 on the leading profiles.
3. Test yield and RandomX JIT huge-page combinations on the leader.
4. Repeat the two strongest configurations to reduce single-run noise.

## Safety and privacy

The tuner:

- never modifies the supplied XMRig executable or production `config.json`;
- reads only CPU and RandomX tuning fields from an existing configuration;
- generates temporary, credential-free offline benchmark configurations;
- never copies pool URLs, wallets, passwords, or API access tokens;
- disables all networking and online benchmark submission;
- disables MSR reads and writes, cache QoS, OpenCL, and CUDA;
- refuses to run beside another `xmrig` process unless explicitly overridden;
- recognizes XMRig's benchmark completion record, then stops only the child
  process it launched because an offline XMRig benchmark otherwise waits for
  Ctrl+C;
- removes each temporary configuration after completion, failure, timeout, or
  interruption;
- leaves temperature monitoring completely disabled unless it is requested;
- fails before benchmarking if temperature enforcement is requested but a
  reliable sensor cannot be read;
- stops and disqualifies only its owned child when an enforced temperature
  ceiling is reached;
- writes reports outside the repository by default.

The default output location is:

```text
%LOCALAPPDATA%\XmrigSalviumTuner\Runs\<timestamp>
```

Each run directory contains raw standard-output and standard-error logs,
incrementally updated `measurements.csv` and `measurements.json`, `report.md`,
and a
`recommended-settings.json` fragment containing no pool configuration. The
fragment separates measured recommendations from settings that were merely
held constant; it does not recommend disabling MSR in the production miner.
XMRig writes its raw log incrementally, so the standard-output log grows
while a benchmark is initializing and running instead of appearing only
after the child exits.

The script controls only XMRig child processes that it starts. It does not
stop an existing miner, change Windows boot configuration, disable Hyper-V,
or attempt to make MSR writes work through a hypervisor.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 or PowerShell 7.
- A 64-bit XMRig build with CPU, RandomX, and benchmark support.
- Enough free memory for the RandomX dataset.
- Huge-page privileges when huge pages are to be measured.

Temperature monitoring on Windows additionally requires one of:

- a running LibreHardwareMonitor WMI provider under
  `root/LibreHardwareMonitor`;
- a running OpenHardwareMonitor WMI provider under
  `root/OpenHardwareMonitor`; or
- `-TemperatureCommand` with a PowerShell expression that returns exactly one
  Celsius value.

Some hardware sensors require the monitoring provider and tuner to run with
administrator rights. The tuner does not use Windows ACPI thermal-zone values
as an automatic CPU-package fallback because a firmware thermal zone is not
guaranteed to represent the processor package.

Close the production miner before running the tuner. Keep virtual-machine and
background workloads stopped or consistent throughout the run; otherwise the
ranking measures changing system load instead of the candidate settings.

## Inspect the plan

Start with plan-only mode. This detects the topology, imports the adjacent
`config.json` tuning fields when available, and shows every stage-one affinity
without starting XMRig:

```powershell
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -PlanOnly
```

Use `-IgnoreAdjacentConfig` to start from conservative built-in tuning
defaults. Use `-BaselineConfigPath` when the configuration is not beside the
executable:

```powershell
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\miners\xmrig.exe `
    -BaselineConfigPath E:\miners\salvium-config.json `
    -PlanOnly
```

Only the following fields can be imported:

- the `rx/0`, `rx`, or wildcard CPU affinity;
- CPU huge pages, JIT huge pages, memory pool, yield, assembly, and AES mode;
- RandomX initialization, mode, NUMA, and scratchpad prefetch mode.

MSR and cache-QoS values are deliberately ignored.

## Smoke test

A smoke test runs one 250K benchmark with the imported baseline affinity, or
one logical processor from every detected performance core when no baseline
profile is available:

```powershell
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -SmokeTest
```

Run this before committing an hour or more to a larger tuning session.

## Tuning presets

Quick uses a 250K benchmark and a reduced affinity search:

```powershell
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -Preset Quick
```

Standard is the recommended first complete run. It uses 1M hashes per
measurement, tests the best two affinity profiles across the prefetch modes,
and confirms the two leading configurations:

```powershell
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -Preset Standard
```

Thorough uses 2M hashes by default, tries every efficient-core count up to the
approximate two-megabytes-of-L3-per-thread limit, advances the best three
profiles, and performs two additional confirmations:

```powershell
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -Preset Thorough
```

Override the preset size with `-BenchmarkSize`. XMRig release builds accept
`250K`, `500K`, and `1M` through `10M`.

## CPU temperature monitoring and enforcement

Temperature support is opt-in. With no temperature option, the tuner does not
look for a sensor, create temperature logs, wait for thermal cooldowns, or use
temperature in candidate eligibility.

### Select and verify the Windows sensor

Start LibreHardwareMonitor or OpenHardwareMonitor before launching the tuner.
To inspect the temperature sensors exposed by LibreHardwareMonitor:

```powershell
Get-CimInstance `
    -Namespace root/LibreHardwareMonitor `
    -ClassName Sensor |
    Where-Object SensorType -eq Temperature |
    Select-Object Name, Identifier, Value
```

Replace the namespace with `root/OpenHardwareMonitor` when appropriate. The
tuner auto-selects a CPU Package sensor when one is present, followed by Core
Max, Tctl/Tdie, and other CPU temperature sensors. It prints and records the
chosen name and identifier before XMRig starts.

Use an exact identifier when auto-selection is not the sensor shown by the
hardware-monitoring UI:

```powershell
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -Preset Thorough `
    -MonitorCpuTemperature `
    -TemperatureSensorIdentifier "/intelcpu/0/temperature/1"
```

The example identifier is illustrative; use the identifier reported on the
actual computer.

`-TemperatureCommand` is an integration point for another sensor provider.
The expression is evaluated for each sample and must return exactly one
numeric Celsius value. For example, if another trusted tool continuously
updates a text file:

```powershell
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -MonitorCpuTemperature `
    -TemperatureCommand "[double](Get-Content E:\sensors\cpu-package-c.txt -Raw)"
```

The command is user-supplied PowerShell and runs with the tuner's privileges.
Do not use an untrusted expression.

### Monitor without changing the winner

Monitor-only mode displays temperature every ten seconds, writes one sample
per second by default, and adds mean, 95th-percentile, and maximum temperature
to the measurements and report. It does not disqualify candidates or alter
ranking:

```powershell
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -Preset Thorough `
    -MonitorCpuTemperature
```

Every candidate receives a live
`<sequence>-<candidate>.temperature.csv` containing UTC timestamps and Celsius
values.

### Enforce a maximum temperature

Specifying a maximum implies monitoring and turns temperature into a hard
eligibility constraint:

```powershell
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -Preset Thorough `
    -MaxCpuTemperatureC 80
```

The enforcement behavior is:

1. Verify the sensor and its initial value before XMRig starts.
2. Before each candidate, wait until the temperature is at or below the
   ceiling minus the cooldown margin.
3. Require that cool condition to remain stable before launching the
   candidate.
4. Sample and append temperature while XMRig runs.
5. At the first sample at or above the ceiling, stop only the owned XMRig
   child and mark the candidate `ThermallyLimited`.
6. Exclude thermally limited candidates from every adaptive ranking and final
   recommendation.
7. Continue with the next distinct candidate after temperature-conditioned
   cooldown.
8. If no candidate complies, write the measurements and report but do not
   write `recommended-settings.json`.

The defaults for an 80 C ceiling are:

- resume at or below 75 C (`-TemperatureCooldownMarginC 5`);
- remain cool for 20 seconds (`-TemperatureStableSeconds 20`);
- sample every second (`-TemperatureSampleSeconds 1`);
- wait at most 1800 seconds for cooldown
  (`-TemperatureCooldownTimeoutSeconds 1800`);
- continue to honor `-CooldownSeconds` as a minimum inter-candidate delay.

The temperature ceiling is a tuning policy, not a replacement for firmware
thermal protection. Sampling and process shutdown have finite latency. If a
machine must remain strictly below a physical limit, select a tuner ceiling
with an appropriate safety margin below that physical limit.

When an enforced sensor disappears, returns multiple values, returns
non-numeric data, or produces an implausible value, the tuner stops rather
than silently continuing without enforcement. Monitor-only mode warns,
preserves its samples, and allows the benchmark itself to finish.

`-PlanOnly` describes the requested temperature policy but does not require a
running sensor provider. Sensor preflight occurs only when benchmarks will
actually run.

This feature discovers a continuously compliant configuration. It does not
dynamically switch between hot and cool mining configurations during
production operation.

## CPU topology overrides

Windows normally reports a higher `EfficiencyClass` for performance cores.
When firmware, virtualization, or a future processor reports unsuitable
classification data, supply both processor lists manually:

```powershell
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -PCoreLogicalProcessors 0,2,4,6,8,10,12,14 `
    -ECoreLogicalProcessors 16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31 `
    -PlanOnly
```

`-IncludeSmt` adds one extra candidate containing all logical processors from
the detected performance cores. SMT is not included by default because a
second RandomX thread on the same performance core often competes for cache
and execution resources.

## Interpreting the result

The report ranks successful, temperature-compliant configurations by median
hash rate and uses mean hash rate as a secondary key. In monitor-only or
temperature-disabled mode, temperature does not change that ordering. The
recommendation is not applied automatically.

Before changing the production miner:

1. Prefer repeated results over a single maximum.
2. Treat differences below roughly one percent cautiously.
3. Run the candidate on the SAL pool for several hours.
4. Compare accepted shares, not only the console's maximum hash rate.
5. Watch package temperature, sustained clocks, and power limits.
6. Test normal virtual-machine responsiveness.

The tuner uses CPU priority 2 by default and holds it constant. Override it
with `-CpuPriority` only when the operational tradeoff is understood.
No-yield can win the offline benchmark while making the host or virtual
machines noticeably less responsive.

MSR access is intentionally outside this experiment. If MSR modification
later becomes available under a separate non-hypervisor boot, rerun or
validate the winning affinity there as a separate comparison.

## Regression test

The lightweight test compiles a mock XMRig executable and verifies disabled,
monitor-only, compliant, thermally limited, cooldown, sensor-failure, report,
and owned-child-cleanup behavior without running RandomX:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\test_salvium_tuner_temperature.ps1
```
