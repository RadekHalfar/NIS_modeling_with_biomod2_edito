#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="/app/modeling_mixedPA.R"
LOCAL_INPUT_DIR="${LOCAL_INPUT_DIR:-/app/input}"
S3_INPUT_TARGET_DIR="${S3_INPUT_TARGET_DIR:-/app}"
OUTDIR="${OUTDIR:-${EDITO_INFRA_OUTPUT:-/app/output}}"
AUTO_PULL_INPUTS="${AUTO_PULL_INPUTS:-1}"
AUTO_PUSH_OUTPUTS="${AUTO_PUSH_OUTPUTS:-0}"
USE_DIRECT_ARGS=0

# If full BIOMOD args are provided, keep them, but still run S3 sync first.
if [ "$#" -ge 11 ]; then
  USE_DIRECT_ARGS=1
fi

# Build arguments from environment variables for EDITO one-click launches.
if [ "$USE_DIRECT_ARGS" = "1" ]; then
  SPECIES_NAME="${SPECIES_NAME:-$1}"
else
  SPECIES_NAME="${SPECIES_NAME:?SPECIES_NAME is required when command-line args are not provided}"
fi
ALGORITHMS="${ALGORITHMS:-GLM,GAM,RF,MAXNET}"
PA_DIST_MIN="${PA_DIST_MIN:-2000}"
PA_DIST_MAX="${PA_DIST_MAX:-100000}"
CV_STRATEGY="${CV_STRATEGY:-kfold}"
CV_NB_REP="${CV_NB_REP:-3}"
CV_PERC_OR_NULL="${CV_PERC_OR_NULL:-NULL}"
CV_K_OR_NULL="${CV_K_OR_NULL:-5}"
N_CORES="${N_CORES:-4}"

S3_ENDPOINT_RAW="${S3_ENDPOINT:-${AWS_S3_ENDPOINT:-}}"
S3_BUCKET="${S3_BUCKET:-}"
S3_INPUT_PREFIX="${S3_INPUT_PREFIX:-input}"
ENV_FILE="${ENV_FILE:-}"
ENV_FILE_S3_KEY="${ENV_FILE_S3_KEY:-}"

mkdir -p "$LOCAL_INPUT_DIR" "$S3_INPUT_TARGET_DIR" "$OUTDIR"

configure_mc() {
  local endpoint
  endpoint="$S3_ENDPOINT_RAW"

  if [ -z "$endpoint" ] || [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    return 1
  fi

  if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
    mc alias set s3 "$endpoint" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" --session-token "$AWS_SESSION_TOKEN" --api S3v4 >/dev/null
  else
    mc alias set s3 "$endpoint" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" --api S3v4 >/dev/null
  fi
  return 0
}

if [ "$AUTO_PULL_INPUTS" = "1" ]; then
  if [ -z "$S3_BUCKET" ] && [ -n "${EDITO_USERNAME:-}" ]; then
    S3_BUCKET="oidc-${EDITO_USERNAME}"
  fi

  if configure_mc && [ -n "$S3_BUCKET" ]; then
    if [ -n "$S3_INPUT_PREFIX" ]; then
      echo "Syncing input folder from s3/${S3_BUCKET}/${S3_INPUT_PREFIX} to ${S3_INPUT_TARGET_DIR}"
      mc cp --recursive "s3/${S3_BUCKET}/${S3_INPUT_PREFIX}" "$S3_INPUT_TARGET_DIR" || true
    fi

    if [ -z "$ENV_FILE" ] && [ -n "$ENV_FILE_S3_KEY" ]; then
      ENV_FILE="/app/$(basename "$ENV_FILE_S3_KEY")"
      echo "Fetching env raster from s3/${S3_BUCKET}/${ENV_FILE_S3_KEY}"
      mc cp "s3/${S3_BUCKET}/${ENV_FILE_S3_KEY}" "$ENV_FILE"
    fi
  else
    echo "Skipping S3 input pull: missing S3 endpoint or credentials."
  fi
fi

if [ -z "$ENV_FILE" ]; then
  ENV_FILE="/app/myExpl_shelf_DISTFIX.tif"
fi

set +e
if [ "$USE_DIRECT_ARGS" = "1" ]; then
  Rscript "$SCRIPT_PATH" "$@"
else
  Rscript "$SCRIPT_PATH" \
    "$SPECIES_NAME" \
    "$ALGORITHMS" \
    "$PA_DIST_MIN" \
    "$PA_DIST_MAX" \
    "$CV_STRATEGY" \
    "$CV_NB_REP" \
    "$CV_PERC_OR_NULL" \
    "$CV_K_OR_NULL" \
    "$N_CORES" \
    "$ENV_FILE" \
    "$OUTDIR"
fi
RUN_EXIT=$?
set -e

if [ "$AUTO_PUSH_OUTPUTS" = "1" ] && [ "$RUN_EXIT" -eq 0 ]; then
  S3_OUTPUT_PREFIX="${S3_OUTPUT_PREFIX:-output}"
  if [ -z "$S3_BUCKET" ] && [ -n "${EDITO_USERNAME:-}" ]; then
    S3_BUCKET="oidc-${EDITO_USERNAME}"
  fi

  if configure_mc && [ -n "$S3_BUCKET" ]; then
    echo "Pushing output folder to s3/${S3_BUCKET}/${S3_OUTPUT_PREFIX}"
    mc cp --recursive "$OUTDIR" "s3/${S3_BUCKET}/${S3_OUTPUT_PREFIX}" || true
  fi
fi

exit "$RUN_EXIT"
