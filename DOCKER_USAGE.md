# Docker Setup: S3 Script Download Workflow

R scripts are **not** baked into the image and are **not** mounted as volumes.
At container startup the entrypoint syncs the entire `S3_SCRIPTS_PREFIX` folder from S3 — including scripts, helper files, and the parameters file — then executes `SCRIPT_NAME`. All run parameters come from the parameters file, not from command-line arguments.

## Directory Structure

```
.
├── Dockerfile              (build configuration)
├── entrypoint.sh           (syncs scripts folder from S3, then runs the R script)
├── scripts/                (local copies — upload contents to S3 before running)
│   ├── modelling/
│   │   └── 01_modeling_mixedPA.R
│   └── parameters.txt      (runtime parameters — must be inside S3_SCRIPTS_PREFIX)
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
| `SCRIPT_NAME` | `01_modeling_mixedPA.R` | R script filename to run |
| `S3_SCRIPTS_PREFIX` | `scripts` | S3 key prefix synced entirely to `/app/scripts/` |
| `S3_INPUT_PREFIX` | `input` | S3 key prefix for input data (read by the R script) |
| `S3_OUTPUT_PREFIX` | `output` | S3 key prefix for output upload (read by the R script) |
| `PARAMS` | `parameters.txt` | Parameters filename inside the scripts folder |
| `AWS_DEFAULT_REGION` | `waw3-1` | S3 region |
| `AWS_SESSION_TOKEN` | *(none)* | Session token for temporary credentials |

At startup the entrypoint syncs the entire prefix to `/app/scripts/`:
```
s3://<S3_BUCKET>/<S3_SCRIPTS_PREFIX>/  →  /app/scripts/
```
The parameters file is expected at `/app/scripts/<PARAMS>` (e.g. `/app/scripts/parameters.txt`).

## Upload Files to S3 Before Running

Both the R script **and** the parameters file must be uploaded to S3 under `S3_SCRIPTS_PREFIX`:

```powershell
$env:AWS_S3_ENDPOINT = "s3.waw3-1.cloudferro.com"
$endpoint = "https://$env:AWS_S3_ENDPOINT"

# Upload the R script
aws s3 cp scripts\modelling\01_modeling_mixedPA.R `
    s3://my-bucket/scripts/modelling/01_modeling_mixedPA.R `
    --endpoint-url $endpoint

# Upload the parameters file (must be inside S3_SCRIPTS_PREFIX)
aws s3 cp scripts\parameters.txt `
    s3://my-bucket/scripts/modelling/parameters.txt `
    --endpoint-url $endpoint

# Or sync the entire modelling subfolder at once:
aws s3 sync scripts\modelling\ `
    s3://my-bucket/scripts/modelling/ `
    --endpoint-url $endpoint
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
  -e S3_SCRIPTS_PREFIX="scripts/modelling" `
  -e SCRIPT_NAME="01_modeling_mixedPA.R" `
  -e PARAMS="parameters.txt" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest
```

All run parameters (species, algorithms, cross-validation settings, etc.) are read from `parameters.txt` synced from S3. Edit it in S3 to change the run — no container rebuild needed.

### Run a Different Script

Change `SCRIPT_NAME` — no rebuild needed:

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID="your-key" `
  -e AWS_SECRET_ACCESS_KEY="your-secret" `
  -e AWS_S3_ENDPOINT="s3.waw3-1.cloudferro.com" `
  -e S3_BUCKET="my-bucket" `
  -e S3_SCRIPTS_PREFIX="scripts/modelling" `
  -e SCRIPT_NAME="02_ensemble.R" `
  -e PARAMS="parameters.txt" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest
```

### Use a Different S3 Scripts Prefix

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID="your-key" `
  -e AWS_SECRET_ACCESS_KEY="your-secret" `
  -e AWS_S3_ENDPOINT="s3.waw3-1.cloudferro.com" `
  -e S3_BUCKET="my-bucket" `
  -e S3_SCRIPTS_PREFIX="bioflow/scripts" `
  -e SCRIPT_NAME="01_modeling_mixedPA.R" `
  -e PARAMS="parameters.txt" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest
```

## Parameters File (`parameters.txt`)

A plain-text `key=value` file stored alongside the scripts in S3. Downloaded automatically at container startup. Example:

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

- Internal paths (`/app/output`, `/app/scripts`, `/app/input`) are fixed inside the container.
- Input data is fetched from S3 by the R script itself using the same AWS credentials.

## Key Benefits

- **No volume mounts for scripts** — scripts and parameters live in S3
- **No Docker rebuilds** — edit `parameters.txt` in S3 or change `SCRIPT_NAME` to modify a run
- **Single credentials set** — the same AWS env vars serve both the entrypoint sync and the R script's S3 operations
- **Consistent workflow** — scripts, parameters, input, and output all flow through S3