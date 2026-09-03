#Requires -Version 5.1

<#
.SYNOPSIS
Finds a strong RandomX CPU affinity and tuning profile for Salvium mining.

.DESCRIPTION
Runs credential-free, offline XMRig rx/0 benchmarks against staged CPU
affinity and RandomX configuration candidates. On Windows hybrid processors,
the script uses CPU-set EfficiencyClass data to distinguish performance and
efficient cores. It never edits the user's XMRig configuration.

The script writes raw logs, CSV/JSON measurements, a Markdown report, and a
credential-free recommendation under the selected output directory. MSR
reads and writes, cache QoS, GPUs, networking, and online benchmark submission
are disabled in every generated benchmark configuration.

.PARAMETER XmrigPath
Path to the XMRig executable to benchmark.

.PARAMETER BaselineConfigPath
Optional path to an existing XMRig config.json. Only CPU and RandomX tuning
fields are read. Pools, wallets, passwords, API tokens, and network settings
are never copied. If omitted, config.json beside the executable is used when
present unless IgnoreAdjacentConfig is specified.

.PARAMETER Preset
Quick uses 250K hashes, Standard uses 1M, and Thorough uses 2M by default.
Rigorous uses stage-specific sizes, randomized repeated screening, an adaptive
survivor beam, reference anchors, and repeated finalist confirmation. The
preset also controls the number of candidate profiles and confirmations.

.PARAMETER BenchmarkSize
Overrides the preset's benchmark size. Supported XMRig release sizes are
250K, 500K, and 1M through 10M. In Rigorous mode, an explicit value also
becomes the default for all three stage-specific size parameters.

.PARAMETER ScreeningBenchmarkSize
Benchmark size for Rigorous affinity screening and reference anchors. The
automatic Rigorous value is 500K.

.PARAMETER RefinementBenchmarkSize
Benchmark size for the Rigorous scratchpad-prefetch refinement stage. The
automatic Rigorous value is 1M.

.PARAMETER FinalBenchmarkSize
Benchmark size for repeated Rigorous finalist measurements. The automatic
Rigorous value is 5M.

.PARAMETER ScreeningRepeats
Number of randomized Rigorous affinity-screening measurements per profile.
Zero selects the preset default, which is two in Rigorous mode.

.PARAMETER FinalConfirmationRuns
Number of measurements for every Rigorous finalist. Zero selects the preset
default, which is three in Rigorous mode.

.PARAMETER AdvanceWithinPercent
Keeps Rigorous candidates whose median is within this percentage of the
stage leader, subject to MaximumSurvivors. The default is two percent.

.PARAMETER MaximumSurvivors
Maximum number of candidates advanced by each Rigorous survivor beam. The
default is four.

.PARAMETER ReferenceInterval
Runs the baseline/reference candidate after this many Rigorous affinity
measurements to expose environmental drift. Zero keeps only the start and
end anchors. The default is five.

.PARAMETER CandidateOrderSeed
Seed for deterministic candidate randomization in Rigorous mode. Zero
generates and records a seed.

.PARAMETER ResumeDirectory
Continues an interrupted Rigorous run from its manifest and preserved
measurements. Resume rejects changed tuner/XMRig/baseline content, CPU
topology, or affinity profiles.

.PARAMETER CpuPriority
XMRig CPU priority for every test. The conservative default is 2. Priority is
held constant because this tuner compares affinity, prefetch, yield, and
huge-page JIT behavior.

.PARAMETER PCoreLogicalProcessors
Manual performance-core logical processor indexes. Specify this together
with ECoreLogicalProcessors only if Windows CPU-set detection is unsuitable.

.PARAMETER ECoreLogicalProcessors
Manual efficient-core logical processor indexes. Specify this together with
PCoreLogicalProcessors only if Windows CPU-set detection is unsuitable.

.PARAMETER IncludeSmt
Adds one candidate using all performance-core logical processors, including
SMT siblings. It is tested only as an additional candidate.

.PARAMETER ExploreThermalAffinities
Adds efficient-only, partial-performance-core, and cache-boundary affinity
profiles. Rigorous mode enables this exploration automatically.

.PARAMETER PlanOnly
Displays the detected topology, stage-one profiles, and estimated run count
without launching XMRig or writing results.

.PARAMETER SmokeTest
Runs a single 250K benchmark using the imported baseline affinity, or the
detected performance-core profile when no baseline affinity is available.

.PARAMETER AllowConcurrentXmrig
Allows benchmarks while another xmrig process is running. This produces
confounded results and is intentionally rejected unless explicitly enabled.

.PARAMETER MonitorCpuTemperature
Records and displays CPU temperature without changing candidate eligibility
or ranking. MaxCpuTemperatureC implies this option.

.PARAMETER MaxCpuTemperatureC
Optional hard CPU-temperature ceiling in degrees Celsius. A candidate that
reaches the ceiling is stopped and marked thermally limited. When omitted,
temperature does not affect candidate eligibility or ranking.

.PARAMETER TemperatureSensorIdentifier
Optional exact LibreHardwareMonitor or OpenHardwareMonitor WMI sensor
identifier. When omitted, the tuner prefers a CPU Package sensor and then
other CPU temperature sensors.

.PARAMETER TemperatureCommand
Optional PowerShell expression that returns exactly one temperature in
degrees Celsius. This provides an integration point for other sensor tools
and takes precedence over WMI auto-detection.

.PARAMETER TemperatureSampleSeconds
Temperature sampling interval. The default is one second.

.PARAMETER TemperatureCooldownMarginC
With a maximum temperature, the next candidate waits until the sensor is at
or below maximum minus this margin. The default is 5 degrees Celsius.

.PARAMETER TemperatureStableSeconds
With a maximum temperature, the sensor must remain below the cooldown
threshold for this many seconds before a candidate starts. The default is 20.

.PARAMETER TemperatureCooldownTimeoutSeconds
Maximum time to wait for a temperature-conditioned cooldown. The default is
1800 seconds.

.EXAMPLE
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -PlanOnly

.EXAMPLE
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -Preset Standard

.EXAMPLE
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -SmokeTest

.EXAMPLE
.\scripts\tune-salvium-randomx.ps1 `
    -XmrigPath E:\xmrig-6.25.0\xmrig.exe `
    -Preset Thorough `
    -MaxCpuTemperatureC 80

powershell.exe -NoProfile -ExecutionPolicy Bypass `
      -File E:\xmrig-dev\xmrig\scripts\tune-salvium-randomx.ps1 `
      -XmrigPath "E:\xmrig-6.25.0\xmrig_6.26.0_Custome.exe" `
      -Preset Rigorous
      -MonitorCpuTemperature $true
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $XmrigPath,

    [string] $BaselineConfigPath,

    [ValidateSet("Quick", "Standard", "Thorough", "Rigorous")]
    [string] $Preset = "Standard",

    [ValidateSet("Auto", "250K", "500K", "1M", "2M", "3M", "4M", "5M", "6M", "7M", "8M", "9M", "10M")]
    [string] $BenchmarkSize = "Auto",

    [ValidateSet("Auto", "250K", "500K", "1M", "2M", "3M", "4M", "5M", "6M", "7M", "8M", "9M", "10M")]
    [string] $ScreeningBenchmarkSize = "Auto",

    [ValidateSet("Auto", "250K", "500K", "1M", "2M", "3M", "4M", "5M", "6M", "7M", "8M", "9M", "10M")]
    [string] $RefinementBenchmarkSize = "Auto",

    [ValidateSet("Auto", "250K", "500K", "1M", "2M", "3M", "4M", "5M", "6M", "7M", "8M", "9M", "10M")]
    [string] $FinalBenchmarkSize = "Auto",

    [ValidateRange(0, 10)]
    [int] $ScreeningRepeats = 0,

    [ValidateRange(0, 10)]
    [int] $FinalConfirmationRuns = 0,

    [ValidateRange(0.0, 20.0)]
    [double] $AdvanceWithinPercent = 2.0,

    [ValidateRange(1, 12)]
    [int] $MaximumSurvivors = 4,

    [ValidateRange(0, 50)]
    [int] $ReferenceInterval = 5,

    [ValidateRange(0, 2000000000)]
    [int] $CandidateOrderSeed = 0,

    [string] $ResumeDirectory,

    [ValidateRange(0, 300)]
    [int] $CooldownSeconds = 10,

    [ValidateRange(30, 7200)]
    [int] $TimeoutSeconds = 1800,

    [ValidateRange(0, 5)]
    [int] $CpuPriority = 2,

    [string] $OutputDirectory,

    [ValidateRange(0, 63)]
    [int[]] $PCoreLogicalProcessors,

    [ValidateRange(0, 63)]
    [int[]] $ECoreLogicalProcessors,

    [switch] $IncludeSmt,

    [switch] $ExploreThermalAffinities,

    [switch] $IgnoreAdjacentConfig,

    [switch] $PlanOnly,

    [switch] $SmokeTest,

    [switch] $AllowConcurrentXmrig,

    [switch] $MonitorCpuTemperature,

    [ValidateRange(1.0, 125.0)]
    [double] $MaxCpuTemperatureC = 0,

    [string] $TemperatureSensorIdentifier,

    [string] $TemperatureCommand,

    [ValidateRange(1, 60)]
    [int] $TemperatureSampleSeconds = 1,

    [ValidateRange(0.0, 30.0)]
    [double] $TemperatureCooldownMarginC = 5.0,

    [ValidateRange(0, 300)]
    [int] $TemperatureStableSeconds = 20,

    [ValidateRange(30, 7200)]
    [int] $TemperatureCooldownTimeoutSeconds = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$temperatureLimitSpecified = $PSBoundParameters.ContainsKey("MaxCpuTemperatureC")
$temperatureRequested = (
    $MonitorCpuTemperature -or
    $temperatureLimitSpecified -or
    -not [string]::IsNullOrWhiteSpace($TemperatureSensorIdentifier) -or
    -not [string]::IsNullOrWhiteSpace($TemperatureCommand)
)
if (
    -not [string]::IsNullOrWhiteSpace($TemperatureSensorIdentifier) -and
    -not [string]::IsNullOrWhiteSpace($TemperatureCommand)
) {
    throw "TemperatureSensorIdentifier and TemperatureCommand are mutually exclusive."
}
if ($temperatureLimitSpecified -and $TemperatureCooldownMarginC -ge $MaxCpuTemperatureC) {
    throw "TemperatureCooldownMarginC must be lower than MaxCpuTemperatureC."
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-StringSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "")
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-HardwareMonitorTemperatureSensors {
    $sensors = New-Object System.Collections.Generic.List[object]
    foreach ($namespace in @("root/LibreHardwareMonitor", "root/OpenHardwareMonitor")) {
        try {
            $items = @(
                Get-CimInstance -Namespace $namespace -ClassName Sensor -ErrorAction Stop |
                    Where-Object { [string] $_.SensorType -eq "Temperature" }
            )
        }
        catch {
            continue
        }

        foreach ($item in $items) {
            $identifier = [string] $item.Identifier
            $name = [string] $item.Name
            if ([string]::IsNullOrWhiteSpace($identifier)) {
                continue
            }

            $lowerIdentifier = $identifier.ToLowerInvariant()
            $lowerName = $name.ToLowerInvariant()
            $isCpu = (
                $lowerIdentifier -match "/(intelcpu|amdcpu|cpu)/" -or
                $lowerName -match "(^|[^a-z])(cpu|package|tctl|tdie|core max)([^a-z]|$)"
            )
            $score = 0
            if ($isCpu) {
                $score += 100
            }
            if ($lowerName -match "cpu package|package id|package") {
                $score += 100
            }
            elseif ($lowerName -match "core max") {
                $score += 90
            }
            elseif ($lowerName -match "tctl.*tdie|tdie|tctl") {
                $score += 80
            }
            elseif ($lowerName -match "cpu") {
                $score += 60
            }

            $sensors.Add([pscustomobject] @{
                Namespace  = $namespace
                Identifier = $identifier
                Name       = $name
                Value      = $item.Value
                IsCpu      = $isCpu
                Score      = $score
            })
        }
    }

    return @($sensors)
}

function ConvertTo-CpuTemperature {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [string] $Source
    )

    $text = [string] $Value
    $temperature = 0.0
    $parsed = [double]::TryParse(
        $text.Trim(),
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref] $temperature
    )
    if (-not $parsed) {
        throw "Temperature source '$Source' returned non-numeric output '$text'."
    }
    if ([double]::IsNaN($temperature) -or [double]::IsInfinity($temperature) -or $temperature -lt -20 -or $temperature -gt 150) {
        throw "Temperature source '$Source' returned implausible value $temperature C."
    }

    return $temperature
}

function New-CpuTemperaturePolicy {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Enabled,

        [Parameter(Mandatory = $true)]
        [bool] $Enforced,

        [AllowNull()]
        [string] $SensorIdentifier,

        [AllowNull()]
        [string] $Command,

        [Parameter(Mandatory = $true)]
        [double] $LimitC,

        [Parameter(Mandatory = $true)]
        [int] $SampleSeconds,

        [Parameter(Mandatory = $true)]
        [double] $CooldownMarginC,

        [Parameter(Mandatory = $true)]
        [int] $StableSeconds,

        [Parameter(Mandatory = $true)]
        [int] $CooldownTimeoutSeconds
    )

    if (-not $Enabled) {
        return [pscustomobject] @{
            Enabled                    = $false
            Enforced                   = $false
            ProviderKind               = "none"
            ProviderName               = $null
            Namespace                  = $null
            Identifier                 = $null
            CommandBlock               = $null
            LimitC                     = $null
            ResumeBelowC               = $null
            SampleSeconds               = $SampleSeconds
            StableSeconds               = $StableSeconds
            CooldownTimeoutSeconds      = $CooldownTimeoutSeconds
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Command)) {
        try {
            $commandBlock = [scriptblock]::Create($Command)
        }
        catch {
            throw "TemperatureCommand is not a valid PowerShell expression: $($_.Exception.Message)"
        }

        $policy = [pscustomobject] @{
            Enabled                    = $true
            Enforced                   = $Enforced
            ProviderKind               = "command"
            ProviderName               = "TemperatureCommand"
            Namespace                  = $null
            Identifier                 = $null
            CommandBlock               = $commandBlock
            LimitC                     = if ($Enforced) { $LimitC } else { $null }
            ResumeBelowC               = if ($Enforced) { $LimitC - $CooldownMarginC } else { $null }
            SampleSeconds               = $SampleSeconds
            StableSeconds               = $StableSeconds
            CooldownTimeoutSeconds      = $CooldownTimeoutSeconds
        }
        $null = Read-CpuTemperature -Policy $policy
        return $policy
    }

    $sensors = @(Get-HardwareMonitorTemperatureSensors)
    $selected = $null
    if (-not [string]::IsNullOrWhiteSpace($SensorIdentifier)) {
        $selected = $sensors |
            Where-Object { $_.Identifier -ieq $SensorIdentifier } |
            Select-Object -First 1
        if ($null -eq $selected) {
            $available = @(
                $sensors |
                    Where-Object IsCpu |
                    ForEach-Object { "'$($_.Identifier)' ($($_.Name))" }
            )
            $detail = if ($available.Count -gt 0) {
                " Available CPU sensors: $($available -join '; ')."
            }
            else {
                ""
            }
            throw "Temperature sensor '$SensorIdentifier' was not found.$detail"
        }
    }
    else {
        $selected = $sensors |
            Where-Object IsCpu |
            Sort-Object Score -Descending |
            Select-Object -First 1
    }

    if ($null -eq $selected) {
        throw @"
CPU temperature monitoring was requested, but no LibreHardwareMonitor or
OpenHardwareMonitor CPU temperature sensor is available. Run one of those
providers with its WMI interface enabled, specify TemperatureSensorIdentifier,
or supply TemperatureCommand with an expression that returns Celsius.
"@
    }

    $policy = [pscustomobject] @{
        Enabled                    = $true
        Enforced                   = $Enforced
        ProviderKind               = "wmi"
        ProviderName               = "$($selected.Name) via $($selected.Namespace)"
        Namespace                  = $selected.Namespace
        Identifier                 = $selected.Identifier
        CommandBlock               = $null
        LimitC                     = if ($Enforced) { $LimitC } else { $null }
        ResumeBelowC               = if ($Enforced) { $LimitC - $CooldownMarginC } else { $null }
        SampleSeconds               = $SampleSeconds
        StableSeconds               = $StableSeconds
        CooldownTimeoutSeconds      = $CooldownTimeoutSeconds
    }
    $null = Read-CpuTemperature -Policy $policy
    return $policy
}

