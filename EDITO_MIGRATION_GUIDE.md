# Migrating a Local R Project to the EDITO Platform

This document is a step-by-step guide for adapting an R project that runs on a local machine so that it runs inside a Docker container on the EDITO platform.  The guide is intentionally general: follow it for any R-based analytical project, substituting your own package names, file names, and parameter names where indicated.

---

## Table of Contents

1. [Overview of the EDITO Execution Model](#1-overview-of-the-edito-execution-model)
2. [Prerequisites](#2-prerequisites)
3. [Project Directory Layout](#3-project-directory-layout)
4. [Creating the Parameters File](#4-creating-the-parameters-file)
5. [Creating the Dockerfile](#5-creating-the-dockerfile)
6. [Creating the Entrypoint Script](#6-creating-the-entrypoint-script)
7. [Modifying R Scripts](#7-modifying-r-scripts)
   - 7.1 [Add the `paws` dependency check](#71-add-the-paws-dependency-check)
   - 7.2 [Replace hard-coded arguments with a parameter-file loader](#72-replace-hard-coded-arguments-with-a-parameter-file-loader)
   - 7.3 [Declare fixed internal paths](#73-declare-fixed-internal-paths)
   - 7.4 [Build the S3 client](#74-build-the-s3-client)
   - 7.5 [Add S3 helper functions](#75-add-s3-helper-functions)
   - 7.6 [Load input files (local-first, S3 fallback)](#76-load-input-files-local-first-s3-fallback)
   - 7.7 [Save outputs and upload to S3](#77-save-outputs-and-upload-to-s3)
8. [Uploading Files to S3 Before Running](#8-uploading-files-to-s3-before-running)
9. [Deploying to EDITO with `add-your-process`](#9-deploying-to-edito-with-add-your-process)
10. [Environment Variable Reference](#10-environment-variable-reference)
11. [Checklist for AI Agents](#11-checklist-for-ai-agents)

---

## 1. Overview of the EDITO Execution Model

EDITO runs each analytical job as an isolated Docker container.  The key differences from a local workflow are:

- **No local file system access.** Input data, scripts, and parameters are stored in an S3-compatible object store (EDITO personal storage, based on CloudFerro S3).
- **Scripts are not baked into the image.** At container startup the entrypoint syncs the entire scripts folder from S3, then executes the requested script.  This means you can update a script without rebuilding the image.
- **Parameters come from a plain-text file, not command-line arguments.** The file is stored in S3 alongside the scripts and is downloaded automatically before the R script starts.
- **Output is written locally inside the container first, then uploaded to S3** by the R script itself before it exits.
- **AWS credentials are injected at runtime** as environment variables; they are never stored in the image.

---

## 2. Prerequisites

### On your development machine

| Requirement | Notes |
|---|---|
| Docker Desktop ≥ 20.10 | Required to build and test the image locally |
| AWS CLI v2 | Used to upload files to EDITO S3 (`aws s3 cp` / `aws s3 sync`) |
| R ≥ 4.3 (optional) | Only needed if you want to test the script locally before containerising |
| An EDITO account with personal S3 storage | Provides a bucket, endpoint URL, access key, and secret key |

### EDITO S3 credentials you will need

Obtain the following four values from the EDITO portal or your project administrator and keep them available.  They are passed as environment variables at runtime and must never be committed to version control.

| Environment variable | Example value |
|---|---|
| `AWS_ACCESS_KEY_ID` | `AKIAIOSFODNN7EXAMPLE` |
| `AWS_SECRET_ACCESS_KEY` | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` |
| `AWS_S3_ENDPOINT` | `s3.waw3-1.cloudferro.com` |
| `S3_BUCKET` | `my-project-bucket` |

---

## 3. Project Directory Layout

Maintain the following structure on your local machine.  The same layout is mirrored inside the container under `/app/`.

```
<project-root>/
├── Dockerfile
├── entrypoint.sh
├── scripts/
│   ├── my_analysis.R        ← your main R script(s)
│   └── PARAMS               ← parameters file (uploaded to S3, not baked in)
├── input/                   ← local copies of input data (not baked in)
└── output/                  ← results land here (can be bind-mounted locally)
```

Inside the running container paths are fixed:

| Purpose | Container path |
|---|---|
| R scripts | `/app/scripts/` |
| Input data | `/app/input/` |
| Output data | `/app/output/` |
| Parameters file | `/app/scripts/PARAMS` (default) |

Use exactly these paths in your R code.  Do not read from or write to any other location.

---

## 4. Creating the Parameters File

Create a plain-text file named **`PARAMS`** (no extension) inside the `scripts/` directory.  One `key=value` pair per line.  Lines starting with `#` are comments and are ignored.  Whitespace around `=` is stripped.

```
# ===========================================================================
# PARAMS — runtime parameters for my_analysis.R
# ===========================================================================

# --- Required ---
species=MySpecies
algorithms=GLM,GAM,RF,MAXNET
cv_strategy=kfold
cv_nb_rep=3

# --- Optional (set to NULL to use the default / disable) ---
pa_dist_min=2000
pa_dist_max=100000
cv_perc=NULL
cv_k=5
n_cores=4

# --- Data paths ---
env_file=/app/input/myRaster.tif
env_file_s3_key=myRaster.tif
```

### Rules for the parameters file

1. Every key your R script requires must have an entry here or a hard-coded default in the script.
2. Use `NULL` (literal string) for optional numeric or string parameters that should fall back to their R default.
3. Multi-value parameters (e.g. a list of algorithm names) are comma-separated; the R loader splits them.
4. File paths must use the container-internal paths (e.g. `/app/input/...`), never local Windows or macOS paths.
5. This file is **not** baked into the Docker image.  It is uploaded to S3 and downloaded at container startup.

---

## 5. Creating the Dockerfile

Create a file named exactly `Dockerfile` (no extension) in the project root.

```dockerfile
# Use the official R image.  Pin the minor version for reproducibility.
FROM rocker/r-ver:4.3

WORKDIR /app

# -----------------------------------------------------------------------
# System libraries
# Add or remove packages to match your R packages' system requirements.
# The list below covers common geospatial and HTTP packages.
# -----------------------------------------------------------------------
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    libgdal-dev \
    libproj-dev \
    libgeos-dev \
    libudunits2-dev \
    libnetcdf-dev \
    libsqlite3-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    libxml2-dev \
    libfontconfig1-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    git \
    awscli \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------
# R packages
# Always include 'paws' for S3 access.
# Add every package your scripts require.
# -----------------------------------------------------------------------
RUN R -e "install.packages(c(\
    'remotes', \
    'dplyr', \
    'paws' \
    ), repos='https://cloud.r-project.org/')"

# Add additional package installation lines as needed, for example:
# RUN R -e "install.packages(c('terra', 'biomod2', 'randomForest'), repos='https://cloud.r-project.org/')"

# -----------------------------------------------------------------------
# Container directory structure
# Scripts are synced from S3 at startup — not baked into the image.
# -----------------------------------------------------------------------
RUN mkdir -p /app/output /app/input /app/scripts

# Entrypoint lives outside /app/scripts so a bind mount cannot shadow it.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# -----------------------------------------------------------------------
# Default environment variables (override at runtime with -e)
# -----------------------------------------------------------------------
ENV TZ=UTC \
    AWS_DEFAULT_REGION=waw3-1 \
    SCRIPT_NAME=my_analysis.R \
    S3_SCRIPTS_PREFIX=scripts \
    S3_INPUT_PREFIX=input \
    S3_OUTPUT_PREFIX=output

# Required at runtime (no default — always pass via -e):
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   AWS_S3_ENDPOINT
#   S3_BUCKET

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### Dockerfile customisation notes

- **Base image:** `rocker/r-ver:<version>` is recommended.  Choose the R version that matches your local development environment.
- **System libraries:** Add only what your R packages need.  Consult each package's `SystemRequirements` field if unsure.
- **R packages:** List every package your scripts `library()` or `require()`.  Pin versions with `install.packages('pkg', version='x.y.z')` if reproducibility is critical.
- **`awscli`** must remain in the system libraries.  The entrypoint uses it to sync files from S3.
- **`paws`** must remain in the R packages.  It is used inside R to access S3 for input data and output upload.
- The `SCRIPT_NAME` default should be the name of your primary R script.

---

## 6. Creating the Entrypoint Script

Create a file named `entrypoint.sh` in the project root.  This file must use Unix line endings (`LF`, not `CRLF`).

```bash
#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Entrypoint: syncs the S3_SCRIPTS_PREFIX folder from S3 (including PARAMS),
# then executes SCRIPT_NAME.  All run parameters come from the PARAMS file.
#
# Required environment variables:
#   SCRIPT_NAME           R script filename to run (e.g. my_analysis.R)
#   S3_BUCKET             S3 bucket name
#   AWS_ACCESS_KEY_ID     S3-compatible access key
#   AWS_SECRET_ACCESS_KEY S3-compatible secret key
#   AWS_S3_ENDPOINT       Custom S3 endpoint URL (e.g. s3.waw3-1.cloudferro.com)
#
# Optional environment variables (defaults set in Dockerfile):
#   S3_SCRIPTS_PREFIX     S3 key prefix for scripts folder (default: scripts)
#   AWS_DEFAULT_REGION    S3 region (default: waw3-1)
#   AWS_SESSION_TOKEN     Session token if using temporary credentials
#   PARAMS                Path to params file (default: /app/scripts/PARAMS)
# ---------------------------------------------------------------------------

SCRIPTS_LOCAL_DIR="/app/scripts"
S3_SCRIPTS_PREFIX="${S3_SCRIPTS_PREFIX:-scripts}"

# ---------------------------------------------------------------------------
# Validate required env vars
# ---------------------------------------------------------------------------
if [[ -z "${SCRIPT_NAME:-}" ]]; then
    echo "Error: SCRIPT_NAME is not set."
    exit 1
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
# Execute the R script
# ---------------------------------------------------------------------------
echo ">>> Running: Rscript ${SCRIPT_PATH}"
exec Rscript "${SCRIPT_PATH}"
```

### Entrypoint notes

- `set -e` causes the script to abort immediately if any command fails.
- The `aws s3 sync` command downloads every file under `S3_SCRIPTS_PREFIX` into `/app/scripts/`, including `PARAMS` and any helper `.R` files.
- `exec Rscript` replaces the shell process with R, so the container's PID 1 is the R process.  This ensures clean signal handling.
- Do not add R command-line arguments after `Rscript "${SCRIPT_PATH}"`.  All parameters come from `PARAMS`.
- If your project has no S3 credentials configured, the entrypoint will fail at validation.  There is no purely local execution mode for the containerised version.

---

## 7. Modifying R Scripts

This section describes every code pattern that must be added to or changed in your R scripts.  Apply these changes in order.

### 7.1 Add the `paws` dependency check

At the very top of your script, after `library()` calls, add:

```r
if (!requireNamespace("paws", quietly = TRUE)) {
  stop("Package 'paws' is required for S3 access. Install it with install.packages('paws').")
}
```

### 7.2 Replace hard-coded arguments with a parameter-file loader

**Before (local script):**
```r
args        <- commandArgs(trailingOnly = TRUE)
myRespName  <- args[1]
algorithms  <- strsplit(args[2], ",")[[1]]
n_cores     <- as.integer(args[3])
env_file    <- "/home/user/data/myRaster.tif"
```

**After (EDITO-compatible):**

Replace all argument parsing and hard-coded values with the `load_params()` function below.  Add one entry to the returned list for every parameter your script needs.

```r
load_params <- function() {
  params_file <- Sys.getenv("PARAMS", unset = "/app/scripts/PARAMS")
  if (!file.exists(params_file)) {
    stop(sprintf(
      "Parameters file not found: %s  (set PARAMS env var to override)",
      params_file
    ))
  }

  lines <- readLines(params_file, warn = FALSE)
  lines <- trimws(lines)
  lines <- lines[nchar(lines) > 0 & !startsWith(lines, "#")]

  raw <- list()
  for (line in lines) {
    idx <- regexpr("=", line, fixed = TRUE)
    if (idx < 1) {
      warning(sprintf("Skipping malformed line in params file: %s", line))
      next
    }
    key        <- trimws(substr(line, 1, idx - 1))
    value      <- trimws(substr(line, idx + 1, nchar(line)))
    raw[[key]] <- value
  }

  # Helper: return string or default
  get_str <- function(key, default = NULL) {
    v <- raw[[key]]
    if (is.null(v) || v == "" || v == "NULL") return(default)
    v
  }
  # Helper: return numeric or default
  get_num <- function(key, default = NULL) {
    v <- raw[[key]]
    if (is.null(v) || v == "" || v == "NULL") return(default)
    as.numeric(v)
  }
  # Helper: return comma-split character vector (required key)
  get_vec <- function(key) {
    v <- raw[[key]]
    if (is.null(v) || v == "") {
      stop(sprintf("Required parameter '%s' is missing or empty.", key))
    }
    trimws(strsplit(v, ",")[[1]])
  }
  # Helper: required string — stops if absent
  require_str <- function(key) {
    v <- get_str(key)
    if (is.null(v)) stop(sprintf("Required parameter '%s' is missing.", key))
    v
  }

  # --- Return one named list entry per parameter your script needs ---
  list(
    # Required parameters (adapt key names and helper calls to your project)
    myParam1       = require_str("param1_key"),
    myVectorParam  = get_vec("vector_param_key"),

    # Numeric parameters with defaults
    myNumParam     = get_num("num_param_key", default = 1),

    # Optional string parameters
    env_file        = get_str("env_file",        default = "/app/input/myRaster.tif"),
    env_file_s3_key = get_str("env_file_s3_key", default = "")
  )
}

p <- load_params()
# Assign to named variables for convenience:
myParam1       <- p$myParam1
myVectorParam  <- p$myVectorParam
myNumParam     <- p$myNumParam
env_file       <- p$env_file
env_file_s3_key <- p$env_file_s3_key
```

### 7.3 Declare fixed internal paths

Immediately after assigning parameters, declare the fixed container-internal directories.  Never derive these from parameters or environment variables; they are structural constants.

```r
outdir      <- "/app/output"
scripts_dir <- "/app/scripts"
input_dir   <- "/app/input"

dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
```

Optionally validate that the volumes are mounted:

```r
if (!dir.exists(scripts_dir)) stop(sprintf("scripts_dir not found: %s", scripts_dir))
if (!dir.exists(input_dir))   stop(sprintf("input_dir not found: %s",   input_dir))
```

### 7.4 Build the S3 client

Add this function after the path declarations.  It reads credentials from environment variables and returns a `paws` S3 client, or `NULL` if credentials are absent (which allows the script to fall back to purely local files during local testing).

```r
build_s3_client <- function() {
  endpoint_raw <- Sys.getenv("AWS_S3_ENDPOINT", "")
  if (endpoint_raw == "") return(NULL)

  endpoint <- if (grepl("^https?://", endpoint_raw)) {
    endpoint_raw
  } else {
    paste0("https://", endpoint_raw)
  }

  access_key    <- Sys.getenv("AWS_ACCESS_KEY_ID",     "")
  secret_key    <- Sys.getenv("AWS_SECRET_ACCESS_KEY", "")
  session_token <- Sys.getenv("AWS_SESSION_TOKEN",     "")
  region        <- Sys.getenv("AWS_DEFAULT_REGION",    "waw3-1")

  if (access_key == "" || secret_key == "") return(NULL)

  creds <- list(access_key_id = access_key, secret_access_key = secret_key)
  if (session_token != "") creds$session_token <- session_token

  paws::s3(config = list(
    credentials = list(creds = creds),
    endpoint    = endpoint,
    region      = region
  ))
}

resolve_bucket <- function() {
  Sys.getenv("S3_BUCKET", "")
}

s3_client        <- build_s3_client()
s3_bucket        <- resolve_bucket()
s3_input_prefix  <- Sys.getenv("S3_INPUT_PREFIX",  "input")
s3_output_prefix <- Sys.getenv("S3_OUTPUT_PREFIX", "output")
```

### 7.5 Add S3 helper functions

These three utility functions encapsulate S3 key construction, file download, and file/directory upload.  Add them once per project; they are called throughout the rest of the script.

```r
# Build a safe S3 key from a prefix and a filename
safe_s3_key <- function(prefix, filename) {
  if (prefix == "") return(filename)
  paste0(gsub("/+$", "", prefix), "/", filename)
}

# Download a single object from S3 to a local path.
# Returns TRUE on success, FALSE on failure (with a warning message).
download_s3_object <- function(s3, bucket, key, dest_path) {
  if (is.null(s3) || bucket == "" || key == "") return(FALSE)
  dir.create(dirname(dest_path), recursive = TRUE, showWarnings = FALSE)

  ok <- tryCatch({
    obj  <- s3$get_object(Bucket = bucket, Key = key)
    body <- obj$Body

    if (is.raw(body)) {
      writeBin(body, dest_path)
    } else if (is.character(body)) {
      writeBin(charToRaw(paste(body, collapse = "")), dest_path)
    } else {
      stop("Unsupported response body type from S3.")
    }
    TRUE
  }, error = function(e) {
    cat(">>> S3 download failed:", paste0("s3://", bucket, "/", key),
        "-", conditionMessage(e), "\n")
    FALSE
  })

  if (ok) cat(">>> Downloaded", paste0("s3://", bucket, "/", key), "->", dest_path, "\n")
  ok
}

# Upload a single local file to S3.
upload_to_s3 <- function(s3, bucket, local_path, s3_key) {
  if (is.null(s3) || bucket == "" || !file.exists(local_path)) return(FALSE)

  ok <- tryCatch({
    s3$put_object(
      Bucket = bucket,
      Key    = s3_key,
      Body   = readBin(local_path, what = "raw", n = file.info(local_path)$size)
    )
    TRUE
  }, error = function(e) {
    cat(">>> S3 upload failed:", paste0("s3://", bucket, "/", s3_key),
        "-", conditionMessage(e), "\n")
    FALSE
  })

  if (ok) cat(">>> Uploaded", local_path, "->", paste0("s3://", bucket, "/", s3_key), "\n")
  ok
}

# Recursively upload an entire local directory to an S3 prefix.
upload_dir_to_s3 <- function(s3, bucket, local_dir, s3_prefix) {
  if (is.null(s3) || bucket == "" || !dir.exists(local_dir)) return(invisible(NULL))
  files <- list.files(local_dir, recursive = TRUE, full.names = TRUE)
  for (f in files) {
    rel <- sub(
      paste0("^", normalizePath(local_dir, mustWork = FALSE), "[/\\\\]"),
      "",
      normalizePath(f, mustWork = FALSE)
    )
    key <- if (s3_prefix == "") rel else paste0(gsub("/+$", "", s3_prefix), "/", rel)
    upload_to_s3(s3, bucket, f, key)
  }
}
```

### 7.6 Load input files (local-first, S3 fallback)

**Before (local script):**
```r
occ_data <- read.csv("/home/user/data/occurrences.csv")
myExpl   <- rast("/home/user/data/myRaster.tif")
```

**After (EDITO-compatible):**

Use the pattern below for every input file.  The script first looks for the file on the local filesystem (inside `/app/input/`).  If it is not found, it attempts to download it from S3 using the S3 helper functions.  This design also allows local testing when you bind-mount input data.

```r
# --- Load a CSV input file ---
my_filename   <- "occurrences.csv"
local_path    <- file.path(input_dir, my_filename)

if (!file.exists(local_path)) {
  s3_keys <- unique(c(
    safe_s3_key(s3_input_prefix, my_filename),
    my_filename
  ))
  for (key in s3_keys) {
    if (download_s3_object(s3_client, s3_bucket, key, local_path)) break
  }
}

if (!file.exists(local_path)) {
  stop(paste("Input file not found locally or in S3:", local_path))
}

cat(">>> Using input file:", local_path, "\n")
my_data <- read.csv(local_path)


# --- Load a raster / binary input file ---
# env_file and env_file_s3_key come from load_params()
if (!file.exists(env_file)) {
  env_keys <- unique(Filter(nzchar, c(
    env_file_s3_key,
    safe_s3_key(s3_input_prefix, basename(env_file)),
    basename(env_file)
  )))
  for (key in env_keys) {
    if (download_s3_object(s3_client, s3_bucket, key, env_file)) break
  }
}

if (!file.exists(env_file)) {
  stop(paste("Environmental raster not found locally or in S3:", env_file))
}

myRaster <- rast(env_file)   # replace rast() with the appropriate read function
```

Apply the same pattern to every input file your script needs.

### 7.7 Save outputs and upload to S3

**Before (local script):**
```r
write.csv(result_df, "/home/user/results/output.csv")
```

**After (EDITO-compatible):**

Write all results to `outdir` (`/app/output/`).  After the analysis is complete, call `upload_dir_to_s3()` once to push everything.

```r
# --- Write results locally ---
write.csv(
  result_df,
  file      = file.path(outdir, paste0("results_", myParam1, ".csv")),
  row.names = FALSE
)

# Additional output files follow the same pattern:
# saveRDS(my_model, file.path(outdir, "model.rds"))
# terra::writeRaster(prediction_raster, file.path(outdir, "prediction.tif"))


# --- Upload entire output directory to S3 ---
# Place this block at the very end of the script, after all results are written.
if (!is.null(s3_client) && s3_bucket != "") {
  cat(">>> Uploading outputs to s3://", s3_bucket, "/", s3_output_prefix, "\n", sep = "")
  upload_dir_to_s3(s3_client, s3_bucket, outdir, s3_output_prefix)
  cat(">>> Upload complete\n")
} else {
  cat(">>> Skipping S3 upload: no S3 client or bucket configured\n")
}
```

---

## 8. Uploading Files to S3 Before Running

On EDITO, all file management is done through the **Personal Storage** browser in the EDITO UI.  There are no command-line upload steps.

### What to upload

| Local file | Destination prefix in your bucket | Required |
|---|---|---|
| `scripts/my_analysis.R` | `scripts/` | Yes |
| `scripts/PARAMS` | `scripts/` | Yes |
| Any helper `.R` files sourced by the main script | `scripts/` | If used |
| `input/myRaster.tif` (and other input data) | `input/` | Yes |

### How to upload via the EDITO UI

1. Log in to the EDITO platform and open **Personal Storage** (the S3 file browser).
2. Navigate to your bucket, or create a new one if it does not exist.
3. Create the `scripts/` prefix (folder) and upload all files from your local `scripts/` directory — this must include both the R script(s) and the `PARAMS` file.
4. Create the `input/` prefix and upload all required input data files.
5. Verify that all expected files are visible in the UI before submitting a job.

The `output/` prefix does not need to be created in advance; the R script creates it automatically when it writes results.

> **Note:** Upload only the files the script actually reads.  Large static rasters that do not change between runs can be uploaded once and reused across many jobs.

---

## 9. Deploying to EDITO with `add-your-process`

EDITO builds and registers your Docker container through the **`add-your-process`** tool, which is available in the [Contribution tab](https://datalab.dive.edito.eu/process-catalog/edito-contribution) of the Datalab Process Catalogue.  You do not run `docker build` or `docker push` manually; EDITO handles the build from your Git repository.

> **Access:** `add-your-process` is an early-access feature.  Contact EDITO user support to be authorised before proceeding.
>
> **Save your configuration:** Use the **Save** button in the tool before launching.  The process configuration is stored in temporary storage and may be lost during platform maintenance.

### Step 1 — Host your project in a Git repository

The project must be in a remote Git repository (public or private) with the following files committed:

- `Dockerfile` (at the repository root, or note its relative path)
- `entrypoint.sh`
- `scripts/my_analysis.R` (and any helper `.R` files)

The `PARAMS` file and input data are **not** committed to Git; they are uploaded to S3 separately (see [Section 8](#8-uploading-files-to-s3-before-running)).

### Step 2 — Open `add-your-process`

Navigate to the [Contribution tab](https://datalab.dive.edito.eu/process-catalog/edito-contribution) in the EDITO Datalab and open the `add-your-process` tool.

### Step 3 — Configuration (2): where to deploy from

Select **Deploy from a Dockerfile**:

1. Set **Container image is already built** to `false`.
2. Set **Dockerfile path** to the path of your `Dockerfile` relative to the repository root.  If it is at the root, enter `Dockerfile`.

EDITO will build the Docker image from the Dockerfile automatically.

> Alternatively, if you have already built and pushed the image to a public registry (e.g. Docker Hub), set **Container image is already built** to `true` and provide the full image URL (e.g. `docker.io/myaccount/my-image-name:tag`).

### Step 4 — Metadata (3)

Fill in the required metadata fields:

| Field | Notes |
|---|---|
| Process name | Lowercase only; no capital letters |
| Process version | Use semantic versioning (e.g. `1.0.0`) |
| Process description | Brief description of what the process does |
| Icon URL | Optional |
| Homepage URL | Optional (e.g. link to the Git repository) |

> If replacing an existing process, the new version number must be higher than the current one.

### Step 5 — Git (4)

Provide access to your Git repository:

- **Public repository:** enable **Add git config inside your environment** and enter the **Repository URL**.
- **Private repository:** also provide **Name**, **Email**, and a **Personal Access Token**.
- If your code is on a branch other than `main`, enter the branch name in the **Branch** field.

### Step 6 — Other environment variables (6)

This section defines every environment variable the container needs at runtime.  Add one entry per variable with a **Name**, **Description**, and **Default Value**.

Add at minimum the following variables (see [Section 10](#10-environment-variable-reference) for full descriptions):

| Name | Default value | Description |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | *(no default — user must supply)* | S3 access key |
| `AWS_SECRET_ACCESS_KEY` | *(no default — user must supply)* | S3 secret key |
| `AWS_S3_ENDPOINT` | `s3.waw3-1.cloudferro.com` | S3 endpoint URL |
| `AWS_DEFAULT_REGION` | `waw3-1` | S3 region |
| `S3_BUCKET` | *(no default — user must supply)* | S3 bucket name |
| `SCRIPT_NAME` | `my_analysis.R` | R script to run |
| `S3_SCRIPTS_PREFIX` | `scripts` | S3 prefix for scripts |
| `S3_INPUT_PREFIX` | `input` | S3 prefix for input data |
| `S3_OUTPUT_PREFIX` | `output` | S3 prefix for output upload |
| `PARAMS` | `/app/scripts/PARAMS` | Path to the parameters file inside the container |

When a user launches the process, they can override any of these values in the launch form.  To run a different script or use a different parameter file, the user changes `SCRIPT_NAME` or `PARAMS` at launch time — no rebuild is needed.

### Step 7 — Resources (7)

Set the CPU and memory **requests** (guaranteed minimum) and **limits** (hard cap) appropriate for your analysis.

### Step 8 — Save and launch

1. Give your configuration a friendly name (max 48 characters, only `-` allowed as separator — no `_` or spaces).
2. Click **Save**.
3. Click **Launch**.

Your process will appear in the [Process Playground catalogue](https://datalab.dive.edito.eu/process-catalog/process-playground) within approximately 5 minutes.

---

## 10. Environment Variable Reference

### Set in the Dockerfile (defaults, override at runtime)

| Variable | Default | Description |
|---|---|---|
| `TZ` | `UTC` | Container timezone |
| `AWS_DEFAULT_REGION` | `waw3-1` | S3 region for EDITO CloudFerro storage |
| `SCRIPT_NAME` | *(your primary script)* | R script filename to download and execute |
| `S3_SCRIPTS_PREFIX` | `scripts` | S3 key prefix for the scripts folder |
| `S3_INPUT_PREFIX` | `input` | S3 key prefix for input data |
| `S3_OUTPUT_PREFIX` | `output` | S3 key prefix for output upload |

### Required at runtime (no default)

| Variable | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | S3-compatible access key |
| `AWS_SECRET_ACCESS_KEY` | S3-compatible secret key |
| `AWS_S3_ENDPOINT` | Custom S3 endpoint URL (e.g. `s3.waw3-1.cloudferro.com`) |
| `S3_BUCKET` | S3 bucket name |

### Optional at runtime

| Variable | Description |
|---|---|
| `AWS_SESSION_TOKEN` | Session token for temporary credentials |
| `PARAMS` | Full container path to the parameters file (default: `/app/scripts/PARAMS`) |

---

## 11. Checklist for AI Agents

Use this checklist to verify that all migration steps have been applied correctly to an R project.

### Dockerfile
- [ ] Base image is `rocker/r-ver:<version>`
- [ ] `awscli` is in the `apt-get install` list
- [ ] `paws` is in the `install.packages()` call
- [ ] All R packages required by the scripts are listed in `install.packages()`
- [ ] All system libraries required by those R packages are in the `apt-get install` list
- [ ] Directories `/app/output`, `/app/input`, `/app/scripts` are created with `mkdir -p`
- [ ] `entrypoint.sh` is copied to `/usr/local/bin/entrypoint.sh` and made executable
- [ ] `ENV` block sets `SCRIPT_NAME`, `S3_SCRIPTS_PREFIX`, `S3_INPUT_PREFIX`, `S3_OUTPUT_PREFIX`
- [ ] `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]` is the last instruction

### entrypoint.sh
- [ ] File uses Unix line endings (`LF`)
- [ ] Validates `SCRIPT_NAME`, `S3_BUCKET`, `AWS_S3_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
- [ ] Prepends `https://` to `AWS_S3_ENDPOINT` if no scheme is present
- [ ] Uses `aws s3 sync` (not `aws s3 cp`) to download the entire scripts prefix
- [ ] Verifies the target script exists after sync
- [ ] Exports `PARAMS` with default `/app/scripts/PARAMS`
- [ ] Executes the script with `exec Rscript "${SCRIPT_PATH}"` (no CLI arguments)

### PARAMS file
- [ ] Located at `scripts/PARAMS` (no extension)
- [ ] Uses Unix line endings (`LF`)
- [ ] Contains one `key=value` entry for every parameter the R script reads
- [ ] All file paths use container-internal paths (`/app/input/...`, `/app/output/...`)
- [ ] Optional parameters have `NULL` as their value when not in use

### R script — structure
- [ ] `paws` requireNamespace check is present at the top
- [ ] `load_params()` function reads from the file at `Sys.getenv("PARAMS", "/app/scripts/PARAMS")`
- [ ] All command-line argument parsing (`commandArgs`) has been removed
- [ ] All hard-coded local file paths have been replaced with `/app/input/...`, `/app/output/...`, or values read from `PARAMS`
- [ ] `outdir`, `scripts_dir`, `input_dir` are declared as constants after `load_params()`
- [ ] `dir.create(outdir, recursive = TRUE, showWarnings = FALSE)` is called

### R script — S3 client
- [ ] `build_s3_client()` builds credentials from env vars and returns a `paws::s3()` client or `NULL`
- [ ] `resolve_bucket()` reads `S3_BUCKET` from env
- [ ] `s3_input_prefix` is read from `S3_INPUT_PREFIX` env var with default `"input"`
- [ ] `s3_output_prefix` is read from `S3_OUTPUT_PREFIX` env var with default `"output"`

### R script — S3 helpers
- [ ] `safe_s3_key(prefix, filename)` is defined
- [ ] `download_s3_object(s3, bucket, key, dest_path)` is defined
- [ ] `upload_to_s3(s3, bucket, local_path, s3_key)` is defined
- [ ] `upload_dir_to_s3(s3, bucket, local_dir, s3_prefix)` is defined

### R script — input loading
- [ ] Every input file is looked up locally first; if absent, a download from S3 is attempted
- [ ] If neither local nor S3 copy exists, the script calls `stop()` with a clear message
- [ ] The `env_file_s3_key` parameter is used when the S3 key differs from the default `s3_input_prefix/basename(env_file)`

### R script — output saving
- [ ] All output files are written to `outdir` (`/app/output/`)
- [ ] `upload_dir_to_s3(s3_client, s3_bucket, outdir, s3_output_prefix)` is called at the end of the script
- [ ] The upload block is guarded: it only runs when `s3_client` is not `NULL` and `s3_bucket != ""`

### S3 upload before running (via EDITO Personal Storage UI)
- [ ] All files from the local `scripts/` folder (including `PARAMS`) are uploaded to the `scripts/` prefix in the bucket
- [ ] All required input files are uploaded to the `input/` prefix in the bucket
- [ ] Uploaded files are confirmed visible in the EDITO Personal Storage browser

### EDITO deployment (via `add-your-process`)
- [ ] Project is committed to a remote Git repository (public or private)
- [ ] `Dockerfile` and `entrypoint.sh` are present in the repository (do **not** commit `PARAMS` or input data)
- [ ] `add-your-process` tool is opened from the Contribution tab of the EDITO Datalab
- [ ] Configuration (2): **Deploy from a Dockerfile** selected; Dockerfile path is correct relative to repository root
- [ ] Metadata (3): process name (lowercase), version, and description are filled in
- [ ] Git (4): repository URL and credentials (if private) are provided; correct branch is set
- [ ] Other environment variables (6): all required env vars are defined with names, descriptions, and default values
- [ ] Resources (7): CPU and memory requests/limits are set appropriately
- [ ] Configuration is saved with a valid friendly name (≤ 48 chars, only `-` as separator)
- [ ] Tool is launched; process appears in the Process Playground catalogue within 5 minutes
- [ ] When launching the process, `SCRIPT_NAME` matches the filename uploaded to `s3://<bucket>/scripts/`
- [ ] Results appear in S3 under `s3://<bucket>/output/` after the process completes
