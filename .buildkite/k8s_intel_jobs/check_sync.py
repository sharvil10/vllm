#!/usr/bin/env python3
"""Report drift between upstream .buildkite/intel_jobs and these K8s ports.

Every upstream step (except image-build-xpu, which we never run) must have a
port here with the same key, and the port must carry over everything that
isn't runner-specific: group, label, timeout_in_minutes, parallelism,
soft_fail, optional, source_file_dependencies, test env, GPU count
(`agent_tags.gpu: N+` -> ResourceClaimTemplate b70-N) and the commands.

Commands are compared after undoing the conversion rules in README.md:
upstream's run-intel-test.sh '<a> && <b>' becomes [a, b], our leading
`cd /workspace/vllm...` maps to upstream's `cd tests` (or nothing), and `$$`
is upload-time escaping. Intentional differences go in DEVIATIONS.

Stdlib only, like select_steps.py: both sides are converted to JSON first
with `buildkite-agent pipeline upload --dry-run --no-interpolation --format
json`. Usage:

  check_sync.py UPSTREAM_JSON_DIR K8S_JSON_DIR

Prints one line per difference and exits 1 if there are any.
"""

import json
import os
import re
import sys

SKIP_KEYS = {"image-build-xpu"}

# Upstream env that only run-intel-test.sh / docker uses.
RUNNER_ENV = {"REGISTRY", "REPO"}

# Steps whose commands intentionally differ: step key -> (why, the upstream
# commands the port was written against, normalized). If upstream's commands
# move away from that list the step is reported, so the port gets re-checked.
DEVIATIONS = {
    "lora-punica-kernels": (
        "`set -o pipefail` dropped: commands run under dash, and there is no pipe",
        [
            "export VLLM_WORKER_MULTIPROC_METHOD=spawn",
            "set -o pipefail",
            "pytest -v -s lora/test_punica_ops.py::test_kernels",
            "pytest -v -s lora/test_punica_ops.py::test_kernels_hidden_size",
            "pytest -v -s lora/test_punica_ops.py::test_add_lora_fused_moe_early_exit",
        ],
    ),
    "multi-modal-models-standard-3-llava-qwen2-vl": (
        "upstream is missing `&&` before test_qwen2_vl.py; ours runs it as its own command",
        [
            'pytest -v -s models/multimodal/generation/test_common.py -m core_model'
            ' -k "not qwen2 and not qwen3 and not gemma"',
            "pytest -v -s models/multimodal/generation/test_gemma_ragged_audio.py -m core_model"
            " pytest -v -s models/multimodal/generation/test_qwen2_vl.py -m core_model",
        ],
    ),
}

RUN_INTEL_TEST = re.compile(
    r"^bash \.buildkite/scripts/hardware_ci/run-intel-test\.sh\s+'(.*)'\s*$", re.S
)


def _split(commands):
    """Shell commands as a flat list: one per line and per `&&`."""
    out = []
    for cmd in commands:
        for part in re.split(r"&&|\n", cmd.replace("$$", "$")):
            part = re.sub(r"\s+", " ", part).strip()
            if part:
                out.append(part)
    return out


def _drop_cds(commands):
    # Upstream runs from the repo root (`cd tests` to go in); ours cd's to
    # the absolute path. Map ours back to repo-relative and drop the moves
    # into tests/ and the root, which only exist on one side.
    out = []
    for c in commands:
        c = re.sub(r"^cd /workspace/vllm/", "cd ", c)
        if c not in ("cd tests", "cd /workspace/vllm"):
            out.append(c)
    return out


def upstream_commands(step):
    commands = step.get("commands") or [step.get("command", "")]
    unwrapped = []
    for cmd in commands:
        m = RUN_INTEL_TEST.match(cmd.strip())
        unwrapped.append(m.group(1) if m else cmd)
    return _drop_cds(_split(unwrapped))


def k8s_commands(step):
    commands = _split(step.get("commands") or [step.get("command", "")])
    # Sharding that run-intel-test.sh did for `parallelism` (README.md).
    commands = [re.sub(r'^(export )?PYTEST_ADDOPTS="--num-shards=[^"]*" ?', "", c) for c in commands]
    return _drop_cds([c for c in commands if c])


def gpus(step):
    tag = (step.get("agent_tags") or {}).get("gpu", "")
    return int(tag.rstrip("+")) if tag else None


def k8s_gpus(step):
    for plugin in step.get("plugins") or []:
        # `pipeline upload` expands `kubernetes` to its full plugin source.
        config = next(iter(plugin.values()), {}) if isinstance(plugin, dict) else {}
        for claim in config.get("podSpec", {}).get("resourceClaims", []):
            m = re.match(r"^b70-(\d+)$", claim.get("resourceClaimTemplateName", ""))
            if m:
                return int(m.group(1))
    return None


def load(json_dir, nested):
    """key -> (file, group, step). Upstream files are one group per file."""
    steps = {}
    for name in sorted(os.listdir(json_dir)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(json_dir, name)) as f:
            data = json.load(f)
        groups = data["steps"] if nested else [data]
        for group in groups:
            for step in group.get("steps", []):
                if step.get("key") not in SKIP_KEYS:
                    steps[step.get("key")] = (name, group.get("group"), step)
    return steps


def compare(upstream, ours):
    problems = []
    for key in sorted(set(upstream) - set(ours)):
        problems.append(f"{key}: missing here (upstream {upstream[key][0]})")
    for key in sorted(set(ours) - set(upstream)):
        problems.append(f"{key}: not in upstream intel_jobs ({ours[key][0]})")
    for key in sorted(set(upstream) & set(ours)):
        _, up_group, up = upstream[key]
        _, our_group, our = ours[key]

        def diff(what, a, b):
            if a != b:
                problems.append(f"{key}: {what}: upstream {a!r}, here {b!r}")

        diff("group", up_group, our_group)
        for field in ("label", "timeout_in_minutes", "parallelism", "retry"):
            diff(field, up.get(field), our.get(field))
        for field in ("soft_fail", "optional"):
            diff(field, bool(up.get(field)), bool(our.get(field)))
        diff("source_file_dependencies", up.get("source_file_dependencies"),
             our.get("source_file_dependencies"))
        diff("gpus", gpus(up), k8s_gpus(our))
        up_env = {k: v for k, v in (up.get("env") or {}).items() if k not in RUNNER_ENV}
        our_env = our.get("env") or {}
        diff("env", up_env, {k: our_env.get(k) for k in up_env if k in our_env})
        if key in DEVIATIONS:
            diff(f"commands changed since the port ({DEVIATIONS[key][0]})",
                 DEVIATIONS[key][1], upstream_commands(up))
        else:
            diff("commands", upstream_commands(up), k8s_commands(our))
    return problems


def main():
    problems = compare(load(sys.argv[1], nested=False), load(sys.argv[2], nested=True))
    for p in problems:
        print(p)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