function Read-CpuTemperature {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Policy
    )

    if (-not $Policy.Enabled) {
        throw "CPU temperature monitoring is disabled."
    }

    if ($Policy.ProviderKind -eq "command") {
        $values = @(
            @(& $Policy.CommandBlock) |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string] $_) }
        )
        if ($values.Count -ne 1) {
            throw "TemperatureCommand must return exactly one Celsius value; it returned $($values.Count)."
        }
        return ConvertTo-CpuTemperature -Value $values[0] -Source $Policy.ProviderName
    }

    if ($Policy.ProviderKind -eq "wmi") {
        $sensor = Get-CimInstance -Namespace $Policy.Namespace -ClassName Sensor -ErrorAction Stop |
            Where-Object { [string] $_.Identifier -ieq $Policy.Identifier } |
            Select-Object -First 1
        if ($null -eq $sensor) {
            throw "Temperature sensor '$($Policy.Identifier)' disappeared from $($Policy.Namespace)."
        }
        return ConvertTo-CpuTemperature -Value $sensor.Value -Source $Policy.ProviderName
    }

    throw "Unknown CPU temperature provider '$($Policy.ProviderKind)'."
}

function Get-TemperatureStatistics {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [double[]] $Values,

        [Parameter(Mandatory = $true)]
        [int] $SampleSeconds
    )

    if ($Values.Count -eq 0) {
        return [pscustomobject] @{
            Samples             = 0
            Start               = $null
            Mean                = $null
            P95                 = $null
            Maximum             = $null
            End                 = $null
            SlopeCPerMinute     = $null
            FirstQuarterMeanC   = $null
            FinalQuarterMeanC   = $null
        }
    }

    $ordered = @($Values | Sort-Object)
    $p95Index = [int] [Math]::Max(0, [Math]::Ceiling($ordered.Count * 0.95) - 1)
    $quarterCount = [Math]::Max(1, [int] [Math]::Ceiling($Values.Count / 4.0))
    $firstQuarter = @($Values | Select-Object -First $quarterCount)
    $finalQuarter = @($Values | Select-Object -Last $quarterCount)
    $slopeCPerMinute = $null
    if ($Values.Count -gt 1) {
        $meanIndex = ($Values.Count - 1) / 2.0
        $meanTemperature = ($Values | Measure-Object -Average).Average
        $numerator = 0.0
        $denominator = 0.0
        for ($index = 0; $index -lt $Values.Count; $index++) {
            $indexDelta = $index - $meanIndex
            $numerator += $indexDelta * ($Values[$index] - $meanTemperature)
            $denominator += $indexDelta * $indexDelta
        }
        if ($denominator -gt 0) {
            $slopePerSample = $numerator / $denominator
            $slopeCPerMinute = $slopePerSample * (60.0 / $SampleSeconds)
        }
    }

    return [pscustomobject] @{
        Samples             = $Values.Count
        Start               = [double] $Values[0]
        Mean                = [double] (($Values | Measure-Object -Average).Average)
        P95                 = [double] $ordered[$p95Index]
        Maximum             = [double] (($Values | Measure-Object -Maximum).Maximum)
        End                 = [double] $Values[$Values.Count - 1]
        SlopeCPerMinute     = $slopeCPerMinute
        FirstQuarterMeanC   = [double] (($firstQuarter | Measure-Object -Average).Average)
        FinalQuarterMeanC   = [double] (($finalQuarter | Measure-Object -Average).Average)
    }
}

function Wait-ForTemperatureReady {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Policy,

        [Parameter(Mandatory = $true)]
        [int] $MinimumWaitSeconds
    )

    if (-not $Policy.Enforced) {
        return [pscustomobject] @{
            WaitSeconds = 0.0
            ReadyTemperatureC = $null
        }
    }

    $startedAt = [DateTime]::UtcNow
    $minimumReadyAt = $startedAt.AddSeconds($MinimumWaitSeconds)
    $deadline = $startedAt.AddSeconds($Policy.CooldownTimeoutSeconds)
    $stableSince = $null
    $lastDisplayAt = [DateTime]::MinValue
    while ($true) {
        $now = [DateTime]::UtcNow
        $temperature = Read-CpuTemperature -Policy $Policy
        if ($temperature -le $Policy.ResumeBelowC) {
            if ($null -eq $stableSince) {
                $stableSince = $now
            }
        }
        else {
            $stableSince = $null
        }

        $minimumWaitSatisfied = $now -ge $minimumReadyAt
        $stableSatisfied = (
            $Policy.StableSeconds -eq 0 -or
            ($null -ne $stableSince -and ($now - $stableSince).TotalSeconds -ge $Policy.StableSeconds)
        )
        if ($minimumWaitSatisfied -and $stableSatisfied) {
            return [pscustomobject] @{
                WaitSeconds = ($now - $startedAt).TotalSeconds
                ReadyTemperatureC = $temperature
            }
        }

        if ($now -ge $deadline) {
            throw "CPU temperature did not remain at or below $($Policy.ResumeBelowC) C within $($Policy.CooldownTimeoutSeconds) seconds; last reading was $temperature C."
        }

        if (($now - $lastDisplayAt).TotalSeconds -ge 10) {
            Write-Host ("      cooling: {0:N1} C; waiting for <= {1:N1} C for {2} seconds" -f @(
                $temperature,
                $Policy.ResumeBelowC,
                $Policy.StableSeconds
            ))
            $lastDisplayAt = $now
        }
        Start-Sleep -Seconds $Policy.SampleSeconds
    }
}

function Get-ObjectProperty {
    param(
        [AllowNull()]
        [object] $Object,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [AllowNull()]
        [object] $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Get-LogicalProcessorsFromProfile {
    param(
        [AllowNull()]
        [object] $Profile
    )

    if ($null -eq $Profile) {
        return @()
    }

    $processors = New-Object System.Collections.Generic.List[int]
    foreach ($entry in @($Profile)) {
        $affinity = $null
        if ($entry -is [System.Array]) {
            $values = @($entry)
            if ($values.Count -ge 2) {
                $affinity = $values[$values.Count - 1]
            }
        }
        elseif ($entry -is [int] -or $entry -is [long] -or $entry -is [decimal]) {
            $affinity = $entry
        }

        if ($null -ne $affinity) {
            $value = [int] $affinity
            if ($value -ge 0 -and $value -le 63) {
                $processors.Add($value)
            }
        }
    }

    return @($processors | Sort-Object -Unique)
}

function Read-BaselineSettings {
    param(
        [AllowNull()]
        [string] $Path
    )

    $settings = [ordered] @{
        Path                    = $null
        Affinity                = @()
        HugePages               = $true
        HugePagesJit            = $false
        MemoryPool              = $true
        Yield                   = $true
        Assembly                = $true
        HardwareAes             = $null
        RandomXInit             = -1
        RandomXInitAvx2         = -1
        RandomXMode             = "auto"
        RandomXNuma             = $true
        ScratchpadPrefetchMode  = 1
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject] $settings
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $document = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    $settings.Path = $resolvedPath

    $cpu = Get-ObjectProperty -Object $document -Name "cpu"
    $randomx = Get-ObjectProperty -Object $document -Name "randomx"

    foreach ($profileName in @("rx/0", "rx", "*")) {
        $profile = Get-ObjectProperty -Object $cpu -Name $profileName
        $affinity = @(Get-LogicalProcessorsFromProfile -Profile $profile)
        if ($affinity.Count -gt 0) {
            $settings.Affinity = $affinity
            break
        }
    }

    $value = Get-ObjectProperty -Object $cpu -Name "huge-pages"
    if ($null -ne $value -and ($value -is [bool] -or $value -is [int] -or $value -is [long])) {
        $settings.HugePages = $value
    }

    $value = Get-ObjectProperty -Object $cpu -Name "huge-pages-jit"
    if ($value -is [bool]) {
        $settings.HugePagesJit = $value
    }

    $value = Get-ObjectProperty -Object $cpu -Name "memory-pool"
    if ($null -ne $value -and ($value -is [bool] -or $value -is [int] -or $value -is [long])) {
        $settings.MemoryPool = $value
    }

    $value = Get-ObjectProperty -Object $cpu -Name "yield"
    if ($value -is [bool]) {
        $settings.Yield = $value
    }

    $value = Get-ObjectProperty -Object $cpu -Name "asm"
    if ($null -ne $value -and ($value -is [bool] -or $value -is [string])) {
        $settings.Assembly = $value
    }

    $value = Get-ObjectProperty -Object $cpu -Name "hw-aes"
    if ($value -is [bool]) {
        $settings.HardwareAes = $value
    }

    $value = Get-ObjectProperty -Object $randomx -Name "init"
    if ($value -is [int] -or $value -is [long]) {
        $settings.RandomXInit = [int] $value
    }

    $value = Get-ObjectProperty -Object $randomx -Name "init-avx2"
    if ($value -is [int] -or $value -is [long]) {
        $settings.RandomXInitAvx2 = [int] $value
    }

    $value = Get-ObjectProperty -Object $randomx -Name "mode"
    if ($value -is [string]) {
        $settings.RandomXMode = $value
    }

    $value = Get-ObjectProperty -Object $randomx -Name "numa"
    if ($value -is [bool]) {
        $settings.RandomXNuma = $value
    }

    $value = Get-ObjectProperty -Object $randomx -Name "scratchpad_prefetch_mode"
    if (($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 3) {
        $settings.ScratchpadPrefetchMode = [int] $value
    }

    return [pscustomobject] $settings
}

function Initialize-CpuSetApi {
    if ("SalviumRandomXTuner.NativeCpuSets" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace SalviumRandomXTuner
{
    public sealed class CpuSetRecord
    {
        public uint Id { get; set; }
        public ushort Group { get; set; }
        public byte LogicalProcessorIndex { get; set; }
        public byte CoreIndex { get; set; }
        public byte LastLevelCacheIndex { get; set; }
        public byte NumaNodeIndex { get; set; }
        public byte EfficiencyClass { get; set; }
        public byte Flags { get; set; }
    }

    public static class NativeCpuSets
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetSystemCpuSetInformation(
            IntPtr information,
            uint bufferLength,
            out uint returnedLength,
            IntPtr process,
            uint flags);

        public static CpuSetRecord[] Read()
        {
            uint requiredLength;
            GetSystemCpuSetInformation(IntPtr.Zero, 0, out requiredLength, IntPtr.Zero, 0);
            if (requiredLength == 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Windows did not return CPU-set information.");
            }

            IntPtr buffer = Marshal.AllocHGlobal(checked((int) requiredLength));
            try
            {
                uint returnedLength;
                if (!GetSystemCpuSetInformation(
                    buffer, requiredLength, out returnedLength, IntPtr.Zero, 0))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                var records = new List<CpuSetRecord>();
                int offset = 0;
                while (offset < returnedLength)
                {
                    IntPtr entry = IntPtr.Add(buffer, offset);
                    uint size = unchecked((uint) Marshal.ReadInt32(entry, 0));
                    int type = Marshal.ReadInt32(entry, 4);
                    if (size < 8 || offset + size > returnedLength)
                    {
                        throw new InvalidOperationException(
                            "Windows returned malformed CPU-set information.");
                    }

                    // CpuSetInformation is type zero. Its documented fields
                    // begin eight bytes into SYSTEM_CPU_SET_INFORMATION.
                    if (type == 0 && size >= 32)
                    {
                        records.Add(new CpuSetRecord
                        {
                            Id = unchecked((uint) Marshal.ReadInt32(entry, 8)),
                            Group = unchecked((ushort) Marshal.ReadInt16(entry, 12)),
                            LogicalProcessorIndex = Marshal.ReadByte(entry, 14),
                            CoreIndex = Marshal.ReadByte(entry, 15),
                            LastLevelCacheIndex = Marshal.ReadByte(entry, 16),
                            NumaNodeIndex = Marshal.ReadByte(entry, 17),
                            EfficiencyClass = Marshal.ReadByte(entry, 18),
                            Flags = Marshal.ReadByte(entry, 19)
                        });
                    }

                    offset += checked((int) size);
                }

                return records.ToArray();
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }
}
"@
}

function Get-CpuTopology {
    param(
        [int[]] $ManualP,
        [int[]] $ManualE,
        [bool] $UseManualP,
        [bool] $UseManualE
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "This tuner currently requires Windows CPU-set topology information."
    }

    Initialize-CpuSetApi
    $records = @([SalviumRandomXTuner.NativeCpuSets]::Read())
    if ($records.Count -eq 0) {
        throw "Windows returned no CPU-set topology records."
    }

    $groups = @($records.Group | Sort-Object -Unique)
    if ($groups.Count -gt 1) {
        throw "Multiple Windows processor groups were detected. This tuner currently supports one group of up to 64 logical processors."
    }

    $group = [int] $groups[0]
    $groupRecords = @($records | Where-Object Group -eq $group | Sort-Object LogicalProcessorIndex)
    $available = @($groupRecords.LogicalProcessorIndex | ForEach-Object { [int] $_ })

    if ($UseManualP -xor $UseManualE) {
        throw "Specify PCoreLogicalProcessors and ECoreLogicalProcessors together."
    }

    if ($UseManualP -and $UseManualE) {
        $performancePrimary = @($ManualP | Sort-Object -Unique)
        $efficient = @($ManualE | Sort-Object -Unique)
        $performanceCoreIndexes = @(
            $groupRecords |
                Where-Object { [int] $_.LogicalProcessorIndex -in $performancePrimary } |
                ForEach-Object { [int] $_.CoreIndex } |
                Sort-Object -Unique
        )
        $performanceAll = @(
            $groupRecords |
                Where-Object { [int] $_.CoreIndex -in $performanceCoreIndexes } |
                ForEach-Object { [int] $_.LogicalProcessorIndex } |
                Sort-Object -Unique
        )
    }
    else {
        $classes = @($groupRecords.EfficiencyClass | Sort-Object -Unique)
        if ($classes.Count -gt 1) {
            $performanceClass = [int] ($classes | Measure-Object -Maximum).Maximum
            $performanceRecords = @($groupRecords | Where-Object EfficiencyClass -eq $performanceClass)
            $efficientRecords = @($groupRecords | Where-Object EfficiencyClass -ne $performanceClass)
        }
        else {
            $performanceRecords = @($groupRecords)
            $efficientRecords = @()
        }

        $performancePrimary = @(
            $performanceRecords |
                Group-Object CoreIndex |
                ForEach-Object {
                    [int] (($_.Group | Sort-Object LogicalProcessorIndex | Select-Object -First 1).LogicalProcessorIndex)
                } |
                Sort-Object
        )
        $performanceAll = @($performanceRecords.LogicalProcessorIndex | ForEach-Object { [int] $_ } | Sort-Object)
        $efficient = @(
            $efficientRecords |
                Group-Object CoreIndex |
                ForEach-Object {
                    [int] (($_.Group | Sort-Object LogicalProcessorIndex | Select-Object -First 1).LogicalProcessorIndex)
                } |
                Sort-Object
        )
    }

    $requested = @($performancePrimary + $efficient | Sort-Object -Unique)
    $missing = @($requested | Where-Object { $_ -notin $available })
    if ($missing.Count -gt 0) {
        throw "The requested logical processors are not available in processor group ${group}: $($missing -join ', ')."
    }

    $overlap = @($performancePrimary | Where-Object { $_ -in $efficient })
    if ($overlap.Count -gt 0) {
        throw "Performance and efficient processor lists overlap: $($overlap -join ', ')."
    }

    $processor = Get-CimInstance Win32_Processor | Select-Object -First 1
    $l3CacheKb = 0
    if ($null -ne $processor.L3CacheSize) {
        $l3CacheKb = [int] $processor.L3CacheSize
    }

    return [pscustomobject] @{
        Name                    = [string] $processor.Name
        Group                   = $group
        LogicalProcessorCount   = $groupRecords.Count
        PhysicalCoreCount       = [int] $processor.NumberOfCores
        L3CacheKb               = $l3CacheKb
        PerformancePrimary      = @($performancePrimary)
        PerformanceAll          = @($performanceAll)
        Efficient               = @($efficient)
        EfficiencyClasses       = @($groupRecords.EfficiencyClass | Sort-Object -Unique)
        UsedManualClassification = ($UseManualP -and $UseManualE)
    }
}

function Select-EvenlySpaced {
    param(
        [Parameter(Mandatory = $true)]
        [int[]] $Items,

        [Parameter(Mandatory = $true)]
        [int] $Count
    )

    if ($Count -le 0 -or $Items.Count -eq 0) {
        return @()
    }

    if ($Count -ge $Items.Count) {
        return @($Items)
    }

    $selected = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $Count; $index++) {
        $sourceIndex = [int] [Math]::Floor(($index * $Items.Count) / [double] $Count)
        $selected.Add($Items[$sourceIndex])
    }

    return @($selected | Sort-Object -Unique)
}

function New-AffinityProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [int[]] $Affinity,

        [Parameter(Mandatory = $true)]
        [string] $Reason
    )

    return [pscustomobject] @{
        Name      = $Name
        Affinity  = @($Affinity | Sort-Object -Unique)
        Threads   = @($Affinity | Sort-Object -Unique).Count
        Reason    = $Reason
    }
}

function Add-UniqueProfile {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]] $Profiles,

        [Parameter(Mandatory = $true)]
        [object] $Profile
    )

    if ($Profile.Affinity.Count -eq 0) {
        return
    }

    $key = $Profile.Affinity -join ","
    foreach ($existing in $Profiles) {
        if (($existing.Affinity -join ",") -eq $key) {
            return
        }
    }

    $Profiles.Add($Profile)
}

