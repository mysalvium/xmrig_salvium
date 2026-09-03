#!/bin/sh

set -eu

target_repo=${1:-}
head_ref=${2:-HEAD}
base_ref=${3:-upstream/master}

if [ -z "$target_repo" ]; then
    echo "Usage: $0 <target-repository> [head-ref] [base-ref]" >&2
    exit 2
fi

lower_target=$(printf '%s' "$target_repo" | tr '[:upper:]' '[:lower:]')
lower_target=${lower_target%/}
lower_target=${lower_target%.git}

case "$lower_target" in
    xmrig/xmrig|\
    github.com/xmrig/xmrig|\
    https://github.com/xmrig/xmrig|\
    http://github.com/xmrig/xmrig|\
    git@github.com:xmrig/xmrig|\
    ssh://git@github.com/xmrig/xmrig|\
    *github.com/xmrig/xmrig/*)
        ;;
    *)
        echo "Target is not xmrig/xmrig; the upstream donation firewall is not applicable."
        exit 0
        ;;
esac

head_sha=$(git rev-parse --verify "$head_ref^{commit}") || {
    echo "REJECTED: cannot resolve head ref '$head_ref'." >&2
    exit 1
}

base_sha=$(git rev-parse --verify "$base_ref^{commit}") || {
    echo "REJECTED: cannot resolve upstream base ref '$base_ref'." >&2
    exit 1
}

current_branch=$(git branch --show-current)
case "$current_branch" in
    donation|combined)
        echo "REJECTED: branch '$current_branch' is never an xmrig/xmrig PR head." >&2
        exit 1
        ;;
esac

if git cat-file -e "$head_sha:docs/DONATION_LAYER.md" 2>/dev/null; then
    echo "REJECTED: '$head_ref' contains the personal donation-layer marker." >&2
    exit 1
fi

for donation_ref in refs/heads/donation refs/remotes/origin/donation; do
    if git show-ref --verify --quiet "$donation_ref" &&
       git merge-base --is-ancestor "$donation_ref" "$head_sha"; then
        echo "REJECTED: '$head_ref' contains '$donation_ref' as an ancestor." >&2
        exit 1
    fi
done

if ! git diff --quiet "$base_sha...$head_sha" -- \
    src/core/config/usage.h \
    src/donate.h \
    src/net/strategies/DonateStrategy.cpp \
    src/net/strategies/DonateStrategy.h; then
    cat >&2 <<EOF
REJECTED: donation-owned files differ from '$base_ref'.
The proposed head must not be sent to xmrig/xmrig.
EOF
    exit 1
fi

cat <<EOF
PASS: no personal donation-layer ancestry, marker, or owned-file changes were
detected between '$base_ref' and '$head_ref'.

This check is necessary but not sufficient. Review the complete diff and
obtain explicit user confirmation naming xmrig/xmrig before any PR-writing
action.
EOF
