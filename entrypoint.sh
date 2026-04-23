#!/bin/bash
set -e

# Wrapper script to run R scripts from mounted volume only.
# Required: /app/scripts must be mounted as volume.
#
# Configuration (priority: CLI arg > env var > default):
#   SCRIPTS_DIR        Folder where scripts are mounted (default: /app/scripts)
#   SCRIPT_NAME        R script filename to execute
#   HOST_SCRIPTS_DIR   Host-side path passed via -e for logging purposes only
#
# Usage: entrypoint.sh [script_name.R] [arg1 arg2 ...]

SCRIPTS_DIR="${SCRIPTS_DIR:-/app/scripts}"

# CLI first argument overrides SCRIPT_NAME env var
if [[ -n "${1:-}" ]] && [[ "$1" == *.R ]]; then
    SCRIPT_NAME="$1"
    shift
fi

# Validate mounted volume
if [[ ! -d "$SCRIPTS_DIR" ]]; then
    echo "Error: SCRIPTS_DIR not mounted at $SCRIPTS_DIR"
    echo "Mount the scripts volume before running: -v /host/scripts:$SCRIPTS_DIR"
    exit 1
fi

# Require script name — must come from env var or CLI arg
if [[ -z "${SCRIPT_NAME:-}" ]]; then
    echo "Error: Script name not set."
    echo "  Set SCRIPT_NAME env var:  docker run -e SCRIPT_NAME=modeling_mixedPA.R ..."
    echo "  Or pass as first argument: entrypoint.sh modeling_mixedPA.R ..."
    echo ""
    echo "Available scripts in $SCRIPTS_DIR:"
    find "$SCRIPTS_DIR" -type f -name "*.R" 2>/dev/null | sort || echo "  (no R scripts found)"
    exit 1
fi

# Build full path to the script
SCRIPT_PATH="$SCRIPTS_DIR/$SCRIPT_NAME"

# Check if script exists
if [[ ! -f "$SCRIPT_PATH" ]]; then
    echo "Error: Script not found: $SCRIPT_PATH"
    echo "Available scripts:"
    find "$SCRIPTS_DIR" -type f -name "*.R" 2>/dev/null || echo "  (no R scripts found)"
    exit 1
fi

# Print host-side scripts path if provided via -e HOST_SCRIPTS_DIR
echo "Host scripts path: ${HOST_SCRIPTS_DIR:-<not provided — pass -e HOST_SCRIPTS_DIR=\$PWD/scripts to see it>}"
echo ""

echo ">>> Running: Rscript $SCRIPT_PATH $@"
exec Rscript "$SCRIPT_PATH" "$@"
