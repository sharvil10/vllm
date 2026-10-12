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
# Exports VLLM_XPU_IMAGE / VLLM_COMMIT and uploads each *_intel.yaml in this
# directory (or just the space-separated files in K8S_INTEL_JOBS).
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
export VLLM_XPU_IMAGE="${REGISTRY}/${REPO}:${VLLM_COMMIT}-xpu"
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

for f in "${files[@]}"; do
  echo "Uploading ${f}"
  buildkite-agent pipeline upload "${f}"
done
