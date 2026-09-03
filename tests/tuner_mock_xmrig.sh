#!/usr/bin/env bash

set -Eeuo pipefail

marker_path="${XMRIG_TUNER_MOCK_MARKER:-}"
if [[ -n "$marker_path" ]]; then
    : >"$marker_path"
    trap 'rm -f -- "$marker_path"' EXIT
fi

config_path=""
for argument in "$@"; do
    case "$argument" in
        --config=*) config_path="${argument#--config=}" ;;
    esac
done

[[ -n "$config_path" && -r "$config_path" ]] || exit 2

log_path="$(sed -n 's/.*"log-file":[[:space:]]*"\([^"]*\)".*/\1/p' "$config_path" | head -n 1)"
[[ -n "$log_path" ]] || exit 3

affinity="$(sed -n 's/.*"rx":[[:space:]]*\[\([^]]*\)\].*/\1/p' "$config_path" | head -n 1)"
benchmark_size="$(sed -n 's/.*"size":[[:space:]]*"\([^"]*\)".*/\1/p' "$config_path" | head -n 1)"
case "$benchmark_size" in
    500K) hash_sum=ABCDEF13 ;;
    1M) hash_sum=ABCDEF14 ;;
    2M) hash_sum=ABCDEF15 ;;
    5M) hash_sum=ABCDEF16 ;;
    *) hash_sum=ABCDEF12 ;;
esac
if [[ -n "${affinity//[[:space:],]/}" ]]; then
    thread_count="$(awk -F',' '{print NF}' <<<"$affinity")"
else
    thread_count=1
fi
if [[ "${XMRIG_TUNER_MOCK_MODE:-success}" == "wrong-threads" ]]; then
    thread_count=$((thread_count + 1))
fi

{
    printf '[mock] bench start benchmark hashes %s algo rx/0\n' "${benchmark_size:-250K}"
    printf '[mock] randomx allocated 2336 MB huge pages 100%%\n'
    printf '[mock] randomx dataset ready\n'
    printf '[mock] cpu READY threads %s/%s (%s) huge pages 100%% %s/%s\n' \
        "$thread_count" "$thread_count" "$thread_count" "$thread_count" "$thread_count"
} >>"$log_path"
printf '[mock] bench start benchmark hashes %s algo rx/0\n' "${benchmark_size:-250K}"
printf '[mock] randomx allocated 2336 MB huge pages 100%%\n'
printf '[mock] randomx dataset ready\n'
printf '[mock] cpu READY threads %s/%s (%s) huge pages 100%% %s/%s\n' \
    "$thread_count" "$thread_count" "$thread_count" "$thread_count" "$thread_count"

if [[ "${XMRIG_TUNER_MOCK_MODE:-success}" == "no-result" ]]; then
    exit 7
fi

sleep 0.25
{
    printf '[mock] miner speed 10s/60s/15m 1000.0 1000.0 n/a H/s max 1000.0 H/s\n'
    printf '[mock] bench benchmark finished in 1.000 seconds (1000.0 h/s) hash sum = %s\n' \
        "$hash_sum"
} >>"$log_path"
printf '[mock] miner speed 10s/60s/15m 1000.0 1000.0 n/a H/s max 1000.0 H/s\n'
printf '[mock] bench benchmark finished in 1.000 seconds (1000.0 h/s) hash sum = %s\n' \
    "$hash_sum"

if [[ "${XMRIG_TUNER_MOCK_MODE:-success}" == "exit-after-result" ]]; then
    exit 0
fi

while true; do
    sleep 60
done
