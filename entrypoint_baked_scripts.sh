#!/bin/bash
set -e

SCRIPTS_LOCAL_DIR="/app/scripts"
INPUT_LOCAL_DIR="/app/input"
PARAMS_BASENAME="parameters.txt"

if [[ -z "${SCRIPT_NAME:-}" ]]; then
    echo "Error: SCRIPT_NAME is not set."
    echo "  Set it with: docker run -e SCRIPT_NAME=modelling/01_modeling_mixedPA.R ..."
    exit 1
fi

if [[ "${SCRIPT_NAME}" = /* ]]; then
    SCRIPT_PATH="${SCRIPT_NAME}"
else
    SCRIPT_PATH="${SCRIPTS_LOCAL_DIR}/${SCRIPT_NAME}"
fi

PARAMS_VALUE="${PARAMS:-/app/input/parameters.txt}"
if [[ "${PARAMS_VALUE}" = /* ]]; then
    export PARAMS="${PARAMS_VALUE}"
else
    export PARAMS="${INPUT_LOCAL_DIR}/${PARAMS_VALUE}"
fi

if [[ -z "${S3_BUCKET:-}" ]]; then
    echo "Error: S3_BUCKET is not set."
    exit 1
fi

if [[ -z "${AWS_S3_ENDPOINT:-}" ]]; then
    echo "Error: AWS_S3_ENDPOINT is not set."
    exit 1
fi

if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] || [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    echo "Error: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must both be set."
    exit 1
fi

ENDPOINT_URL="${AWS_S3_ENDPOINT}"
if [[ "${ENDPOINT_URL}" != http* ]]; then
    ENDPOINT_URL="https://${ENDPOINT_URL}"
fi

S3_INPUT_PREFIX_TRIMMED="$(echo "${S3_INPUT_PREFIX:-input}" | sed 's|/*$||')"
if [[ -n "${S3_INPUT_PREFIX_TRIMMED}" ]]; then
    PARAMS_S3_KEY="${S3_INPUT_PREFIX_TRIMMED}/${PARAMS_BASENAME}"
else
    PARAMS_S3_KEY="${PARAMS_BASENAME}"
fi

mkdir -p "$(dirname "${PARAMS}")" "${INPUT_LOCAL_DIR}"

echo ">>> Downloading parameters from S3: s3://${S3_BUCKET}/${PARAMS_S3_KEY} -> ${PARAMS}"
aws s3 cp --endpoint-url "${ENDPOINT_URL}" \
    "s3://${S3_BUCKET}/${PARAMS_S3_KEY}" \
    "${PARAMS}"

if [[ ! -f "${SCRIPT_PATH}" ]]; then
    echo "Error: script not found: ${SCRIPT_PATH}"
    echo "  Available scripts are under: ${SCRIPTS_LOCAL_DIR}"
    exit 1
fi

if [[ ! -f "${PARAMS}" ]]; then
    echo "Error: PARAMS file not found: ${PARAMS}"
    echo "  Expected S3 source: s3://${S3_BUCKET}/${PARAMS_S3_KEY}"
    exit 1
fi

echo ">>> Running baked script: ${SCRIPT_PATH}"
echo ">>> PARAMS file: ${PARAMS}"

exec Rscript "${SCRIPT_PATH}"
