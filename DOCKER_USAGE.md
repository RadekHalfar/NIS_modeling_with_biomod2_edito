# Docker Setup: S3 Script Download Workflow

R scripts are **not** baked into the image and are **not** mounted as volumes.
At container startup the entrypoint downloads the requested script directly from your personal S3 bucket (the same bucket used for input data), then executes it.

## Directory Structure

```
.
├── Dockerfile              (build configuration)
├── entrypoint.sh           (downloads script from S3, then runs it)
├── scripts/                (local copies — upload these to S3 before running)
│   └── modeling_mixedPA.R
├── input/                  (local sample data)
└── output/                 (results)
```

## Build the Docker Image

Build once:

```powershell
docker build -t biomod2-modeling:latest .
```

## Required Environment Variables

| Variable | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | S3-compatible access key |
| `AWS_SECRET_ACCESS_KEY` | S3-compatible secret key |
| `AWS_S3_ENDPOINT` | Custom S3 endpoint (e.g. `s3.waw3-1.cloudferro.com`) |
| `S3_BUCKET` | S3 bucket name (same bucket used for input data and output) |
| `SCRIPT_NAME` | R script filename to download and run (default: `modeling_mixedPA.R`) |

## Optional Environment Variables

| Variable | Default | Description |
|---|---|---|
| `S3_SCRIPTS_PREFIX` | `scripts` | S3 key prefix where R scripts are stored |
| `S3_INPUT_PREFIX` | `input` | S3 key prefix for input data (read by the R script) |
| `S3_OUTPUT_PREFIX` | `output` | S3 key prefix for output upload (read by the R script) |
| `AWS_DEFAULT_REGION` | `waw3-1` | S3 region |
| `AWS_SESSION_TOKEN` | *(none)* | Session token for temporary credentials |

The entrypoint downloads:
```
s3://<S3_BUCKET>/<S3_SCRIPTS_PREFIX>/<SCRIPT_NAME>
```

## Upload Scripts to S3 Before Running

Use the AWS CLI or your preferred S3 client to upload scripts:

```powershell
$env:AWS_S3_ENDPOINT = "s3.waw3-1.cloudferro.com"
aws s3 cp scripts\modeling_mixedPA.R `
    s3://my-bucket/scripts/modeling_mixedPA.R `
    --endpoint-url https://$env:AWS_S3_ENDPOINT
```

## Run the Container

### Basic Run

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID="your-key" `
  -e AWS_SECRET_ACCESS_KEY="your-secret" `
  -e AWS_S3_ENDPOINT="s3.waw3-1.cloudferro.com" `
  -e AWS_DEFAULT_REGION="waw3-1" `
  -e S3_BUCKET="my-bucket" `
  -e SCRIPT_NAME="modeling_mixedPA.R" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest `
  Bugulaneritina GLM,GAM,RF,MAXNET 2000 100000 kfold 3 NULL 5 4 /app/input/myExpl_shelf_DISTFIX.tif /app/output /app/scripts /app/input
```

Input data is fetched from S3 by the R script itself (using the same AWS credentials).

### Run a Different Script

Just change `SCRIPT_NAME` — no rebuild needed:

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID="your-key" `
  -e AWS_SECRET_ACCESS_KEY="your-secret" `
  -e AWS_S3_ENDPOINT="s3.waw3-1.cloudferro.com" `
  -e S3_BUCKET="my-bucket" `
  -e SCRIPT_NAME="preprocessing.R" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest `
  arg1 arg2 arg3
```

### Use a Different S3 Scripts Prefix

If your scripts are stored under a different prefix (e.g. `bioflow/scripts/`):

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID="your-key" `
  -e AWS_SECRET_ACCESS_KEY="your-secret" `
  -e AWS_S3_ENDPOINT="s3.waw3-1.cloudferro.com" `
  -e S3_BUCKET="my-bucket" `
  -e S3_SCRIPTS_PREFIX="bioflow/scripts" `
  -e SCRIPT_NAME="modeling_mixedPA.R" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest
```

## Argument Order for `modeling_mixedPA.R`

```
<species> <algorithms> <PA_dist_min> <PA_dist_max> <CV_strategy> <CV_nb_rep> <CV_perc_or_NULL> <CV_k_or_NULL> <n_cores> <env_file> <outdir> <scripts_dir> <input_dir>
```

## Key Benefits

- **No volume mounts for scripts** — scripts live in S3 alongside input data
- **No Docker rebuilds** — change `SCRIPT_NAME` to run a different script
- **Single credentials set** — the same AWS env vars serve both the entrypoint download and the R script's S3 operations
- **Consistent workflow** — scripts, input, and output all flow through S3