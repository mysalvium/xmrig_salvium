#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_NAME="$(basename "$0")"

XMRIG_PATH=""
BASELINE_CONFIG_PATH=""
IGNORE_ADJACENT_CONFIG=false
PRESET="standard"
BENCHMARK_SIZE="AUTO"
CPU_PRIORITY=2
COOLDOWN_SECONDS=10
TIMEOUT_SECONDS=1800
OUTPUT_DIRECTORY=""
MANUAL_PERFORMANCE_CPUS=""
MANUAL_EFFICIENT_CPUS=""
ALLOWED_CPUS_OVERRIDE=""
INCLUDE_SMT=false
PLAN_ONLY=false
SMOKE_TEST=false
ALLOW_CONCURRENT_XMRIG=false
SYSFS_CPU_ROOT="/sys/devices/system/cpu"
HWMON_ROOT="/sys/class/hwmon"

MONITOR_CPU_TEMPERATURE=false
MAX_CPU_TEMPERATURE_C=""
TEMPERATURE_SENSOR_PATH=""
TEMPERATURE_COMMAND=""
TEMPERATURE_SAMPLE_SECONDS=1
TEMPERATURE_COOLDOWN_MARGIN_C=5
TEMPERATURE_STABLE_SECONDS=20
TEMPERATURE_COOLDOWN_TIMEOUT_SECONDS=1800
TEMPERATURE_ENABLED=false
TEMPERATURE_ENFORCED=false
TEMPERATURE_PROVIDER_KIND="none"
TEMPERATURE_PROVIDER_NAME=""
TEMPERATURE_PROVIDER_PATH=""
TEMPERATURE_RESUME_BELOW_C=""
HAS_RUN_CANDIDATE=false
LAST_COOLDOWN_WAIT_SECONDS=0
LAST_READY_TEMPERATURE_C=""

BASELINE_IMPORTED=false
BASELINE_AFFINITY=""
BASE_HUGE_PAGES="true"
BASE_HUGE_PAGES_JIT="false"
BASE_MEMORY_POOL="true"
BASE_YIELD="true"
BASE_ASSEMBLY="true"
BASE_HW_AES="null"
BASE_RANDOMX_INIT="-1"
BASE_RANDOMX_INIT_AVX2="-1"
BASE_RANDOMX_MODE='"auto"'
BASE_RANDOMX_NUMA="true"
BASE_ONE_GB_PAGES="false"
BASE_PREFETCH_MODE=1

CPU_MODEL="unknown"
CPU_VENDOR="unknown"
CLASSIFICATION_METHOD="homogeneous topology"
L3_CACHE_KB=0
MAX_RANDOMX_THREADS=0

declare -a ALLOWED_CPUS=()
declare -a CORE_KEYS=()
declare -a PERFORMANCE_PRIMARY=()
declare -a PERFORMANCE_ALL=()
declare -a EFFICIENT_PRIMARY=()

declare -A ONLINE_CPU_SET=()
declare -A ALLOWED_CPU_SET=()
declare -A CPU_CORE_KEY=()
declare -A CORE_PRIMARY=()
declare -A CORE_ALLOWED_CPUS=()
declare -A CORE_GLOBAL_THREADS=()
declare -A CORE_TYPE_VALUE=()
declare -A CORE_CAPACITY_VALUE=()
declare -A CORE_MAX_FREQUENCY=()

declare -a PROFILE_NAMES=()
declare -a PROFILE_AFFINITIES=()
declare -a PROFILE_THREADS=()
declare -a PROFILE_REASONS=()
declare -A PROFILE_AFFINITY_KEYS=()

declare -A MEASURED_KEYS=()
RUN_SEQUENCE=0
RUN_DATA_FILE=""
RESULTS_DIRECTORY=""
RANKING_FILE=""
CURRENT_TEMP_CONFIG=""
CURRENT_XMRIG_PID=""

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME --xmrig PATH [options]

Required:
  --xmrig PATH                 XMRig executable to benchmark.

Configuration:
  --baseline-config PATH       Import safe CPU/RandomX tuning fields.
  --ignore-adjacent-config     Do not inspect config.json beside XMRig.
  --preset NAME                quick, standard, or thorough (default: standard).
  --benchmark-size SIZE        auto, 250K, 500K, or 1M through 10M.
  --cpu-priority N             XMRig CPU priority 0-5 (default: 2).
  --cooldown-seconds N         Pause between runs, 0-60 (default: 10).
  --timeout-seconds N          Per-run timeout, 30-7200 (default: 1800).
  --output-directory PATH      Result directory.

Temperature:
  --monitor-cpu-temperature    Record/display temperature without ranking changes.
  --max-cpu-temperature C      Stop and disqualify candidates at this ceiling.
  --temperature-sensor PATH    Explicit Linux hwmon temp*_input sensor.
  --temperature-command CMD    Command that prints one Celsius value.
  --temperature-sample-seconds N
                               Sampling interval, 1-60 (default: 1).
  --temperature-cooldown-margin C
                               Resume below maximum minus C (default: 5).
  --temperature-stable-seconds N
                               Required cool/stable interval, 0-300 (default: 20).
  --temperature-cooldown-timeout-seconds N
                               Maximum cooldown wait, 30-7200 (default: 1800).
  --hwmon-root PATH            Alternate hwmon root for containers/tests.

Topology:
  --performance-cpus LIST      Manual primary performance CPU list.
  --efficient-cpus LIST        Manual primary efficient CPU list.
  --allowed-cpus LIST          Restrict discovery to this Linux CPU list.
  --include-smt                Add all P-core/physical-core SMT threads.
  --sysfs-cpu-root PATH        Alternate CPU sysfs root for containers/tests.

Modes:
  --plan-only                  Detect topology and show the test plan only.
  --smoke-test                Run one 250K baseline/physical-core benchmark.
  --allow-concurrent-xmrig     Allow a knowingly confounded concurrent run.
  -h, --help                   Show this help.

CPU lists use Linux syntax such as 0-7,16,18.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

require_uint_range() {
    local name="$1"
    local value="$2"
    local minimum="$3"
    local maximum="$4"

    is_uint "$value" || fail "$name must be an integer."
    (( value >= minimum && value <= maximum )) ||
        fail "$name must be between $minimum and $maximum."
}

