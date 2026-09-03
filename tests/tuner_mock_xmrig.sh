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

printf '[mock] randomx dataset ready\n' >>"$log_path"
printf '[mock] randomx dataset ready\n'

if [[ "${XMRIG_TUNER_MOCK_MODE:-success}" == "no-result" ]]; then
    exit 7
fi

sleep 0.25
printf '[mock] bench benchmark finished in 1.000 seconds (1000.0 h/s) hash sum = ABCDEF12\n' >>"$log_path"
printf '[mock] bench benchmark finished in 1.000 seconds (1000.0 h/s) hash sum = ABCDEF12\n'

if [[ "${XMRIG_TUNER_MOCK_MODE:-success}" == "exit-after-result" ]]; then
    exit 0
fi

while true; do
    sleep 60
done
