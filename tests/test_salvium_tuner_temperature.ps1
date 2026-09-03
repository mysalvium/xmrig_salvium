#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$tunerPath = Join-Path $repositoryRoot "scripts\tune-salvium-randomx.ps1"
$mockSourcePath = Join-Path $PSScriptRoot "tuner_mock_xmrig.cs"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "xmrig-tuner-temperature-tests-{0}" -f [Guid]::NewGuid().ToString("N")
)
$null = New-Item -ItemType Directory -Path $testRoot

try {
    $compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path -LiteralPath $compiler)) {
        $compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
    }
    Assert-True -Condition (Test-Path -LiteralPath $compiler) `
        -Message "The .NET Framework C# compiler is required."

    $mockPath = Join-Path $testRoot "xmrig-temperature-mock.exe"
    & $compiler /nologo /target:exe "/out:$mockPath" $mockSourcePath
    Assert-True -Condition ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $mockPath)) `
        -Message "The mock XMRig executable must compile."

    function Invoke-TestTuner {
        param(
            [Parameter(Mandatory = $true)]
            [string] $Name,

            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [string[]] $AdditionalArguments,

            [Parameter(Mandatory = $true)]
            [int] $ExpectedExitCode
        )

        $outputDirectory = Join-Path $testRoot $Name
        $arguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $tunerPath,
            "-XmrigPath", $mockPath,
            "-SmokeTest",
            "-IgnoreAdjacentConfig",
            "-OutputDirectory", $outputDirectory,
            "-CooldownSeconds", "0",
            "-AllowConcurrentXmrig"
        ) + $AdditionalArguments
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = @(& powershell.exe @arguments 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorAction
        }
        if ($exitCode -ne $ExpectedExitCode) {
            throw "Scenario '$Name' exited with $exitCode instead of $ExpectedExitCode.`n$($output -join [Environment]::NewLine)"
        }

        $measurementPath = Join-Path $outputDirectory "measurements.json"
        Assert-True -Condition (Test-Path -LiteralPath $measurementPath) `
            -Message "Scenario '$Name' must preserve measurements.json."
        return [pscustomobject] @{
            OutputDirectory = $outputDirectory
            Measurement = Get-Content -LiteralPath $measurementPath -Raw | ConvertFrom-Json
            Output = $output
        }
    }

    $disabled = Invoke-TestTuner -Name "disabled" -AdditionalArguments @() -ExpectedExitCode 0
    Assert-True -Condition ([bool] $disabled.Measurement.Succeeded) `
        -Message "The temperature-disabled baseline must succeed."
    Assert-True -Condition ($disabled.Measurement.TemperatureSamples -eq 0) `
        -Message "The disabled mode must not sample temperature."
    Assert-True -Condition (
        @(Get-ChildItem -LiteralPath $disabled.OutputDirectory -Filter "*.temperature.csv").Count -eq 0
    ) -Message "The disabled mode must not create temperature logs."

    $monitor = Invoke-TestTuner -Name "monitor-only" -AdditionalArguments @(
        "-MonitorCpuTemperature",
        "-TemperatureCommand", "65"
    ) -ExpectedExitCode 0
    Assert-True -Condition ([bool] $monitor.Measurement.Succeeded) `
        -Message "Monitor-only mode must not disqualify a candidate."
    Assert-True -Condition ($monitor.Measurement.TemperatureSamples -gt 0) `
        -Message "Monitor-only mode must record samples."
    Assert-True -Condition ($monitor.Measurement.TemperatureMaximumC -eq 65) `
        -Message "Monitor-only mode must preserve the measured maximum."
    Assert-True -Condition ($null -eq $monitor.Measurement.TemperatureLimitC) `
        -Message "Monitor-only mode must not create a thermal ceiling."

    $compliant = Invoke-TestTuner -Name "compliant" -AdditionalArguments @(
        "-MaxCpuTemperatureC", "80",
        "-TemperatureStableSeconds", "1",
        "-TemperatureCommand", "65"
    ) -ExpectedExitCode 0
    Assert-True -Condition ([bool] $compliant.Measurement.Succeeded) `
        -Message "A compliant candidate must be rankable."
    Assert-True -Condition (-not [bool] $compliant.Measurement.ThermallyLimited) `
        -Message "A compliant candidate must not be thermally limited."
    Assert-True -Condition ($compliant.Measurement.TemperatureLimitC -eq 80) `
        -Message "The configured ceiling must be recorded."
    Assert-True -Condition ($compliant.Measurement.CooldownWaitSeconds -ge 1) `
        -Message "The first enforced candidate must honor the stable-cool interval."

    $hotCommand = @"
if (Get-Process -Name 'xmrig-temperature-mock' -ErrorAction SilentlyContinue) {
    85
}
else {
    65
}
"@
    $limited = Invoke-TestTuner -Name "thermally-limited" -AdditionalArguments @(
        "-MaxCpuTemperatureC", "80",
        "-TemperatureStableSeconds", "0",
        "-TemperatureCommand", $hotCommand
    ) -ExpectedExitCode 1
    Assert-True -Condition (-not [bool] $limited.Measurement.Succeeded) `
        -Message "A hot candidate must not be rankable."
    Assert-True -Condition ([bool] $limited.Measurement.ThermallyLimited) `
        -Message "A hot candidate must be marked thermally limited."
    Assert-True -Condition ($limited.Measurement.ThermalLimitObservedC -eq 85) `
        -Message "The triggering temperature must be recorded."
    Assert-True -Condition (
        -not [bool](Get-Process -Name "xmrig-temperature-mock" -ErrorAction SilentlyContinue)
    ) -Message "The owned mock XMRig child must be stopped."
    Assert-True -Condition (
        Test-Path -LiteralPath (Join-Path $limited.OutputDirectory "report.md")
    ) -Message "A no-compliant-result run must still write a report."
    Assert-True -Condition (
        -not (Test-Path -LiteralPath (Join-Path $limited.OutputDirectory "recommended-settings.json"))
    ) -Message "A no-compliant-result run must not write a recommendation."

    $failingCommand = @"
if (Get-Process -Name 'xmrig-temperature-mock' -ErrorAction SilentlyContinue) {
    'not-a-temperature'
}
else {
    65
}
"@
    $sensorFailure = Invoke-TestTuner -Name "sensor-failure" -AdditionalArguments @(
        "-MaxCpuTemperatureC", "80",
        "-TemperatureStableSeconds", "0",
        "-TemperatureCommand", $failingCommand
    ) -ExpectedExitCode 1
    Assert-True -Condition ([bool] $sensorFailure.Measurement.TemperatureMonitoringFailed) `
        -Message "An enforced sensor failure must be recorded."
    Assert-True -Condition (-not [bool] $sensorFailure.Measurement.ThermallyLimited) `
        -Message "A sensor failure must remain distinct from a thermal limit."
    Assert-True -Condition (
        -not [bool](Get-Process -Name "xmrig-temperature-mock" -ErrorAction SilentlyContinue)
    ) -Message "A sensor failure must stop the owned mock child."
    Assert-True -Condition (
        Test-Path -LiteralPath (Join-Path $sensorFailure.OutputDirectory "report.md")
    ) -Message "A sensor-failure run must preserve a report."

    Write-Host "Windows Salvium tuner temperature tests passed." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $resolvedSystemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\")
        $expectedPrefix = "$resolvedSystemTemp\xmrig-tuner-temperature-tests-"
        if ($resolvedTestRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
        else {
            throw "Refusing to remove unexpected test directory '$resolvedTestRoot'."
        }
    }
}
