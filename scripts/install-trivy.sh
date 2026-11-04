#!/usr/bin/env bash
#
# Install the pinned Trivy release from GitHub.
#
#   install-trivy.sh                 # v0.76.1 into /usr/local/bin
#   install-trivy.sh -b ~/.local/bin # somewhere writable without sudo
#   install-trivy.sh v0.76.1
#
# CI used to run Trivy's contrib/install.sh through `curl | sudo sh`. That
# script is generated with `set -e`, so the first transient network error kills
# it with curl's own exit status and no diagnostic -- the sync job failed with
# exit code 6 ("couldn't resolve host") while fetching the release tarball.
# Downloading the asset here retries transient failures, verifies the published
# sha256, and keeps `sudo` to the final install so the download still sees the
# runner's proxy settings.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

TRIVY_VERSION=${TRIVY_VERSION:-v0.76.1}
BIN_DIR=/usr/local/bin

usage() {
  cat <<'EOF'
Usage: install-trivy.sh [options] [TAG]

  -b, --bindir DIR   install into DIR (default: /usr/local/bin)
  -h, --help         show this help

TAG defaults to $TRIVY_VERSION, then v0.76.1.
EOF
}

while (($#)); do
  case $1 in
    -b | --bindir) BIN_DIR=${2:?$1 needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown argument: $1 (see --help)" ;;
    *) TRIVY_VERSION=$1; shift ;;
  esac
done

require_cmd curl tar

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) arch=Linux-64bit ;;
  Linux/aarch64 | Linux/arm64) arch=Linux-ARM64 ;;
  Darwin/x86_64) arch=macOS-64bit ;;
  Darwin/arm64) arch=macOS-ARM64 ;;
  *) die "unsupported platform: $(uname -s)/$(uname -m)" ;;
esac

version=${TRIVY_VERSION#v}
asset="trivy_${version}_${arch}.tar.gz"
base_url="https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VERSION}"

# --retry-all-errors is what makes a DNS hiccup (curl exit 6) retryable; plain
# --retry only covers 5xx and connection resets.
fetch() {
  curl -fsSL --proto '=https' --connect-timeout 15 \
    --retry 5 --retry-delay 2 --retry-all-errors \
    -o "$2" "$1"
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

info "downloading ${asset}"
fetch "${base_url}/${asset}" "${tmpdir}/${asset}"
fetch "${base_url}/trivy_${version}_checksums.txt" "${tmpdir}/checksums.txt"

expected=$(awk -v f="$asset" '$2 == f { print $1; exit }' "${tmpdir}/checksums.txt")
[[ -n $expected ]] || die "no checksum published for ${asset}"
actual=$(sha256_stdin <"${tmpdir}/${asset}")
[[ $actual == "$expected" ]] || die "checksum mismatch for ${asset}: expected ${expected}, got ${actual}"
ok "sha256 verified"

tar -xzf "${tmpdir}/${asset}" -C "$tmpdir" trivy

if [[ -d $BIN_DIR && -w $BIN_DIR ]]; then
  install -m 0755 "${tmpdir}/trivy" "${BIN_DIR}/trivy"
else
  sudo mkdir -p "$BIN_DIR"
  sudo install -m 0755 "${tmpdir}/trivy" "${BIN_DIR}/trivy"
fi

ok "installed ${BIN_DIR}/trivy"
