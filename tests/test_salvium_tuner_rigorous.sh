#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd -P)"
TUNER_PATH="$REPOSITORY_ROOT/scripts/tune-salvium-randomx.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xmrig-tuner-rigorous-tests.XXXXXX")"
MOCK_PATH="$TEST_ROOT/xmrig-rigorous-mock"
SYSFS_ROOT="$TEST_ROOT/sysfs"

cleanup() {
    if [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]]; then
        case "$TEST_ROOT" in
            "${TMPDIR:-/tmp}"/xmrig-tuner-rigorous-tests.*)
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

assert_stage_present() {
    local path="$1"
    local pattern="$2"
    local message="$3"
    awk -F'\t' -v pattern="$pattern" '$2 ~ pattern {found = 1} END {exit !found}' "$path" || {
        printf 'Assertion failed: %s\n' "$message" >&2
        exit 1
    }
}

cp -- "$SCRIPT_DIRECTORY/tuner_mock_xmrig.sh" "$MOCK_PATH"
chmod +x -- "$MOCK_PATH"

mkdir -p -- "$SYSFS_ROOT"
printf '0-3\n' >"$SYSFS_ROOT/online"
for cpu in 0 1 2 3; do
    topology_path="$SYSFS_ROOT/cpu$cpu/topology"
    mkdir -p -- "$topology_path"
    printf '0\n' >"$topology_path/physical_package_id"
    printf '0\n' >"$topology_path/die_id"
    printf '%s\n' "$cpu" >"$topology_path/core_id"
    printf '%s\n' "$cpu" >"$topology_path/core_cpus_list"
    if ((cpu < 2)); then
        printf '2\n' >"$topology_path/core_type"
    else
        printf '1\n' >"$topology_path/core_type"
    fi
done

rigorous_output="$TEST_ROOT/rigorous"
topology_arguments=(
    --sysfs-cpu-root "$SYSFS_ROOT"
    --allowed-cpus 0-3
    --performance-cpus 0-1
    --efficient-cpus 2-3
)
rigorous_arguments=(
    --xmrig "$MOCK_PATH"
    --preset rigorous
    --screening-repeats 1
    --final-confirmation-runs 2
    --maximum-survivors 2
    --reference-interval 2
    --candidate-order-seed 8675309
    --ignore-adjacent-config
    --output-directory "$rigorous_output"
    --cooldown-seconds 0
    --allow-concurrent-xmrig
    "${topology_arguments[@]}"
)
rigorous_console="$TEST_ROOT/rigorous-console.log"
if ! "$TUNER_PATH" "${rigorous_arguments[@]}" >"$rigorous_console" 2>&1; then
    printf 'Rigorous mock run failed:\n' >&2
    tail -n 180 -- "$rigorous_console" >&2
    exit 1
fi

manifest_path="$rigorous_output/run-manifest.json"
measurement_path="$rigorous_output/measurements.tsv"
measurement_csv_path="$rigorous_output/measurements.csv"
recommendation_path="$rigorous_output/recommended-settings.json"
report_path="$rigorous_output/report.md"
for path in "$manifest_path" "$measurement_path" "$measurement_csv_path" \
    "$recommendation_path" "$report_path"; do
    [[ -f "$path" ]] || {
        printf 'Assertion failed: rigorous mode did not create %s\n' "$path" >&2
        exit 1
    }
done

assert_file_contains "$manifest_path" '"schema_version": 2' \
    "The resumable manifest must use schema two."
assert_file_contains "$manifest_path" '"preset": "rigorous"' \
    "The manifest must preserve the rigorous preset."
assert_file_contains "$manifest_path" '"candidate_order_seed": 8675309' \
    "The manifest must preserve the deterministic order seed."
assert_file_contains "$measurement_csv_path" '"BenchmarkValidated"' \
    "Measurements must expose benchmark-contract validation."
assert_file_contains "$measurement_csv_path" '"TemperatureSlopeCPerMinute"' \
    "Measurements must expose thermal-stability diagnostics."

assert_stage_present "$measurement_path" '^rigorous-reference-' \
    "Rigorous mode must insert reference anchors."
