#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_DIR="$(cd "${REPO_DIR}/.." && pwd)"

TAG=""
MODEL_ID=""
MODEL_REVISION="main"
BAKE_MODEL="false"
PUSH_IMAGE="false"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="$2"
      shift 2
      ;;
    --model-id)
      MODEL_ID="$2"
      shift 2
      ;;
    --model-revision)
      MODEL_REVISION="$2"
      shift 2
      ;;
    --bake-model)
      BAKE_MODEL="true"
      shift
      ;;
    --push)
      PUSH_IMAGE="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${TAG}" ]]; then
  echo "--tag is required" >&2
  exit 1
fi

if [[ "${BAKE_MODEL}" == "true" && -z "${MODEL_ID}" ]]; then
  echo "--model-id is required when --bake-model is set" >&2
  exit 1
fi

if [[ ! -d "${WORKSPACE_DIR}/rvllm" ]]; then
  echo "expected sibling rvllm directory at ${WORKSPACE_DIR}/rvllm" >&2
  exit 1
fi

BUILD_ROOT="$(mktemp -d)"
trap 'rm -rf "${BUILD_ROOT}"' EXIT

mkdir -p "${BUILD_ROOT}/rvLLM-serverless" "${BUILD_ROOT}/rvllm"
cp -R "${REPO_DIR}/." "${BUILD_ROOT}/rvLLM-serverless/"
cp -R "${WORKSPACE_DIR}/rvllm/." "${BUILD_ROOT}/rvllm/"

BUILD_CMD=(
  docker build
  -f "${BUILD_ROOT}/rvLLM-serverless/Dockerfile"
  -t "${TAG}"
  --build-arg "BAKE_MODEL=${BAKE_MODEL}"
  --build-arg "MODEL_ID=${MODEL_ID}"
  --build-arg "MODEL_REVISION=${MODEL_REVISION}"
)

if [[ -n "${HF_TOKEN:-}" ]]; then
  BUILD_CMD+=(--secret id=HF_TOKEN,env=HF_TOKEN)
fi

BUILD_CMD+=("${BUILD_ROOT}")

echo "Building ${TAG}"
if [[ "${DRY_RUN}" == "true" ]]; then
  printf 'Dry run command:\n'
  printf '  %q' "${BUILD_CMD[@]}"
  printf '\n'
  exit 0
fi

"${BUILD_CMD[@]}"

if [[ "${PUSH_IMAGE}" == "true" ]]; then
  docker push "${TAG}"
fi
