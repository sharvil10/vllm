#!/bin/sh

# This script runs a single XPU test identified by name.
# Usage: run-xpu-test.sh <test-name>
set -ex

TEST_NAME="${1:?Usage: run-xpu-test.sh <test-name>}"

pip install tblib==3.1.0

case "$TEST_NAME" in
  opt125m-eager)
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 --enforce-eager
    ;;
  opt125m-O3)
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 -O3 -cc.cudagraph_mode=NONE
    ;;
  opt125m-ray-tp2)
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 --enforce-eager -tp 2 --distributed-executor-backend ray
    ;;
  opt125m-mp-tp2)
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 --enforce-eager -tp 2 --distributed-executor-backend mp
    ;;
  opt125m-triton)
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 --enforce-eager --attention-backend=TRITON_ATTN
    ;;
  opt125m-fp8)
    python3 examples/offline_inference/basic/generate.py --model facebook/opt-125m --block-size 64 --enforce-eager --quantization fp8
    ;;
  qwen3-gptq)
    python3 examples/offline_inference/basic/generate.py --model superjob/Qwen3-4B-Instruct-2507-GPTQ-Int4 --block-size 64 --enforce-eager
    ;;
  powermoe-tp2)
    python3 examples/offline_inference/basic/generate.py --model ibm-research/PowerMoE-3b --block-size 64 --enforce-eager -tp 2
    ;;
  powermoe-expert-parallel)
    python3 examples/offline_inference/basic/generate.py --model ibm-research/PowerMoE-3b --block-size 64 --enforce-eager -tp 2 --enable-expert-parallel
    ;;
  pytest-v1-core)
    cd tests
    pytest -v -s v1/core --ignore=v1/core/test_reset_prefix_cache_e2e.py
    ;;
  pytest-v1-engine)
    cd tests
    pytest -v -s v1/engine
    ;;
  pytest-v1-sample)
    cd tests
    pytest -v -s v1/sample --ignore=v1/sample/test_logprobs.py --ignore=v1/sample/test_logprobs_e2e.py
    ;;
  pytest-v1-worker)
    cd tests
    pytest -v -s v1/worker --ignore=v1/worker/test_gpu_model_runner.py
    ;;
  pytest-v1-structured-output)
    cd tests
    pytest -v -s v1/structured_output
    ;;
  pytest-v1-spec-decode)
    cd tests
    pytest -v -s v1/spec_decode --ignore=v1/spec_decode/test_max_len.py --ignore=v1/spec_decode/test_tree_attention.py --ignore=v1/spec_decode/test_speculators_eagle3.py --ignore=v1/spec_decode/test_acceptance_length.py
    ;;
  pytest-v1-kv-connector)
    cd tests
    pytest -v -s v1/kv_connector/unit --ignore=v1/kv_connector/unit/test_multi_connector.py --ignore=v1/kv_connector/unit/test_nixl_connector.py --ignore=v1/kv_connector/unit/test_example_connector.py --ignore=v1/kv_connector/unit/test_lmcache_integration.py
    ;;
  pytest-v1-serial-utils)
    cd tests
    pytest -v -s v1/test_serial_utils.py
    ;;
  *)
    echo "Unknown test: $TEST_NAME"
    exit 1
    ;;
esac