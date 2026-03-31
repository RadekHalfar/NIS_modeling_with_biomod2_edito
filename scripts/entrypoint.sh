#!/bin/bash

# Wrapper script to run R scripts from mounted volume only.
# Required: /app/scripts must be mounted as volume.
#
# Configuration (priority: CLI arg > env var > error):
#   SCRIPTS_DIR   Folder where scripts are mounted (default: /app/scripts)
#   SCRIPT_NAME   R script filename to execute (must be set via env var or CLI)
#
# Usage: entrypoint.sh [script_name.R] [arg1 arg2 ...]

set -e

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

# List all files in the mounted scripts directory on every run.
echo "Files in $SCRIPTS_DIR:"
if [[ -d "$SCRIPTS_DIR" ]]; then
    find "$SCRIPTS_DIR" -type f 2>/dev/null | sort || echo "  (no files found)"
else
    echo "  (directory not found)"
fi
echo ""

# Run the R script with all remaining arguments
echo ">>> Running: Rscript $SCRIPT_PATH $@"
exec Rscript "$SCRIPT_PATH" "$@"
