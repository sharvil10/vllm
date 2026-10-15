#!/usr/bin/env bash
# Upload the Kubernetes-native Intel XPU test pipelines.
#
# Only the *test* stage runs on our cluster. The image is the one upstream
# vLLM CI's `image-build-xpu` step already pushed for the commit, so this
# script never builds anything; it just picks which upstream image to test:
#
#   - VLLM_COMMIT (build env, full 40-char SHA) if set. Works for any commit
#     upstream CI built, including PR heads (premerge images share the repo).
#   - Otherwise the newest commit in this branch's history that has an
#     image. Our own .buildkite/k8s_intel_jobs commits never do, so this
#     lands on the upstream main commit the branch was last synced to.
#
# Needs enough history to walk back: the upload step clones with --depth=100.
#
# VLLM_IMAGE_MIRROR (e.g. ghcr.io/sharvil10/vllm-ci-test-repo) makes the Pods
# pull <mirror>:<sha>-xpu instead. The cluster's NAT IP can hit ECR Public's
# anonymous "Data limit exceeded" (429) on blob pulls; the image still has to
# exist upstream, and has to be copied to the mirror out of band.
#
# Exports VLLM_XPU_IMAGE / VLLM_COMMIT and uploads each *_intel.yaml in this
# directory (or just the space-separated files in K8S_INTEL_JOBS).
#
# Step selection follows upstream's generator (see select_steps.py): steps
# whose source_file_dependencies don't match the files VLLM_COMMIT changes,
# and `optional: true` steps, are uploaded behind a block step. The diff is
# against VLLM_COMMIT's merge-base with upstream main, or its parent if it is
# on main (like upstream's HEAD~1). Build env RUN_ALL=1 runs everything but
# optional steps, NIGHTLY=1 runs everything, NOAUTO=1 blocks everything.
set -euo pipefail

REGISTRY="public.ecr.aws/q9t5s3a7"
REPO="vllm-ci-test-repo"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

token=$(curl -fsS --retry 5 \
  "https://public.ecr.aws/token/?scope=repository:${REGISTRY#*/}/${REPO}:pull" |
  sed -E 's/.*"token":"([^"]+)".*/\1/')

has_image() {
  # curl --retry covers ECR public's anonymous 429 rate limit.
  curl -fsS -o /dev/null --head --retry 5 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://public.ecr.aws/v2/${REGISTRY#*/}/${REPO}/manifests/$1-xpu" 2>/dev/null
}

if [[ -n "${VLLM_COMMIT:-}" ]]; then
  if [[ ! "${VLLM_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "VLLM_COMMIT must be a full 40-char SHA (image tags use the full SHA)" >&2
    exit 1
  fi
  if ! has_image "${VLLM_COMMIT}"; then
    echo "No upstream XPU image for ${VLLM_COMMIT}: ${REGISTRY}/${REPO}:${VLLM_COMMIT}-xpu" >&2
    exit 1
  fi
else
  VLLM_COMMIT=""
  for c in $(git log --format=%H -n 100 HEAD); do
    if has_image "${c}"; then
      VLLM_COMMIT="${c}"
      break
    fi
  done
  if [[ -z "${VLLM_COMMIT}" ]]; then
    echo "No upstream XPU image for any of the last 100 commits; set VLLM_COMMIT" >&2
    exit 1
  fi
fi

export VLLM_COMMIT
export VLLM_XPU_IMAGE="${VLLM_IMAGE_MIRROR:-${REGISTRY}/${REPO}}:${VLLM_COMMIT}-xpu"
echo "Testing upstream commit ${VLLM_COMMIT}"
echo "Image: ${VLLM_XPU_IMAGE}"

buildkite-agent meta-data set vllm-commit "${VLLM_COMMIT}"
buildkite-agent annotate --style info --context vllm-image \
  "Testing upstream [\`${VLLM_COMMIT:0:12}\`](https://github.com/vllm-project/vllm/commit/${VLLM_COMMIT}) with image \`${VLLM_XPU_IMAGE}\`"

if [[ -n "${K8S_INTEL_JOBS:-}" ]]; then
  read -ra files <<< "${K8S_INTEL_JOBS}"
  files=("${files[@]/#/${DIR}/}")
else
  files=("${DIR}"/*_intel.yaml)
fi

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

changed_files() {
  local up="${tmp}/upstream" base
  git init -q --bare "${up}"
  # Treeless: commits only (~20 MB); diff fetches the two trees it needs.
  git -C "${up}" fetch -q --filter=tree:0 --no-tags \
    https://github.com/vllm-project/vllm.git +refs/heads/main:refs/heads/main "$1" || return
  base=$(git -C "${up}" merge-base main "$1") || return
  if [[ "${base}" == "$1" ]]; then
    base="$1~1"
  fi
  git -C "${up}" diff --name-only --diff-filter=ACMDR "${base}" "$1"
}

: > "${tmp}/diff.txt"
if [[ "${NIGHTLY:-0}" != "1" && "${RUN_ALL:-0}" != "1" && "${NOAUTO:-0}" != "1" ]]; then
  if ! changed_files "${VLLM_COMMIT}" > "${tmp}/diff.txt"; then
    # Same fallback as upstream's bootstrap when it can't find a merge-base.
    echo "WARNING: could not diff ${VLLM_COMMIT} against upstream main; RUN_ALL=1" >&2
    export RUN_ALL=1
  fi
  echo "Changed files in ${VLLM_COMMIT:0:12}:"
  cat "${tmp}/diff.txt"
fi

# `pipeline upload --dry-run` resolves anchors and interpolates ${VLLM_XPU_IMAGE}
# / $$, so the final upload below must not interpolate again.
mkdir "${tmp}/in" "${tmp}/out"
buildkite-agent pipeline upload --dry-run --format json \
  "${DIR}/../ci_config_intel.yaml" > "${tmp}/config.json"
for f in "${files[@]}"; do
  buildkite-agent pipeline upload --dry-run --format json "${f}" \
    > "${tmp}/in/$(basename "${f}" .yaml).json"
done
python3 "${DIR}/select_steps.py" --config "${tmp}/config.json" \
  --diff "${tmp}/diff.txt" --summary "${tmp}/summary.md" \
  --source-dir .buildkite/k8s_intel_jobs "${tmp}/in" "${tmp}/out"
buildkite-agent annotate --style info --context step-selection < "${tmp}/summary.md"

for f in "${tmp}"/out/*.json; do
  echo "Uploading $(basename "${f}" .json).yaml"
  buildkite-agent pipeline upload --no-interpolation "${f}"
done
