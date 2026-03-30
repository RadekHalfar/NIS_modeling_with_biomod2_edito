#!/bin/bash

# Wrapper script to run R scripts from a configurable scripts folder.
# Environment variables:
#   SCRIPTS_DIR   Folder where scripts are stored (default: /app/scripts)
#   SCRIPT_NAME   Script to execute (default: modelling/01_modeling_mixedPA.R)
# Usage: entrypoint.sh [script_name] [arg1 arg2 ...]

set -e

SCRIPTS_DIR="${SCRIPTS_DIR:-/app/scripts}"
SCRIPT_NAME="${SCRIPT_NAME:-modeling_mixedPA.R}"

# Optional first argument can override SCRIPT_NAME when it looks like an R script path.
if [[ -n "${1:-}" ]] && [[ "$1" == *.R ]]; then
    SCRIPT_NAME="$1"
    shift
fi

# Show help if no script provided
if [[ -z "$SCRIPT_NAME" ]]; then
    echo "Usage: $(basename "$0") [script_name] [arguments...]"
    echo ""
    echo "Available scripts in $SCRIPTS_DIR:"
    find "$SCRIPTS_DIR" -type f -name "*.R" 2>/dev/null || echo "  (no R scripts found)"
    echo ""
    echo "Example:"
    echo "  entrypoint.sh modeling_mixedPA.R Bugulaneritina GLM,GAM,RF,MAXNET 2000 100000 ..."
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
