#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd -P)"
TUNER_PATH="$REPOSITORY_ROOT/scripts/tune-salvium-randomx.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xmrig-tuner-temperature-tests.XXXXXX")"
MOCK_PATH="$TEST_ROOT/xmrig-temperature-mock"

cleanup() {
    if [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]]; then
        case "$TEST_ROOT" in
            "${TMPDIR:-/tmp}"/xmrig-tuner-temperature-tests.*)
                rm -rf -- "$TEST_ROOT"
                ;;
            *)
                printf 'Refusing to remove unexpected test directory %s\n' "$TEST_ROOT" >&2
                return 1
                ;;
        esac
    fi
}
trap cleanup EXIT

assert_file_contains() {
    local path="$1"
    local pattern="$2"
    local message="$3"
    grep -Fq -- "$pattern" "$path" || {
        printf 'Assertion failed: %s\n' "$message" >&2
        exit 1
    }
}

cp -- "$SCRIPT_DIRECTORY/tuner_mock_xmrig.sh" "$MOCK_PATH"
chmod +x -- "$MOCK_PATH"

common_arguments=(
    --xmrig "$MOCK_PATH"
    --smoke-test
    --ignore-adjacent-config
    --cooldown-seconds 0
    --allow-concurrent-xmrig
)

disabled_output="$TEST_ROOT/disabled"
"$TUNER_PATH" "${common_arguments[@]}" --output-directory "$disabled_output" >/dev/null
[[ ! -e "$disabled_output/001-smoke-performance-cores-p1-ytrue-jfalse.temperature.csv" ]] ||
    { printf 'Assertion failed: disabled mode created a temperature log.\n' >&2; exit 1; }
assert_file_contains "$disabled_output/report.md" "CPU temperature: disabled" \
    "The disabled report must identify its temperature mode."
assert_file_contains "$disabled_output/recommended-settings.json" '"mode": "disabled"' \
    "The disabled recommendation must preserve the temperature mode."

hwmon_root="$TEST_ROOT/hwmon"
mkdir -p -- "$hwmon_root/hwmon0"
printf 'coretemp\n' >"$hwmon_root/hwmon0/name"
printf 'Package id 0\n' >"$hwmon_root/hwmon0/temp1_label"
printf '65000\n' >"$hwmon_root/hwmon0/temp1_input"

monitor_output="$TEST_ROOT/monitor-only"
"$TUNER_PATH" "${common_arguments[@]}" \
    --output-directory "$monitor_output" \
    --monitor-cpu-temperature \
    --hwmon-root "$hwmon_root" >/dev/null
assert_file_contains "$monitor_output/measurements.csv" '"65.000"' \
    "Monitor-only mode must record the auto-detected package temperature."
assert_file_contains "$monitor_output/recommended-settings.json" '"mode": "monitor-only"' \
    "Monitor-only mode must not become an enforced ceiling."
assert_file_contains "$monitor_output/report.md" "coretemp Package id 0" \
    "The report must identify the selected sensor."

compliant_output="$TEST_ROOT/compliant"
"$TUNER_PATH" "${common_arguments[@]}" \
    --output-directory "$compliant_output" \
    --max-cpu-temperature 80 \
    --temperature-stable-seconds 1 \
    --temperature-command "printf 65" >/dev/null
assert_file_contains "$compliant_output/measurements.csv" '"true","false","143"' \
    "A completed compliant benchmark must remain successful after its owned child is stopped."
assert_file_contains "$compliant_output/recommended-settings.json" '"mode": "enforced-maximum"' \
    "The compliant recommendation must record enforced mode."
assert_file_contains "$compliant_output/recommended-settings.json" '"maximum_limit_c": 80' \
    "The compliant recommendation must record the ceiling."
assert_file_contains "$compliant_output/measurements.csv" '"1","65.000"' \
    "The first enforced candidate must honor the stable-cool interval."

limited_output="$TEST_ROOT/thermally-limited"
marker_path="$TEST_ROOT/mock-running"
export XMRIG_TUNER_MOCK_MARKER="$marker_path"
if "$TUNER_PATH" "${common_arguments[@]}" \
    --output-directory "$limited_output" \
    --max-cpu-temperature 80 \
    --temperature-stable-seconds 0 \
    --temperature-command "if [[ -e '$marker_path' ]]; then printf 85; else printf 65; fi" \
    >/dev/null 2>&1; then
    printf 'Assertion failed: a thermally limited run unexpectedly succeeded.\n' >&2
    exit 1
fi
[[ ! -e "$marker_path" ]] ||
    { printf 'Assertion failed: the owned mock child was not cleaned up.\n' >&2; exit 1; }
assert_file_contains "$limited_output/measurements.csv" '"true","80","85.000"' \
    "The thermally limited measurement must record the ceiling and trigger."
assert_file_contains "$limited_output/report.md" "No successful temperature-compliant benchmark result" \
    "A no-compliant-result run must still explain its outcome."
[[ ! -e "$limited_output/recommended-settings.json" ]] ||
    { printf 'Assertion failed: a thermally limited run wrote a recommendation.\n' >&2; exit 1; }

sensor_failure_output="$TEST_ROOT/sensor-failure"
if "$TUNER_PATH" "${common_arguments[@]}" \
    --output-directory "$sensor_failure_output" \
    --max-cpu-temperature 80 \
    --temperature-stable-seconds 0 \
    --temperature-command "if [[ -e '$marker_path' ]]; then printf invalid; else printf 65; fi" \
    >/dev/null 2>&1; then
    printf 'Assertion failed: an enforced sensor failure unexpectedly succeeded.\n' >&2
    exit 1
fi
[[ ! -e "$marker_path" ]] ||
    { printf 'Assertion failed: sensor failure did not clean up the owned child.\n' >&2; exit 1; }
assert_file_contains "$sensor_failure_output/measurements.csv" \
    '"true","the CPU temperature source failed during the benchmark"' \
    "An enforced sensor failure must be recorded distinctly."
assert_file_contains "$sensor_failure_output/report.md" \
    "CPU temperature enforcement stopped because the selected sensor failed" \
    "A sensor-failure run must preserve an explanatory report."

printf 'Linux Salvium tuner temperature tests passed.\n'