function New-AffinityProfiles {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Topology,

        [Parameter(Mandatory = $true)]
        [object] $Baseline,

        [Parameter(Mandatory = $true)]
        [string] $SelectedPreset,

        [Parameter(Mandatory = $true)]
        [bool] $AddSmt,

        [Parameter(Mandatory = $true)]
        [bool] $ExploreThermal
    )

    $profiles = New-Object System.Collections.Generic.List[object]

    if ($Baseline.Affinity.Count -gt 0) {
        Add-UniqueProfile -Profiles $profiles -Profile (
            New-AffinityProfile -Name "baseline-rx" -Affinity $Baseline.Affinity `
                -Reason "Affinity imported from the existing rx/0, rx, or wildcard CPU profile."
        )
    }

    Add-UniqueProfile -Profiles $profiles -Profile (
        New-AffinityProfile -Name "performance-cores" -Affinity $Topology.PerformancePrimary `
            -Reason "One logical processor from each detected performance core."
    )

    $efficient = @($Topology.Efficient)
    if ($efficient.Count -gt 0) {
        if ($Topology.L3CacheKb -gt 0) {
            $cacheThreadLimit = [Math]::Max(
                $Topology.PerformancePrimary.Count,
                [Math]::Floor($Topology.L3CacheKb / 2048.0)
            )
            $cacheEfficientLimit = [Math]::Max(
                0,
                [Math]::Min($efficient.Count, $cacheThreadLimit - $Topology.PerformancePrimary.Count)
            )
        }
        else {
            $cacheEfficientLimit = $efficient.Count
        }

        $baselineEfficientCount = @(
            $Baseline.Affinity | Where-Object { $_ -in $efficient }
        ).Count

        switch ($SelectedPreset) {
            "Quick" {
                $counts = @(
                    $baselineEfficientCount,
                    [Math]::Ceiling($efficient.Count / 2.0),
                    $cacheEfficientLimit
                )
            }
            "Standard" {
                $counts = @(
                    $baselineEfficientCount,
                    [Math]::Ceiling($efficient.Count / 4.0),
                    [Math]::Ceiling($efficient.Count / 2.0),
                    $cacheEfficientLimit
                )
            }
            "Thorough" {
                $counts = @(0..$cacheEfficientLimit)
            }
            "Rigorous" {
                $counts = @(0..$cacheEfficientLimit)
            }
        }

        foreach ($countValue in @($counts | ForEach-Object { [int] $_ } | Where-Object {
            $_ -gt 0 -and $_ -le $cacheEfficientLimit
        } | Sort-Object -Unique)) {
            $selectedEfficient = Select-EvenlySpaced -Items $efficient -Count $countValue
            $affinity = @($Topology.PerformancePrimary + $selectedEfficient)
            Add-UniqueProfile -Profiles $profiles -Profile (
                New-AffinityProfile -Name "performance-plus-$countValue-efficient" -Affinity $affinity `
                    -Reason "Performance cores plus $countValue evenly distributed efficient cores."
            )
        }
    }

    if ($AddSmt -and $Topology.PerformanceAll.Count -gt $Topology.PerformancePrimary.Count) {
        Add-UniqueProfile -Profiles $profiles -Profile (
            New-AffinityProfile -Name "performance-cores-with-smt" -Affinity $Topology.PerformanceAll `
                -Reason "All performance-core logical processors, including SMT siblings."
        )
    }

    if ($ExploreThermal -and $efficient.Count -gt 0) {
        $efficientOnlyCount = if ($Topology.L3CacheKb -gt 0) {
            [Math]::Min($efficient.Count, [Math]::Floor($Topology.L3CacheKb / 2048.0))
        }
        else {
            $efficient.Count
        }
        if ($efficientOnlyCount -gt 0) {
            $selectedEfficient = Select-EvenlySpaced -Items $efficient -Count $efficientOnlyCount
            Add-UniqueProfile -Profiles $profiles -Profile (
                New-AffinityProfile -Name "efficient-cores-$efficientOnlyCount" `
                    -Affinity $selectedEfficient `
                    -Reason "Temperature-aware profile using efficient cores without performance cores."
            )
        }

        foreach ($fraction in @(0.5, 0.75)) {
            $performanceCount = [Math]::Max(
                1,
                [int] [Math]::Ceiling($Topology.PerformancePrimary.Count * $fraction)
            )
            $selectedPerformance = Select-EvenlySpaced `
                -Items $Topology.PerformancePrimary -Count $performanceCount
            $threadBudget = if ($Topology.L3CacheKb -gt 0) {
                [Math]::Max($performanceCount, [Math]::Floor($Topology.L3CacheKb / 2048.0))
            }
            else {
                $performanceCount + $efficient.Count
            }
            $efficientCount = [Math]::Min(
                $efficient.Count,
                [Math]::Max(0, $threadBudget - $performanceCount)
            )
            $selectedEfficient = Select-EvenlySpaced -Items $efficient -Count $efficientCount
            $fractionLabel = [int] [Math]::Round($fraction * 100)
            Add-UniqueProfile -Profiles $profiles -Profile (
                New-AffinityProfile -Name "thermal-$fractionLabel-percent-performance" `
                    -Affinity @($selectedPerformance + $selectedEfficient) `
                    -Reason "Temperature-aware mix with $performanceCount performance cores and $efficientCount efficient cores."
            )
        }

        if ($Topology.L3CacheKb -gt 0) {
            $boundaryCount = [Math]::Min($efficient.Count, $cacheEfficientLimit + 2)
            if ($boundaryCount -gt 0) {
                $selectedEfficient = Select-EvenlySpaced -Items $efficient -Count $boundaryCount
                Add-UniqueProfile -Profiles $profiles -Profile (
                    New-AffinityProfile -Name "performance-plus-$boundaryCount-efficient-boundary" `
                        -Affinity @($Topology.PerformancePrimary + $selectedEfficient) `
                        -Reason "Boundary check two threads beyond the approximate two-MiB-L3-per-thread heuristic."
                )
            }
        }
    }

    return $profiles.ToArray()
}

function Get-TestKey {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Candidate
    )

    return "{0}|p{1}|y{2}|j{3}" -f @(
        $Candidate.Profile.Name,
        $Candidate.PrefetchMode,
        ([int] $Candidate.Yield),
        ([int] $Candidate.HugePagesJit)
    )
}

function New-TestCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Profile,

        [Parameter(Mandatory = $true)]
        [int] $PrefetchMode,

        [Parameter(Mandatory = $true)]
        [bool] $Yield,

        [Parameter(Mandatory = $true)]
        [bool] $HugePagesJit
    )

    $candidate = [pscustomobject] @{
        Profile       = $Profile
        PrefetchMode  = $PrefetchMode
        Yield         = $Yield
        HugePagesJit  = $HugePagesJit
        Key           = $null
    }
    $candidate.Key = Get-TestKey -Candidate $candidate

    return $candidate
}

function New-BenchmarkConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Candidate,

        [Parameter(Mandatory = $true)]
        [object] $Baseline,

        [Parameter(Mandatory = $true)]
        [string] $Size,

        [Parameter(Mandatory = $true)]
        [int] $Priority
    )

    return [ordered] @{
        api = [ordered] @{
            id          = $null
            "worker-id" = $null
        }
        http = [ordered] @{
            enabled        = $false
            host           = "127.0.0.1"
            port           = 0
            "access-token" = $null
            restricted     = $true
        }
        autosave  = $false
        background = $false
        colors    = $false
        title     = $false
        randomx   = [ordered] @{
            init                       = $Baseline.RandomXInit
            "init-avx2"                = $Baseline.RandomXInitAvx2
            mode                       = $Baseline.RandomXMode
            "1gb-pages"                = $false
            rdmsr                      = $false
            wrmsr                      = $false
            cache_qos                  = $false
            numa                       = $Baseline.RandomXNuma
            scratchpad_prefetch_mode   = $Candidate.PrefetchMode
        }
        cpu = [ordered] @{
            enabled            = $true
            "huge-pages"       = $Baseline.HugePages
            "huge-pages-jit"   = $Candidate.HugePagesJit
            "hw-aes"           = $Baseline.HardwareAes
            priority           = $Priority
            "memory-pool"      = $Baseline.MemoryPool
            yield              = $Candidate.Yield
            "max-threads-hint" = 100
            asm                = $Baseline.Assembly
            rx                 = @($Candidate.Profile.Affinity)
        }
        opencl = [ordered] @{
            enabled = $false
        }
        cuda = [ordered] @{
            enabled = $false
        }
        benchmark = [ordered] @{
            size   = $Size
            algo   = "rx/0"
            submit = $false
            verify = $null
            token  = $null
            seed   = $null
            user   = $null
            hash   = $null
        }
        "donate-level"      = 0
        "donate-over-proxy" = 0
        "log-file"          = $null
        "print-time"        = 60
        "health-print-time" = 0
        dmi                 = $false
        retries             = 0
        "retry-pause"       = 0
        syslog              = $false
        verbose             = 0
        watch               = $false
        "pause-on-battery"  = $false
        "pause-on-active"   = $false
    }
}

function Invoke-XmrigBenchmark {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Executable,

        [Parameter(Mandatory = $true)]
        [object] $Candidate,

        [Parameter(Mandatory = $true)]
        [object] $Baseline,

        [Parameter(Mandatory = $true)]
        [string] $Size,

        [Parameter(Mandatory = $true)]
        [int] $Priority,

        [Parameter(Mandatory = $true)]
        [string] $Stage,

        [Parameter(Mandatory = $true)]
        [int] $Sequence,

        [Parameter(Mandatory = $true)]
        [string] $ResultsDirectory,

        [Parameter(Mandatory = $true)]
        [int] $Timeout,

        [Parameter(Mandatory = $true)]
        [object] $TemperaturePolicy,

        [AllowNull()]
        [object] $PreRunCooling
    )

    $safeProfileName = $Candidate.Profile.Name -replace "[^A-Za-z0-9_.-]", "-"
    $runName = "{0:D3}-{1}-{2}-p{3}-y{4}-j{5}" -f @(
        $Sequence,
        $Stage,
        $safeProfileName,
        $Candidate.PrefetchMode,
        ([int] $Candidate.Yield),
        ([int] $Candidate.HugePagesJit)
    )
    $stdoutPath = Join-Path $ResultsDirectory "$runName.stdout.log"
    $stderrPath = Join-Path $ResultsDirectory "$runName.stderr.log"
    $temperaturePath = if ($TemperaturePolicy.Enabled) {
        Join-Path $ResultsDirectory "$runName.temperature.csv"
    }
    else {
        $null
    }
    $temporaryName = "xmrig-salvium-tuner-{0}" -f [Guid]::NewGuid().ToString("N")
    $configPath = Join-Path ([System.IO.Path]::GetTempPath()) "$temporaryName.json"

    $configuration = New-BenchmarkConfig -Candidate $Candidate -Baseline $Baseline `
        -Size $Size -Priority $Priority
    Write-Utf8File -Path $configPath -Content ($configuration | ConvertTo-Json -Depth 8)

    Write-Host ("[{0:D3}] {1}: {2} threads, prefetch {3}, yield {4}, JIT huge pages {5}" -f @(
        $Sequence,
        $Stage,
        $Candidate.Profile.Threads,
        $Candidate.PrefetchMode,
        $Candidate.Yield,
        $Candidate.HugePagesJit
    ))
    Write-Host "      affinity: $($Candidate.Profile.Affinity -join ',')"

    $process = $null
    $processStarted = $false
    $stdoutWriter = $null
    $stderrWriter = $null
    $temperatureWriter = $null
    $timedOut = $false
    $exitCode = $null
    $startedAt = [DateTime]::UtcNow
    $temperatureSamples = New-Object System.Collections.Generic.List[double]
    $temperatureMonitoringActive = [bool] $TemperaturePolicy.Enabled
    $temperatureMonitoringFailed = $false
    $temperatureFailure = $null
    $thermallyLimited = $false
    $thermalLimitObservedC = $null
    $timeToThermalLimitSeconds = $null
    $completionPattern = "benchmark finished in\s+([0-9.]+)\s+seconds\s+\(([0-9.]+)\s+h/s\)\s+hash sum\s*=\s*([0-9A-Fa-f]+)"
    try {
        $argument = "--config=`"$configPath`""
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $stdoutWriter = New-Object System.IO.StreamWriter($stdoutPath, $false, $encoding)
        $stderrWriter = New-Object System.IO.StreamWriter($stderrPath, $false, $encoding)
        $stdoutWriter.AutoFlush = $true
        $stderrWriter.AutoFlush = $true
        if ($TemperaturePolicy.Enabled) {
            $temperatureWriter = New-Object System.IO.StreamWriter($temperaturePath, $false, $encoding)
            $temperatureWriter.AutoFlush = $true
            $temperatureWriter.WriteLine("timestamp_utc,temperature_c")
        }

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $Executable
        $startInfo.Arguments = $argument
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Failed to start XMRig."
        }
        $processStarted = $true

        $stdoutClosed = $false
        $stderrClosed = $false
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()
        $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
        $completionDetected = $false
        $stopDeadline = $null
        $nextTemperatureSampleAt = [DateTime]::UtcNow
        $nextTemperatureDisplayAt = [DateTime]::UtcNow

        while ($true) {
            if (-not $stdoutClosed -and $stdoutTask.IsCompleted) {
                $line = $stdoutTask.Result
                if ($null -eq $line) {
                    $stdoutClosed = $true
                }
                else {
                    $stdoutWriter.WriteLine($line)
                    if (-not $completionDetected -and [regex]::IsMatch(
                        $line,
                        $completionPattern,
                        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                    )) {
                        $completionDetected = $true
                    }
                    $stdoutTask = $process.StandardOutput.ReadLineAsync()
                }
            }

            if (-not $stderrClosed -and $stderrTask.IsCompleted) {
                $line = $stderrTask.Result
                if ($null -eq $line) {
                    $stderrClosed = $true
                }
                else {
                    $stderrWriter.WriteLine($line)
                    $stderrTask = $process.StandardError.ReadLineAsync()
                }
            }

            $now = [DateTime]::UtcNow
            if ($temperatureMonitoringActive -and $now -ge $nextTemperatureSampleAt) {
                try {
                    $temperature = Read-CpuTemperature -Policy $TemperaturePolicy
                    $temperatureSamples.Add($temperature)
                    $temperatureWriter.WriteLine((
                        "{0},{1}" -f @(
                            $now.ToString("o"),
                            $temperature.ToString("F3", [Globalization.CultureInfo]::InvariantCulture)
                        )
                    ))
                    if ($now -ge $nextTemperatureDisplayAt) {
                        $limitText = if ($TemperaturePolicy.Enforced) {
                            " / {0:N1} C maximum" -f $TemperaturePolicy.LimitC
                        }
                        else {
                            ""
                        }
                        Write-Host ("      CPU temperature: {0:N1} C{1}" -f $temperature, $limitText)
                        $nextTemperatureDisplayAt = $now.AddSeconds(10)
                    }

                    if ($TemperaturePolicy.Enforced -and $temperature -ge $TemperaturePolicy.LimitC) {
                        $thermallyLimited = $true
                        $thermalLimitObservedC = $temperature
                        $timeToThermalLimitSeconds = ($now - $startedAt).TotalSeconds
                        if (-not $process.HasExited) {
                            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                        }
                        if ($null -eq $stopDeadline) {
                            $stopDeadline = $now.AddSeconds(5)
                        }
                    }
                }
                catch {
                    $temperatureMonitoringFailed = $true
                    $temperatureFailure = $_.Exception.Message
                    $temperatureMonitoringActive = $false
                    if ($TemperaturePolicy.Enforced) {
                        if (-not $process.HasExited) {
                            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                        }
                        if ($null -eq $stopDeadline) {
                            $stopDeadline = $now.AddSeconds(5)
                        }
                    }
                    else {
                        Write-Warning "CPU temperature monitoring stopped: $temperatureFailure"
                    }
                }
                $nextTemperatureSampleAt = $now.AddSeconds($TemperaturePolicy.SampleSeconds)
            }

            if ($null -eq $stopDeadline -and $completionDetected) {
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
                $stopDeadline = [DateTime]::UtcNow.AddSeconds(5)
            }
            elseif ($null -eq $stopDeadline -and $process.HasExited) {
                $stopDeadline = [DateTime]::UtcNow.AddSeconds(5)
            }
            elseif ($null -eq $stopDeadline -and [DateTime]::UtcNow -ge $deadline) {
                $timedOut = $true
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
                $stopDeadline = [DateTime]::UtcNow.AddSeconds(5)
            }

            if ($process.HasExited -and $stdoutClosed -and $stderrClosed) {
                break
            }
            if ($null -ne $stopDeadline -and [DateTime]::UtcNow -ge $stopDeadline) {
                break
            }

            Start-Sleep -Milliseconds 50
        }

        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        $null = $process.WaitForExit(5000)
        $process.Refresh()
        if ($process.HasExited) {
            $exitCode = $process.ExitCode
        }
    }
    finally {
        if ($null -ne $process -and $processStarted -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $null = $process.WaitForExit(5000)
        }

        if ($null -ne $stdoutWriter) {
            $stdoutWriter.Dispose()
        }
        if ($null -ne $stderrWriter) {
            $stderrWriter.Dispose()
        }
        if ($null -ne $temperatureWriter) {
            $temperatureWriter.Dispose()
        }
        if ($null -ne $process) {
            $process.Dispose()
        }

        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
    }

    $stdout = if (Test-Path -LiteralPath $stdoutPath) {
        Get-Content -LiteralPath $stdoutPath -Raw
    }
    else {
        ""
    }
    $stderr = if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -LiteralPath $stderrPath -Raw
    }
    else {
        ""
    }
    $combinedOutput = "$stdout`n$stderr"

    $match = [regex]::Match(
        $combinedOutput,
        $completionPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    # Offline XMRig benchmarks deliberately wait for Ctrl+C after logging the
    # result. The tuner stops that owned child, so the completion record—not
    # the resulting process exit code—is authoritative.
    if ($match.Success) {
        $timedOut = $false
    }
    $temperatureStatistics = Get-TemperatureStatistics -Values $temperatureSamples.ToArray() `
        -SampleSeconds $TemperaturePolicy.SampleSeconds
    $hashrateTrace = Get-HashrateTraceStatistics -Output $combinedOutput
    $benchmarkContract = Test-BenchmarkContract -Output $combinedOutput `
        -ExpectedThreads $Candidate.Profile.Threads -ExpectedHugePages $Baseline.HugePages
    $succeeded = (
        $match.Success -and
        $benchmarkContract.Passed -and
        -not $thermallyLimited -and
        -not ($TemperaturePolicy.Enforced -and $temperatureMonitoringFailed)
    )
    $seconds = $null
    $hashrate = $null
    $hashSum = $null
    if ($match.Success) {
        $seconds = [double]::Parse($match.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
        $hashrate = [double]::Parse($match.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
        $hashSum = $match.Groups[3].Value.ToUpperInvariant()
    }

    if ($thermallyLimited) {
        Write-Warning ("$runName reached the {0:N1} C CPU-temperature ceiling (observed {1:N1} C) and was stopped." -f @(
            $TemperaturePolicy.LimitC,
            $thermalLimitObservedC
        ))
    }
    elseif ($TemperaturePolicy.Enforced -and $temperatureMonitoringFailed) {
        Write-Warning "$runName stopped because CPU temperature monitoring failed: $temperatureFailure"
    }
    elseif ($succeeded) {
        Write-Host ("      result: {0:N1} H/s in {1:N3} seconds" -f $hashrate, $seconds) -ForegroundColor Green
        if ($hashrateTrace.Samples -gt 0) {
            Write-Host ("      sustained 60-second rate: {0:N1} H/s median ({1} sample(s))" -f @(
                $hashrateTrace.Median,
                $hashrateTrace.Samples
            ))
        }
        if ($temperatureStatistics.Samples -gt 0) {
            Write-Host ("      temperature: mean {0:N1} C, p95 {1:N1} C, max {2:N1} C" -f @(
                $temperatureStatistics.Mean,
                $temperatureStatistics.P95,
                $temperatureStatistics.Maximum
            ))
        }
    }
    else {
        $reason = if ($timedOut) {
            "timed out after $Timeout seconds"
        }
        elseif (-not $benchmarkContract.Passed) {
            "benchmark validity checks failed: $($benchmarkContract.Failures -join ' ')"
        }
        elseif ($null -ne $exitCode -and $exitCode -ne 0) {
            "XMRig exited with code $exitCode"
        }
        else {
            "the benchmark result was not found in XMRig output"
        }
        Write-Warning "$runName failed: $reason. Inspect $stdoutPath and $stderrPath."
    }

    return [pscustomobject] @{
        Sequence        = $Sequence
        Stage           = $Stage
        ConfigKey       = $Candidate.Key
        Profile         = $Candidate.Profile.Name
        Affinity        = $Candidate.Profile.Affinity -join ","
        ThreadCount     = $Candidate.Profile.Threads
        PrefetchMode    = $Candidate.PrefetchMode
        Yield           = $Candidate.Yield
        HugePagesJit    = $Candidate.HugePagesJit
        HugePages       = $Baseline.HugePages
        CpuPriority     = $Priority
        BenchmarkSize   = $Size
        Hashrate        = $hashrate
        Seconds         = $seconds
        HashSum         = $hashSum
        Succeeded       = $succeeded
        BenchmarkValidated = $benchmarkContract.Passed
        ValidationFailures = $benchmarkContract.Failures -join " "
        ValidationWarnings = $benchmarkContract.Warnings -join " "
        ReportedAlgorithm = $benchmarkContract.Algorithm
        ActualThreadCount = $benchmarkContract.ActualThreads
        WorkerHugePagesPercent = $benchmarkContract.WorkerHugePagesPercent
        DatasetHugePagesPercent = $benchmarkContract.DatasetHugePagesPercent
        SustainedHashrateSamples = $hashrateTrace.Samples
        SustainedHashrateMedian = $hashrateTrace.Median
        SustainedHashrateMean = $hashrateTrace.Mean
        SustainedHashrateEnding = $hashrateTrace.Ending
        SustainedHashrateChangePercent = $hashrateTrace.ChangePercent
        TimedOut        = $timedOut
        ExitCode        = $exitCode
        StartedAtUtc    = $startedAt.ToString("o")
        StdoutLog       = $stdoutPath
        StderrLog       = $stderrPath
        TemperatureSensor = $TemperaturePolicy.ProviderName
        TemperatureSamples = $temperatureStatistics.Samples
        TemperatureStartC = $temperatureStatistics.Start
        TemperatureMeanC = $temperatureStatistics.Mean
        TemperatureP95C = $temperatureStatistics.P95
        TemperatureMaximumC = $temperatureStatistics.Maximum
        TemperatureEndC = $temperatureStatistics.End
        TemperatureSlopeCPerMinute = $temperatureStatistics.SlopeCPerMinute
        TemperatureFirstQuarterMeanC = $temperatureStatistics.FirstQuarterMeanC
        TemperatureFinalQuarterMeanC = $temperatureStatistics.FinalQuarterMeanC
        ThermallyLimited = $thermallyLimited
        TemperatureLimitC = $TemperaturePolicy.LimitC
        ThermalLimitObservedC = $thermalLimitObservedC
        TimeToThermalLimitSeconds = $timeToThermalLimitSeconds
        TemperatureMonitoringFailed = $temperatureMonitoringFailed
        TemperatureFailure = $temperatureFailure
        TemperatureLog = $temperaturePath
        CooldownWaitSeconds = if ($null -ne $PreRunCooling) { $PreRunCooling.WaitSeconds } else { 0.0 }
        ReadyTemperatureC = if ($null -ne $PreRunCooling) { $PreRunCooling.ReadyTemperatureC } else { $null }
    }
}

function Get-ShuffledItems {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Items,

        [Parameter(Mandatory = $true)]
        [int] $Seed
    )

    $copy = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Items) {
        $copy.Add($item)
    }

    $random = New-Object System.Random($Seed)
    for ($index = $copy.Count - 1; $index -gt 0; $index--) {
        $swapIndex = $random.Next(0, $index + 1)
        $temporary = $copy[$index]
        $copy[$index] = $copy[$swapIndex]
        $copy[$swapIndex] = $temporary
    }

    return $copy.ToArray()
}

function Get-StandardDeviation {
    param(
        [Parameter(Mandatory = $true)]
        [double[]] $Values
    )

    if ($Values.Count -lt 2) {
        return $null
    }

    $mean = ($Values | Measure-Object -Average).Average
    $sumSquares = 0.0
    foreach ($value in $Values) {
        $sumSquares += [Math]::Pow($value - $mean, 2)
    }

    return [Math]::Sqrt($sumSquares / ($Values.Count - 1))
}

function Get-Median {
    param(
        [Parameter(Mandatory = $true)]
        [double[]] $Values
    )

    $ordered = @($Values | Sort-Object)
    if ($ordered.Count -eq 0) {
        return $null
    }

    $middle = [Math]::Floor($ordered.Count / 2)
    if (($ordered.Count % 2) -eq 1) {
        return [double] $ordered[$middle]
    }

    return ([double] $ordered[$middle - 1] + [double] $ordered[$middle]) / 2.0
}

function Get-MedianAbsoluteDeviation {
    param(
        [Parameter(Mandatory = $true)]
        [double[]] $Values
    )

    if ($Values.Count -eq 0) {
        return $null
    }

    $median = Get-Median -Values $Values
    $deviations = @($Values | ForEach-Object { [Math]::Abs($_ - $median) })
    return Get-Median -Values $deviations
}

function Get-HashrateTraceStatistics {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Output
    )

    $rates = New-Object System.Collections.Generic.List[double]
    $pattern = "speed\s+(?:10s/60s/15m\s+)?[0-9.]+\s+([0-9.]+|n/a)\s+([0-9.]+|n/a)\s+h/s"
    foreach ($match in [regex]::Matches(
        $Output,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) {
        if ($match.Groups[1].Value -ne "n/a") {
            $rates.Add([double]::Parse(
                $match.Groups[1].Value,
                [Globalization.CultureInfo]::InvariantCulture
            ))
        }
    }

    if ($rates.Count -eq 0) {
        return [pscustomobject] @{
            Samples       = 0
            Median        = $null
            Mean          = $null
            Minimum       = $null
            Maximum       = $null
            Ending        = $null
            ChangePercent = $null
        }
    }

    $change = if ($rates.Count -gt 1 -and $rates[0] -gt 0) {
        (($rates[$rates.Count - 1] - $rates[0]) / $rates[0]) * 100.0
    }
    else {
        $null
    }

    return [pscustomobject] @{
        Samples       = $rates.Count
        Median        = Get-Median -Values $rates.ToArray()
        Mean          = ($rates | Measure-Object -Average).Average
        Minimum       = ($rates | Measure-Object -Minimum).Minimum
        Maximum       = ($rates | Measure-Object -Maximum).Maximum
        Ending        = $rates[$rates.Count - 1]
        ChangePercent = $change
    }
}

function Test-BenchmarkContract {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Output,

        [Parameter(Mandatory = $true)]
        [int] $ExpectedThreads,

        [Parameter(Mandatory = $true)]
        [object] $ExpectedHugePages
    )

    $failures = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $algorithm = $null
    $actualThreads = $null
    $workerHugePagesPercent = $null
    $datasetHugePagesPercent = $null

    $startMatch = [regex]::Match(
        $Output,
        "start benchmark hashes\s+\S+\s+algo\s+(\S+)",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($startMatch.Success) {
        $algorithm = $startMatch.Groups[1].Value.ToLowerInvariant()
        if ($algorithm -ne "rx/0") {
            $failures.Add("XMRig reported algorithm '$algorithm' instead of rx/0.")
        }
    }
    else {
        $failures.Add("XMRig did not report the offline benchmark algorithm.")
    }

    $readyMatch = [regex]::Match(
        $Output,
        "READY threads\s+([0-9]+)/([0-9]+).*?huge pages\s+([0-9.]+)%",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($readyMatch.Success) {
        $actualThreads = [int] $readyMatch.Groups[1].Value
        $readyExpectedThreads = [int] $readyMatch.Groups[2].Value
        $workerHugePagesPercent = [double]::Parse(
            $readyMatch.Groups[3].Value,
            [Globalization.CultureInfo]::InvariantCulture
        )
        if ($actualThreads -ne $ExpectedThreads -or $readyExpectedThreads -ne $ExpectedThreads) {
            $failures.Add(
                "XMRig started $actualThreads/$readyExpectedThreads workers; $ExpectedThreads were requested."
            )
        }
    }
    else {
        $failures.Add("XMRig did not report a CPU READY thread count.")
    }

    $hugePagesExpected = $ExpectedHugePages -ne $false -and $ExpectedHugePages -ne 0
    $datasetMatch = [regex]::Match(
        $Output,
        "allocated\s+[^\r\n]*?huge pages\s+([0-9.]+)%",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($datasetMatch.Success) {
        $datasetHugePagesPercent = [double]::Parse(
            $datasetMatch.Groups[1].Value,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    else {
        if ($hugePagesExpected) {
            $failures.Add("XMRig did not report RandomX dataset huge-page allocation.")
        }
        else {
            $warnings.Add("XMRig did not report RandomX dataset huge-page allocation.")
        }
    }

    if ($hugePagesExpected) {
        if ($null -ne $workerHugePagesPercent -and $workerHugePagesPercent -lt 100.0) {
            $failures.Add("Worker huge pages were $workerHugePagesPercent%; 100% were expected.")
        }
        if ($null -ne $datasetHugePagesPercent -and $datasetHugePagesPercent -lt 100.0) {
            $failures.Add("RandomX dataset huge pages were $datasetHugePagesPercent%; 100% were expected.")
        }
    }

    return [pscustomobject] @{
        Passed                  = $failures.Count -eq 0
        Failures                = $failures.ToArray()
        Warnings                = $warnings.ToArray()
        Algorithm               = $algorithm
        ActualThreads           = $actualThreads
        WorkerHugePagesPercent  = $workerHugePagesPercent
        DatasetHugePagesPercent = $datasetHugePagesPercent
    }
}

function Get-RankedConfigurations {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Runs
    )

    $ranked = foreach ($group in @($Runs | Group-Object ConfigKey)) {
        $successfulRuns = @($group.Group | Where-Object Succeeded)
        if ($successfulRuns.Count -eq 0) {
            continue
        }

        $sample = $successfulRuns | Select-Object -First 1
        $rates = @($successfulRuns.Hashrate | ForEach-Object { [double] $_ })
        $standardDeviation = Get-StandardDeviation -Values $rates
        $meanHashrate = ($rates | Measure-Object -Average).Average
        $confidence95 = if ($null -ne $standardDeviation) {
            1.96 * $standardDeviation / [Math]::Sqrt($rates.Count)
        }
        else {
            $null
        }
        $sustainedRates = @(
            $successfulRuns |
                Where-Object { $null -ne $_.SustainedHashrateMedian } |
                ForEach-Object { [double] $_.SustainedHashrateMedian }
        )
        $temperatureMeans = @(
            $successfulRuns |
                Where-Object { $null -ne $_.TemperatureMeanC } |
                ForEach-Object { [double] $_.TemperatureMeanC }
        )
        $temperatureMaximums = @(
            $successfulRuns |
                Where-Object { $null -ne $_.TemperatureMaximumC } |
                ForEach-Object { [double] $_.TemperatureMaximumC }
        )
        $temperatureSlopes = @(
            $successfulRuns |
                Where-Object { $null -ne $_.TemperatureSlopeCPerMinute } |
                ForEach-Object { [double] $_.TemperatureSlopeCPerMinute }
        )
        [pscustomobject] @{
            ConfigKey       = $group.Name
            Profile         = $sample.Profile
            Affinity        = $sample.Affinity
            ThreadCount     = $sample.ThreadCount
            PrefetchMode    = $sample.PrefetchMode
            Yield           = $sample.Yield
            HugePagesJit    = $sample.HugePagesJit
            BenchmarkSize   = $sample.BenchmarkSize
            Attempts        = $group.Count
            Samples         = $rates.Count
            FailedSamples   = $group.Count - $rates.Count
            AllAttemptsSucceeded = $group.Count -eq $rates.Count
            MeanHashrate    = $meanHashrate
            MedianHashrate  = Get-Median -Values $rates
            MinimumHashrate = ($rates | Measure-Object -Minimum).Minimum
            MaximumHashrate = ($rates | Measure-Object -Maximum).Maximum
            StandardDeviation = $standardDeviation
            MedianAbsoluteDeviation = Get-MedianAbsoluteDeviation -Values $rates
            CoefficientOfVariationPercent = if ($null -ne $standardDeviation -and $meanHashrate -gt 0) {
                ($standardDeviation / $meanHashrate) * 100.0
            }
            else {
                $null
            }
            Confidence95HalfWidth = $confidence95
            SustainedMedianHashrate = if ($sustainedRates.Count -gt 0) {
                Get-Median -Values $sustainedRates
            }
            else {
                $null
            }
            MeanTemperatureC = if ($temperatureMeans.Count -gt 0) {
                ($temperatureMeans | Measure-Object -Average).Average
            }
            else {
                $null
            }
            MaximumTemperatureC = if ($temperatureMaximums.Count -gt 0) {
                ($temperatureMaximums | Measure-Object -Maximum).Maximum
            }
            else {
                $null
            }
            MeanTemperatureSlopeCPerMinute = if ($temperatureSlopes.Count -gt 0) {
                ($temperatureSlopes | Measure-Object -Average).Average
            }
            else {
                $null
            }
        }
    }

    return @($ranked | Sort-Object MedianHashrate, MeanHashrate -Descending)
}

function Select-AdvancingRankings {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Rankings,

        [Parameter(Mandatory = $true)]
        [double] $WithinPercent,

        [Parameter(Mandatory = $true)]
        [int] $MinimumCount,

        [Parameter(Mandatory = $true)]
        [int] $MaximumCount
    )

    if ($Rankings.Count -eq 0) {
        return @()
    }

    $leader = [double] $Rankings[0].MedianHashrate
    $minimumRate = $leader * (1.0 - ($WithinPercent / 100.0))
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($ranking in $Rankings) {
        if (
            $selected.Count -lt $MinimumCount -or
            ([double] $ranking.MedianHashrate -ge $minimumRate -and $selected.Count -lt $MaximumCount)
        ) {
            $selected.Add($ranking)
        }
        if ($selected.Count -ge $MaximumCount) {
            break
        }
    }

    return $selected.ToArray()
}

function Get-CandidateFromRanking {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Ranking,

        [Parameter(Mandatory = $true)]
        [object[]] $Profiles
    )

    $profile = $Profiles | Where-Object Name -eq $Ranking.Profile | Select-Object -First 1
    if ($null -eq $profile) {
        throw "Unable to reconstruct profile '$($Ranking.Profile)'."
    }

    return New-TestCandidate -Profile $profile -PrefetchMode $Ranking.PrefetchMode `
        -Yield ([bool] $Ranking.Yield) -HugePagesJit ([bool] $Ranking.HugePagesJit)
}

function Test-CandidateAlreadyMeasured {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Candidate,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]] $Runs,

        [AllowNull()]
        [string] $Stage,

        [AllowNull()]
        [string] $Size,

        [switch] $ExactStage
    )

    return @(
        $Runs |
            Where-Object {
                $_.ConfigKey -eq $Candidate.Key -and
                ($_.Succeeded -or $_.ThermallyLimited -or $_.TemperatureMonitoringFailed) -and
                (
                    -not $ExactStage -or
                    ($_.Stage -eq $Stage -and $_.BenchmarkSize -eq $Size)
                )
            }
    ).Count -gt 0
}

function Write-TuningOutputs {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]] $Runs,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Rankings,

        [Parameter(Mandatory = $true)]
        [object] $Topology,

        [Parameter(Mandatory = $true)]
        [object] $Baseline,

        [Parameter(Mandatory = $true)]
        [string] $Executable,

        [Parameter(Mandatory = $true)]
        [string] $ResultsDirectory,

        [Parameter(Mandatory = $true)]
        [string] $Size,

        [Parameter(Mandatory = $true)]
        [int] $Priority,

        [Parameter(Mandatory = $true)]
        [object] $TemperaturePolicy
    )

    $csvPath = Join-Path $ResultsDirectory "measurements.csv"
    $jsonPath = Join-Path $ResultsDirectory "measurements.json"
    $reportPath = Join-Path $ResultsDirectory "report.md"
    $recommendationPath = Join-Path $ResultsDirectory "recommended-settings.json"
    if ($Rankings.Count -eq 0 -and (Test-Path -LiteralPath $recommendationPath)) {
        Remove-Item -LiteralPath $recommendationPath -Force
    }

    $Runs | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    Write-Utf8File -Path $jsonPath -Content ($Runs | ConvertTo-Json -Depth 6)

    $report = New-Object System.Collections.Generic.List[string]
    $report.Add("# Salvium RandomX tuning report")
    $report.Add("")
    $report.Add("- Generated: $([DateTime]::UtcNow.ToString('u')) UTC")
    $report.Add("- XMRig: $Executable")
    $report.Add("- CPU: $($Topology.Name.Trim())")
    $report.Add("- Logical processors: $($Topology.LogicalProcessorCount)")
    $report.Add("- Detected performance-core primary processors: $($Topology.PerformancePrimary -join ', ')")
    $report.Add("- Detected efficient-core processors: $($Topology.Efficient -join ', ')")
    $report.Add("- L3 cache: $($Topology.L3CacheKb) KiB")
    $report.Add("- Preset: $Preset")
    if ($Preset -eq "Rigorous") {
        $report.Add(
            "- Benchmarks: screening $ScreeningBenchmarkSize; refinement $RefinementBenchmarkSize; interaction $BenchmarkSize; final $FinalBenchmarkSize"
        )
        $report.Add("- Candidate-order seed: $CandidateOrderSeed")
        $report.Add("- Survivor beam: within $AdvanceWithinPercent%; maximum $MaximumSurvivors")
        $report.Add("- Final confirmation runs requested: $resolvedFinalConfirmationRuns")
        $report.Add("- Run manifest: $(Join-Path $ResultsDirectory 'run-manifest.json')")
    }
    else {
        $report.Add("- Benchmark: offline rx/0, size $Size")
    }
    $report.Add("- CPU priority: $Priority")
    $report.Add("- MSR reads/writes, cache QoS, networking, OpenCL, and CUDA: disabled")
    if ($TemperaturePolicy.Enabled) {
        $temperatureMode = if ($TemperaturePolicy.Enforced) {
            "enforced maximum $($TemperaturePolicy.LimitC) C; resume below $($TemperaturePolicy.ResumeBelowC) C"
        }
        else {
            "monitor only; temperature did not affect ranking"
        }
        $report.Add("- CPU temperature: $temperatureMode")
        $report.Add("- Temperature sensor: $($TemperaturePolicy.ProviderName)")
        if (-not [string]::IsNullOrWhiteSpace([string] $TemperaturePolicy.Identifier)) {
            $report.Add("- Temperature sensor identifier: $($TemperaturePolicy.Identifier)")
        }
    }
    else {
        $report.Add("- CPU temperature: disabled")
    }
    if ($null -ne $Baseline.Path) {
        $report.Add("- Baseline tuning imported from: $($Baseline.Path)")
    }
    $report.Add("")
    $report.Add("## Ranked configurations")
    $report.Add("")
    $report.Add("| Rank | Profile | Threads | Prefetch | Yield | JIT huge pages | Success/attempts | Median H/s | Mean H/s | 95% half-width | CV | Sustained H/s | Range H/s | Mean temp C | Max temp C | Temp slope C/min |")
    $report.Add("|---:|---|---:|---:|:---:|:---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")

    $rank = 0
    foreach ($entry in $Rankings) {
        $rank++
        $meanTemperature = if ($null -ne $entry.MeanTemperatureC) {
            "{0:N1}" -f $entry.MeanTemperatureC
        }
        else {
            "-"
        }
        $maximumTemperature = if ($null -ne $entry.MaximumTemperatureC) {
            "{0:N1}" -f $entry.MaximumTemperatureC
        }
        else {
            "-"
        }
        $confidence = if ($null -ne $entry.Confidence95HalfWidth) {
            "{0:N1}" -f $entry.Confidence95HalfWidth
        }
        else {
            "-"
        }
        $coefficientOfVariation = if ($null -ne $entry.CoefficientOfVariationPercent) {
            "{0:N2}%" -f $entry.CoefficientOfVariationPercent
        }
        else {
            "-"
        }
        $sustainedHashrate = if ($null -ne $entry.SustainedMedianHashrate) {
            "{0:N1}" -f $entry.SustainedMedianHashrate
        }
        else {
            "-"
        }
        $temperatureSlope = if ($null -ne $entry.MeanTemperatureSlopeCPerMinute) {
            "{0:N2}" -f $entry.MeanTemperatureSlopeCPerMinute
        }
        else {
            "-"
        }
        $report.Add((
            "| {0} | {1} | {2} | {3} | {4} | {5} | {6}/{7} | {8:N1} | {9:N1} | {10} | {11} | {12} | {13:N1}-{14:N1} | {15} | {16} | {17} |" -f @(
                $rank,
                $entry.Profile,
                $entry.ThreadCount,
                $entry.PrefetchMode,
                $entry.Yield,
                $entry.HugePagesJit,
                $entry.Samples,
                $entry.Attempts,
                $entry.MedianHashrate,
                $entry.MeanHashrate,
                $confidence,
                $coefficientOfVariation,
                $sustainedHashrate,
                $entry.MinimumHashrate,
                $entry.MaximumHashrate,
                $meanTemperature,
                $maximumTemperature,
                $temperatureSlope
            )
        ))
    }

    if ($Preset -eq "Rigorous") {
        $referenceRates = @(
            $Runs |
                Where-Object { $_.Succeeded -and $_.Stage -like "rigorous-reference-*" } |
                ForEach-Object { [double] $_.Hashrate }
        )
        $report.Add("")
        $report.Add("## Experimental controls")
        $report.Add("")
        if ($referenceRates.Count -gt 1) {
            $referenceMedian = Get-Median -Values $referenceRates
            $referenceMinimum = ($referenceRates | Measure-Object -Minimum).Minimum
            $referenceMaximum = ($referenceRates | Measure-Object -Maximum).Maximum
            $referenceDrift = if ($referenceMedian -gt 0) {
                (($referenceMaximum - $referenceMinimum) / $referenceMedian) * 100.0
            }
            else {
                0.0
            }
            $report.Add(
                ("Reference candidate: {0} measurements, {1:N1}-{2:N1} H/s, {3:N2}% full drift." -f @(
                    $referenceRates.Count,
                    $referenceMinimum,
                    $referenceMaximum,
                    $referenceDrift
                ))
            )
            if ($referenceDrift -gt 2.0) {
                $report.Add("")
                $report.Add(
                    "**Warning:** reference drift exceeded 2%; repeat close finalists under quieter and more thermally consistent conditions."
                )
            }
        }
        else {
            $report.Add("Fewer than two successful reference measurements were available.")
        }

        if ($Rankings.Count -gt 1) {
            $leaderRate = [double] $Rankings[0].MedianHashrate
            $runnerUpRate = [double] $Rankings[1].MedianHashrate
            $leaderMarginPercent = if ($runnerUpRate -gt 0) {
                (($leaderRate - $runnerUpRate) / $runnerUpRate) * 100.0
            }
            else {
                0.0
            }
            $report.Add("")
            if ($leaderMarginPercent -lt 1.0) {
                $report.Add(
                    ("The leading two configurations differ by only {0:N2}%; treat them as practically tied and prefer the cooler or more stable option." -f $leaderMarginPercent)
                )
            }
            else {
                $report.Add(
                    ("The leader's median advantage over the runner-up is {0:N2}%." -f $leaderMarginPercent)
                )
            }
        }
    }

    $failures = @($Runs | Where-Object { -not $_.Succeeded })
    $report.Add("")
    $report.Add("## Interpretation")
    $report.Add("")
    $report.Add("Use the highest-ranked configuration as a candidate, not as an automatic production change. Validate it while mining SAL for several hours and compare accepted shares, temperature, package power, and virtualization responsiveness. A difference below roughly one percent should be treated cautiously unless repeated runs agree.")
    $report.Add("")
    $report.Add("This tuner deliberately disables MSR access. If a separate non-hypervisor boot later makes the XMRig MSR modification available, validate that environment separately while keeping the winning affinity and RandomX settings constant.")
    $report.Add("")
    $report.Add("Successful runs: $(@($Runs | Where-Object Succeeded).Count)")
    $report.Add("")
    $report.Add("Failed runs: $($failures.Count)")
    if ($failures.Count -gt 0) {
        $report.Add("")
        foreach ($failure in $failures) {
            if ($failure.ThermallyLimited) {
                $report.Add("- Sequence $($failure.Sequence), $($failure.ConfigKey): thermally limited at $($failure.ThermalLimitObservedC) C (ceiling $($failure.TemperatureLimitC) C)")
            }
            elseif ($failure.TemperatureMonitoringFailed) {
                $report.Add("- Sequence $($failure.Sequence), $($failure.ConfigKey): temperature monitoring failed: $($failure.TemperatureFailure)")
            }
            elseif (-not $failure.BenchmarkValidated) {
                $report.Add("- Sequence $($failure.Sequence), $($failure.ConfigKey): benchmark validation failed: $($failure.ValidationFailures)")
            }
            else {
                $report.Add("- Sequence $($failure.Sequence), $($failure.ConfigKey): exit $($failure.ExitCode), timeout $($failure.TimedOut)")
            }
        }
    }

    Write-Utf8File -Path $reportPath -Content ($report -join [Environment]::NewLine)

    if ($Rankings.Count -gt 0) {
        $winner = $Rankings[0]
        $recommendation = [ordered] @{
            generated_at_utc = [DateTime]::UtcNow.ToString("o")
            algorithm        = "rx/0"
            source           = "offline XMRig benchmark; validate on the SAL pool before production use"
            cpu              = [ordered] @{
                "huge-pages-jit" = [bool] $winner.HugePagesJit
                yield            = [bool] $winner.Yield
                rx               = @($winner.Affinity -split "," | ForEach-Object { [int] $_ })
            }
            randomx = [ordered] @{
                scratchpad_prefetch_mode = [int] $winner.PrefetchMode
            }
            held_constant = [ordered] @{
                "huge-pages" = $Baseline.HugePages
                cpu_priority = $Priority
                rdmsr        = $false
                wrmsr        = $false
                cache_qos    = $false
            }
            measurement = [ordered] @{
                benchmark_size    = $winner.BenchmarkSize
                attempts          = $winner.Attempts
                samples           = $winner.Samples
                median_hashrate   = [Math]::Round($winner.MedianHashrate, 1)
                mean_hashrate     = [Math]::Round($winner.MeanHashrate, 1)
                minimum_hashrate  = [Math]::Round($winner.MinimumHashrate, 1)
                maximum_hashrate  = [Math]::Round($winner.MaximumHashrate, 1)
                standard_deviation = if ($null -ne $winner.StandardDeviation) {
                    [Math]::Round($winner.StandardDeviation, 1)
                }
                else {
                    $null
                }
                median_absolute_deviation = if ($null -ne $winner.MedianAbsoluteDeviation) {
                    [Math]::Round($winner.MedianAbsoluteDeviation, 1)
                }
                else {
                    $null
                }
                coefficient_of_variation_percent = if ($null -ne $winner.CoefficientOfVariationPercent) {
                    [Math]::Round($winner.CoefficientOfVariationPercent, 3)
                }
                else {
                    $null
                }
                confidence_95_half_width = if ($null -ne $winner.Confidence95HalfWidth) {
                    [Math]::Round($winner.Confidence95HalfWidth, 1)
                }
                else {
                    $null
                }
                sustained_median_hashrate = if ($null -ne $winner.SustainedMedianHashrate) {
                    [Math]::Round($winner.SustainedMedianHashrate, 1)
                }
                else {
                    $null
                }
            }
        }
        if ($Preset -eq "Rigorous") {
            $recommendation["experiment"] = [ordered] @{
                preset                    = $Preset
                candidate_order_seed      = $CandidateOrderSeed
                advance_within_percent    = $AdvanceWithinPercent
                screening_benchmark_size  = $ScreeningBenchmarkSize
                refinement_benchmark_size = $RefinementBenchmarkSize
                interaction_benchmark_size = $BenchmarkSize
                final_benchmark_size      = $FinalBenchmarkSize
                final_confirmation_runs   = $resolvedFinalConfirmationRuns
                manifest                  = $runManifestPath
            }
            $recommendation["alternatives_within_one_percent"] = @(
                $Rankings |
                    Select-Object -Skip 1 |
                    Where-Object {
                        $_.MedianHashrate -ge ($winner.MedianHashrate * 0.99)
                    } |
                    ForEach-Object {
                        [ordered] @{
                            profile                 = $_.Profile
                            affinity                = @($_.Affinity -split "," | ForEach-Object { [int] $_ })
                            scratchpad_prefetch_mode = [int] $_.PrefetchMode
                            yield                   = [bool] $_.Yield
                            huge_pages_jit          = [bool] $_.HugePagesJit
                            median_hashrate         = [Math]::Round($_.MedianHashrate, 1)
                            measured_mean_c         = if ($null -ne $_.MeanTemperatureC) {
                                [Math]::Round($_.MeanTemperatureC, 1)
                            }
                            else {
                                $null
                            }
                            measured_maximum_c      = if ($null -ne $_.MaximumTemperatureC) {
                                [Math]::Round($_.MaximumTemperatureC, 1)
                            }
                            else {
                                $null
                            }
                        }
                    }
            )
        }
        if ($TemperaturePolicy.Enabled) {
            $recommendation["temperature"] = [ordered] @{
                mode = if ($TemperaturePolicy.Enforced) { "enforced-maximum" } else { "monitor-only" }
                sensor = $TemperaturePolicy.ProviderName
                sensor_identifier = $TemperaturePolicy.Identifier
                maximum_limit_c = $TemperaturePolicy.LimitC
                resume_below_c = $TemperaturePolicy.ResumeBelowC
                measured_mean_c = if ($null -ne $winner.MeanTemperatureC) {
                    [Math]::Round($winner.MeanTemperatureC, 1)
                }
                else {
                    $null
                }
                measured_maximum_c = if ($null -ne $winner.MaximumTemperatureC) {
                    [Math]::Round($winner.MaximumTemperatureC, 1)
                }
                else {
                    $null
                }
                measured_slope_c_per_minute = if ($null -ne $winner.MeanTemperatureSlopeCPerMinute) {
                    [Math]::Round($winner.MeanTemperatureSlopeCPerMinute, 3)
                }
                else {
                    $null
                }
            }
        }
        Write-Utf8File -Path $recommendationPath -Content ($recommendation | ConvertTo-Json -Depth 6)
    }

    return [pscustomobject] @{
        Csv            = $csvPath
        Json           = $jsonPath
        Report         = $reportPath
        Recommendation = if (Test-Path -LiteralPath $recommendationPath) { $recommendationPath } else { $null }
    }
}

function Write-MeasurementCheckpoint {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]] $Runs,

        [Parameter(Mandatory = $true)]
        [string] $ResultsDirectory
    )

    $csvPath = Join-Path $ResultsDirectory "measurements.csv"
    $jsonPath = Join-Path $ResultsDirectory "measurements.json"
    $Runs | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    Write-Utf8File -Path $jsonPath -Content ($Runs | ConvertTo-Json -Depth 6)
}

$resolvedXmrigPath = (Resolve-Path -LiteralPath $XmrigPath).Path
if ([System.IO.Path]::GetExtension($resolvedXmrigPath) -ne ".exe") {
    throw "XmrigPath must point to a Windows .exe file."
}

$resumeManifest = $null
$resumeDirectoryPath = $null
if (-not [string]::IsNullOrWhiteSpace($ResumeDirectory)) {
    if ($SmokeTest -or $PlanOnly) {
        throw "ResumeDirectory cannot be combined with SmokeTest or PlanOnly."
    }
    $resumeDirectoryPath = (Resolve-Path -LiteralPath $ResumeDirectory).Path
    if (
        -not [string]::IsNullOrWhiteSpace($OutputDirectory) -and
        [System.IO.Path]::GetFullPath($OutputDirectory) -ne $resumeDirectoryPath
    ) {
        throw "OutputDirectory and ResumeDirectory must identify the same directory."
    }
    $manifestPath = Join-Path $resumeDirectoryPath "run-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "ResumeDirectory does not contain run-manifest.json."
    }
    $resumeManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([int] $resumeManifest.schema_version -ne 2) {
        throw "The run manifest schema is not supported for resume."
    }
    $currentScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    if ([string] $resumeManifest.script.sha256 -ne $currentScriptSha256) {
        throw "The tuner script hash does not match the resumed run."
    }
    if ($PSBoundParameters.ContainsKey("Preset") -and $Preset -ne [string] $resumeManifest.preset) {
        throw "Preset '$Preset' does not match the resumed '$($resumeManifest.preset)' run."
    }
    $Preset = [string] $resumeManifest.preset
    if ($Preset -ne "Rigorous") {
        throw "Only Rigorous runs currently support resume."
    }

    $CandidateOrderSeed = [int] $resumeManifest.experiment.candidate_order_seed
    $BenchmarkSize = [string] $resumeManifest.experiment.interaction_benchmark_size
    $ScreeningBenchmarkSize = [string] $resumeManifest.experiment.screening_benchmark_size
    $RefinementBenchmarkSize = [string] $resumeManifest.experiment.refinement_benchmark_size
    $FinalBenchmarkSize = [string] $resumeManifest.experiment.final_benchmark_size
    $ScreeningRepeats = [int] $resumeManifest.experiment.screening_repeats
    $FinalConfirmationRuns = [int] $resumeManifest.experiment.final_confirmation_runs
    $AdvanceWithinPercent = [double] $resumeManifest.experiment.advance_within_percent
    $MaximumSurvivors = [int] $resumeManifest.experiment.maximum_survivors
    $ReferenceInterval = [int] $resumeManifest.experiment.reference_interval
    $CpuPriority = [int] $resumeManifest.experiment.cpu_priority
    $CooldownSeconds = [int] $resumeManifest.experiment.cooldown_seconds
    $TimeoutSeconds = [int] $resumeManifest.experiment.timeout_seconds
    $IncludeSmt = [bool] $resumeManifest.experiment.include_smt
    $ExploreThermalAffinities = [bool] $resumeManifest.experiment.explore_thermal_affinities
    if ([bool] $resumeManifest.temperature.enabled) {
        $MonitorCpuTemperature = $true
        if ([bool] $resumeManifest.temperature.enforced) {
            $MaxCpuTemperatureC = [double] $resumeManifest.temperature.maximum_limit_c
        }
        $TemperatureSensorIdentifier = [string] $resumeManifest.temperature.sensor_identifier
        $manifestTemperatureCommandSha256 = [string] $resumeManifest.temperature.command_sha256
        $currentTemperatureCommandSha256 = if (
            -not [string]::IsNullOrWhiteSpace($TemperatureCommand)
        ) {
            Get-StringSha256 -Value $TemperatureCommand
        }
        else {
            ""
        }
        if ($manifestTemperatureCommandSha256 -ne $currentTemperatureCommandSha256) {
            throw "TemperatureCommand does not match the resumed run; repeat the original command."
        }
        $TemperatureSampleSeconds = [int] $resumeManifest.temperature.sample_seconds
        $TemperatureCooldownMarginC = [double] $resumeManifest.temperature.cooldown_margin_c
        $TemperatureStableSeconds = [int] $resumeManifest.temperature.stable_seconds
        $TemperatureCooldownTimeoutSeconds = [int] $resumeManifest.temperature.cooldown_timeout_seconds
    }
    elseif ($temperatureRequested) {
        throw "Temperature options do not match the temperature-disabled resumed run."
    }
    $OutputDirectory = $resumeDirectoryPath
}

$temperatureLimitSpecified = (
    $PSBoundParameters.ContainsKey("MaxCpuTemperatureC") -or
    ($null -ne $resumeManifest -and [bool] $resumeManifest.temperature.enforced)
)
$temperatureRequested = (
    $MonitorCpuTemperature -or
    $temperatureLimitSpecified -or
    -not [string]::IsNullOrWhiteSpace($TemperatureSensorIdentifier) -or
    -not [string]::IsNullOrWhiteSpace($TemperatureCommand)
)
if ($temperatureLimitSpecified -and $TemperatureCooldownMarginC -ge $MaxCpuTemperatureC) {
    throw "TemperatureCooldownMarginC must be lower than MaxCpuTemperatureC."
}

$manualPProvided = $PSBoundParameters.ContainsKey("PCoreLogicalProcessors")
$manualEProvided = $PSBoundParameters.ContainsKey("ECoreLogicalProcessors")

if ([string]::IsNullOrWhiteSpace($BaselineConfigPath) -and -not $IgnoreAdjacentConfig) {
    $adjacentConfig = Join-Path (Split-Path -Parent $resolvedXmrigPath) "config.json"
    if (Test-Path -LiteralPath $adjacentConfig) {
        $BaselineConfigPath = $adjacentConfig
    }
}

$baseline = Read-BaselineSettings -Path $BaselineConfigPath
$topology = Get-CpuTopology -ManualP $PCoreLogicalProcessors -ManualE $ECoreLogicalProcessors `
    -UseManualP $manualPProvided -UseManualE $manualEProvided

$invalidBaselineProcessors = @(
    $baseline.Affinity | Where-Object {
        $_ -lt 0 -or $_ -ge $topology.LogicalProcessorCount
    }
)
if ($invalidBaselineProcessors.Count -gt 0) {
    throw "The baseline CPU profile contains unavailable logical processors: $($invalidBaselineProcessors -join ', ')."
}

$benchmarkSizeExplicit = $PSBoundParameters.ContainsKey("BenchmarkSize") -and $BenchmarkSize -ne "Auto"
if ($BenchmarkSize -eq "Auto") {
    $BenchmarkSize = switch ($Preset) {
        "Quick" { "250K" }
        "Standard" { "1M" }
        "Thorough" { "2M" }
        "Rigorous" { "2M" }
    }
}
if ($SmokeTest) {
    $BenchmarkSize = "250K"
}

if ($ScreeningBenchmarkSize -eq "Auto") {
    $ScreeningBenchmarkSize = if ($Preset -eq "Rigorous" -and -not $benchmarkSizeExplicit) {
        "500K"
    }
    else {
        $BenchmarkSize
    }
}
if ($RefinementBenchmarkSize -eq "Auto") {
    $RefinementBenchmarkSize = if ($Preset -eq "Rigorous" -and -not $benchmarkSizeExplicit) {
        "1M"
    }
    else {
        $BenchmarkSize
    }
}
if ($FinalBenchmarkSize -eq "Auto") {
    $FinalBenchmarkSize = if ($Preset -eq "Rigorous" -and -not $benchmarkSizeExplicit) {
        "5M"
    }
    else {
        $BenchmarkSize
    }
}
if ($SmokeTest) {
    $ScreeningBenchmarkSize = "250K"
    $RefinementBenchmarkSize = "250K"
    $FinalBenchmarkSize = "250K"
}

$resolvedScreeningRepeats = if ($ScreeningRepeats -gt 0) {
    $ScreeningRepeats
}
elseif ($Preset -eq "Rigorous") {
    2
}
else {
    1
}
$resolvedFinalConfirmationRuns = if ($FinalConfirmationRuns -gt 0) {
    $FinalConfirmationRuns
}
elseif ($Preset -eq "Rigorous") {
    3
}
else {
    switch ($Preset) {
        "Quick" { 1 }
        "Standard" { 1 }
        "Thorough" { 2 }
    }
}
if ($CandidateOrderSeed -eq 0) {
    $CandidateOrderSeed = Get-Random -Minimum 1 -Maximum 1999000000
}

$profiles = @(New-AffinityProfiles -Topology $topology -Baseline $baseline `
    -SelectedPreset $Preset -AddSmt ([bool] $IncludeSmt) `
    -ExploreThermal ([bool] ($ExploreThermalAffinities -or $Preset -eq "Rigorous")))
if ($profiles.Count -eq 0) {
    throw "No valid CPU affinity profiles were generated."
}
$profileFingerprint = @(
    $profiles | ForEach-Object {
        "{0}={1}" -f $_.Name, ($_.Affinity -join ",")
    }
) -join "|"

$xmrigSha256 = (Get-FileHash -LiteralPath $resolvedXmrigPath -Algorithm SHA256).Hash
$baselineSha256 = if ($null -ne $baseline.Path) {
    (Get-FileHash -LiteralPath $baseline.Path -Algorithm SHA256).Hash
}
else {
    $null
}
$topologyFingerprint = "{0}|{1}|p={2}|e={3}|l3={4}" -f @(
    $topology.Name.Trim(),
    $topology.LogicalProcessorCount,
    ($topology.PerformancePrimary -join ","),
    ($topology.Efficient -join ","),
    $topology.L3CacheKb
)
if ($null -ne $resumeManifest) {
    if ([string] $resumeManifest.xmrig.sha256 -ne $xmrigSha256) {
        throw "The XMRig executable hash does not match the resumed run."
    }
    if ([string] $resumeManifest.topology.fingerprint -ne $topologyFingerprint) {
        throw "The CPU topology does not match the resumed run."
    }
    if ([string] $resumeManifest.experiment.profile_fingerprint -ne $profileFingerprint) {
        throw "The generated affinity profiles do not match the resumed run."
    }
    $manifestBaselineHash = [string] $resumeManifest.baseline.sha256
    $currentBaselineHash = [string] $baselineSha256
    if ($manifestBaselineHash -ne $currentBaselineHash) {
        throw "The baseline configuration hash does not match the resumed run."
    }
}

$topProfileCount = switch ($Preset) {
    "Quick" { 1 }
    "Standard" { 2 }
    "Thorough" { 3 }
    "Rigorous" { 3 }
}
$confirmationRuns = switch ($Preset) {
    "Quick" { 1 }
    "Standard" { 1 }
    "Thorough" { 2 }
    "Rigorous" { $resolvedFinalConfirmationRuns }
}

Write-Host ""
Write-Host "Salvium RandomX tuner" -ForegroundColor Cyan
Write-Host "  CPU: $($topology.Name.Trim())"
Write-Host "  performance-core primary processors: $($topology.PerformancePrimary -join ',')"
Write-Host "  efficient-core processors: $($topology.Efficient -join ',')"
Write-Host "  L3 cache: $($topology.L3CacheKb) KiB"
if ($Preset -eq "Rigorous") {
    Write-Host "  benchmark sizes: screen $ScreeningBenchmarkSize; refine $RefinementBenchmarkSize; interaction $BenchmarkSize; final $FinalBenchmarkSize"
    Write-Host "  candidate-order seed: $CandidateOrderSeed"
    Write-Host "  screening repeats: $resolvedScreeningRepeats"
    Write-Host "  survivor beam: within $AdvanceWithinPercent%, maximum $MaximumSurvivors"
    Write-Host "  final confirmation runs: $resolvedFinalConfirmationRuns"
}
else {
    Write-Host "  benchmark size: $BenchmarkSize"
}
Write-Host "  CPU priority: $CpuPriority"
Write-Host "  MSR and networking: disabled"
if ($temperatureRequested) {
    if ($temperatureLimitSpecified) {
        Write-Host ("  CPU temperature: enforced maximum {0:N1} C; resume below {1:N1} C" -f @(
            $MaxCpuTemperatureC,
            ($MaxCpuTemperatureC - $TemperatureCooldownMarginC)
        ))
    }
    else {
        Write-Host "  CPU temperature: monitor only; rankings are unchanged"
    }
    $requestedSensor = if (-not [string]::IsNullOrWhiteSpace($TemperatureCommand)) {
        "custom TemperatureCommand"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($TemperatureSensorIdentifier)) {
        $TemperatureSensorIdentifier
    }
    else {
        "auto-detect at execution time"
    }
    Write-Host "  requested temperature source: $requestedSensor"
}
else {
    Write-Host "  CPU temperature: disabled"
}
if ($null -ne $baseline.Path) {
    Write-Host "  imported tuning fields: $($baseline.Path)"
}
Write-Host ""

if ($PlanOnly) {
    Write-Host "Stage-one affinity profiles:" -ForegroundColor Cyan
    foreach ($profile in $profiles) {
        Write-Host ("  {0,-34} {1,2} threads  [{2}]" -f @(
            $profile.Name,
            $profile.Threads,
            ($profile.Affinity -join ",")
        ))
        Write-Host "    $($profile.Reason)"
    }

    if ($SmokeTest) {
        Write-Host ""
        Write-Host "Smoke test: one 250K run."
    }
    elseif ($Preset -eq "Rigorous") {
        $referenceRuns = if ($ReferenceInterval -gt 0) {
            [Math]::Ceiling(($profiles.Count * $resolvedScreeningRepeats) / [double] $ReferenceInterval) + 2
        }
        else {
            2
        }
        $estimatedRuns = (
            ($profiles.Count * $resolvedScreeningRepeats) +
            $referenceRuns +
            ($MaximumSurvivors * 4) +
            ($MaximumSurvivors * 4) +
            ([Math]::Min(3, $MaximumSurvivors) * $resolvedFinalConfirmationRuns)
        )
        $referenceDescription = if ($ReferenceInterval -gt 0) {
            "every $ReferenceInterval candidate(s)"
        }
        else {
            "at the start and end only"
        }
        Write-Host ""
        Write-Host "Rigorous adaptive stages:"
        Write-Host "  1. Randomized affinity screening with $resolvedScreeningRepeats measurement(s) per profile."
        Write-Host "  2. Reference anchors $referenceDescription to expose environmental drift."
        Write-Host "  3. Advance configurations within $AdvanceWithinPercent% of the leader, capped at $MaximumSurvivors."
        Write-Host "  4. Test prefetch and then yield/JIT interactions across every survivor."
        Write-Host "  5. Randomize and repeat up to three finalists $resolvedFinalConfirmationRuns time(s) at $FinalBenchmarkSize."
        Write-Host "  Approximate maximum: $estimatedRuns runs; duplicate stage measurements are reused on resume."
    }
    else {
        $estimatedRuns = $profiles.Count + ($topProfileCount * 4) + 4 + (2 * $confirmationRuns)
        Write-Host ""
        Write-Host "Adaptive stages:"
        Write-Host "  1. Compare $($profiles.Count) affinity profiles with imported baseline settings."
        Write-Host "  2. Test prefetch modes 0-3 on the best $topProfileCount profile(s)."
        Write-Host "  3. Test yield and JIT huge-page combinations on the leading profile."
        Write-Host "  4. Confirm the leading two configurations $confirmationRuns additional time(s)."
        Write-Host "  Approximate maximum: $estimatedRuns runs; duplicate configurations are reused."
    }

    Write-Host ""
    Write-Host "Plan only: XMRig was not launched and no result files were written." -ForegroundColor Green
    exit 0
}

$runningXmrig = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match "^xmrig" }
)
if ($runningXmrig.Count -gt 0 -and -not $AllowConcurrentXmrig) {
    $processDescription = $runningXmrig | ForEach-Object { "$($_.ProcessName) (PID $($_.Id))" }
    throw "Another XMRig process is running: $($processDescription -join ', '). Stop it before tuning, or explicitly use -AllowConcurrentXmrig and accept confounded results."
}
if ($runningXmrig.Count -gt 0) {
    Write-Warning "Another XMRig process is running. Benchmark results will be confounded."
}

$temperaturePolicy = New-CpuTemperaturePolicy -Enabled $temperatureRequested `
    -Enforced $temperatureLimitSpecified -SensorIdentifier $TemperatureSensorIdentifier `
    -Command $TemperatureCommand -LimitC $MaxCpuTemperatureC `
    -SampleSeconds $TemperatureSampleSeconds -CooldownMarginC $TemperatureCooldownMarginC `
    -StableSeconds $TemperatureStableSeconds `
    -CooldownTimeoutSeconds $TemperatureCooldownTimeoutSeconds
if ($temperaturePolicy.Enabled) {
    $initialTemperature = Read-CpuTemperature -Policy $temperaturePolicy
    Write-Host "Temperature sensor: $($temperaturePolicy.ProviderName)"
    if (-not [string]::IsNullOrWhiteSpace([string] $temperaturePolicy.Identifier)) {
        Write-Host "  identifier: $($temperaturePolicy.Identifier)"
    }
    Write-Host ("  initial reading: {0:N1} C" -f $initialTemperature)
    Write-Host ""
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $baseOutputDirectory = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:LOCALAPPDATA "XmrigSalviumTuner\Runs"
    }
    else {
        Join-Path ([System.IO.Path]::GetTempPath()) "XmrigSalviumTuner\Runs"
    }
    $OutputDirectory = Join-Path $baseOutputDirectory (Get-Date -Format "yyyyMMdd-HHmmss")
}
else {
    $OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
}

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
Write-Host "Results: $OutputDirectory"
Write-Host ""

$runs = New-Object System.Collections.Generic.List[object]
$sequence = 0
$hasRunCandidate = $false
$runManifestPath = Join-Path $OutputDirectory "run-manifest.json"
if ($null -eq $resumeManifest) {
    $scriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    $runManifest = [ordered] @{
        schema_version = 2
        created_at_utc = [DateTime]::UtcNow.ToString("o")
        platform       = "windows"
        preset         = $Preset
        script         = [ordered] @{
            path   = $PSCommandPath
            sha256 = $scriptSha256
        }
        xmrig          = [ordered] @{
            path   = $resolvedXmrigPath
            sha256 = $xmrigSha256
        }
        baseline       = [ordered] @{
            path   = $baseline.Path
            sha256 = $baselineSha256
        }
        topology       = [ordered] @{
            fingerprint            = $topologyFingerprint
            cpu                    = $topology.Name.Trim()
            logical_processors     = $topology.LogicalProcessorCount
            performance_processors = @($topology.PerformancePrimary)
            efficient_processors   = @($topology.Efficient)
            l3_cache_kib           = $topology.L3CacheKb
        }
        experiment     = [ordered] @{
            candidate_order_seed       = $CandidateOrderSeed
            screening_benchmark_size   = $ScreeningBenchmarkSize
            refinement_benchmark_size  = $RefinementBenchmarkSize
            interaction_benchmark_size = $BenchmarkSize
            final_benchmark_size       = $FinalBenchmarkSize
            screening_repeats          = $resolvedScreeningRepeats
            final_confirmation_runs    = $resolvedFinalConfirmationRuns
            advance_within_percent     = $AdvanceWithinPercent
            maximum_survivors          = $MaximumSurvivors
            reference_interval         = $ReferenceInterval
            cpu_priority               = $CpuPriority
            cooldown_seconds           = $CooldownSeconds
            timeout_seconds            = $TimeoutSeconds
            include_smt                = [bool] $IncludeSmt
            explore_thermal_affinities = [bool] ($ExploreThermalAffinities -or $Preset -eq "Rigorous")
            profile_fingerprint        = $profileFingerprint
        }
        temperature    = [ordered] @{
            enabled                  = [bool] $temperaturePolicy.Enabled
            enforced                 = [bool] $temperaturePolicy.Enforced
            maximum_limit_c          = $temperaturePolicy.LimitC
            sensor                   = $temperaturePolicy.ProviderName
            sensor_identifier        = $temperaturePolicy.Identifier
            command_sha256           = if (
                [string]::IsNullOrWhiteSpace($TemperatureCommand)
            ) {
                $null
            }
            else {
                Get-StringSha256 -Value $TemperatureCommand
            }
            sample_seconds           = $TemperatureSampleSeconds
            cooldown_margin_c        = $TemperatureCooldownMarginC
            stable_seconds           = $TemperatureStableSeconds
            cooldown_timeout_seconds = $TemperatureCooldownTimeoutSeconds
        }
        affinity_profiles = @(
            $profiles | ForEach-Object {
                [ordered] @{
                    name     = $_.Name
                    affinity = @($_.Affinity)
                    reason   = $_.Reason
                }
            }
        )
    }
    Write-Utf8File -Path $runManifestPath -Content ($runManifest | ConvertTo-Json -Depth 8)
}
else {
    $measurementPath = Join-Path $OutputDirectory "measurements.json"
    if (Test-Path -LiteralPath $measurementPath) {
        $parsedExistingRuns = Get-Content -LiteralPath $measurementPath -Raw |
            ConvertFrom-Json
        [object[]] $existingRuns = $parsedExistingRuns
        foreach ($existingRun in $existingRuns) {
            $runs.Add($existingRun)
        }
        if ($runs.Count -gt 0) {
            $sequence = [int] (($runs | Measure-Object Sequence -Maximum).Maximum)
            $hasRunCandidate = $true
        }
    }
    Write-Host "Resuming $($runs.Count) preserved measurement(s) at sequence $sequence." `
        -ForegroundColor Cyan
    Write-Host ""
}

function Invoke-Candidate {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Candidate,

        [Parameter(Mandatory = $true)]
        [string] $Stage,

        [string] $Size = $BenchmarkSize,

        [switch] $Force,

        [switch] $ExactStage
    )

    if (
        -not $Force -and
        (Test-CandidateAlreadyMeasured -Candidate $Candidate -Runs $runs `
            -Stage $Stage -Size $Size -ExactStage:$ExactStage)
    ) {
        return
    }

    $preRunCooling = $null
    if ($script:temperaturePolicy.Enforced) {
        $minimumWait = if ($script:hasRunCandidate) { $CooldownSeconds } else { 0 }
        try {
            $preRunCooling = Wait-ForTemperatureReady -Policy $script:temperaturePolicy `
                -MinimumWaitSeconds $minimumWait
        }
        catch {
            $null = Write-PartialTuningOutputs
            throw
        }
        Write-Host ("      thermal start condition: {0:N1} C after {1:N1} seconds" -f @(
            $preRunCooling.ReadyTemperatureC,
            $preRunCooling.WaitSeconds
        ))
    }

    $script:sequence++
    $result = Invoke-XmrigBenchmark -Executable $resolvedXmrigPath -Candidate $Candidate `
        -Baseline $baseline -Size $Size -Priority $CpuPriority -Stage $Stage `
        -Sequence $script:sequence -ResultsDirectory $OutputDirectory -Timeout $TimeoutSeconds `
        -TemperaturePolicy $script:temperaturePolicy -PreRunCooling $preRunCooling
    $expectedHashSum = $runs |
        Where-Object {
            $_.Succeeded -and
            $_.BenchmarkSize -eq $Size -and
            -not [string]::IsNullOrWhiteSpace([string] $_.HashSum)
        } |
        Select-Object -ExpandProperty HashSum -First 1
    if (
        $result.Succeeded -and
        -not [string]::IsNullOrWhiteSpace([string] $expectedHashSum) -and
        [string] $result.HashSum -ne [string] $expectedHashSum
    ) {
        $result.Succeeded = $false
        $result.BenchmarkValidated = $false
        $hashFailure = "Benchmark hash sum $($result.HashSum) did not match expected $expectedHashSum for size $Size."
        $result.ValidationFailures = (
            @($result.ValidationFailures, $hashFailure) |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
        ) -join " "
        Write-Warning $hashFailure
    }
    $runs.Add($result)
    $script:hasRunCandidate = $true
    Write-MeasurementCheckpoint -Runs $runs -ResultsDirectory $OutputDirectory

    if ($script:temperaturePolicy.Enforced -and $result.TemperatureMonitoringFailed) {
        $null = Write-PartialTuningOutputs
        throw "CPU temperature enforcement stopped because the sensor failed: $($result.TemperatureFailure). Measurements were preserved in $OutputDirectory."
    }

    if (-not $script:temperaturePolicy.Enforced -and $CooldownSeconds -gt 0) {
        Start-Sleep -Seconds $CooldownSeconds
    }
}

function Write-PartialTuningOutputs {
    $emptyRankings = [object[]] @()
    return Write-TuningOutputs -Runs $runs -Rankings $emptyRankings -Topology $topology `
        -Baseline $baseline -Executable $resolvedXmrigPath -ResultsDirectory $OutputDirectory `
        -Size $BenchmarkSize -Priority $CpuPriority -TemperaturePolicy $temperaturePolicy
}

$baselineProfile = $profiles | Where-Object Name -eq "baseline-rx" | Select-Object -First 1
if ($null -eq $baselineProfile) {
    $baselineProfile = $profiles | Where-Object Name -eq "performance-cores" | Select-Object -First 1
}
if ($null -eq $baselineProfile) {
    $baselineProfile = $profiles[0]
}

$rankingScopeRuns = $null
if ($SmokeTest) {
    $candidate = New-TestCandidate -Profile $baselineProfile `
        -PrefetchMode $baseline.ScratchpadPrefetchMode `
        -Yield $baseline.Yield -HugePagesJit $baseline.HugePagesJit
    Invoke-Candidate -Candidate $candidate -Stage "smoke"
}
elseif ($Preset -eq "Rigorous") {
    $referenceCandidate = New-TestCandidate -Profile $baselineProfile `
        -PrefetchMode $baseline.ScratchpadPrefetchMode `
        -Yield $baseline.Yield -HugePagesJit $baseline.HugePagesJit
    Invoke-Candidate -Candidate $referenceCandidate -Stage "rigorous-reference-start" `
        -Size $ScreeningBenchmarkSize -ExactStage

    $screeningOrdinal = 0
    for ($repeat = 1; $repeat -le $resolvedScreeningRepeats; $repeat++) {
        $orderedProfiles = @(Get-ShuffledItems -Items $profiles `
            -Seed ($CandidateOrderSeed + (1000 * $repeat)))
        foreach ($profile in $orderedProfiles) {
            $candidate = New-TestCandidate -Profile $profile `
                -PrefetchMode $baseline.ScratchpadPrefetchMode `
                -Yield $baseline.Yield -HugePagesJit $baseline.HugePagesJit
            Invoke-Candidate -Candidate $candidate -Stage "rigorous-affinity-r$repeat" `
                -Size $ScreeningBenchmarkSize -ExactStage
            $screeningOrdinal++
            if ($ReferenceInterval -gt 0 -and ($screeningOrdinal % $ReferenceInterval) -eq 0) {
                $referenceNumber = [int] ($screeningOrdinal / $ReferenceInterval)
                Invoke-Candidate -Candidate $referenceCandidate `
                    -Stage "rigorous-reference-$referenceNumber" `
                    -Size $ScreeningBenchmarkSize -ExactStage
            }
        }
    }
    Invoke-Candidate -Candidate $referenceCandidate -Stage "rigorous-reference-end" `
        -Size $ScreeningBenchmarkSize -ExactStage

    $affinityRuns = @($runs | Where-Object { $_.Stage -like "rigorous-affinity-r*" })
    $affinityRankings = @(Get-RankedConfigurations -Runs $affinityRuns)
    if ($affinityRankings.Count -eq 0) {
        $null = Write-PartialTuningOutputs
        throw "Every rigorous affinity screening benchmark failed. Inspect the logs in $OutputDirectory."
    }
    $advancingAffinities = @(
        Select-AdvancingRankings -Rankings $affinityRankings `
            -WithinPercent $AdvanceWithinPercent `
            -MinimumCount ([Math]::Min(3, $affinityRankings.Count)) `
            -MaximumCount ([Math]::Min($MaximumSurvivors, $affinityRankings.Count))
    )

    $prefetchCandidates = New-Object System.Collections.Generic.List[object]
    $prefetchKeys = @{}
    foreach ($ranking in $advancingAffinities) {
        $profile = $profiles | Where-Object Name -eq $ranking.Profile | Select-Object -First 1
        foreach ($prefetchMode in 0..3) {
            $candidate = New-TestCandidate -Profile $profile -PrefetchMode $prefetchMode `
                -Yield $baseline.Yield -HugePagesJit $baseline.HugePagesJit
            if (-not $prefetchKeys.ContainsKey($candidate.Key)) {
                $prefetchKeys[$candidate.Key] = $true
                $prefetchCandidates.Add($candidate)
            }
        }
    }
    $orderedPrefetchCandidates = @(Get-ShuffledItems -Items $prefetchCandidates.ToArray() `
        -Seed ($CandidateOrderSeed + 200000))
    foreach ($candidate in $orderedPrefetchCandidates) {
        Invoke-Candidate -Candidate $candidate -Stage "rigorous-prefetch" `
            -Size $RefinementBenchmarkSize -ExactStage
    }

    $prefetchRuns = @($runs | Where-Object Stage -eq "rigorous-prefetch")
    $prefetchRankings = @(Get-RankedConfigurations -Runs $prefetchRuns)
    if ($prefetchRankings.Count -eq 0) {
        $null = Write-PartialTuningOutputs
        throw "Every rigorous prefetch benchmark failed. Inspect the logs in $OutputDirectory."
    }
    $advancingPrefetch = @(
        Select-AdvancingRankings -Rankings $prefetchRankings `
            -WithinPercent $AdvanceWithinPercent `
            -MinimumCount ([Math]::Min(3, $prefetchRankings.Count)) `
            -MaximumCount ([Math]::Min($MaximumSurvivors, $prefetchRankings.Count))
    )

    $interactionCandidates = New-Object System.Collections.Generic.List[object]
    $interactionKeys = @{}
    foreach ($ranking in $advancingPrefetch) {
        $profile = $profiles | Where-Object Name -eq $ranking.Profile | Select-Object -First 1
        foreach ($yieldSetting in @($true, $false)) {
            foreach ($jitSetting in @($false, $true)) {
                $candidate = New-TestCandidate -Profile $profile `
                    -PrefetchMode $ranking.PrefetchMode `
                    -Yield $yieldSetting -HugePagesJit $jitSetting
                if (-not $interactionKeys.ContainsKey($candidate.Key)) {
                    $interactionKeys[$candidate.Key] = $true
                    $interactionCandidates.Add($candidate)
                }
            }
        }
    }
    $orderedInteractionCandidates = @(
        Get-ShuffledItems -Items $interactionCandidates.ToArray() `
            -Seed ($CandidateOrderSeed + 300000)
    )
    foreach ($candidate in $orderedInteractionCandidates) {
        Invoke-Candidate -Candidate $candidate -Stage "rigorous-interaction" `
            -Size $BenchmarkSize -ExactStage
    }

    $interactionRuns = @($runs | Where-Object Stage -eq "rigorous-interaction")
    $interactionRankings = @(Get-RankedConfigurations -Runs $interactionRuns)
    if ($interactionRankings.Count -eq 0) {
        $null = Write-PartialTuningOutputs
        throw "Every rigorous interaction benchmark failed. Inspect the logs in $OutputDirectory."
    }
    $finalistLimit = [Math]::Min(3, [Math]::Min($MaximumSurvivors, $interactionRankings.Count))
    $finalistRankings = @(
        Select-AdvancingRankings -Rankings $interactionRankings `
            -WithinPercent $AdvanceWithinPercent `
            -MinimumCount ([Math]::Min(2, $interactionRankings.Count)) `
            -MaximumCount $finalistLimit
    )
    $finalists = @(
        $finalistRankings | ForEach-Object {
            Get-CandidateFromRanking -Ranking $_ -Profiles $profiles
        }
    )

    for ($confirmation = 1; $confirmation -le $resolvedFinalConfirmationRuns; $confirmation++) {
        $orderedFinalists = @(
            Get-ShuffledItems -Items $finalists `
                -Seed ($CandidateOrderSeed + 400000 + (1000 * $confirmation))
        )
        foreach ($candidate in $orderedFinalists) {
            Invoke-Candidate -Candidate $candidate -Stage "rigorous-final-r$confirmation" `
                -Size $FinalBenchmarkSize -ExactStage
        }
    }

    $rankingScopeRuns = @($runs | Where-Object { $_.Stage -like "rigorous-final-r*" })
}
else {
    foreach ($profile in $profiles) {
        $candidate = New-TestCandidate -Profile $profile `
            -PrefetchMode $baseline.ScratchpadPrefetchMode `
            -Yield $baseline.Yield -HugePagesJit $baseline.HugePagesJit
        Invoke-Candidate -Candidate $candidate -Stage "affinity"
    }

    $stageOneRankings = @(Get-RankedConfigurations -Runs $runs.ToArray())
    if ($stageOneRankings.Count -eq 0) {
        $null = Write-PartialTuningOutputs
        throw "Every affinity benchmark failed. Inspect the logs in $OutputDirectory."
    }

    $leadingProfiles = @(
        $stageOneRankings |
            Select-Object -First $topProfileCount |
            ForEach-Object Profile |
            Select-Object -Unique
    )
    foreach ($profileName in $leadingProfiles) {
        $profile = $profiles | Where-Object Name -eq $profileName | Select-Object -First 1
        foreach ($prefetchMode in 0..3) {
            $candidate = New-TestCandidate -Profile $profile -PrefetchMode $prefetchMode `
                -Yield $baseline.Yield -HugePagesJit $baseline.HugePagesJit
            Invoke-Candidate -Candidate $candidate -Stage "prefetch"
        }
    }

    $prefetchRankings = @(
        Get-RankedConfigurations -Runs $runs.ToArray() |
            Where-Object Profile -in $leadingProfiles
    )
    if ($prefetchRankings.Count -eq 0) {
        $null = Write-PartialTuningOutputs
        throw "Every prefetch benchmark failed. Inspect the logs in $OutputDirectory."
    }

    $leadingPrefetch = $prefetchRankings[0]
    $leadingProfile = $profiles | Where-Object Name -eq $leadingPrefetch.Profile | Select-Object -First 1
    foreach ($yieldSetting in @($true, $false)) {
        foreach ($jitSetting in @($false, $true)) {
            $candidate = New-TestCandidate -Profile $leadingProfile `
                -PrefetchMode $leadingPrefetch.PrefetchMode `
                -Yield $yieldSetting -HugePagesJit $jitSetting
            Invoke-Candidate -Candidate $candidate -Stage "runtime"
        }
    }

    $rankingsBeforeConfirmation = @(Get-RankedConfigurations -Runs $runs.ToArray())
    $confirmationCandidates = @(
        $rankingsBeforeConfirmation |
            Select-Object -First 2 |
            ForEach-Object {
                Get-CandidateFromRanking -Ranking $_ -Profiles $profiles
            }
    )
    for ($confirmation = 1; $confirmation -le $confirmationRuns; $confirmation++) {
        foreach ($candidate in $confirmationCandidates) {
        Invoke-Candidate -Candidate $candidate -Stage "confirm-$confirmation" -Force
        }
    }
}

$rankings = @(
    if ($null -ne $rankingScopeRuns) {
        Get-RankedConfigurations -Runs $rankingScopeRuns |
            Where-Object {
                -not $temperaturePolicy.Enforced -or $_.AllAttemptsSucceeded
            }
    }
    else {
        Get-RankedConfigurations -Runs $runs.ToArray()
    }
)
if ($rankings.Count -eq 0) {
    $null = Write-PartialTuningOutputs
    throw "No successful benchmark result was produced. Inspect the logs in $OutputDirectory."
}

$outputs = Write-TuningOutputs -Runs $runs -Rankings $rankings -Topology $topology `
    -Baseline $baseline -Executable $resolvedXmrigPath -ResultsDirectory $OutputDirectory `
    -Size $BenchmarkSize -Priority $CpuPriority -TemperaturePolicy $temperaturePolicy

$winner = $rankings[0]
Write-Host ""
Write-Host "Best measured configuration" -ForegroundColor Cyan
Write-Host ("  {0:N1} H/s median ({1} sample(s))" -f $winner.MedianHashrate, $winner.Samples)
Write-Host "  profile: $($winner.Profile)"
Write-Host "  affinity: $($winner.Affinity)"
Write-Host "  scratchpad prefetch mode: $($winner.PrefetchMode)"
Write-Host "  yield: $($winner.Yield)"
Write-Host "  JIT huge pages: $($winner.HugePagesJit)"
if ($temperaturePolicy.Enabled -and $null -ne $winner.MaximumTemperatureC) {
    Write-Host ("  measured CPU temperature: {0:N1} C mean, {1:N1} C maximum" -f @(
        $winner.MeanTemperatureC,
        $winner.MaximumTemperatureC
    ))
}
$thermallyLimitedRuns = @($runs | Where-Object ThermallyLimited).Count
if ($thermallyLimitedRuns -gt 0) {
    Write-Host "  thermally limited candidates: $thermallyLimitedRuns"
}
Write-Host ""
Write-Host "Report: $($outputs.Report)"
Write-Host "Measurements: $($outputs.Csv)"
Write-Host "Recommendation: $($outputs.Recommendation)"
Write-Host ""
Write-Host "Validate the recommendation on the SAL pool before changing the production configuration." -ForegroundColor Yellow