is_number() {
    [[ "${1:-}" =~ ^-?([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

require_number_range() {
    local name="$1"
    local value="$2"
    local minimum="$3"
    local maximum="$4"

    is_number "$value" || fail "$name must be numeric."
    awk -v value="$value" -v minimum="$minimum" -v maximum="$maximum" \
        'BEGIN {exit !(value >= minimum && value <= maximum)}' ||
        fail "$name must be between $minimum and $maximum."
}

number_is_less_than() {
    awk -v left="$1" -v right="$2" 'BEGIN {exit !(left < right)}'
}

number_is_less_than_or_equal() {
    awk -v left="$1" -v right="$2" 'BEGIN {exit !(left <= right)}'
}

number_is_greater_than_or_equal() {
    awk -v left="$1" -v right="$2" 'BEGIN {exit !(left >= right)}'
}

expand_cpu_list() {
    local specification="${1//[[:space:]]/}"
    local -a segments=()
    local segment start end cpu

    [[ -n "$specification" ]] || return 0
    IFS=',' read -r -a segments <<<"$specification"

    for segment in "${segments[@]}"; do
        if [[ "$segment" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            (( start <= end )) || fail "Invalid descending CPU range '$segment'."
            for ((cpu = start; cpu <= end; cpu++)); do
                printf '%s\n' "$cpu"
            done
        elif [[ "$segment" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$segment"
        else
            fail "Invalid Linux CPU list segment '$segment'."
        fi
    done
}

normalize_cpu_list() {
    local specification="$1"
    local -a values=()

    mapfile -t values < <(expand_cpu_list "$specification" | sort -n -u)
    if ((${#values[@]} == 0)); then
        printf ''
        return 0
    fi

    local joined
    printf -v joined '%s,' "${values[@]}"
    printf '%s' "${joined%,}"
}

array_to_cpu_list() {
    local -a values=("$@")
    local joined

    if ((${#values[@]} == 0)); then
        printf ''
        return 0
    fi

    printf -v joined '%s,' "${values[@]}"
    printf '%s' "${joined%,}"
}

cpu_list_count() {
    local specification="$1"
    local -a values=()
    mapfile -t values < <(expand_cpu_list "$specification")
    printf '%s' "${#values[@]}"
}

read_first_line() {
    local path="$1"
    local fallback="${2:-}"

    if [[ -r "$path" ]]; then
        IFS= read -r REPLY <"$path" || true
        printf '%s' "${REPLY:-$fallback}"
    else
        printf '%s' "$fallback"
    fi
}

parse_cache_size_kb() {
    local value="${1^^}"
    value="${value//[[:space:]]/}"

    if [[ "$value" =~ ^([0-9]+)K(B)?$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^([0-9]+)M(B)?$ ]]; then
        printf '%s' "$((BASH_REMATCH[1] * 1024))"
    elif [[ "$value" =~ ^([0-9]+)G(B)?$ ]]; then
        printf '%s' "$((BASH_REMATCH[1] * 1024 * 1024))"
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '0'
    fi
}

process_is_running() {
    local pid="$1"
    local stat state

    [[ -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat <"/proc/$pid/stat" || return 1
    stat="${stat##*) }"
    state="${stat%% *}"

    [[ "$state" != "Z" && "$state" != "X" ]]
}

terminate_xmrig_child() {
    local pid="$1"
    local attempt

    [[ -n "$pid" ]] || return 0
    if process_is_running "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
        for ((attempt = 0; attempt < 50; attempt++)); do
            process_is_running "$pid" || return 0
            sleep 0.1
        done

        kill -KILL "$pid" 2>/dev/null || true
    fi
}

normalize_temperature_reading() {
    local raw="$1"
    local source="$2"
    local normalized

    is_number "$raw" || {
        warn "Temperature source '$source' returned non-numeric output '$raw'."
        return 1
    }

    normalized="$(awk -v value="$raw" '
        BEGIN {
            if (value > 1000 || value < -1000) {
                value /= 1000.0
            }
            if (value < -20 || value > 150) {
                exit 1
            }
            printf "%.3f", value
        }
    ')" || {
        warn "Temperature source '$source' returned implausible value '$raw'."
        return 1
    }
    printf '%s' "$normalized"
}

read_cpu_temperature() {
    local raw output
    case "$TEMPERATURE_PROVIDER_KIND" in
        command)
            output="$(bash -c "$TEMPERATURE_COMMAND")" || {
                warn "Temperature command exited unsuccessfully."
                return 1
            }
            output="${output#"${output%%[![:space:]]*}"}"
            output="${output%"${output##*[![:space:]]}"}"
            [[ "$output" != *$'\n'* ]] || {
                warn "Temperature command returned more than one line."
                return 1
            }
            normalize_temperature_reading "$output" "$TEMPERATURE_PROVIDER_NAME"
            ;;
        sysfs)
            [[ -r "$TEMPERATURE_PROVIDER_PATH" ]] || {
                warn "Temperature sensor '$TEMPERATURE_PROVIDER_PATH' is no longer readable."
                return 1
            }
            IFS= read -r raw <"$TEMPERATURE_PROVIDER_PATH" || {
                warn "Temperature sensor '$TEMPERATURE_PROVIDER_PATH' could not be read."
                return 1
            }
            normalize_temperature_reading "$raw" "$TEMPERATURE_PROVIDER_NAME"
            ;;
        *)
            warn "CPU temperature provider is not configured."
            return 1
            ;;
    esac
}

discover_temperature_provider() {
    local hwmon chip input label_path label score best_score=-1 best_path="" best_name=""

    if [[ -n "$TEMPERATURE_COMMAND" ]]; then
        TEMPERATURE_PROVIDER_KIND="command"
        TEMPERATURE_PROVIDER_NAME="temperature command"
        read_cpu_temperature >/dev/null ||
            fail "The configured temperature command did not return one plausible Celsius value."
        return 0
    fi

    if [[ -n "$TEMPERATURE_SENSOR_PATH" ]]; then
        [[ -r "$TEMPERATURE_SENSOR_PATH" ]] ||
            fail "Temperature sensor '$TEMPERATURE_SENSOR_PATH' is not readable."
        TEMPERATURE_PROVIDER_KIND="sysfs"
        TEMPERATURE_PROVIDER_PATH="$(readlink -f -- "$TEMPERATURE_SENSOR_PATH" 2>/dev/null || printf '%s' "$TEMPERATURE_SENSOR_PATH")"
        TEMPERATURE_PROVIDER_NAME="$TEMPERATURE_PROVIDER_PATH"
        read_cpu_temperature >/dev/null ||
            fail "Temperature sensor '$TEMPERATURE_PROVIDER_PATH' did not return a plausible value."
        return 0
    fi

    for hwmon in "$HWMON_ROOT"/hwmon*; do
        [[ -d "$hwmon" && -r "$hwmon/name" ]] || continue
        IFS= read -r chip <"$hwmon/name" || continue
        case "${chip,,}" in
            coretemp|k10temp|zenpower) ;;
            *) continue ;;
        esac

        for input in "$hwmon"/temp*_input; do
            [[ -r "$input" ]] || continue
            label_path="${input%_input}_label"
            label=""
            [[ -r "$label_path" ]] && IFS= read -r label <"$label_path" || true
            score=10
            case "${label,,}" in
                *"package id"*|*"cpu package"*|package) score=100 ;;
                *"core max"*) score=95 ;;
                *"tctl/tdie"*|*"tctl and tdie"*) score=90 ;;
                *"tdie"*) score=85 ;;
                *"tctl"*) score=80 ;;
                *"cpu"*) score=70 ;;
                *"core"*) score=40 ;;
            esac
            if ((score > best_score)); then
                best_score="$score"
                best_path="$input"
                best_name="$chip${label:+ $label} ($input)"
            fi
        done
    done

    [[ -n "$best_path" ]] ||
        fail "CPU temperature monitoring was requested, but no coretemp, k10temp, or zenpower hwmon sensor was found under '$HWMON_ROOT'. Specify --temperature-sensor or --temperature-command."

    TEMPERATURE_PROVIDER_KIND="sysfs"
    TEMPERATURE_PROVIDER_PATH="$(readlink -f -- "$best_path" 2>/dev/null || printf '%s' "$best_path")"
    TEMPERATURE_PROVIDER_NAME="$best_name"
    read_cpu_temperature >/dev/null ||
        fail "Auto-detected temperature sensor '$TEMPERATURE_PROVIDER_PATH' did not return a plausible value."
}

temperature_statistics() {
    local path="$1"
    awk -F',' '
        NR > 1 && $2 != "" {
            values[++count] = $2 + 0
            sum += $2
            if (count == 1 || $2 > maximum) maximum = $2
        }
        END {
            if (count == 0) {
                printf "0\t\t\t\t\t"
                exit
            }
            for (i = 1; i <= count; i++) {
                for (j = i + 1; j <= count; j++) {
                    if (values[j] < values[i]) {
                        temporary = values[i]
                        values[i] = values[j]
                        values[j] = temporary
                    }
                }
            }
            p95_index = int(count * 0.95)
            if (p95_index < count * 0.95) p95_index++
            if (p95_index < 1) p95_index = 1
            printf "%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f", count, values[1], sum / count, values[p95_index], maximum, values[count]
        }
    ' "$path"
}

wait_for_temperature_ready() {
    local minimum_wait_seconds="$1"
    local started_at="$SECONDS"
    local minimum_ready_at=$((started_at + minimum_wait_seconds))
    local deadline=$((started_at + TEMPERATURE_COOLDOWN_TIMEOUT_SECONDS))
    local stable_since=-1
    local last_display=-1000
    local temperature

    LAST_COOLDOWN_WAIT_SECONDS=0
    LAST_READY_TEMPERATURE_C=""
    [[ "$TEMPERATURE_ENFORCED" == true ]] || return 0

    while true; do
        if ! temperature="$(read_cpu_temperature)"; then
            write_partial_tuning_outputs "CPU temperature enforcement stopped because the sensor failed during cooldown."
            fail "CPU temperature enforcement stopped because the sensor failed during cooldown."
        fi

        if number_is_less_than_or_equal "$temperature" "$TEMPERATURE_RESUME_BELOW_C"; then
            ((stable_since < 0)) && stable_since="$SECONDS"
        else
            stable_since=-1
        fi

        if ((SECONDS >= minimum_ready_at)) &&
            { ((TEMPERATURE_STABLE_SECONDS == 0)) ||
              ((stable_since >= 0 && SECONDS - stable_since >= TEMPERATURE_STABLE_SECONDS)); }; then
            LAST_COOLDOWN_WAIT_SECONDS=$((SECONDS - started_at))
            LAST_READY_TEMPERATURE_C="$temperature"
            return 0
        fi

        if ((SECONDS >= deadline)); then
            write_partial_tuning_outputs "CPU temperature did not reach a stable cooldown condition within $TEMPERATURE_COOLDOWN_TIMEOUT_SECONDS seconds; last reading was $temperature C."
            fail "CPU temperature did not remain at or below $TEMPERATURE_RESUME_BELOW_C C within $TEMPERATURE_COOLDOWN_TIMEOUT_SECONDS seconds; last reading was $temperature C."
        fi

        if ((SECONDS - last_display >= 10)); then
            printf '      cooling: %.1f C; waiting for <= %.1f C for %s seconds\n' \
                "$temperature" "$TEMPERATURE_RESUME_BELOW_C" "$TEMPERATURE_STABLE_SECONDS"
            last_display="$SECONDS"
        fi
        sleep "$TEMPERATURE_SAMPLE_SECONDS"
    done
}

cleanup() {
    if [[ -n "${CURRENT_XMRIG_PID:-}" ]]; then
        terminate_xmrig_child "$CURRENT_XMRIG_PID"
        wait "$CURRENT_XMRIG_PID" 2>/dev/null || true
        CURRENT_XMRIG_PID=""
    fi

    if [[ -n "${CURRENT_TEMP_CONFIG:-}" && -f "$CURRENT_TEMP_CONFIG" ]]; then
        rm -f -- "$CURRENT_TEMP_CONFIG"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while (($# > 0)); do
    case "$1" in
        --xmrig)
            (($# >= 2)) || fail "--xmrig requires a path."
            XMRIG_PATH="$2"
            shift 2
            ;;
        --baseline-config)
            (($# >= 2)) || fail "--baseline-config requires a path."
            BASELINE_CONFIG_PATH="$2"
            shift 2
            ;;
        --ignore-adjacent-config)
            IGNORE_ADJACENT_CONFIG=true
            shift
            ;;
        --preset)
            (($# >= 2)) || fail "--preset requires a value."
            PRESET="${2,,}"
            shift 2
            ;;
        --benchmark-size)
            (($# >= 2)) || fail "--benchmark-size requires a value."
            BENCHMARK_SIZE="${2^^}"
            shift 2
            ;;
        --cpu-priority)
            (($# >= 2)) || fail "--cpu-priority requires a value."
            CPU_PRIORITY="$2"
            shift 2
            ;;
        --cooldown-seconds)
            (($# >= 2)) || fail "--cooldown-seconds requires a value."
            COOLDOWN_SECONDS="$2"
            shift 2
            ;;
        --timeout-seconds)
            (($# >= 2)) || fail "--timeout-seconds requires a value."
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --output-directory)
            (($# >= 2)) || fail "--output-directory requires a path."
            OUTPUT_DIRECTORY="$2"
            shift 2
            ;;
        --monitor-cpu-temperature)
            MONITOR_CPU_TEMPERATURE=true
            shift
            ;;
        --max-cpu-temperature)
            (($# >= 2)) || fail "--max-cpu-temperature requires a Celsius value."
            MAX_CPU_TEMPERATURE_C="$2"
            shift 2
            ;;
        --temperature-sensor)
            (($# >= 2)) || fail "--temperature-sensor requires a path."
            TEMPERATURE_SENSOR_PATH="$2"
            shift 2
            ;;
        --temperature-command)
            (($# >= 2)) || fail "--temperature-command requires a command."
            TEMPERATURE_COMMAND="$2"
            shift 2
            ;;
        --temperature-sample-seconds)
            (($# >= 2)) || fail "--temperature-sample-seconds requires a value."
            TEMPERATURE_SAMPLE_SECONDS="$2"
            shift 2
            ;;
        --temperature-cooldown-margin)
            (($# >= 2)) || fail "--temperature-cooldown-margin requires a Celsius value."
            TEMPERATURE_COOLDOWN_MARGIN_C="$2"
            shift 2
            ;;
        --temperature-stable-seconds)
            (($# >= 2)) || fail "--temperature-stable-seconds requires a value."
            TEMPERATURE_STABLE_SECONDS="$2"
            shift 2
            ;;
        --temperature-cooldown-timeout-seconds)
            (($# >= 2)) || fail "--temperature-cooldown-timeout-seconds requires a value."
            TEMPERATURE_COOLDOWN_TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --hwmon-root)
            (($# >= 2)) || fail "--hwmon-root requires a path."
            HWMON_ROOT="${2%/}"
            shift 2
            ;;
        --performance-cpus)
            (($# >= 2)) || fail "--performance-cpus requires a CPU list."
            MANUAL_PERFORMANCE_CPUS="$2"
            shift 2
            ;;
        --efficient-cpus)
            (($# >= 2)) || fail "--efficient-cpus requires a CPU list."
            MANUAL_EFFICIENT_CPUS="$2"
            shift 2
            ;;
        --allowed-cpus)
            (($# >= 2)) || fail "--allowed-cpus requires a CPU list."
            ALLOWED_CPUS_OVERRIDE="$2"
            shift 2
            ;;
        --include-smt)
            INCLUDE_SMT=true
            shift
            ;;
        --sysfs-cpu-root)
            (($# >= 2)) || fail "--sysfs-cpu-root requires a path."
            SYSFS_CPU_ROOT="${2%/}"
            shift 2
            ;;
        --plan-only)
            PLAN_ONLY=true
            shift
            ;;
        --smoke-test)
            SMOKE_TEST=true
            shift
            ;;
        --allow-concurrent-xmrig)
            ALLOW_CONCURRENT_XMRIG=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument '$1'. Use --help for usage."
            ;;
    esac
done

((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) ||
    fail "Bash 4.4 or newer is required."
[[ "$(uname -s)" == "Linux" ]] || fail "This tuner requires Linux."
[[ -n "$XMRIG_PATH" ]] || fail "--xmrig is required."
command -v awk >/dev/null 2>&1 || fail "awk is required."
command -v grep >/dev/null 2>&1 || fail "grep is required."
command -v sed >/dev/null 2>&1 || fail "sed is required."
command -v sort >/dev/null 2>&1 || fail "sort is required."

case "$PRESET" in
    quick|standard|thorough) ;;
    *) fail "--preset must be quick, standard, or thorough." ;;
esac

case "$BENCHMARK_SIZE" in
    AUTO|250K|500K|1M|2M|3M|4M|5M|6M|7M|8M|9M|10M) ;;
    *) fail "Unsupported benchmark size '$BENCHMARK_SIZE'." ;;
esac

require_uint_range "--cpu-priority" "$CPU_PRIORITY" 0 5
require_uint_range "--cooldown-seconds" "$COOLDOWN_SECONDS" 0 60
require_uint_range "--timeout-seconds" "$TIMEOUT_SECONDS" 30 7200
require_uint_range "--temperature-sample-seconds" "$TEMPERATURE_SAMPLE_SECONDS" 1 60
require_number_range "--temperature-cooldown-margin" "$TEMPERATURE_COOLDOWN_MARGIN_C" 0 30
require_uint_range "--temperature-stable-seconds" "$TEMPERATURE_STABLE_SECONDS" 0 300
require_uint_range "--temperature-cooldown-timeout-seconds" "$TEMPERATURE_COOLDOWN_TIMEOUT_SECONDS" 30 7200

if [[ -n "$TEMPERATURE_SENSOR_PATH" && -n "$TEMPERATURE_COMMAND" ]]; then
    fail "--temperature-sensor and --temperature-command are mutually exclusive."
fi
if [[ -n "$MAX_CPU_TEMPERATURE_C" ]]; then
    require_number_range "--max-cpu-temperature" "$MAX_CPU_TEMPERATURE_C" 1 125
    number_is_less_than "$TEMPERATURE_COOLDOWN_MARGIN_C" "$MAX_CPU_TEMPERATURE_C" ||
        fail "--temperature-cooldown-margin must be lower than --max-cpu-temperature."
    TEMPERATURE_ENFORCED=true
    TEMPERATURE_ENABLED=true
    TEMPERATURE_RESUME_BELOW_C="$(awk -v limit="$MAX_CPU_TEMPERATURE_C" -v margin="$TEMPERATURE_COOLDOWN_MARGIN_C" 'BEGIN {printf "%.3f", limit - margin}')"
fi
if [[ "$MONITOR_CPU_TEMPERATURE" == true || -n "$TEMPERATURE_SENSOR_PATH" || -n "$TEMPERATURE_COMMAND" ]]; then
    TEMPERATURE_ENABLED=true
fi

[[ -d "$SYSFS_CPU_ROOT" ]] || fail "CPU sysfs root '$SYSFS_CPU_ROOT' does not exist."

if command -v readlink >/dev/null 2>&1; then
    XMRIG_PATH="$(readlink -f -- "$XMRIG_PATH")"
fi
[[ -f "$XMRIG_PATH" ]] || fail "XMRig executable '$XMRIG_PATH' does not exist."
[[ -x "$XMRIG_PATH" ]] || fail "XMRig executable '$XMRIG_PATH' is not executable."

if [[ -z "$BASELINE_CONFIG_PATH" && "$IGNORE_ADJACENT_CONFIG" == false ]]; then
    adjacent_config="$(dirname "$XMRIG_PATH")/config.json"
    if [[ -f "$adjacent_config" ]]; then
        BASELINE_CONFIG_PATH="$adjacent_config"
    fi
fi

read_baseline_config() {
    local path="$1"
    local parsed

    [[ -f "$path" ]] || fail "Baseline config '$path' does not exist."

    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 is unavailable; the baseline config will not be imported. The generated benchmarks still contain no pool credentials."
        return 0
    fi

    if ! parsed="$(python3 - "$path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    document = json.load(stream)

cpu = document.get("cpu") if isinstance(document.get("cpu"), dict) else {}
randomx = document.get("randomx") if isinstance(document.get("randomx"), dict) else {}

affinity = []
for name in ("rx/0", "rx", "*"):
    profile = cpu.get(name)
    if not isinstance(profile, list):
        continue
    for entry in profile:
        value = None
        if isinstance(entry, int):
            value = entry
        elif isinstance(entry, list) and len(entry) >= 2 and isinstance(entry[-1], int):
            value = entry[-1]
        if value is not None and value >= 0:
            affinity.append(value)
    if affinity:
        break

def emit(name, value):
    print(f"{name}\t{json.dumps(value, separators=(',', ':'))}")

emit("affinity", sorted(set(affinity)))
emit("huge_pages", cpu.get("huge-pages", True))
emit("huge_pages_jit", cpu.get("huge-pages-jit", False))
emit("memory_pool", cpu.get("memory-pool", True))
emit("yield", cpu.get("yield", True))
emit("assembly", cpu.get("asm", True))
emit("hw_aes", cpu.get("hw-aes"))
emit("randomx_init", randomx.get("init", -1))
emit("randomx_init_avx2", randomx.get("init-avx2", -1))
emit("randomx_mode", randomx.get("mode", "auto"))
emit("randomx_numa", randomx.get("numa", True))
emit("one_gb_pages", randomx.get("1gb-pages", False))
emit("prefetch_mode", randomx.get("scratchpad_prefetch_mode", 1))
PY
)"; then
        fail "Unable to parse baseline config '$path'."
    fi

    local key value
    while IFS=$'\t' read -r key value; do
        case "$key" in
            affinity)
                BASELINE_AFFINITY="$(tr -cd '0-9,[]' <<<"$value" | tr -d '[]')"
                BASELINE_AFFINITY="$(normalize_cpu_list "$BASELINE_AFFINITY")"
                ;;
            huge_pages) BASE_HUGE_PAGES="$value" ;;
            huge_pages_jit) BASE_HUGE_PAGES_JIT="$value" ;;
            memory_pool) BASE_MEMORY_POOL="$value" ;;
            yield) BASE_YIELD="$value" ;;
            assembly) BASE_ASSEMBLY="$value" ;;
            hw_aes) BASE_HW_AES="$value" ;;
            randomx_init) BASE_RANDOMX_INIT="$value" ;;
            randomx_init_avx2) BASE_RANDOMX_INIT_AVX2="$value" ;;
            randomx_mode) BASE_RANDOMX_MODE="$value" ;;
            randomx_numa) BASE_RANDOMX_NUMA="$value" ;;
            one_gb_pages) BASE_ONE_GB_PAGES="$value" ;;
            prefetch_mode)
                if is_uint "$value" && ((value >= 0 && value <= 3)); then
                    BASE_PREFETCH_MODE="$value"
                fi
                ;;
        esac
    done <<<"$parsed"

    BASELINE_CONFIG_PATH="$(readlink -f -- "$path" 2>/dev/null || printf '%s' "$path")"
    BASELINE_IMPORTED=true
}

if [[ -n "$BASELINE_CONFIG_PATH" ]]; then
    read_baseline_config "$BASELINE_CONFIG_PATH"
fi

discover_allowed_cpus() {
    local online_spec allowed_spec cpu cpu_path
    local -a online_values=() requested_values=()

    if [[ -r "$SYSFS_CPU_ROOT/online" ]]; then
        online_spec="$(read_first_line "$SYSFS_CPU_ROOT/online")"
        mapfile -t online_values < <(expand_cpu_list "$online_spec")
    else
        for cpu_path in "$SYSFS_CPU_ROOT"/cpu[0-9]*; do
            [[ -d "$cpu_path" ]] || continue
            cpu="${cpu_path##*cpu}"
            [[ "$cpu" =~ ^[0-9]+$ ]] && online_values+=("$cpu")
        done
    fi

    ((${#online_values[@]} > 0)) || fail "No online CPUs were found under '$SYSFS_CPU_ROOT'."
    for cpu in "${online_values[@]}"; do
        ONLINE_CPU_SET["$cpu"]=1
    done

    if [[ -n "$ALLOWED_CPUS_OVERRIDE" ]]; then
        allowed_spec="$ALLOWED_CPUS_OVERRIDE"
    elif [[ -r /proc/self/status ]]; then
        allowed_spec="$(awk -F: '/^Cpus_allowed_list:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/self/status)"
    else
        allowed_spec="$online_spec"
    fi

    mapfile -t requested_values < <(expand_cpu_list "$allowed_spec" | sort -n -u)
    for cpu in "${requested_values[@]}"; do
        if [[ -n "${ONLINE_CPU_SET[$cpu]+x}" && -d "$SYSFS_CPU_ROOT/cpu$cpu" ]]; then
            ALLOWED_CPUS+=("$cpu")
            ALLOWED_CPU_SET["$cpu"]=1
        fi
    done

    ((${#ALLOWED_CPUS[@]} > 0)) ||
        fail "The process CPU allowance does not intersect the online CPUs under '$SYSFS_CPU_ROOT'."
}

discover_allowed_cpus

CPU_VENDOR="$(awk -F: '/^vendor_id[[:space:]]*:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
CPU_MODEL="$(awk -F: '/^(model name|Hardware|Processor)[[:space:]]*:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
CPU_VENDOR="${CPU_VENDOR:-unknown}"
CPU_MODEL="${CPU_MODEL:-unknown}"

discover_core_topology() {
    local cpu topology_path package_id die_id core_id core_key siblings_spec
    local sibling_count core_type capacity maximum_frequency

    for cpu in "${ALLOWED_CPUS[@]}"; do
        topology_path="$SYSFS_CPU_ROOT/cpu$cpu/topology"
        package_id="$(read_first_line "$topology_path/physical_package_id" 0)"
        die_id="$(read_first_line "$topology_path/die_id" 0)"
        core_id="$(read_first_line "$topology_path/core_id" "$cpu")"
        core_key="$package_id:$die_id:$core_id"
        CPU_CORE_KEY["$cpu"]="$core_key"

        if [[ -z "${CORE_PRIMARY[$core_key]+x}" ]]; then
            CORE_KEYS+=("$core_key")
            CORE_PRIMARY["$core_key"]="$cpu"
            CORE_ALLOWED_CPUS["$core_key"]="$cpu"

            if [[ -r "$topology_path/core_cpus_list" ]]; then
                siblings_spec="$(read_first_line "$topology_path/core_cpus_list" "$cpu")"
            else
                siblings_spec="$(read_first_line "$topology_path/thread_siblings_list" "$cpu")"
            fi
            sibling_count="$(cpu_list_count "$siblings_spec")"
            CORE_GLOBAL_THREADS["$core_key"]="${sibling_count:-1}"

            core_type="$(read_first_line "$topology_path/core_type" "")"
            [[ "$core_type" =~ ^[0-9]+$ ]] && CORE_TYPE_VALUE["$core_key"]="$core_type"

            capacity="$(read_first_line "$SYSFS_CPU_ROOT/cpu$cpu/cpu_capacity" "")"
            [[ "$capacity" =~ ^[0-9]+$ ]] && CORE_CAPACITY_VALUE["$core_key"]="$capacity"

            maximum_frequency="$(read_first_line "$SYSFS_CPU_ROOT/cpu$cpu/cpufreq/cpuinfo_max_freq" "")"
            if [[ ! "$maximum_frequency" =~ ^[0-9]+$ ]]; then
                maximum_frequency="$(read_first_line "$SYSFS_CPU_ROOT/cpu$cpu/cpufreq/scaling_max_freq" "")"
            fi
            [[ "$maximum_frequency" =~ ^[0-9]+$ ]] && CORE_MAX_FREQUENCY["$core_key"]="$maximum_frequency"
        else
            CORE_ALLOWED_CPUS["$core_key"]+=",${cpu}"
        fi
    done

    return 0
}

discover_core_topology

validate_manual_cpu_list() {
    local label="$1"
    local specification="$2"
    local cpu
    local -a values=()

    mapfile -t values < <(expand_cpu_list "$specification" | sort -n -u)
    for cpu in "${values[@]}"; do
        [[ -n "${ALLOWED_CPU_SET[$cpu]+x}" ]] ||
            fail "$label CPU $cpu is outside the process's allowed online CPU set."
    done
}

classify_cores() {
    local manual_p_set=false manual_e_set=false
    local core_key cpu value maximum minimum
    local -a manual_p=() manual_e=() unique_values=()
    local -A performance_core_set=() efficient_core_set=()

    [[ -n "$MANUAL_PERFORMANCE_CPUS" ]] && manual_p_set=true
    [[ -n "$MANUAL_EFFICIENT_CPUS" ]] && manual_e_set=true
    [[ "$manual_p_set" == "$manual_e_set" ]] ||
        fail "--performance-cpus and --efficient-cpus must be supplied together."

    if [[ "$manual_p_set" == true ]]; then
        validate_manual_cpu_list "Performance" "$MANUAL_PERFORMANCE_CPUS"
        validate_manual_cpu_list "Efficient" "$MANUAL_EFFICIENT_CPUS"
        mapfile -t manual_p < <(expand_cpu_list "$MANUAL_PERFORMANCE_CPUS" | sort -n -u)
        mapfile -t manual_e < <(expand_cpu_list "$MANUAL_EFFICIENT_CPUS" | sort -n -u)

        for cpu in "${manual_p[@]}"; do
            core_key="${CPU_CORE_KEY[$cpu]}"
            performance_core_set["$core_key"]=1
        done
        for cpu in "${manual_e[@]}"; do
            core_key="${CPU_CORE_KEY[$cpu]}"
            [[ -z "${performance_core_set[$core_key]+x}" ]] ||
                fail "Manual performance and efficient CPU lists overlap on core '$core_key'."
            efficient_core_set["$core_key"]=1
        done
        CLASSIFICATION_METHOD="manual CPU lists"
    else
        mapfile -t unique_values < <(
            for core_key in "${CORE_KEYS[@]}"; do
                [[ -n "${CORE_TYPE_VALUE[$core_key]+x}" ]] && printf '%s\n' "${CORE_TYPE_VALUE[$core_key]}"
            done | sort -n -u
        )

        if ((${#unique_values[@]} > 1)); then
            maximum="${unique_values[${#unique_values[@]} - 1]}"
            for core_key in "${CORE_KEYS[@]}"; do
                value="${CORE_TYPE_VALUE[$core_key]:-$maximum}"
                if ((value == maximum)); then
                    performance_core_set["$core_key"]=1
                else
                    efficient_core_set["$core_key"]=1
                fi
            done
            CLASSIFICATION_METHOD="Linux topology core_type"
        elif [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
            mapfile -t unique_values < <(
                for core_key in "${CORE_KEYS[@]}"; do
                    printf '%s\n' "${CORE_GLOBAL_THREADS[$core_key]}"
                done | sort -n -u
            )
            minimum="${unique_values[0]}"
            maximum="${unique_values[${#unique_values[@]} - 1]}"
            if ((${#unique_values[@]} > 1 && maximum > 1 && minimum == 1)); then
                for core_key in "${CORE_KEYS[@]}"; do
                    if ((${CORE_GLOBAL_THREADS[$core_key]} > 1)); then
                        performance_core_set["$core_key"]=1
                    else
                        efficient_core_set["$core_key"]=1
                    fi
                done
                CLASSIFICATION_METHOD="Intel mixed-SMT hybrid topology"
            fi
        fi

        if ((${#performance_core_set[@]} == 0)); then
            mapfile -t unique_values < <(
                for core_key in "${CORE_KEYS[@]}"; do
                    [[ -n "${CORE_CAPACITY_VALUE[$core_key]+x}" ]] && printf '%s\n' "${CORE_CAPACITY_VALUE[$core_key]}"
                done | sort -n -u
            )
            if ((${#unique_values[@]} > 1)); then
                minimum="${unique_values[0]}"
                maximum="${unique_values[${#unique_values[@]} - 1]}"
                if ((minimum * 100 <= maximum * 85)); then
                    for core_key in "${CORE_KEYS[@]}"; do
                        value="${CORE_CAPACITY_VALUE[$core_key]:-$maximum}"
                        if ((value * 100 >= maximum * 90)); then
                            performance_core_set["$core_key"]=1
                        else
                            efficient_core_set["$core_key"]=1
                        fi
                    done
                    CLASSIFICATION_METHOD="Linux asymmetric CPU capacity"
                fi
            fi
        fi

        if ((${#performance_core_set[@]} == 0)); then
            mapfile -t unique_values < <(
                for core_key in "${CORE_KEYS[@]}"; do
                    [[ -n "${CORE_MAX_FREQUENCY[$core_key]+x}" ]] && printf '%s\n' "${CORE_MAX_FREQUENCY[$core_key]}"
                done | sort -n -u
            )
            if ((${#unique_values[@]} > 1)); then
                minimum="${unique_values[0]}"
                maximum="${unique_values[${#unique_values[@]} - 1]}"
                if ((minimum * 100 <= maximum * 85)); then
                    for core_key in "${CORE_KEYS[@]}"; do
                        value="${CORE_MAX_FREQUENCY[$core_key]:-$maximum}"
                        if ((value * 100 >= maximum * 90)); then
                            performance_core_set["$core_key"]=1
                        else
                            efficient_core_set["$core_key"]=1
                        fi
                    done
                    CLASSIFICATION_METHOD="maximum-frequency heuristic"
                fi
            fi
        fi

        if ((${#performance_core_set[@]} == 0)); then
            for core_key in "${CORE_KEYS[@]}"; do
                performance_core_set["$core_key"]=1
            done
            CLASSIFICATION_METHOD="homogeneous physical-core topology"
        fi
    fi

    for core_key in "${CORE_KEYS[@]}"; do
        if [[ -n "${performance_core_set[$core_key]+x}" ]]; then
            PERFORMANCE_PRIMARY+=("${CORE_PRIMARY[$core_key]}")
            mapfile -t core_cpus < <(expand_cpu_list "${CORE_ALLOWED_CPUS[$core_key]}")
            PERFORMANCE_ALL+=("${core_cpus[@]}")
        elif [[ -n "${efficient_core_set[$core_key]+x}" ]]; then
            EFFICIENT_PRIMARY+=("${CORE_PRIMARY[$core_key]}")
        fi
    done

    mapfile -t PERFORMANCE_PRIMARY < <(printf '%s\n' "${PERFORMANCE_PRIMARY[@]}" | sort -n -u)
    mapfile -t PERFORMANCE_ALL < <(printf '%s\n' "${PERFORMANCE_ALL[@]}" | sort -n -u)
    if ((${#EFFICIENT_PRIMARY[@]} > 0)); then
        mapfile -t EFFICIENT_PRIMARY < <(printf '%s\n' "${EFFICIENT_PRIMARY[@]}" | sort -n -u)
    fi

    ((${#PERFORMANCE_PRIMARY[@]} > 0)) || fail "No performance/physical cores were identified."
}

classify_cores

discover_l3_cache() {
    local cpu index_path level cache_type shared_list size size_kb domain_key
    local -A seen_domains=()

    for cpu in "${ALLOWED_CPUS[@]}"; do
        for index_path in "$SYSFS_CPU_ROOT/cpu$cpu"/cache/index*; do
            [[ -d "$index_path" ]] || continue
            level="$(read_first_line "$index_path/level" "")"
            [[ "$level" == "3" ]] || continue
            cache_type="$(read_first_line "$index_path/type" "")"
            [[ "$cache_type" != "Instruction" ]] || continue
            shared_list="$(read_first_line "$index_path/shared_cpu_list" "$cpu")"
            size="$(read_first_line "$index_path/size" "0")"
            size_kb="$(parse_cache_size_kb "$size")"
            ((size_kb > 0)) || continue
            domain_key="$shared_list:$size_kb"
            if [[ -z "${seen_domains[$domain_key]+x}" ]]; then
                seen_domains["$domain_key"]=1
                L3_CACHE_KB=$((L3_CACHE_KB + size_kb))
            fi
        done
    done

    if ((L3_CACHE_KB > 0)); then
        MAX_RANDOMX_THREADS=$((L3_CACHE_KB / 2048))
    else
        MAX_RANDOMX_THREADS=${#PERFORMANCE_PRIMARY[@]}
    fi
    ((MAX_RANDOMX_THREADS >= ${#PERFORMANCE_PRIMARY[@]})) ||
        MAX_RANDOMX_THREADS=${#PERFORMANCE_PRIMARY[@]}
}

discover_l3_cache

if [[ -n "$BASELINE_AFFINITY" ]]; then
    mapfile -t baseline_cpus < <(expand_cpu_list "$BASELINE_AFFINITY")
    for baseline_cpu in "${baseline_cpus[@]}"; do
        [[ -n "${ALLOWED_CPU_SET[$baseline_cpu]+x}" ]] ||
            fail "Baseline affinity CPU $baseline_cpu is outside this process's allowed online CPU set."
    done
fi

add_profile() {
    local name="$1"
    local affinity="$2"
    local reason="$3"
    local normalized

    normalized="$(normalize_cpu_list "$affinity")"
    [[ -n "$normalized" ]] || return 0
    [[ -z "${PROFILE_AFFINITY_KEYS[$normalized]+x}" ]] || return 0

    PROFILE_AFFINITY_KEYS["$normalized"]=1
    PROFILE_NAMES+=("$name")
    PROFILE_AFFINITIES+=("$normalized")
    PROFILE_THREADS+=("$(cpu_list_count "$normalized")")
    PROFILE_REASONS+=("$reason")
}

select_evenly_spaced() {
    local count="$1"
    shift
    local -a items=("$@")
    local item_count="${#items[@]}"
    local index source_index
    local -a selected=()

    ((count > 0 && item_count > 0)) || return 0
    if ((count >= item_count)); then
        array_to_cpu_list "${items[@]}"
        return 0
    fi

    for ((index = 0; index < count; index++)); do
        source_index=$((index * item_count / count))
        selected+=("${items[$source_index]}")
    done
    array_to_cpu_list "${selected[@]}"
}

build_profiles() {
    local performance_list efficient_selection affinity count
    local efficient_limit baseline_efficient_count=0
    local -a counts=() baseline_values=()
    local -A efficient_set=()

    performance_list="$(array_to_cpu_list "${PERFORMANCE_PRIMARY[@]}")"

    if [[ -n "$BASELINE_AFFINITY" ]]; then
        add_profile "baseline-rx" "$BASELINE_AFFINITY" \
            "Affinity imported from the existing rx/0, rx, or wildcard CPU profile."
    fi

    add_profile "performance-cores" "$performance_list" \
        "One allowed Linux CPU from each detected performance/physical core."

    if ((${#EFFICIENT_PRIMARY[@]} > 0)); then
        for count in "${EFFICIENT_PRIMARY[@]}"; do
            efficient_set["$count"]=1
        done
        if [[ -n "$BASELINE_AFFINITY" ]]; then
            mapfile -t baseline_values < <(expand_cpu_list "$BASELINE_AFFINITY")
            for count in "${baseline_values[@]}"; do
                [[ -n "${efficient_set[$count]+x}" ]] && ((baseline_efficient_count += 1))
            done
        fi

        efficient_limit=$((MAX_RANDOMX_THREADS - ${#PERFORMANCE_PRIMARY[@]}))
        ((efficient_limit < 0)) && efficient_limit=0
        ((efficient_limit > ${#EFFICIENT_PRIMARY[@]})) && efficient_limit=${#EFFICIENT_PRIMARY[@]}

        case "$PRESET" in
            quick)
                counts=(
                    "$baseline_efficient_count"
                    "$(((${#EFFICIENT_PRIMARY[@]} + 1) / 2))"
                    "$efficient_limit"
                )
                ;;
            standard)
                counts=(
                    "$baseline_efficient_count"
                    "$(((${#EFFICIENT_PRIMARY[@]} + 3) / 4))"
                    "$(((${#EFFICIENT_PRIMARY[@]} + 1) / 2))"
                    "$efficient_limit"
                )
                ;;
            thorough)
                for ((count = 1; count <= efficient_limit; count++)); do
                    counts+=("$count")
                done
                ;;
        esac

        mapfile -t counts < <(printf '%s\n' "${counts[@]}" | awk -v limit="$efficient_limit" '$1 > 0 && $1 <= limit' | sort -n -u)
        for count in "${counts[@]}"; do
            efficient_selection="$(select_evenly_spaced "$count" "${EFFICIENT_PRIMARY[@]}")"
            affinity="$performance_list,$efficient_selection"
            add_profile "performance-plus-${count}-efficient" "$affinity" \
                "Performance cores plus $count evenly distributed efficient cores."
        done
    fi

    if [[ "$INCLUDE_SMT" == true && ${#PERFORMANCE_ALL[@]} -gt ${#PERFORMANCE_PRIMARY[@]} ]]; then
        add_profile "performance-cores-with-smt" "$(array_to_cpu_list "${PERFORMANCE_ALL[@]}")" \
            "All allowed logical CPUs from the performance/physical cores, including SMT siblings."
    fi

    return 0
}

build_profiles
((${#PROFILE_NAMES[@]} > 0)) || fail "No benchmark profiles were generated."

if [[ "$BENCHMARK_SIZE" == "AUTO" ]]; then
    case "$PRESET" in
        quick) BENCHMARK_SIZE="250K" ;;
        standard) BENCHMARK_SIZE="1M" ;;
        thorough) BENCHMARK_SIZE="2M" ;;
    esac
fi
[[ "$SMOKE_TEST" == false ]] || BENCHMARK_SIZE="250K"

case "$PRESET" in
    quick)
        TOP_PROFILE_COUNT=1
        CONFIRMATION_RUNS=1
        ;;
    standard)
        TOP_PROFILE_COUNT=2
        CONFIRMATION_RUNS=1
        ;;
    thorough)
        TOP_PROFILE_COUNT=3
        CONFIRMATION_RUNS=2
        ;;
esac

if ((TOP_PROFILE_COUNT > ${#PROFILE_NAMES[@]})); then
    TOP_PROFILE_COUNT=${#PROFILE_NAMES[@]}
fi

printf '\nSalvium RandomX Linux tuner\n'
printf '  CPU: %s\n' "$CPU_MODEL"
printf '  allowed online CPUs: %s\n' "$(array_to_cpu_list "${ALLOWED_CPUS[@]}")"
printf '  performance/physical primary CPUs: %s\n' "$(array_to_cpu_list "${PERFORMANCE_PRIMARY[@]}")"
printf '  efficient CPUs: %s\n' "$(array_to_cpu_list "${EFFICIENT_PRIMARY[@]}")"
printf '  classification: %s\n' "$CLASSIFICATION_METHOD"
printf '  detected L3 cache: %s KiB\n' "$L3_CACHE_KB"
printf '  approximate RandomX cache limit: %s threads\n' "$MAX_RANDOMX_THREADS"
printf '  benchmark size: %s\n' "$BENCHMARK_SIZE"
printf '  CPU priority: %s\n' "$CPU_PRIORITY"
printf '  MSR and networking: disabled\n'
if [[ "$TEMPERATURE_ENABLED" == true ]]; then
    if [[ "$TEMPERATURE_ENFORCED" == true ]]; then
        printf '  CPU temperature: enforced maximum %.1f C; resume below %.1f C\n' \
            "$MAX_CPU_TEMPERATURE_C" "$TEMPERATURE_RESUME_BELOW_C"
    else
        printf '  CPU temperature: monitor only; rankings are unchanged\n'
    fi
    if [[ -n "$TEMPERATURE_COMMAND" ]]; then
        printf '  requested temperature source: custom command\n'
    elif [[ -n "$TEMPERATURE_SENSOR_PATH" ]]; then
        printf '  requested temperature source: %s\n' "$TEMPERATURE_SENSOR_PATH"
    else
        printf '  requested temperature source: auto-detect at execution time\n'
    fi
else
    printf '  CPU temperature: disabled\n'
fi
if [[ "$BASELINE_IMPORTED" == true ]]; then
    printf '  imported tuning fields: %s\n' "$BASELINE_CONFIG_PATH"
fi
printf '\n'

if [[ "$PLAN_ONLY" == true ]]; then
    printf 'Stage-one affinity profiles:\n'
    for profile_index in "${!PROFILE_NAMES[@]}"; do
        printf '  %-36s %3s threads  [%s]\n' \
            "${PROFILE_NAMES[$profile_index]}" \
            "${PROFILE_THREADS[$profile_index]}" \
            "${PROFILE_AFFINITIES[$profile_index]}"
        printf '    %s\n' "${PROFILE_REASONS[$profile_index]}"
    done

    printf '\n'
    if [[ "$SMOKE_TEST" == true ]]; then
        printf 'Smoke test: one 250K run.\n'
    else
        estimated_runs=$((
            ${#PROFILE_NAMES[@]} +
            TOP_PROFILE_COUNT * 4 +
            4 +
            2 * CONFIRMATION_RUNS
        ))
        printf 'Adaptive stages:\n'
        printf '  1. Compare %s affinity profiles with imported/default baseline settings.\n' "${#PROFILE_NAMES[@]}"
        printf '  2. Test prefetch modes 0-3 on the best %s profile(s).\n' "$TOP_PROFILE_COUNT"
        printf '  3. Test yield and JIT huge-page combinations on the leading profile.\n'
        printf '  4. Confirm the leading two configurations %s additional time(s).\n' "$CONFIRMATION_RUNS"
        printf '  Approximate maximum: %s runs; duplicate configurations are reused.\n' "$estimated_runs"
    fi
    printf '\nPlan only: XMRig was not launched and no result files were written.\n'
    exit 0
fi

find_running_xmrig() {
    local process_path process_name process_id
    for process_path in /proc/[0-9]*/comm; do
        [[ -r "$process_path" ]] || continue
        process_id="${process_path#/proc/}"
        process_id="${process_id%/comm}"
        [[ "$process_id" != "$$" ]] || continue
        IFS= read -r process_name <"$process_path" || continue
        if [[ "$process_name" == xmrig* ]]; then
            printf '%s:%s\n' "$process_id" "$process_name"
        fi
    done
}

mapfile -t running_xmrig < <(find_running_xmrig)
if ((${#running_xmrig[@]} > 0)) && [[ "$ALLOW_CONCURRENT_XMRIG" == false ]]; then
    fail "Another XMRig process is running: ${running_xmrig[*]}. Stop it before tuning, or explicitly use --allow-concurrent-xmrig and accept confounded results."
elif ((${#running_xmrig[@]} > 0)); then
    warn "Another XMRig process is running. Benchmark results will be confounded."
fi

if [[ "$TEMPERATURE_ENABLED" == true ]]; then
    discover_temperature_provider
    initial_temperature="$(read_cpu_temperature)" ||
        fail "The selected CPU temperature source failed its initial read."
    printf 'Temperature sensor: %s\n' "$TEMPERATURE_PROVIDER_NAME"
    [[ -z "$TEMPERATURE_PROVIDER_PATH" ]] ||
        printf '  path: %s\n' "$TEMPERATURE_PROVIDER_PATH"
    printf '  initial reading: %.1f C\n\n' "$initial_temperature"
fi

if [[ -z "$OUTPUT_DIRECTORY" ]]; then
    if [[ -n "${XDG_STATE_HOME:-}" ]]; then
        state_root="$XDG_STATE_HOME"
    elif [[ -n "${HOME:-}" ]]; then
        state_root="$HOME/.local/state"
    else
        state_root="${TMPDIR:-/tmp}"
    fi
    OUTPUT_DIRECTORY="$state_root/xmrig-salvium-tuner/runs/$(date -u +%Y%m%d-%H%M%S)"
fi

mkdir -p -- "$OUTPUT_DIRECTORY"
RESULTS_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd -P)"
RUN_DATA_FILE="$RESULTS_DIRECTORY/measurements.tsv"
RANKING_FILE="$RESULTS_DIRECTORY/rankings.tsv"
: >"$RUN_DATA_FILE"

printf 'Results: %s\n\n' "$RESULTS_DIRECTORY"

create_benchmark_config() {
    local path="$1"
    local affinity="$2"
    local prefetch="$3"
    local yield_setting="$4"
    local jit_setting="$5"
    local log_path="$6"

    log_path="${log_path//\\/\\\\}"
    log_path="${log_path//\"/\\\"}"
    log_path="${log_path//$'\n'/\\n}"
    log_path="${log_path//$'\r'/\\r}"
    log_path="${log_path//$'\t'/\\t}"

    cat >"$path" <<EOF
{
  "api": {
    "id": null,
    "worker-id": null
  },
  "http": {
    "enabled": false,
    "host": "127.0.0.1",
    "port": 0,
    "access-token": null,
    "restricted": true
  },
  "autosave": false,
  "background": false,
  "colors": false,
  "title": false,
  "randomx": {
    "init": $BASE_RANDOMX_INIT,
    "init-avx2": $BASE_RANDOMX_INIT_AVX2,
    "mode": $BASE_RANDOMX_MODE,
    "1gb-pages": $BASE_ONE_GB_PAGES,
    "rdmsr": false,
    "wrmsr": false,
    "cache_qos": false,
    "numa": $BASE_RANDOMX_NUMA,
    "scratchpad_prefetch_mode": $prefetch
  },
  "cpu": {
    "enabled": true,
    "huge-pages": $BASE_HUGE_PAGES,
    "huge-pages-jit": $jit_setting,
    "hw-aes": $BASE_HW_AES,
    "priority": $CPU_PRIORITY,
    "memory-pool": $BASE_MEMORY_POOL,
    "yield": $yield_setting,
    "max-threads-hint": 100,
    "asm": $BASE_ASSEMBLY,
    "rx": [$affinity]
  },
  "opencl": {
    "enabled": false
  },
  "cuda": {
    "enabled": false
  },
  "benchmark": {
    "size": "$BENCHMARK_SIZE",
    "algo": "rx/0",
    "submit": false,
    "verify": null,
    "token": null,
    "seed": null,
    "user": null,
    "hash": null
  },
  "donate-level": 0,
  "donate-over-proxy": 0,
  "log-file": "$log_path",
  "print-time": 60,
  "health-print-time": 0,
  "dmi": false,
  "retries": 0,
  "retry-pause": 0,
  "syslog": false,
  "verbose": 0,
  "watch": false,
  "pause-on-battery": false,
  "pause-on-active": false
}
EOF
}

candidate_key() {
    local profile_name="$1"
    local prefetch="$2"
    local yield_setting="$3"
    local jit_setting="$4"
    printf '%s|p%s|y%s|j%s' "$profile_name" "$prefetch" "$yield_setting" "$jit_setting"
}

profile_index_by_name() {
    local target="$1"
    local index
    for index in "${!PROFILE_NAMES[@]}"; do
        if [[ "${PROFILE_NAMES[$index]}" == "$target" ]]; then
            printf '%s' "$index"
            return 0
        fi
    done
    return 1
}

run_candidate() {
    local profile_index="$1"
    local prefetch="$2"
    local yield_setting="$3"
    local jit_setting="$4"
    local stage="$5"
    local force="${6:-false}"
    local profile_name="${PROFILE_NAMES[$profile_index]}"
    local affinity="${PROFILE_AFFINITIES[$profile_index]}"
    local thread_count="${PROFILE_THREADS[$profile_index]}"
    local key safe_profile run_name stdout_path stderr_path console_path temperature_path combined_output result_line
    local exit_code timed_out=false succeeded=false seconds="" hashrate="" hash_sum=""
    local started_at deadline completion_detected=false
    local thermally_limited=false thermal_limit_observed="" time_to_thermal_limit=""
    local temperature_monitoring_active="$TEMPERATURE_ENABLED"
    local temperature_monitoring_failed=false temperature_failure=""
    local temperature_samples=0 temperature_start="" temperature_mean="" temperature_p95=""
    local temperature_maximum="" temperature_end="" temperature=""
    local next_temperature_sample=0 next_temperature_display=0
    local minimum_wait=0

    key="$(candidate_key "$profile_name" "$prefetch" "$yield_setting" "$jit_setting")"
    if [[ "$force" == false && -n "${MEASURED_KEYS[$key]+x}" ]]; then
        return 0
    fi

    if [[ "$TEMPERATURE_ENFORCED" == true ]]; then
        [[ "$HAS_RUN_CANDIDATE" == false ]] || minimum_wait="$COOLDOWN_SECONDS"
        wait_for_temperature_ready "$minimum_wait"
        printf '      thermal start condition: %.1f C after %.1f seconds\n' \
            "$LAST_READY_TEMPERATURE_C" "$LAST_COOLDOWN_WAIT_SECONDS"
    else
        LAST_COOLDOWN_WAIT_SECONDS=0
        LAST_READY_TEMPERATURE_C=""
    fi

    MEASURED_KEYS["$key"]=1

    RUN_SEQUENCE=$((RUN_SEQUENCE + 1))
    safe_profile="${profile_name//[^A-Za-z0-9_.-]/-}"
    run_name="$(printf '%03d-%s-%s-p%s-y%s-j%s' \
        "$RUN_SEQUENCE" "$stage" "$safe_profile" "$prefetch" "$yield_setting" "$jit_setting")"
    stdout_path="$RESULTS_DIRECTORY/$run_name.stdout.log"
    stderr_path="$RESULTS_DIRECTORY/$run_name.stderr.log"
    console_path="$RESULTS_DIRECTORY/$run_name.console.log"
    temperature_path="$RESULTS_DIRECTORY/$run_name.temperature.csv"
    : >"$stdout_path"
    : >"$stderr_path"
    : >"$console_path"
    if [[ "$TEMPERATURE_ENABLED" == true ]]; then
        printf 'timestamp_utc,temperature_c\n' >"$temperature_path"
    else
        temperature_path=""
    fi
    CURRENT_TEMP_CONFIG="$(mktemp "${TMPDIR:-/tmp}/xmrig-salvium-tuner.XXXXXX.json")"
    create_benchmark_config "$CURRENT_TEMP_CONFIG" "$affinity" "$prefetch" "$yield_setting" "$jit_setting" "$stdout_path"

    printf '[%03d] %s: %s threads, prefetch %s, yield %s, JIT huge pages %s\n' \
        "$RUN_SEQUENCE" "$stage" "$thread_count" "$prefetch" "$yield_setting" "$jit_setting"
    printf '      affinity: %s\n' "$affinity"

    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set +e
    "$XMRIG_PATH" "--config=$CURRENT_TEMP_CONFIG" >"$console_path" 2>"$stderr_path" &
    CURRENT_XMRIG_PID=$!
    deadline=$((SECONDS + TIMEOUT_SECONDS))
    next_temperature_sample="$SECONDS"
    next_temperature_display="$SECONDS"

    while process_is_running "$CURRENT_XMRIG_PID"; do
        if [[ "$temperature_monitoring_active" == true ]] &&
            ((SECONDS >= next_temperature_sample)); then
            if temperature="$(read_cpu_temperature)"; then
                printf '%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$temperature" >>"$temperature_path"
                if ((SECONDS >= next_temperature_display)); then
                    if [[ "$TEMPERATURE_ENFORCED" == true ]]; then
                        printf '      CPU temperature: %.1f C / %.1f C maximum\n' \
                            "$temperature" "$MAX_CPU_TEMPERATURE_C"
                    else
                        printf '      CPU temperature: %.1f C\n' "$temperature"
                    fi
                    next_temperature_display=$((SECONDS + 10))
                fi

                if [[ "$TEMPERATURE_ENFORCED" == true ]] &&
                    number_is_greater_than_or_equal "$temperature" "$MAX_CPU_TEMPERATURE_C"; then
                    thermally_limited=true
                    thermal_limit_observed="$temperature"
                    time_to_thermal_limit=$((SECONDS - (deadline - TIMEOUT_SECONDS)))
                    break
                fi
            else
                temperature_monitoring_failed=true
                temperature_failure="the CPU temperature source failed during the benchmark"
                temperature_monitoring_active=false
                if [[ "$TEMPERATURE_ENFORCED" == true ]]; then
                    break
                fi
                warn "$run_name temperature monitoring stopped: $temperature_failure."
            fi
            next_temperature_sample=$((SECONDS + TEMPERATURE_SAMPLE_SECONDS))
        fi

        if grep -Eq 'benchmark finished in[[:space:]]+[0-9.]+[[:space:]]+seconds[[:space:]]+\([0-9.]+[[:space:]]+h/s\).*hash sum[[:space:]]*=' "$stdout_path"; then
            completion_detected=true
            break
        fi

        if ((SECONDS >= deadline)); then
            timed_out=true
            break
        fi

        sleep 0.2
    done

    if [[ "$completion_detected" == true || "$timed_out" == true ||
          "$thermally_limited" == true ||
          ( "$temperature_monitoring_failed" == true && "$TEMPERATURE_ENFORCED" == true ) ]]; then
        terminate_xmrig_child "$CURRENT_XMRIG_PID"
    fi

    wait "$CURRENT_XMRIG_PID"
    exit_code=$?
    CURRENT_XMRIG_PID=""
    set -e

    rm -f -- "$CURRENT_TEMP_CONFIG"
    CURRENT_TEMP_CONFIG=""

    if [[ ! -s "$stdout_path" && -s "$console_path" ]]; then
        mv -f -- "$console_path" "$stdout_path"
    else
        rm -f -- "$console_path"
    fi

    combined_output="$(cat -- "$stdout_path" "$stderr_path" 2>/dev/null || true)"
    result_line="$(grep -E 'benchmark finished in[[:space:]]+[0-9.]+[[:space:]]+seconds[[:space:]]+\([0-9.]+[[:space:]]+h/s\).*hash sum[[:space:]]*=' <<<"$combined_output" | tail -n 1 || true)"
    if [[ -n "$temperature_path" ]]; then
        IFS=$'\t' read -r temperature_samples temperature_start temperature_mean \
            temperature_p95 temperature_maximum temperature_end \
            <<<"$(temperature_statistics "$temperature_path")"
    fi

    if [[ -n "$result_line" ]]; then
        timed_out=false
        seconds="$(sed -E 's/.*benchmark finished in[[:space:]]+([0-9.]+)[[:space:]]+seconds.*/\1/' <<<"$result_line")"
        hashrate="$(sed -E 's/.*\(([0-9.]+)[[:space:]]+h\/s\).*/\1/' <<<"$result_line")"
        hash_sum="$(sed -E 's/.*hash sum[[:space:]]*=[[:space:]]*([0-9A-Fa-f]+).*/\1/' <<<"$result_line" | tr '[:lower:]' '[:upper:]')"
    fi

    if [[ -n "$hashrate" && "$thermally_limited" == false ]] &&
        { [[ "$temperature_monitoring_failed" == false ]] ||
          [[ "$TEMPERATURE_ENFORCED" == false ]]; }; then
        succeeded=true
        printf '      result: %.1f H/s in %.3f seconds\n' "$hashrate" "$seconds"
        if ((temperature_samples > 0)); then
            printf '      temperature: mean %.1f C, p95 %.1f C, max %.1f C\n' \
                "$temperature_mean" "$temperature_p95" "$temperature_maximum"
        fi
    else
        if [[ "$thermally_limited" == true ]]; then
            warn "$run_name reached the $MAX_CPU_TEMPERATURE_C C CPU-temperature ceiling (observed $thermal_limit_observed C) and was stopped."
        elif [[ "$temperature_monitoring_failed" == true && "$TEMPERATURE_ENFORCED" == true ]]; then
            warn "$run_name stopped because $temperature_failure."
        elif [[ "$timed_out" == true ]]; then
            warn "$run_name timed out after $TIMEOUT_SECONDS seconds."
        elif [[ "$exit_code" -ne 0 ]]; then
            warn "$run_name exited with code $exit_code."
        else
            warn "$run_name did not contain a benchmark completion record."
        fi
        warn "Inspect '$stdout_path' and '$stderr_path'."
    fi

    local sanitized_temperature_name="${TEMPERATURE_PROVIDER_NAME//$'\t'/ }"
    sanitized_temperature_name="${sanitized_temperature_name//$'\n'/ }"
    printf '%s\t' \
        "$RUN_SEQUENCE" "$stage" "$key" "$profile_name" "$affinity" "$thread_count" \
        "$prefetch" "$yield_setting" "$jit_setting" "$BASE_HUGE_PAGES" "$CPU_PRIORITY" \
        "$BENCHMARK_SIZE" "$hashrate" "$seconds" "$hash_sum" "$succeeded" "$timed_out" \
        "$exit_code" "$started_at" "$stdout_path" "$stderr_path" "$sanitized_temperature_name" \
        "$temperature_samples" "$temperature_start" "$temperature_mean" "$temperature_p95" \
        "$temperature_maximum" "$temperature_end" "$thermally_limited" "$MAX_CPU_TEMPERATURE_C" \
        "$thermal_limit_observed" "$time_to_thermal_limit" "$temperature_monitoring_failed" \
        "$temperature_failure" "$temperature_path" "$LAST_COOLDOWN_WAIT_SECONDS" \
        >>"$RUN_DATA_FILE"
    printf '%s\n' "$LAST_READY_TEMPERATURE_C" >>"$RUN_DATA_FILE"

    HAS_RUN_CANDIDATE=true
    if [[ "$TEMPERATURE_ENFORCED" == true && "$temperature_monitoring_failed" == true ]]; then
        write_partial_tuning_outputs "CPU temperature enforcement stopped because the selected sensor failed during a benchmark."
        fail "CPU temperature enforcement stopped because the sensor failed. Measurements were preserved in '$RESULTS_DIRECTORY'."
    fi

    if [[ "$TEMPERATURE_ENFORCED" == false ]] && ((COOLDOWN_SECONDS > 0)); then
        sleep "$COOLDOWN_SECONDS"
    fi
}

build_rankings() {
    local output="$1"
    local key sample profile affinity threads prefetch yield_setting jit_setting
    local mean median minimum maximum samples sum middle temperature_mean temperature_maximum
    local -a keys=() rates=()
    local temporary_output

    temporary_output="$(mktemp "${TMPDIR:-/tmp}/xmrig-salvium-rankings.XXXXXX")"
    mapfile -t keys < <(awk -F'\t' '$16 == "true" {print $3}' "$RUN_DATA_FILE" | sort -u)

    for key in "${keys[@]}"; do
        sample="$(awk -F'\t' -v key="$key" '$3 == key && $16 == "true" {print; exit}' "$RUN_DATA_FILE")"
        [[ -n "$sample" ]] || continue
        IFS=$'\t' read -r _ _ _ profile affinity threads prefetch yield_setting jit_setting _ <<<"$sample"
        mapfile -t rates < <(awk -F'\t' -v key="$key" '$3 == key && $16 == "true" {print $13}' "$RUN_DATA_FILE" | sort -n)
        samples="${#rates[@]}"
        ((samples > 0)) || continue
        minimum="${rates[0]}"
        maximum="${rates[samples - 1]}"
        sum="$(printf '%s\n' "${rates[@]}" | awk '{sum += $1} END {printf "%.6f", sum}')"
        mean="$(awk -v sum="$sum" -v count="$samples" 'BEGIN {printf "%.6f", sum / count}')"
        middle=$((samples / 2))
        if ((samples % 2 == 1)); then
            median="${rates[$middle]}"
        else
            median="$(awk -v a="${rates[middle - 1]}" -v b="${rates[middle]}" 'BEGIN {printf "%.6f", (a + b) / 2}')"
        fi
        temperature_mean="$(awk -F'\t' -v key="$key" '
            $3 == key && $16 == "true" && $25 != "" {sum += $25; count++}
            END {if (count > 0) printf "%.6f", sum / count}
        ' "$RUN_DATA_FILE")"
        temperature_maximum="$(awk -F'\t' -v key="$key" '
            $3 == key && $16 == "true" && $27 != "" {
                if (!found || $27 > maximum) maximum = $27
                found = 1
            }
            END {if (found) printf "%.6f", maximum}
        ' "$RUN_DATA_FILE")"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$key" "$profile" "$affinity" "$threads" "$prefetch" "$yield_setting" \
            "$jit_setting" "$median" "$mean" "$minimum" "$maximum" "$samples" \
            "$temperature_mean" "$temperature_maximum" >>"$temporary_output"
    done

    sort -t$'\t' -k8,8nr -k9,9nr -k1,1 "$temporary_output" >"$output"
    rm -f -- "$temporary_output"
}

write_measurements_csv() {
    local destination="$1"
    awk -F'\t' '
        BEGIN {
            OFS=","
            print "\"Sequence\",\"Stage\",\"ConfigKey\",\"Profile\",\"Affinity\",\"ThreadCount\",\"PrefetchMode\",\"Yield\",\"HugePagesJit\",\"HugePages\",\"CpuPriority\",\"BenchmarkSize\",\"Hashrate\",\"Seconds\",\"HashSum\",\"Succeeded\",\"TimedOut\",\"ExitCode\",\"StartedAtUtc\",\"StdoutLog\",\"StderrLog\",\"TemperatureSensor\",\"TemperatureSamples\",\"TemperatureStartC\",\"TemperatureMeanC\",\"TemperatureP95C\",\"TemperatureMaximumC\",\"TemperatureEndC\",\"ThermallyLimited\",\"TemperatureLimitC\",\"ThermalLimitObservedC\",\"TimeToThermalLimitSeconds\",\"TemperatureMonitoringFailed\",\"TemperatureFailure\",\"TemperatureLog\",\"CooldownWaitSeconds\",\"ReadyTemperatureC\""
        }
        function quote(value) {
            gsub(/"/, "\"\"", value)
            return "\"" value "\""
        }
        {
            for (column = 1; column <= NF; column++) {
                printf "%s%s", quote($column), (column == NF ? ORS : OFS)
            }
        }
    ' "$RUN_DATA_FILE" >"$destination"
}

write_partial_tuning_outputs() {
    local reason="$1"
    local csv_path="$RESULTS_DIRECTORY/measurements.csv"
    local report_path="$RESULTS_DIRECTORY/report.md"
    local successful failed thermally_limited
    rm -f -- "$RESULTS_DIRECTORY/recommended-settings.json"
    write_measurements_csv "$csv_path"
    successful="$(awk -F'\t' '$16 == "true" {count++} END {print count + 0}' "$RUN_DATA_FILE")"
    failed="$(awk -F'\t' '$16 != "true" {count++} END {print count + 0}' "$RUN_DATA_FILE")"
    thermally_limited="$(awk -F'\t' '$29 == "true" {count++} END {print count + 0}' "$RUN_DATA_FILE")"
    {
        printf '# Salvium RandomX Linux tuning report\n\n'
        printf -- '- Generated: %s UTC\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
        printf -- '- XMRig: %s\n' "$XMRIG_PATH"
        printf -- '- CPU: %s\n' "$CPU_MODEL"
        printf -- '- Benchmark: offline rx/0, size %s\n' "$BENCHMARK_SIZE"
        if [[ "$TEMPERATURE_ENFORCED" == true ]]; then
            printf -- '- CPU temperature: enforced maximum %s C; resume below %s C\n' \
                "$MAX_CPU_TEMPERATURE_C" "$TEMPERATURE_RESUME_BELOW_C"
            printf -- '- Temperature sensor: %s\n' "$TEMPERATURE_PROVIDER_NAME"
        elif [[ "$TEMPERATURE_ENABLED" == true ]]; then
            printf -- '- CPU temperature: monitor only\n'
            printf -- '- Temperature sensor: %s\n' "$TEMPERATURE_PROVIDER_NAME"
        else
            printf -- '- CPU temperature: disabled\n'
        fi
        printf '\n## Outcome\n\n%s\n\n' "$reason"
        printf 'Successful runs: %s\n\n' "$successful"
        printf 'Failed runs: %s\n\n' "$failed"
        printf 'Thermally limited runs: %s\n' "$thermally_limited"
    } >"$report_path"
}

baseline_profile_index=""
if baseline_profile_index="$(profile_index_by_name "baseline-rx" 2>/dev/null)"; then
    :
elif baseline_profile_index="$(profile_index_by_name "performance-cores" 2>/dev/null)"; then
    :
else
    baseline_profile_index=0
fi

if [[ "$SMOKE_TEST" == true ]]; then
    run_candidate "$baseline_profile_index" "$BASE_PREFETCH_MODE" "$BASE_YIELD" "$BASE_HUGE_PAGES_JIT" "smoke"
else
    for profile_index in "${!PROFILE_NAMES[@]}"; do
        run_candidate "$profile_index" "$BASE_PREFETCH_MODE" "$BASE_YIELD" "$BASE_HUGE_PAGES_JIT" "affinity"
    done

    build_rankings "$RANKING_FILE"
    if [[ ! -s "$RANKING_FILE" ]]; then
        write_partial_tuning_outputs "Every affinity benchmark failed or was thermally disqualified. No compliant configuration could be ranked."
        fail "Every affinity benchmark failed or was thermally disqualified. Inspect '$RESULTS_DIRECTORY'."
    fi

    declare -a leading_profiles=()
    while IFS=$'\t' read -r _ profile _; do
        if [[ ! " ${leading_profiles[*]} " =~ [[:space:]]${profile}[[:space:]] ]]; then
            leading_profiles+=("$profile")
        fi
        ((${#leading_profiles[@]} >= TOP_PROFILE_COUNT)) && break
    done <"$RANKING_FILE"

    for profile in "${leading_profiles[@]}"; do
        profile_index="$(profile_index_by_name "$profile")"
        for prefetch in 0 1 2 3; do
            run_candidate "$profile_index" "$prefetch" "$BASE_YIELD" "$BASE_HUGE_PAGES_JIT" "prefetch"
        done
    done

    build_rankings "$RANKING_FILE"
    leading_row=""
    while IFS=$'\t' read -r ranking_row; do
        ranking_profile="$(cut -f2 <<<"$ranking_row")"
        if [[ " ${leading_profiles[*]} " =~ [[:space:]]${ranking_profile}[[:space:]] ]]; then
            leading_row="$ranking_row"
            break
        fi
    done <"$RANKING_FILE"
    if [[ -z "$leading_row" ]]; then
        write_partial_tuning_outputs "Every prefetch benchmark failed or was thermally disqualified. No compliant prefetch configuration could be ranked."
        fail "Every prefetch benchmark failed or was thermally disqualified. Inspect '$RESULTS_DIRECTORY'."
    fi

    IFS=$'\t' read -r _ leading_profile _ _ leading_prefetch _ _ _ <<<"$leading_row"
    leading_profile_index="$(profile_index_by_name "$leading_profile")"
    for yield_setting in true false; do
        for jit_setting in false true; do
            run_candidate "$leading_profile_index" "$leading_prefetch" "$yield_setting" "$jit_setting" "runtime"
        done
    done

    build_rankings "$RANKING_FILE"
    mapfile -t confirmation_rows < <(head -n 2 "$RANKING_FILE")
    for ((confirmation = 1; confirmation <= CONFIRMATION_RUNS; confirmation++)); do
        for confirmation_row in "${confirmation_rows[@]}"; do
            IFS=$'\t' read -r _ profile _ _ prefetch yield_setting jit_setting _ <<<"$confirmation_row"
            profile_index="$(profile_index_by_name "$profile")"
            run_candidate "$profile_index" "$prefetch" "$yield_setting" "$jit_setting" "confirm-$confirmation" true
        done
    done
fi

build_rankings "$RANKING_FILE"
if [[ ! -s "$RANKING_FILE" ]]; then
    write_partial_tuning_outputs "No successful temperature-compliant benchmark result was produced."
    fail "No successful benchmark result was produced. Inspect '$RESULTS_DIRECTORY'."
fi

CSV_PATH="$RESULTS_DIRECTORY/measurements.csv"
REPORT_PATH="$RESULTS_DIRECTORY/report.md"
RECOMMENDATION_PATH="$RESULTS_DIRECTORY/recommended-settings.json"
write_measurements_csv "$CSV_PATH"

IFS=$'\t' read -r _ winner_profile winner_affinity winner_threads \
    winner_prefetch winner_yield winner_jit winner_median winner_mean \
    winner_minimum winner_maximum winner_samples winner_temperature_mean \
    winner_temperature_maximum <"$RANKING_FILE"

successful_runs="$(awk -F'\t' '$16 == "true" {count++} END {print count + 0}' "$RUN_DATA_FILE")"
failed_runs="$(awk -F'\t' '$16 != "true" {count++} END {print count + 0}' "$RUN_DATA_FILE")"
thermally_limited_runs="$(awk -F'\t' '$29 == "true" {count++} END {print count + 0}' "$RUN_DATA_FILE")"

{
    printf '# Salvium RandomX Linux tuning report\n\n'
    printf -- '- Generated: %s UTC\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf -- '- XMRig: %s\n' "$XMRIG_PATH"
    printf -- '- CPU: %s\n' "$CPU_MODEL"
    printf -- '- Allowed online CPUs: %s\n' "$(array_to_cpu_list "${ALLOWED_CPUS[@]}")"
    printf -- '- Performance/physical primary CPUs: %s\n' "$(array_to_cpu_list "${PERFORMANCE_PRIMARY[@]}")"
    printf -- '- Efficient CPUs: %s\n' "$(array_to_cpu_list "${EFFICIENT_PRIMARY[@]}")"
    printf -- '- Classification: %s\n' "$CLASSIFICATION_METHOD"
    printf -- '- Detected L3 cache: %s KiB\n' "$L3_CACHE_KB"
    printf -- '- Benchmark: offline rx/0, size %s\n' "$BENCHMARK_SIZE"
    printf -- '- CPU priority: %s\n' "$CPU_PRIORITY"
    printf -- '- MSR reads/writes, cache QoS, networking, OpenCL, and CUDA: disabled\n'
    if [[ "$TEMPERATURE_ENABLED" == true ]]; then
        if [[ "$TEMPERATURE_ENFORCED" == true ]]; then
            printf -- '- CPU temperature: enforced maximum %s C; resume below %s C\n' \
                "$MAX_CPU_TEMPERATURE_C" "$TEMPERATURE_RESUME_BELOW_C"
        else
            printf -- '- CPU temperature: monitor only; temperature did not affect ranking\n'
        fi
        printf -- '- Temperature sensor: %s\n' "$TEMPERATURE_PROVIDER_NAME"
        [[ -z "$TEMPERATURE_PROVIDER_PATH" ]] ||
            printf -- '- Temperature sensor path: %s\n' "$TEMPERATURE_PROVIDER_PATH"
    else
        printf -- '- CPU temperature: disabled\n'
    fi
    if [[ "$BASELINE_IMPORTED" == true ]]; then
        printf -- '- Baseline tuning imported from: %s\n' "$BASELINE_CONFIG_PATH"
    fi

    printf '\n## Ranked configurations\n\n'
    printf '| Rank | Profile | Threads | Prefetch | Yield | JIT huge pages | Samples | Median H/s | Mean H/s | Range H/s | Mean temp C | Max temp C |\n'
    printf '|---:|---|---:|---:|:---:|:---:|---:|---:|---:|---:|---:|---:|\n'
    rank=0
    while IFS=$'\t' read -r _ profile _ threads prefetch yield_setting jit_setting \
        median mean minimum maximum samples mean_temperature maximum_temperature; do
        rank=$((rank + 1))
        [[ -n "$mean_temperature" ]] || mean_temperature="-"
        [[ -n "$maximum_temperature" ]] || maximum_temperature="-"
        printf '| %s | %s | %s | %s | %s | %s | %s | %.1f | %.1f | %.1f-%.1f | %s | %s |\n' \
            "$rank" "$profile" "$threads" "$prefetch" "$yield_setting" "$jit_setting" \
            "$samples" "$median" "$mean" "$minimum" "$maximum" \
            "$mean_temperature" "$maximum_temperature"
    done <"$RANKING_FILE"

    printf '\n## Interpretation\n\n'
    printf 'Use the leader as a candidate, not as an automatic production change. Validate it while mining SAL for several hours and compare accepted shares, temperature, package power, clocks, and host responsiveness. Treat a difference below roughly one percent cautiously unless repeated runs agree.\n\n'
    printf 'MSR access was deliberately disabled. Validate MSR or one-gigabyte-page changes separately while keeping the winning affinity and measured RandomX settings constant.\n\n'
    printf 'Successful runs: %s\n\n' "$successful_runs"
    printf 'Failed runs: %s\n\n' "$failed_runs"
    printf 'Thermally limited runs: %s\n' "$thermally_limited_runs"
} >"$REPORT_PATH"

temperature_mode="disabled"
[[ "$TEMPERATURE_ENABLED" == false ]] || temperature_mode="monitor-only"
[[ "$TEMPERATURE_ENFORCED" == false ]] || temperature_mode="enforced-maximum"
temperature_sensor_json="$(json_escape "$TEMPERATURE_PROVIDER_NAME")"
temperature_path_json="$(json_escape "$TEMPERATURE_PROVIDER_PATH")"
temperature_limit_json="${MAX_CPU_TEMPERATURE_C:-null}"
temperature_resume_json="${TEMPERATURE_RESUME_BELOW_C:-null}"
winner_temperature_mean_json="${winner_temperature_mean:-null}"
winner_temperature_maximum_json="${winner_temperature_maximum:-null}"

cat >"$RECOMMENDATION_PATH" <<EOF
{
  "generated_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "algorithm": "rx/0",
  "source": "offline XMRig benchmark; validate on the SAL pool before production use",
  "cpu": {
    "huge-pages-jit": $winner_jit,
    "yield": $winner_yield,
    "rx": [$winner_affinity]
  },
  "randomx": {
    "scratchpad_prefetch_mode": $winner_prefetch
  },
  "held_constant": {
    "huge-pages": $BASE_HUGE_PAGES,
    "one-gb-pages": $BASE_ONE_GB_PAGES,
    "cpu_priority": $CPU_PRIORITY,
    "rdmsr": false,
    "wrmsr": false,
    "cache_qos": false
  },
  "temperature": {
    "mode": "$temperature_mode",
    "sensor": "$temperature_sensor_json",
    "sensor_path": "$temperature_path_json",
    "maximum_limit_c": $temperature_limit_json,
    "resume_below_c": $temperature_resume_json,
    "measured_mean_c": $winner_temperature_mean_json,
    "measured_maximum_c": $winner_temperature_maximum_json
  },
  "measurement": {
    "benchmark_size": "$BENCHMARK_SIZE",
    "samples": $winner_samples,
    "median_hashrate": $winner_median,
    "mean_hashrate": $winner_mean,
    "minimum_hashrate": $winner_minimum,
    "maximum_hashrate": $winner_maximum
  }
}
EOF

printf '\nBest measured configuration\n'
printf '  %.1f H/s median (%s sample(s))\n' "$winner_median" "$winner_samples"
printf '  profile: %s\n' "$winner_profile"
printf '  threads: %s\n' "$winner_threads"
printf '  affinity: %s\n' "$winner_affinity"
printf '  scratchpad prefetch mode: %s\n' "$winner_prefetch"
printf '  yield: %s\n' "$winner_yield"
printf '  JIT huge pages: %s\n' "$winner_jit"
if [[ -n "$winner_temperature_maximum" ]]; then
    printf '  measured CPU temperature: %.1f C mean, %.1f C maximum\n' \
        "$winner_temperature_mean" "$winner_temperature_maximum"
fi
if ((thermally_limited_runs > 0)); then
    printf '  thermally limited candidates: %s\n' "$thermally_limited_runs"
fi
printf '\nReport: %s\n' "$REPORT_PATH"
printf 'Measurements: %s\n' "$CSV_PATH"
printf 'Recommendation: %s\n' "$RECOMMENDATION_PATH"
printf '\nValidate the recommendation on the SAL pool before changing the production configuration.\n'
