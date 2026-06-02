# Docker Setup: Baked Scripts + S3 Input Parameters

R scripts are baked into the image under `/app/scripts`.
At container startup, the entrypoint downloads `parameters.txt` from S3 input prefix and writes it to `${PARAMS}` (default: `/app/input/parameters.txt`).

Parameters are not baked into the image.

## Directory Structure

```
.
├── Dockerfile              (build configuration)
├── entrypoint.sh           (downloads params from S3 input, then runs baked script)
├── scripts/                (baked into image; do not upload to S3 for runtime)
│   └── modelling/
│       └── 01_modeling_mixedPA.R
├── input/                  (local sample data)
└── output/                 (results)
```

## Build the Docker Image

```powershell
docker build -t biomod2-modeling:latest .
```

## Required Environment Variables

| Variable | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | S3-compatible access key |
| `AWS_SECRET_ACCESS_KEY` | S3-compatible secret key |
| `AWS_S3_ENDPOINT` | Custom S3 endpoint (e.g. `s3.waw3-1.cloudferro.com`) |
| `S3_BUCKET` | S3 bucket name |

## Optional Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SCRIPT_NAME` | `modelling/01_modeling_mixedPA.R` | Script path relative to `/app/scripts` |
| `S3_INPUT_PREFIX` | `input` | S3 key prefix used for params and input data |
| `S3_OUTPUT_PREFIX` | `output` | S3 key prefix for output upload (read by R scripts) |
| `PARAMS` | `/app/input/parameters.txt` | Full path for the downloaded parameters file |
| `AWS_DEFAULT_REGION` | `waw3-1` | S3 region |
| `AWS_SESSION_TOKEN` | *(none)* | Session token for temporary credentials |

At startup the entrypoint downloads:

```
s3://<S3_BUCKET>/<S3_INPUT_PREFIX>/parameters.txt  ->  <PARAMS>
```

## Upload Files to S3 Before Running

Only the parameters file must be present for startup:

```powershell
$env:AWS_S3_ENDPOINT = "s3.waw3-1.cloudferro.com"
$endpoint = "https://$env:AWS_S3_ENDPOINT"

# Upload parameters file to input prefix
aws s3 cp scripts\parameters.txt `
    s3://my-bucket/input/parameters.txt `
    --endpoint-url $endpoint
```

Input rasters/CSVs should also be uploaded under `S3_INPUT_PREFIX` as needed by your script.

## Run the Container

### Basic Run

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID="your-key" `
  -e AWS_SECRET_ACCESS_KEY="your-secret" `
  -e AWS_S3_ENDPOINT="s3.waw3-1.cloudferro.com" `
  -e AWS_DEFAULT_REGION="waw3-1" `
  -e S3_BUCKET="my-bucket" `
  -e S3_INPUT_PREFIX="input" `
  -e SCRIPT_NAME="modelling/01_modeling_mixedPA.R" `
  -e PARAMS="/app/input/parameters.txt" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest
```

All run parameters are read from `/app/input/parameters.txt`, downloaded by entrypoint from S3.

### Run a Different Script

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID="your-key" `
  -e AWS_SECRET_ACCESS_KEY="your-secret" `
  -e AWS_S3_ENDPOINT="s3.waw3-1.cloudferro.com" `
  -e S3_BUCKET="my-bucket" `
  -e S3_INPUT_PREFIX="input" `
  -e SCRIPT_NAME="modelling/02_ensemble.R" `
  -e PARAMS="/app/input/parameters.txt" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest
```

### Use a Different Input Prefix

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID="your-key" `
  -e AWS_SECRET_ACCESS_KEY="your-secret" `
  -e AWS_S3_ENDPOINT="s3.waw3-1.cloudferro.com" `
  -e S3_BUCKET="my-bucket" `
  -e S3_INPUT_PREFIX="bioflow/input" `
  -e SCRIPT_NAME="modelling/01_modeling_mixedPA.R" `
  -e PARAMS="/app/input/parameters.txt" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest
```

## Parameters File (`parameters.txt`)

A plain-text `key=value` file stored in S3 input prefix and downloaded at startup. Example:

```
# Required
species=Bugulaneritina
algorithms=GLM,GAM,RF,MAXNET
cv_strategy=kfold
cv_nb_rep=3

# Optional (NULL = use default / disable)
pa_dist_min=2000
pa_dist_max=100000
cv_perc=NULL
cv_k=5
n_cores=4

# Data paths
env_file=/app/input/myExpl_shelf_DISTFIX.tif
env_file_s3_key=myExpl_shelf_DISTFIX.tif
```

## Key Benefits

- No baked parameters: update `parameters.txt` in S3 without rebuilding image.
- Fail-fast startup: container stops before running R if params download fails.
- Deterministic path: all scripts read the same local file path (`/app/input/parameters.txt`).
