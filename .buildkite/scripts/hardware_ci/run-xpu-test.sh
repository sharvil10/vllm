#!/bin/sh

# This script runs XPU tests for a given test group.
# Usage: run-xpu-test.sh <test-group>
# Groups: offline-basic, offline-distributed, pytest-core-engine,
#         pytest-sample-worker, pytest-spec-structured, pytest-kv-serial
set -ex

TEST_GROUP="${1:?Usage: run-xpu-test.sh <test-group>}"

pip install tblib==3.1.0

case "$TEST_GROUP" in
  offline-basic)
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 --enforce-eager
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 -O3 -cc.cudagraph_mode=NONE
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 --enforce-eager --attention-backend=TRITON_ATTN
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 --enforce-eager --quantization fp8
    python3 examples/offline_inference/basic/generate.py --model superjob/Qwen3-4B-Instruct-2507-GPTQ-Int4 --block-size 64 --enforce-eager
    ;;
  offline-distributed)
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 --enforce-eager -tp 2 --distributed-executor-backend ray
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 --enforce-eager -tp 2 --distributed-executor-backend mp
    python3 examples/offline_inference/basic/generate.py --model ibm-research/PowerMoE-3b --block-size 64 --enforce-eager -tp 2
    python3 examples/offline_inference/basic/generate.py --model ibm-research/PowerMoE-3b --block-size 64 --enforce-eager -tp 2 --enable-expert-parallel
    ;;
  pytest-core-engine)
    cd tests
    pytest -v -s v1/core --ignore=v1/core/test_reset_prefix_cache_e2e.py
    pytest -v -s v1/engine
    ;;
  pytest-sample-worker)
    cd tests
    pytest -v -s v1/sample --ignore=v1/sample/test_logprobs.py --ignore=v1/sample/test_logprobs_e2e.py
    pytest -v -s v1/worker --ignore=v1/worker/test_gpu_model_runner.py
    ;;
  pytest-spec-structured)
    cd tests
    pytest -v -s v1/structured_output
    pytest -v -s v1/spec_decode --ignore=v1/spec_decode/test_max_len.py --ignore=v1/spec_decode/test_tree_attention.py --ignore=v1/spec_decode/test_speculators_eagle3.py --ignore=v1/spec_decode/test_acceptance_length.py
    ;;
  pytest-kv-serial)
    cd tests
    pytest -v -s v1/kv_connector/unit --ignore=v1/kv_connector/unit/test_multi_connector.py --ignore=v1/kv_connector/unit/test_nixl_connector.py --ignore=v1/kv_connector/unit/test_example_connector.py --ignore=v1/kv_connector/unit/test_lmcache_integration.py
    pytest -v -s v1/test_serial_utils.py
    ;;
  *)
    echo "Unknown test group: $TEST_GROUP"
    echo "Valid groups: offline-basic, offline-distributed, pytest-core-engine, pytest-sample-worker, pytest-spec-structured, pytest-kv-serial"
    exit 1
    ;;
esac