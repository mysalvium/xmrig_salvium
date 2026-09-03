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
    "xmrig-tuner-rigorous-tests-{0}" -f [Guid]::NewGuid().ToString("N")
)
$null = New-Item -ItemType Directory -Path $testRoot

try {
    $compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path -LiteralPath $compiler)) {
        $compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
    }
    Assert-True -Condition (Test-Path -LiteralPath $compiler) `
        -Message "The .NET Framework C# compiler is required."

    $mockPath = Join-Path $testRoot "xmrig-rigorous-mock.exe"
    & $compiler /nologo /target:exe "/out:$mockPath" $mockSourcePath
    Assert-True -Condition ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $mockPath)) `
        -Message "The mock XMRig executable must compile."

    $rigorousOutput = Join-Path $testRoot "rigorous"
    $rigorousArguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $tunerPath,
        "-XmrigPath", $mockPath,
        "-Preset", "Rigorous",
        "-ScreeningRepeats", "1",
        "-FinalConfirmationRuns", "2",
        "-MaximumSurvivors", "2",
        "-ReferenceInterval", "3",
        "-CandidateOrderSeed", "8675309",
        "-IgnoreAdjacentConfig",
        "-OutputDirectory", $rigorousOutput,
        "-CooldownSeconds", "0",
        "-AllowConcurrentXmrig"
    )
    $rigorousConsole = @(& powershell.exe @rigorousArguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Rigorous mock run failed.`n$($rigorousConsole -join [Environment]::NewLine)"
    }

    $manifestPath = Join-Path $rigorousOutput "run-manifest.json"
    $measurementPath = Join-Path $rigorousOutput "measurements.json"
    $recommendationPath = Join-Path $rigorousOutput "recommended-settings.json"
    $reportPath = Join-Path $rigorousOutput "report.md"
    foreach ($path in @($manifestPath, $measurementPath, $recommendationPath, $reportPath)) {
        Assert-True -Condition (Test-Path -LiteralPath $path) `
            -Message "Rigorous mode must create '$path'."
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $parsedMeasurements = Get-Content -LiteralPath $measurementPath -Raw | ConvertFrom-Json
    [object[]] $measurements = $parsedMeasurements
    $recommendation = Get-Content -LiteralPath $recommendationPath -Raw | ConvertFrom-Json
    Assert-True -Condition ($manifest.schema_version -eq 2) `
        -Message "The resumable manifest must use schema two."
    Assert-True -Condition ($manifest.preset -eq "Rigorous") `
        -Message "The manifest must preserve the rigorous preset."
    Assert-True -Condition ($manifest.experiment.candidate_order_seed -eq 8675309) `
        -Message "The manifest must preserve the deterministic order seed."
    Assert-True -Condition (
        $null -eq $manifest.temperature.PSObject.Properties["command"]
    ) -Message "The manifest must never persist executable temperature-command text."
    Assert-True -Condition (
        @($measurements | Where-Object Stage -like "rigorous-reference-*").Count -ge 2
    ) -Message "Rigorous mode must insert reference anchors."
    Assert-True -Condition (
        @($measurements | Where-Object Stage -like "rigorous-affinity-r*").Count -gt 1
    ) -Message "Rigorous mode must screen multiple affinities."
    Assert-True -Condition (
        @($measurements | Where-Object Stage -eq "rigorous-prefetch").Count -gt 1
    ) -Message "Rigorous mode must refine prefetch settings."
    Assert-True -Condition (
        @($measurements | Where-Object Stage -eq "rigorous-interaction").Count -gt 1
    ) -Message "Rigorous mode must test setting interactions."
    Assert-True -Condition (
        @($measurements | Where-Object Stage -like "rigorous-final-r*").Count -eq 4
    ) -Message "Two finalists must receive two final confirmations each."
    Assert-True -Condition (
        @($measurements | Where-Object { -not $_.BenchmarkValidated }).Count -eq 0
    ) -Message "Valid mock benchmarks must pass contract checks."
    Assert-True -Condition (
        @($measurements | Where-Object SustainedHashrateSamples -ne 1).Count -eq 0
    ) -Message "The XMRig 60-second trace must be parsed for every mock benchmark."
    Assert-True -Condition (
        @($measurements | Select-Object -ExpandProperty BenchmarkSize -Unique).Count -eq 4
    ) -Message "The default Rigorous run must exercise all four stage sizes."
    Assert-True -Condition (
        @(
            $measurements |
                Group-Object BenchmarkSize |
                Where-Object {
                    @($_.Group | Select-Object -ExpandProperty HashSum -Unique).Count -ne 1
                }
        ).Count -eq 0
    ) -Message "Hash-sum consistency must be enforced within, not across, benchmark sizes."
    Assert-True -Condition ($recommendation.measurement.samples -eq 2) `
        -Message "The recommendation must use only repeated finalist measurements."
    Assert-True -Condition ($recommendation.measurement.coefficient_of_variation_percent -eq 0) `
        -Message "Identical finalist measurements must report zero variation."
    Assert-True -Condition ($recommendation.experiment.candidate_order_seed -eq 8675309) `
        -Message "The recommendation must preserve experimental provenance."
    Assert-True -Condition (
        (Get-Content -LiteralPath $reportPath -Raw) -match "practically tied"
    ) -Message "The report must identify statistically indistinguishable leaders."

    $measurementCountBeforeResume = $measurements.Count
    $resumeArguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $tunerPath,
        "-XmrigPath", $mockPath,
        "-ResumeDirectory", $rigorousOutput,
        "-IgnoreAdjacentConfig",
        "-AllowConcurrentXmrig"
    )
    $resumeConsole = @(& powershell.exe @resumeArguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Rigorous resume failed.`n$($resumeConsole -join [Environment]::NewLine)"
    }
    $parsedMeasurementsAfterResume = Get-Content -LiteralPath $measurementPath -Raw |
        ConvertFrom-Json
    [object[]] $measurementsAfterResume = $parsedMeasurementsAfterResume
    Assert-True -Condition ($measurementsAfterResume.Count -eq $measurementCountBeforeResume) `
        -Message "Resume must reuse completed stage measurements instead of repeating them."

    $temperatureCommandMarker = Join-Path $testRoot "resume-command-executed"
    $escapedMarker = $temperatureCommandMarker.Replace("'", "''")
    $mismatchedTemperatureArguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $tunerPath,
        "-XmrigPath", $mockPath,
        "-ResumeDirectory", $rigorousOutput,
        "-IgnoreAdjacentConfig",
        "-AllowConcurrentXmrig",
        "-TemperatureCommand", "Set-Content -LiteralPath '$escapedMarker' -Value executed; 65"
    )
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $null = @(& powershell.exe @mismatchedTemperatureArguments 2>&1)
        $temperatureMismatchExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    Assert-True -Condition ($temperatureMismatchExitCode -eq 1) `
        -Message "Resume must reject temperature options that differ from its manifest."
    Assert-True -Condition (-not (Test-Path -LiteralPath $temperatureCommandMarker)) `
        -Message "Resume must reject, not execute, temperature command text absent from its manifest."

    $invalidOutput = Join-Path $testRoot "invalid-contract"
    $env:XMRIG_TUNER_MOCK_MODE = "wrong-threads"
    try {
        $invalidArguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $tunerPath,
            "-XmrigPath", $mockPath,
            "-SmokeTest",
            "-IgnoreAdjacentConfig",
            "-OutputDirectory", $invalidOutput,
            "-CooldownSeconds", "0",
            "-AllowConcurrentXmrig"
        )
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $null = @(& powershell.exe @invalidArguments 2>&1)
            $invalidExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorAction
        }
        Assert-True -Condition ($invalidExitCode -eq 1) `
            -Message "A thread-count contract mismatch must fail the smoke test."
    }
    finally {
        Remove-Item Env:XMRIG_TUNER_MOCK_MODE -ErrorAction SilentlyContinue
    }
    $invalidMeasurement = Get-Content `
        -LiteralPath (Join-Path $invalidOutput "measurements.json") -Raw |
        ConvertFrom-Json
    Assert-True -Condition (-not [bool] $invalidMeasurement.BenchmarkValidated) `
        -Message "The invalid measurement must record failed contract validation."
    Assert-True -Condition (
        [string] $invalidMeasurement.ValidationFailures -match "workers"
    ) -Message "The invalid measurement must explain its worker-count mismatch."

    Write-Host "Windows Salvium tuner rigorous-workflow tests passed." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $resolvedSystemTemp = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::GetTempPath()
        ).TrimEnd("\")
        $expectedPrefix = "$resolvedSystemTemp\xmrig-tuner-rigorous-tests-"
        if ($resolvedTestRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
        else {
            throw "Refusing to remove unexpected test directory '$resolvedTestRoot'."
        }
    }
}