assert_stage_present "$measurement_path" '^rigorous-affinity-r' \
    "Rigorous mode must screen multiple affinities."
assert_stage_present "$measurement_path" '^rigorous-prefetch$' \
    "Rigorous mode must refine prefetch settings."
assert_stage_present "$measurement_path" '^rigorous-interaction$' \
    "Rigorous mode must test setting interactions."
assert_stage_present "$measurement_path" '^rigorous-final-r' \
    "Rigorous mode must repeat finalist measurements."

final_count="$(awk -F'\t' '$2 ~ /^rigorous-final-r/ {count++} END {print count + 0}' \
    "$measurement_path")"
[[ "$final_count" == "4" ]] || {
    printf 'Assertion failed: expected four final measurements, found %s\n' \
        "$final_count" >&2
    exit 1
}
awk -F'\t' '$38 != "true" {exit 1}' "$measurement_path" || {
    printf 'Assertion failed: valid mock benchmarks did not all pass contract checks.\n' >&2
    exit 1
}
awk -F'\t' '$45 != "1" {exit 1}' "$measurement_path" || {
    printf 'Assertion failed: XMRig 60-second traces were not parsed.\n' >&2
    exit 1
}
stage_size_count="$(awk -F'\t' '{print $12}' "$measurement_path" | sort -u | wc -l)"
[[ "$stage_size_count" == "4" ]] || {
    printf 'Assertion failed: expected four Rigorous stage sizes, found %s.\n' \
        "$stage_size_count" >&2
    exit 1
}
awk -F'\t' '
    {
        size_hash = $12 SUBSEP $15
        if (!(size_hash in seen_hash)) {
            seen_hash[size_hash] = 1
            hash_count[$12]++
        }
    }
    END {
        for (size in hash_count) {
            if (hash_count[size] != 1) exit 1
        }
    }
' "$measurement_path" || {
    printf 'Assertion failed: hash consistency was not scoped to benchmark size.\n' >&2
    exit 1
}
assert_file_contains "$recommendation_path" '"samples": 2' \
    "The recommendation must use only repeated finalist measurements."
assert_file_contains "$recommendation_path" '"coefficient_of_variation_percent": 0.000000' \
    "Identical finalist measurements must report zero variation."
assert_file_contains "$recommendation_path" '"candidate_order_seed": 8675309' \
    "The recommendation must preserve experimental provenance."
assert_file_contains "$report_path" "practically tied" \
    "The report must identify statistically indistinguishable leaders."

measurement_count_before_resume="$(wc -l <"$measurement_path")"
"$TUNER_PATH" \
    --xmrig "$MOCK_PATH" \
    --resume-directory "$rigorous_output" \
    --ignore-adjacent-config \
    --allow-concurrent-xmrig \
    "${topology_arguments[@]}" \
    >/dev/null
measurement_count_after_resume="$(wc -l <"$measurement_path")"
[[ "$measurement_count_after_resume" == "$measurement_count_before_resume" ]] || {
    printf 'Assertion failed: resume repeated completed measurements (%s became %s).\n' \
        "$measurement_count_before_resume" "$measurement_count_after_resume" >&2
    exit 1
}

invalid_output="$TEST_ROOT/invalid-contract"
export XMRIG_TUNER_MOCK_MODE=wrong-threads
if "$TUNER_PATH" \
    --xmrig "$MOCK_PATH" \
    --smoke-test \
    --ignore-adjacent-config \
    --output-directory "$invalid_output" \
    --cooldown-seconds 0 \
    --allow-concurrent-xmrig \
    "${topology_arguments[@]}" \
    >/dev/null 2>&1; then
    printf 'Assertion failed: a thread-count contract mismatch unexpectedly succeeded.\n' >&2
    exit 1
fi
unset XMRIG_TUNER_MOCK_MODE

awk -F'\t' '$38 == "false" && $39 ~ /workers/ {found = 1} END {exit !found}' \
    "$invalid_output/measurements.tsv" || {
    printf 'Assertion failed: invalid benchmark did not record its worker mismatch.\n' >&2
    exit 1
}

printf 'Linux Salvium tuner rigorous-workflow tests passed.\n'
