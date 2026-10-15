#!/usr/bin/env python3
"""Apply upstream's step-selection fields to the k8s_intel_jobs pipelines.

The job files keep upstream's `source_file_dependencies` and `optional`
verbatim. Buildkite doesn't know either field: upstream's pipeline generator
(vllm-project/ci-infra, buildkite/pipeline_generator) consumes them. This
mirrors its `_step_should_run`, in order:

  NOAUTO=1                    -> block every step
  NIGHTLY=1                   -> run
  optional: true              -> block
  run all                     -> run (RUN_ALL=1, or a changed file matches
                                 run_all_patterns in ci_config_intel.yaml)
  source_file_dependencies    -> run if a changed file is under an entry
                                 ("!" entries exclude), plus the job file
                                 itself; otherwise block

A blocked step stays in the build behind a `block: Run <label>` step, the
same as upstream, so it can still be unblocked by hand.

Stdlib only: the upload step's agent image has python3 but no PyYAML, so
upload.sh converts YAML to JSON with `buildkite-agent pipeline upload
--dry-run --format json` first. Usage:

  select_steps.py --config CFG.json --diff DIFF.txt --summary OUT.md \
      --source-dir .buildkite/k8s_intel_jobs IN_DIR OUT_DIR

reads IN_DIR/<stem>.json and writes OUT_DIR/<stem>.json for each job file.
"""

import argparse
import json
import os
import re


def _matches(dependency, path):
    dependency = dependency.rstrip("/")
    return bool(dependency) and (path == dependency or path.startswith(dependency + "/"))


def deps_match(dependencies, diff):
    includes = [d for d in dependencies if not d.startswith("!")]
    excludes = [d[1:] for d in dependencies if d.startswith("!")]
    return any(
        any(_matches(i, f) for i in includes) and not any(_matches(e, f) for e in excludes)
        for f in diff
    )


def run_all_reason(config, diff):
    if os.getenv("RUN_ALL") == "1":
        return "RUN_ALL=1"
    patterns = config.get("run_all_patterns") or []
    excludes = config.get("run_all_exclude_patterns") or []
    for f in diff:
        if any(re.match(p, f) for p in patterns) and not any(re.match(p, f) for p in excludes):
            return f"`{f}` matches run_all_patterns"
    return None


def should_run(step, run_all, diff, source):
    if os.getenv("NOAUTO") == "1":
        return False
    if os.getenv("NIGHTLY") == "1":
        return True
    if step.get("optional"):
        return False
    if run_all:
        return True
    return deps_match((step.get("source_file_dependencies") or []) + [source], diff)


def select(pipeline, run_all, diff, source, ran, blocked):
    for group in pipeline["steps"]:
        steps = []
        for step in group.get("steps", []):
            run = should_run(step, run_all, diff, source)
            step.pop("optional", None)
            step.pop("source_file_dependencies", None)
            depends_on = step.get("depends_on") or []
            if isinstance(depends_on, str):
                depends_on = [depends_on]
            if run:
                ran.append(step["label"])
            else:
                block_key = f"block-{step['key']}"
                steps.append({"block": f"Run {step['label']}", "key": block_key, "depends_on": []})
                depends_on = [block_key] + depends_on
                blocked.append(step["label"])
            # Explicit (even empty) depends_on keeps a block step from acting
            # as a barrier for the steps after it, as upstream's steps do.
            step["depends_on"] = depends_on
            steps.append(step)
        group["steps"] = steps
    return pipeline


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--diff", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("in_dir")
    parser.add_argument("out_dir")
    args = parser.parse_args()

    with open(args.config) as f:
        config = json.load(f)
    with open(args.diff) as f:
        diff = [line.strip() for line in f if line.strip()]
    run_all = run_all_reason(config, diff)

    ran, blocked = [], []
    for name in sorted(os.listdir(args.in_dir)):
        stem, ext = os.path.splitext(name)
        if ext != ".json":
            continue
        with open(os.path.join(args.in_dir, name)) as f:
            pipeline = json.load(f)
        source = f"{args.source_dir}/{stem}.yaml"
        with open(os.path.join(args.out_dir, name), "w") as f:
            json.dump(select(pipeline, run_all, diff, source, ran, blocked), f, indent=2)

    if os.getenv("NOAUTO") == "1":
        mode = "NOAUTO=1: every step blocked"
    elif os.getenv("NIGHTLY") == "1":
        mode = "NIGHTLY=1: every step runs, including optional ones"
    elif run_all:
        mode = f"run all ({run_all}); optional steps blocked"
    else:
        mode = f"{len(diff)} changed file(s) matched against source_file_dependencies"
    lines = [f"**Step selection:** {mode}. {len(ran)} run, {len(blocked)} blocked."]
    if blocked:
        lines += ["", "<details><summary>Blocked (unblock to run)</summary>", ""]
        lines += [f"- {label}" for label in blocked]
        lines += ["", "</details>"]
    with open(args.summary, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
