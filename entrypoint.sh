#!/bin/bash
set -e

SCRIPTS_LOCAL_DIR="/app/scripts"

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

PARAMS_VALUE="${PARAMS:-parameters.txt}"
if [[ "${PARAMS_VALUE}" = /* ]]; then
    export PARAMS="${PARAMS_VALUE}"
else
    export PARAMS="${SCRIPTS_LOCAL_DIR}/${PARAMS_VALUE}"
fi

if [[ ! -f "${SCRIPT_PATH}" ]]; then
    echo "Error: script not found: ${SCRIPT_PATH}"
    echo "  Available scripts are under: ${SCRIPTS_LOCAL_DIR}"
    exit 1
fi

if [[ ! -f "${PARAMS}" ]]; then
    echo "Error: PARAMS file not found: ${PARAMS}"
    echo "  Set PARAMS to a file under ${SCRIPTS_LOCAL_DIR} or an absolute path."
    exit 1
fi

echo ">>> Running baked script: ${SCRIPT_PATH}"
echo ">>> PARAMS file: ${PARAMS}"

exec Rscript "${SCRIPT_PATH}"
