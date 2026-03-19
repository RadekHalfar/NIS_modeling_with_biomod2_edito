# Docker Setup: Scripts-Mounted Workflow

This project is now configured to mount the `scripts/` folder into the Docker container. This means you can edit R scripts locally without rebuilding the Docker image.

## Directory Structure

```
.
├── Dockerfile              (build configuration)
├── scripts/               (mounted at /app/scripts in container)
│   ├── entrypoint.sh      (wrapper script that routes to R scripts)
│   ├── modeling_mixedPA.R (main R script - EDITABLE)
│   └── ...                (add more R scripts here)
├── input/                 (sample data - mounted at /app/input)
└── output/                (results - mounted at /app/output)
```

## Build the Docker Image

Build once:

```powershell
docker build -t biomod2-modeling:latest .
```

## Run the Container

The container now uses a wrapper script (`entrypoint.sh`) that routes to your R scripts. The first argument specifies which script to run.

### Basic Run with Default Script

Runs `modeling_mixedPA.R` with default arguments:

```powershell
docker run --rm `
  -v "${PWD}\scripts:/app/scripts" `
  -v "${PWD}\input:/app/input:ro" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest
```

### Run with Custom Arguments for Default Script

```powershell
docker run --rm `
  -v "${PWD}\scripts:/app/scripts" `
  -v "${PWD}\input:/app/input:ro" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest `
  modeling_mixedPA.R Bugulaneritina GLM,GAM,RF,MAXNET 2000 100000 kfold 3 NULL 5 4 /app/input/myExpl_shelf_DISTFIX.tif /app/output scripts input
```

Argument order for `modeling_mixedPA.R`:

`<species> <algorithms> <PA_dist_min> <PA_dist_max> <CV_strategy> <CV_nb_rep> <CV_perc_or_NULL> <CV_k_or_NULL> <n_cores> <env_file> <outdir> [scripts_dir] [input_dir]`

### Run a Different Script

If you add `preprocessing.R` or `analysis.R` to the scripts folder:

```powershell
docker run --rm `
  -v "${PWD}\scripts:/app/scripts" `
  -v "${PWD}\input:/app/input:ro" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest `
  preprocessing.R arg1 arg2 arg3
```

### Use Custom Folder Names

You can change script folder name, input folder name, and output folder path by passing them as arguments.

```powershell
docker run --rm `
  -v "${PWD}\my_scripts:/app/my_scripts" `
  -v "${PWD}\my_input:/app/my_input:ro" `
  -v "${PWD}\my_results:/app/my_results" `
  biomod2-modeling:latest `
  modeling_mixedPA.R Bugulaneritina GLM,GAM,RF,MAXNET 2000 100000 kfold 3 NULL 5 4 /app/my_input/myExpl_shelf_DISTFIX.tif /app/my_results my_scripts my_input
```

### List Available Scripts

```powershell
docker run --rm `
  -v "${PWD}\scripts:/app/scripts" `
  biomod2-modeling:latest
```

### Edit or Add Scripts Without Rebuilding

1. **Create or modify** R scripts in the `scripts/` folder (e.g., `preprocessing.R`, `analysis.R`)
2. **Run** the container with the new script name
3. **No rebuild needed!** The wrapper script automatically finds and runs any `.R` file in the folder

## Usage Pattern

```powershell
# 1. Create or edit scripts in scripts folder
notepad scripts\modeling_mixedPA.R
notepad scripts\preprocessing.R

# 2. Run with default script and args
docker run --rm `
  -v "${PWD}\scripts:/app/scripts" `
  -v "${PWD}\input:/app/input:ro" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest

# 3. Or run a different script (no rebuild needed!)
docker run --rm `
  -v "${PWD}\scripts:/app/scripts" `
  -v "${PWD}\input:/app/input:ro" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest `
  preprocessing.R --input input/data.csv --output output/processed.csv

# 4. Or keep script same but use custom folders
docker run --rm `
  -v "${PWD}\my_scripts:/app/my_scripts" `
  -v "${PWD}\my_input:/app/my_input:ro" `
  -v "${PWD}\my_results:/app/my_results" `
  biomod2-modeling:latest `
  modeling_mixedPA.R Bugulaneritina GLM,GAM,RF,MAXNET 2000 100000 kfold 3 NULL 5 4 /app/my_input/myExpl_shelf_DISTFIX.tif /app/my_results my_scripts my_input

# 5. Check results
dir output\
```

## Environment Variables

You can pass environment variables for S3 integration:

```powershell
docker run --rm `
  -e AWS_S3_ENDPOINT="your-s3-endpoint" `
  -e AWS_ACCESS_KEY_ID="your-key" `
  -e AWS_SECRET_ACCESS_KEY="your-secret" `
  -v "${PWD}\scripts:/app/scripts" `
  -v "${PWD}\input:/app/input:ro" `
  -v "${PWD}\output:/app/output" `
  biomod2-modeling:latest
```

## Key Benefits

- **No Docker rebuilds** when editing or adding R scripts
- **Flexible workflow** — run any script in the `scripts/` folder without changing Dockerfile
- **Fast iteration** — edit → run → check results
- **Single entry point** — wrapper script (`entrypoint.sh`) routes to different R files
- **All volumes persistent** (input, output, scripts)
