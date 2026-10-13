# Kubernetes-native Intel XPU CI

Ports of upstream `.buildkite/intel_jobs/*.yaml` to the vllm-ci cluster
(8x Arc Pro B70 on `vllm-ci-116`). Only the **test** stage runs here. Images
come from upstream CI's `image-build-xpu` step, and nothing is built on our
side.

- Buildkite pipeline: https://buildkite.com/sharvil-shah/vllm-intel-k8s
  (branches `k8s-ci`, `k8s-ci-*`; agent-stack-k8s controller on queue
  `intel-b70`, namespace `vllm-ci`).
- `upload.sh` resolves the image (`VLLM_COMMIT`, `VLLM_IMAGE_MIRROR`) and
  uploads every `*_intel.yaml` here, or only the space-separated file names
  in build env `K8S_INTEL_JOBS`.
- Image pinned for now: the cluster's NAT IP is over ECR Public's anonymous
  data cap, so the pipeline's upload step defaults to upstream commit
  `fe341a53dda0…` copied to `ghcr.io/sharvil10/vllm-ci-test-repo` (private,
  pulled with `imagePullSecrets: ghcr-push`). That is the commit of upstream's
  "Full intel CI-daily" build #13969, which runs every step (per-commit
  intel-ci builds skip steps whose `source_file_dependencies` didn't change).

## Converting a workflow

Copy `kernels_intel.yaml` as the template: keep its `.env` and `.k8s-*` anchors
verbatim, then for each upstream step:

| upstream | here |
| --- | --- |
| `group: X` + top-level `steps:` | `steps: [ {group: X, key: <file-stem>, steps: [...]} ]` (`pipeline upload` needs `steps:` at the top) |
| `depends_on: image-build-xpu`, `device`, `no_plugin`, `working_dir`, `source_file_dependencies`, `agent_tags` | drop them |
| `agent_tags.gpu: N+` | anchor `.k8s-Ngpu` using `resourceClaimTemplateName: b70-N` (templates exist for 1/2/4/8) |
| `env: REGISTRY/REPO/VLLM_TEST_DEVICE` | `env: *env` (merge extra step env with `<<: *env`) |
| `timeout_in_minutes`, `label`, `key`, `parallelism`, `soft_fail`, `retry` | keep as-is |
| `bash .buildkite/scripts/hardware_ci/run-intel-test.sh '<cmds>'` | `commands:` list. First item is `cd /workspace/vllm/tests` (or `cd /workspace/vllm` if the upstream string doesn't `cd tests`). Then the `&&`-separated commands, one per item |
| `parallelism: N` | run-intel-test.sh's sharding is lost, so add `PYTEST_ADDOPTS="--num-shards=$$BUILDKITE_PARALLEL_JOB_COUNT --shard-id=$$BUILDKITE_PARALLEL_JOB"` to the pytest command (`$$` escapes upload-time interpolation) |

Rules that bite:

- Commands run under the image's `/bin/sh` (dash) with `-e`. `BUILDKITE_SHELL`
  is protected, so step env can't change it. Wrap bashisms (`source`,
  `[[ ]]`, `pipefail`, arrays) in `bash -c '...'`.
- The bootstrap `cd`s to the empty checkout dir and ignores `workingDir`, so
  always `cd /workspace/vllm...` first.
- agent-stack-k8s mounts an emptyDir over `/workspace`. The `copy-vllm-src`
  init container restores the image's `/workspace/vllm`. Don't remove it.
- Every `$` in commands is interpolated at upload time, so use `$$VAR` for
  runtime variables.
- TP>=4 on these PCIe-only B70s needs `CCL_TOPO_FABRIC_VERTEX_CONNECTION_CHECK=0`.
- `HF_TOKEN` comes from Secret `vllm-ci/hf-token` (created out of band, not in
  git) through the container `env` in the pod template, which gives access to
  gated meta-llama models. The HF cache is the node-local hostPath
  `/var/lib/hf-cache`.
- Name files `<stem>_intel.yaml` so the upload glob picks them up.
- Every file is uploaded into one build, so step and group keys must be unique
  across all files, and a group key can't reuse one of its step keys.
- Upstream's `optional: true` is a field for its own pipeline generator, not
  Buildkite; map it to `soft_fail: true`.
- Multi-GPU templates (`.k8s-2gpu`, `.k8s-4gpu`) are the 1-GPU template with
  `b70-N` and larger memory limits.

Test one file in isolation from a `k8s-ci-<name>` branch:

```bash
curl -X POST -H "Authorization: Bearer $BK_TOKEN" \
  https://api.buildkite.com/v2/organizations/sharvil-shah/pipelines/vllm-intel-k8s/builds \
  -d '{"commit":"HEAD","branch":"k8s-ci-<name>","env":{"K8S_INTEL_JOBS":"<file>_intel.yaml"}}'
```

## Status

Pass criterion: match upstream's result for the same commit. Upstream Intel
tests run in https://buildkite.com/vllm/intel-ci, also on B70s. Compare
against the scheduled "Full intel CI-daily" build: per-commit intel-ci builds
skip steps whose `source_file_dependencies` didn't change, so they leave gaps.

**`fe341a53dd` vs daily intel-ci #13969: 63/63 jobs match (all pass).**
Full run: https://buildkite.com/sharvil-shah/vllm-intel-k8s/builds/14 (15
files, 56 steps, 63 jobs incl. parallel shards; about 2h on 8 B70s).

Three jobs needed a retry within that build; none was a conversion problem:

| step | first attempt | cause |
| --- | --- | --- |
| Engine (1 GPU) | 2 failed, 403 | `meta-llama/Meta-Llama-3-8B-Instruct` license not yet accepted on the hf-token account |
| API Server Generate | 1 failed | `test_chat_completion_without_tools[hermes]`: streamed and non-streamed text differed; passed on retry (flaky) |
| XPU GPQA Eval (GPT-OSS) | 1 failed | DNS: nodelocaldns forwards only to 8.8.8.8/8.8.4.4, which time out intermittently (~300 timeouts in 4h) |
