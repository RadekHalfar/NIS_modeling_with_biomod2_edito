#!/bin/bash

# Wrapper script to run R scripts from the scripts folder
# Usage: entrypoint.sh <script_name> [arg1 arg2 ...]
# Example: entrypoint.sh modeling_mixedPA.R Bugulaneritina GLM,GAM,RF,MAXNET 2000 100000 ...

set -e

SCRIPTS_DIR="/app/scripts"
SCRIPT_NAME="${1:-}"

# Show help if no script provided
if [[ -z "$SCRIPT_NAME" ]]; then
    echo "Usage: $(basename "$0") <script_name> [arguments...]"
    echo ""
    echo "Available scripts in $SCRIPTS_DIR:"
    ls -1 "$SCRIPTS_DIR"/*.R 2>/dev/null || echo "  (no R scripts found)"
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
    ls -1 "$SCRIPTS_DIR"/*.R 2>/dev/null || echo "  (no R scripts found)"
    exit 1
fi

# Remove the script name from arguments (shift moves to remaining args)
shift

# Run the R script with all remaining arguments
echo ">>> Running: Rscript $SCRIPT_PATH $@"
exec Rscript "$SCRIPT_PATH" "$@"
