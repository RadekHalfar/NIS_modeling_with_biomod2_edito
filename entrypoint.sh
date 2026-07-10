#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# EDITO process-container entrypoint: S3 connection + sync + run.
#
# Pattern: discover the caller's S3 bucket from EDITO's auto-injected
# credentials, sync the scripts/data prefix down from S3 (so the workload can
# be updated without rebuilding the image), then exec the workload.
#
# Required environment variables (auto-injected by EDITO for a process
# container - see docs.dive.edito.eu/articles/contribute/process-playground.html):
#   SCRIPT_NAME           R script filename to run, relative to the scripts
#                         folder (e.g. modelling/01_modeling_mixedPA.R)
#   AWS_ACCESS_KEY_ID     S3-compatible access key
#   AWS_SECRET_ACCESS_KEY S3-compatible secret key
#   AWS_S3_ENDPOINT       Custom S3 endpoint URL (e.g. s3.waw3-1.cloudferro.com)
#
# S3_BUCKET is not read as an env var: it is always auto-discovered below via
# `aws s3api list-buckets`, since the injected credentials are scoped to the
# launching user's own bucket - listing buckets with them returns exactly
# that bucket, with no need to know the username or bucket name in advance.
#
# Optional environment variables (defaults set in Dockerfile):
#   S3_SCRIPTS_PREFIX     S3 key prefix for scripts folder (default: scripts)
#   AWS_SESSION_TOKEN     Session token if using temporary credentials
#   PARAMS                Path to params file (default: <SCRIPTS_LOCAL_DIR>/PARAMS)
# ---------------------------------------------------------------------------

RUNTIME_CMD="Rscript"
SCRIPTS_LOCAL_DIR="/app/scripts"

S3_SCRIPTS_PREFIX="${S3_SCRIPTS_PREFIX:-scripts}"

# ---------------------------------------------------------------------------
# Validate required env vars
# ---------------------------------------------------------------------------
if [[ -z "${SCRIPT_NAME:-}" ]]; then
    echo "Error: SCRIPT_NAME is not set."
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

# ---------------------------------------------------------------------------
# Build the --endpoint-url argument (prepend https:// if no scheme present)
# ---------------------------------------------------------------------------
ENDPOINT_ARG=""
if [[ -n "${AWS_S3_ENDPOINT:-}" ]]; then
    if [[ "${AWS_S3_ENDPOINT}" != http* ]]; then
        ENDPOINT_ARG="--endpoint-url https://${AWS_S3_ENDPOINT}"
    else
        ENDPOINT_ARG="--endpoint-url ${AWS_S3_ENDPOINT}"
    fi
fi

# ---------------------------------------------------------------------------
# Auto-discover the S3 bucket. No bucket-name or username env var is read:
# the credentials validated above are enough to list the caller's own
# bucket(s).
# ---------------------------------------------------------------------------
echo ">>> Discovering S3 bucket via 'aws s3api list-buckets'..."
# shellcheck disable=SC2086
bucket_list="$(aws s3api list-buckets ${ENDPOINT_ARG} --query 'Buckets[].Name' --output text)"
bucket_count="$(wc -w <<< "${bucket_list}")"

if [[ "${bucket_count}" -eq 1 ]]; then
    export S3_BUCKET="${bucket_list}"
    echo ">>> Discovered S3 bucket: ${S3_BUCKET}"
elif [[ "${bucket_count}" -gt 1 ]]; then
    echo "Error: bucket discovery found multiple buckets (${bucket_list}); this entrypoint expects exactly one."
    exit 1
else
    echo "Error: bucket discovery via 'aws s3api list-buckets' returned no buckets for the injected credentials."
    exit 1
fi

# ---------------------------------------------------------------------------
# Sync the entire scripts prefix from S3.
# This downloads SCRIPT_NAME, PARAMS, and any helper files.
# ---------------------------------------------------------------------------
SCRIPT_PATH="${SCRIPTS_LOCAL_DIR}/${SCRIPT_NAME}"
S3_SCRIPTS_URI="s3://${S3_BUCKET}/$(echo "${S3_SCRIPTS_PREFIX}" | sed 's|/*$||')/"
mkdir -p "${SCRIPTS_LOCAL_DIR}"

echo ">>> Syncing scripts folder from S3: ${S3_SCRIPTS_URI} -> ${SCRIPTS_LOCAL_DIR}/"
# shellcheck disable=SC2086
aws s3 sync ${ENDPOINT_ARG} "${S3_SCRIPTS_URI}" "${SCRIPTS_LOCAL_DIR}/"
echo ">>> Sync complete"

if [[ ! -f "${SCRIPT_PATH}" ]]; then
    echo "Error: SCRIPT_NAME '${SCRIPT_NAME}' not found in ${SCRIPTS_LOCAL_DIR} after sync."
    echo "  Check that s3://${S3_BUCKET}/${S3_SCRIPTS_PREFIX}/${SCRIPT_NAME} exists."
    exit 1
fi

export PARAMS="${PARAMS:-${SCRIPTS_LOCAL_DIR}/PARAMS}"
echo ">>> PARAMS file: ${PARAMS}"

# ---------------------------------------------------------------------------
# Execute the workload
# ---------------------------------------------------------------------------
echo ">>> Running: ${RUNTIME_CMD} ${SCRIPT_PATH}"
exec ${RUNTIME_CMD} "${SCRIPT_PATH}"
