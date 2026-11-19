#!/usr/bin/env bash
# Regression: skopeo_copy must read multiarch from the third argument.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

AUTHFILE=/dev/null
policy() { printf '1'; }
tls_verify_for() { printf 'true'; }
skopeo() { printf '%s\n' "$@"; }

fail() { echo "FAIL: $*" >&2; exit 1; }

multiarch_out="$(skopeo_copy docker://src.example/repo:v1 docker://dst.example/repo:v1 true)"
grep -qx -- '--all' <<<"${multiarch_out}" || fail "multiarch copy must use --all"
if grep -qx -- '--preserve-digests' <<<"${multiarch_out}"; then
  fail "multiarch copy must not force a single platform"
fi

single_out="$(skopeo_copy docker://src.example/repo:v1 docker://dst.example/repo:v1 false)"
grep -qx -- '--preserve-digests' <<<"${single_out}" \
  || fail "single-arch copy must preserve digests"
grep -qx -- '--override-arch' <<<"${single_out}" \
  || fail "single-arch copy must override the architecture"
if grep -qx -- '--all' <<<"${single_out}"; then
  fail "single-arch copy must not use --all"
fi

printf 'ok - skopeo_copy multiarch argument\n'
