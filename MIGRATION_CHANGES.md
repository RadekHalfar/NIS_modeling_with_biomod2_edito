# EDITO Migration — Change Report

Changes applied to R scripts in `scripts/modelling/` to make them compatible with the EDITO platform (Docker-based, S3 I/O, no local filesystem access). Reference: `EDITO_MIGRATION_GUIDE.md`.

---

## scripts/PARAMS  *(new file)*

Created a shared parameter file for all 4 modelling scripts. Read by each script at startup; unused keys are silently ignored.

**Contents:**

| Key | Used by | Purpose |
|---|---|---|
| `species` | 01–04 | Species name (matches occurrence CSV filename) |
| `algorithms` | 01 | Comma-separated biomod2 model types |
| `cv_strategy`, `cv_nb_rep`, `cv_k`, `cv_perc` | 01 | Cross-validation settings |
| `modeling_date` | 01 | Date tag used when constructing `modeling_id` |
| `pa_dist_min`, `pa_dist_max` | 01 | Pseudo-absence distance buffer (metres) |
| `env_file`, `env_file_s3_key` | 01 | Current env raster path + S3 key for model fitting |
| `modeling_id` | 02–04 | Full ID string produced by script 01 (e.g. `2025-08-19_mix50_kfold_myExpl_shelf_DISTFIX`) |
| `proj_env_file`, `proj_env_file_s3_key` | 03, 04 | Current env raster for projection (different file from `env_file`) |
| `ssp126/245/585_env_file`, `…_s3_key` | 04 | Future scenario env rasters + S3 keys |
| `n_cores` | 01–04 | CPU count (replaces SLURM env var in 02–04) |

---

## scripts/modelling/01_modeling_mixedPA.R

**Parameter loading**
- Removed all 12 `commandArgs()` positional argument reads.
- Added `load_params()` function that reads `scripts/PARAMS` (path overridable via `PARAMS` env var).
- `modeling_date` defaults to `format(Sys.Date(), "%Y-%m-%d")` when not set in PARAMS.

**Fixed paths**
- `outdir` hardcoded to `/app/output` (container path).
- `input_dir` hardcoded to `/app/input`.
- `scripts_dir` hardcoded to `/app/scripts`.
- Added `setwd(outdir)` before biomod2 calls so model files are written to `/app/output`.

**S3 integration**
- Added `paws` dependency check at startup (stops with clear message if missing).
- Added `build_s3_client()` using env vars `AWS_S3_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_DEFAULT_REGION`.
- Added S3 helper functions: `safe_s3_key()`, `download_s3_object()`, `upload_to_s3()`, `upload_dir_to_s3()`.
- Occurrence CSV loading: first tries `file.path(input_dir, occ_filename)`, falls back to S3 download if not found.
- Env raster loading: first tries `env_file` path, falls back to S3 download via `env_file_s3_key`.
- Added `upload_dir_to_s3()` call at end of script to upload all output files to S3.

---

## scripts/modelling/02_ensemble.R

**Parameter loading**
- Removed `commandArgs()` reads for `species` and `modeling_id`.
- Removed `Sys.getenv("SLURM_CPUS_PER_TASK")` for core count — replaced with `n_cores` from PARAMS.
- Added `load_params()` (same as script 01).

**Fixed paths**
- `outdir`, `input_dir`, `scripts_dir` set to fixed container paths.
- `output_dir = "EM_mix50"` → `outdir` (results written to `/app/output`, not a subdirectory).
- Added `setwd(outdir)` so biomod2 can locate model files.

**S3 integration**
- Added full EDITO boilerplate (paws check, S3 client, helpers).
- Added new helper `download_s3_prefix(s3, bucket, s3_prefix, local_dir)` — lists all objects under an S3 prefix and downloads them maintaining relative paths. Needed because biomd2 model outputs are complex nested directory trees, not single files.
- Model loading: tries local `/app/output/{species}/{species}.{modeling_id}.models.out` first; if missing, downloads the entire `{s3_output_prefix}/{species}/` prefix from S3.
- Added `upload_dir_to_s3()` call at end.

---

## scripts/modelling/03_projection_EM.R

**Parameter loading**
- Removed `commandArgs()` reads for `species`, `modeling_id`, `n_cores`.
- Added `load_params()` (same as script 01).
- Added `proj_env_file` and `proj_env_file_s3_key` parameters (separate from script 01's `env_file` — projection uses `myExpl_shelf.tif`, not `myExpl_shelf_DISTFIX.tif`).

**Fixed paths**
- `outdir`, `input_dir`, `scripts_dir` set to fixed container paths.
- `tmp_dir` changed from `file.path(getwd(), "tmp")` to `file.path(outdir, "tmp")` — evaluated after `setwd(outdir)` to avoid wrong path.
- Added `setwd(outdir)`.

**S3 integration**
- Added full EDITO boilerplate including `download_s3_prefix()`.
- Env raster loading: uses `proj_env_file` with S3 fallback via `proj_env_file_s3_key`.
- Ensemble model loading: downloads `{s3_output_prefix}/{species}/` prefix when `.ensemble.models.out` not found locally.
- Added `upload_dir_to_s3()` call at end.

**Bug fix**
- `my RespName` (variable name with a space — pre-existing syntax error) corrected to `myRespName`.

---

## scripts/modelling/04_projection_EM_future.R

**Parameter loading**
- Removed `commandArgs()` reads for `species`, `modeling_id`, `n_cores`.
- Added `load_params()`.
- Added `proj_env_file`/`proj_env_file_s3_key` (current climate raster).
- Added per-scenario parameters: `ssp126_env_file`, `ssp126_env_file_s3_key`, `ssp245_env_file`, `ssp245_env_file_s3_key`, `ssp585_env_file`, `ssp585_env_file_s3_key`.

**Fixed paths**
- Same as script 03 (`outdir`, `input_dir`, `scripts_dir`, `tmp_dir`, `setwd(outdir)`).

**S3 integration**
- Added full EDITO boilerplate including `download_s3_prefix()`.
- Current env raster loading uses `proj_env_file` with S3 fallback.
- Hardcoded future raster filenames (`paste0(scenario, "_shelf_2100.tif")`) replaced with a `scenario_env_files` named list populated from PARAMS. Each scenario's raster is downloaded from S3 inside the for-loop if not found locally.
- Ensemble model downloaded from S3 when missing.
- Added `upload_dir_to_s3()` call at end.

**Other fixes**
- Em-dash character (`—`) in a `cat()` message replaced with ` - ` (ASCII-safe).
- Unicode tick/cross symbols in final `cat()` messages replaced with ASCII equivalents.

---

## Scripts NOT modified

| Folder | Files | Reason |
|---|---|---|
| `scripts/figures/` | Figure_1–6 | Local visualization scripts; use `base_dir <- "path/to/..."` set manually |
| `scripts/pre-modelling/occurrence data/` | 01–04 | Local/HPC data download and thinning scripts |
| `scripts/pre-modelling/environmental data/` | 01–08 | Local/HPC Bio-Oracle download and processing scripts |
| `scripts/post-modelling processing/` | post-mod processing.r | Local post-processing; reads outputs downloaded from HPC/EDITO |
| `scripts/contingency.areas.computing/` | cold.spot.* (4 files) | Local cold-spot analysis; orchestrated by masterscript on researcher's machine |
