#!/bin/bash
set -e

# Entrypoint: downloads an R script from S3, then executes it.
#
# Required environment variables:
#   SCRIPT_NAME           R script filename to download and run (e.g. modeling_mixedPA.R)
#   S3_BUCKET             S3 bucket name (same bucket used for input data)
#   AWS_ACCESS_KEY_ID     AWS / S3-compatible access key
#   AWS_SECRET_ACCESS_KEY AWS / S3-compatible secret key
#   AWS_S3_ENDPOINT       Custom S3 endpoint URL (e.g. s3.waw3-1.cloudferro.com)
#
# Optional environment variables (defaults set in Dockerfile):
#   S3_SCRIPTS_PREFIX    S3 key prefix for scripts (default: scripts)
#   S3_INPUT_PREFIX      S3 key prefix for input data (default: input)
#   S3_OUTPUT_PREFIX     S3 key prefix for output upload (default: output)
#   AWS_DEFAULT_REGION   S3 region (default: waw3-1)
#   AWS_SESSION_TOKEN    Session token if using temporary credentials
#
# Usage: extra CLI arguments are forwarded to Rscript unchanged.

# ---------------------------------------------------------------------------
# Internal defaults (env var defaults are set in the Dockerfile)
# ---------------------------------------------------------------------------
SCRIPTS_LOCAL_DIR="/app/scripts"
S3_SCRIPTS_PREFIX="${S3_SCRIPTS_PREFIX:-scripts}"

# ---------------------------------------------------------------------------
# Validate required env vars
# ---------------------------------------------------------------------------
if [[ -z "${SCRIPT_NAME:-}" ]]; then
    echo "Error: SCRIPT_NAME is not set."
    echo "  Set it with: docker run -e SCRIPT_NAME=modeling_mixedPA.R ..."
    exit 1
fi

if [[ -z "${S3_BUCKET:-}" ]]; then
    echo "Error: S3_BUCKET is not set."
    echo "  Set it with: docker run -e S3_BUCKET=my-bucket ..."
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
# Build the S3 key and optional endpoint argument
# ---------------------------------------------------------------------------
# Strip trailing slash from prefix, then compose key
S3_KEY="$(echo "${S3_SCRIPTS_PREFIX}" | sed 's|/*$||')/${SCRIPT_NAME}"
S3_URI="s3://${S3_BUCKET}/${S3_KEY}"

ENDPOINT_ARG=""
if [[ -n "${AWS_S3_ENDPOINT:-}" ]]; then
    # Prepend https:// if no scheme is present (mirrors R script behaviour)
    if [[ "${AWS_S3_ENDPOINT}" != http* ]]; then
        ENDPOINT_ARG="--endpoint-url https://${AWS_S3_ENDPOINT}"
    else
        ENDPOINT_ARG="--endpoint-url ${AWS_S3_ENDPOINT}"
    fi
fi

# ---------------------------------------------------------------------------
# Download the script from S3
# ---------------------------------------------------------------------------
SCRIPT_PATH="${SCRIPTS_LOCAL_DIR}/${SCRIPT_NAME}"
mkdir -p "${SCRIPTS_LOCAL_DIR}"

echo ">>> Downloading script from S3: ${S3_URI}"
# shellcheck disable=SC2086
aws s3 cp ${ENDPOINT_ARG} "${S3_URI}" "${SCRIPT_PATH}"
echo ">>> Script downloaded to: ${SCRIPT_PATH}"
echo ""

# ---------------------------------------------------------------------------
# Execute the script, forwarding all remaining CLI arguments
# ---------------------------------------------------------------------------
echo ">>> Running: Rscript ${SCRIPT_PATH} $*"
exec Rscript "${SCRIPT_PATH}" "$@"
