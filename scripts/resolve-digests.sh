#!/usr/bin/env bash
#
# Fill missing versions[].digest pins from the mirrored target.
#
# Run this after sync-images has copied the tags to Harbor. The digest is read
# from the target registry, not from the upstream source: that is the object
# consumers will pull. Existing pins are never rewritten; a mismatch is
# reported as drift and fails the run.
#
#   resolve-digests.sh                 # all manifests, write missing pins
#   resolve-digests.sh --category metax
#   resolve-digests.sh --dry-run       # resolve and report, do not write
#
# After a successful run, regenerate index.json with `make index` (or simply
# use `make digests`, which does both).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

CATEGORY=all
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: resolve-digests.sh [options]

  --category NAME   only images/NAME.yaml (default: all)
  --dry-run         resolve and report, but do not modify YAML
  -h, --help        show this help

Requires the target tags to exist (run sync-images first).
EOF
}

while (($#)); do
  case $1 in
    --category) CATEGORY=${2:?--category needs a value}; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

require_cmd jq yq skopeo python3
prepare_authfile
trap cleanup_authfile EXIT

manifest_lines=$(select_manifest_files "$CATEGORY") || die "cannot load manifests"

total=0
added=0
failures=0

resolve_target_digest() {
  local ref=$1 multiarch=$2 digest=''
  local attempt
  for attempt in 1 2 3; do
    if [[ $multiarch == false ]]; then
      digest=$(manifest_amd64_digest "$ref") || digest=''
    else
      digest=$(manifest_digest "$ref") || digest=''
    fi
    [[ -n $digest ]] && break
    sleep 2
  done
  printf '%s' "$digest"
}

while IFS=$'\t' read -r category doc; do
  [[ -n $category ]] || continue
  file="${IMAGES_DIR}/${category}.yaml"
  image_count=$(jq '.spec.images | length' <<<"$doc")

  for ((i = 0; i < image_count; i++)); do
    img_json=$(jq -c --argjson i "$i" '.spec.images[$i]' <<<"$doc")
    name=$(jq -r '.name' <<<"$img_json")
    target=$(jq -r '.target' <<<"$img_json")
    multiarch=$(jq -r --argjson i "$i" \
      'if ((.spec.images[$i].multiarch // .spec.defaults.multiarch) == false)
       then "false" else "true" end' <<<"$doc")
    version_count=$(jq '.versions | length' <<<"$img_json")

    for ((k = 0; k < version_count; k++)); do
      tag=$(jq -r --argjson k "$k" '.versions[$k].tag' <<<"$img_json")
      pinned=$(jq -r --argjson k "$k" '.versions[$k].digest // ""' <<<"$img_json")
      target_ref="${target}:${tag}"
      total=$((total + 1))

      digest=$(resolve_target_digest "$target_ref" "$multiarch")
      if [[ -z $digest ]]; then
        error "${category}/${name}:${tag}: target not resolvable: ${target_ref}"
        error "  run sync-images first, or check target credentials"
        failures=$((failures + 1))
        continue
      fi

      if [[ -n $pinned ]]; then
        if [[ $pinned != "$digest" ]]; then
          error "${category}/${name}:${tag}: digest drift"
          error "  pinned ${pinned}"
          error "  target ${digest}"
          failures=$((failures + 1))
        fi
        continue
      fi

      if [[ $DRY_RUN == true ]]; then
        info "would add ${category}/${name}:${tag} digest ${digest}"
        continue
      fi

      yq -i ".spec.images[${i}].versions[${k}].digest = \"${digest}\"" "$file"
      ok "added ${category}/${name}:${tag} digest ${digest}"
      added=$((added + 1))
    done
  done
done <<<"$manifest_lines"

if ((failures > 0)); then
  error "${failures} version(s) failed; no digest was changed for those entries"
  exit 1
fi

if [[ $DRY_RUN == true ]]; then
  ok "resolved ${total} version(s); no files written"
else
  ok "resolved ${total} version(s); added ${added} digest pin(s)"
fi
