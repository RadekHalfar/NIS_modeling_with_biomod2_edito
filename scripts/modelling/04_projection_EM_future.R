# ========== Load Libraries ==========
library(terra)
library(biomod2)

# ========== paws dependency check ==========
if (!requireNamespace("paws", quietly = TRUE)) {
  stop("Package 'paws' is required for S3 access. Install it with install.packages('paws').")
}

# ========== Parameter Loader ==========
load_params <- function() {
  params_file <- Sys.getenv("PARAMS", unset = "/app/scripts/PARAMS")
  if (!file.exists(params_file)) {
    stop(sprintf("Parameters file not found: %s  (set PARAMS env var to override)", params_file))
  }
  lines <- readLines(params_file, warn = FALSE)
  lines <- trimws(lines)
  lines <- lines[nchar(lines) > 0 & !startsWith(lines, "#")]
  raw <- list()
  for (line in lines) {
    idx <- regexpr("=", line, fixed = TRUE)
    if (idx < 1) { warning(sprintf("Skipping malformed line in params file: %s", line)); next }
    key <- trimws(substr(line, 1, idx - 1))
    value <- trimws(substr(line, idx + 1, nchar(line)))
    raw[[key]] <- value
  }
  get_num <- function(key, default = NULL) {
    v <- raw[[key]]; if (is.null(v) || v == "" || v == "NULL") return(default); as.numeric(v)
  }
  get_str <- function(key, default = NULL) {
    v <- raw[[key]]; if (is.null(v) || v == "" || v == "NULL") return(default); v
  }
  require_str <- function(key) {
    v <- raw[[key]]
    if (is.null(v) || v == "" || v == "NULL") stop(sprintf("Required parameter '%s' is missing.", key))
    v
  }
  list(
    myRespName            = require_str("species"),
    modeling_id           = require_str("modeling_id"),
    n_cores               = get_num("n_cores", default = 1),
    proj_env_file         = get_str("proj_env_file",          default = "/app/input/myExpl_shelf.tif"),
    proj_env_file_s3_key  = get_str("proj_env_file_s3_key",   default = ""),
    ssp126_env_file       = get_str("ssp126_env_file",        default = "/app/input/ssp126_shelf_2100.tif"),
    ssp126_env_file_s3_key= get_str("ssp126_env_file_s3_key", default = ""),
    ssp245_env_file       = get_str("ssp245_env_file",        default = "/app/input/ssp245_shelf_2100.tif"),
    ssp245_env_file_s3_key= get_str("ssp245_env_file_s3_key", default = ""),
    ssp585_env_file       = get_str("ssp585_env_file",        default = "/app/input/ssp585_shelf_2100.tif"),
    ssp585_env_file_s3_key= get_str("ssp585_env_file_s3_key", default = "")
  )
}

p <- load_params()
myRespName             <- p$myRespName
modeling_id            <- p$modeling_id
n_cores                <- p$n_cores
proj_env_file          <- p$proj_env_file
proj_env_file_s3_key   <- p$proj_env_file_s3_key
ssp126_env_file        <- p$ssp126_env_file
ssp126_env_file_s3_key <- p$ssp126_env_file_s3_key
ssp245_env_file        <- p$ssp245_env_file
ssp245_env_file_s3_key <- p$ssp245_env_file_s3_key
ssp585_env_file        <- p$ssp585_env_file
ssp585_env_file_s3_key <- p$ssp585_env_file_s3_key

# ========== Fixed Internal Paths ==========
outdir    <- "/app/output"
input_dir <- "/app/input"
dir.create(outdir, recursive = TRUE, showWarnings = FALSE)

# ========== S3 Client ==========
build_s3_client <- function() {
  endpoint_raw <- Sys.getenv("AWS_S3_ENDPOINT", "")
  if (endpoint_raw == "") return(NULL)
  endpoint <- if (grepl("^https?://", endpoint_raw)) endpoint_raw else paste0("https://", endpoint_raw)
  access_key    <- Sys.getenv("AWS_ACCESS_KEY_ID",     "")
  secret_key    <- Sys.getenv("AWS_SECRET_ACCESS_KEY", "")
  session_token <- Sys.getenv("AWS_SESSION_TOKEN",     "")
  region        <- Sys.getenv("AWS_DEFAULT_REGION",    "waw3-1")
  if (access_key == "" || secret_key == "") return(NULL)
  creds <- list(access_key_id = access_key, secret_access_key = secret_key)
  if (session_token != "") creds$session_token <- session_token
  paws::s3(config = list(credentials = list(creds = creds), endpoint = endpoint, region = region))
}

s3_client        <- build_s3_client()
s3_bucket        <- Sys.getenv("S3_BUCKET",        "")
s3_input_prefix  <- Sys.getenv("S3_INPUT_PREFIX",  "input")
s3_output_prefix <- Sys.getenv("S3_OUTPUT_PREFIX", "output")

# ========== S3 Helper Functions ==========
safe_s3_key <- function(prefix, filename) {
  if (prefix == "") return(filename)
  paste0(gsub("/+$", "", prefix), "/", filename)
}

download_s3_object <- function(s3, bucket, key, dest_path) {
  if (is.null(s3) || bucket == "" || key == "") return(FALSE)
  dir.create(dirname(dest_path), recursive = TRUE, showWarnings = FALSE)
  ok <- tryCatch({
    obj  <- s3$get_object(Bucket = bucket, Key = key)
    body <- obj$Body
    if (is.raw(body)) writeBin(body, dest_path)
    else if (is.character(body)) writeBin(charToRaw(paste(body, collapse = "")), dest_path)
    else stop("Unsupported response body type from S3.")
    TRUE
  }, error = function(e) {
    cat(">>> S3 download failed:", paste0("s3://", bucket, "/", key), "-", conditionMessage(e), "\n"); FALSE
  })
  if (ok) cat(">>> Downloaded", paste0("s3://", bucket, "/", key), "->", dest_path, "\n")
  ok
}

download_s3_prefix <- function(s3, bucket, s3_prefix, local_dir) {
  if (is.null(s3) || bucket == "" || s3_prefix == "") return(invisible(FALSE))
  tryCatch({
    response <- s3$list_objects_v2(Bucket = bucket, Prefix = s3_prefix)
    objects  <- response$Contents
    while (isTRUE(response$IsTruncated)) {
      response <- s3$list_objects_v2(Bucket = bucket, Prefix = s3_prefix,
                                     ContinuationToken = response$NextContinuationToken)
      objects <- c(objects, response$Contents)
    }
    if (length(objects) == 0) {
      cat(">>> No objects found under s3://", bucket, "/", s3_prefix, "\n", sep = "")
      return(invisible(FALSE))
    }
    prefix_clean <- gsub("/+$", "", s3_prefix)
    for (obj in objects) {
      key      <- obj$Key
      rel_path <- sub(paste0("^", prefix_clean, "/?" ), "", key)
      if (rel_path == "") next
      download_s3_object(s3, bucket, key, file.path(local_dir, rel_path))
    }
    invisible(TRUE)
  }, error = function(e) {
    cat(">>> S3 prefix download failed:", s3_prefix, "-", conditionMessage(e), "\n")
    invisible(FALSE)
  })
}

upload_to_s3 <- function(s3, bucket, local_path, s3_key) {
  if (is.null(s3) || bucket == "" || !file.exists(local_path)) return(FALSE)
  ok <- tryCatch({
    s3$put_object(Bucket = bucket, Key = s3_key,
                  Body = readBin(local_path, what = "raw", n = file.info(local_path)$size))
    TRUE
  }, error = function(e) {
    cat(">>> S3 upload failed:", paste0("s3://", bucket, "/", s3_key), "-", conditionMessage(e), "\n"); FALSE
  })
  if (ok) cat(">>> Uploaded", local_path, "->", paste0("s3://", bucket, "/", s3_key), "\n")
  ok
}

upload_dir_to_s3 <- function(s3, bucket, local_dir, s3_prefix) {
  if (is.null(s3) || bucket == "" || !dir.exists(local_dir)) return(invisible(NULL))
  files <- list.files(local_dir, recursive = TRUE, full.names = TRUE)
  for (f in files) {
    rel <- sub(paste0("^", normalizePath(local_dir, mustWork = FALSE), "[/\\\\]"), "",
               normalizePath(f, mustWork = FALSE))
    key <- if (s3_prefix == "") rel else paste0(gsub("/+$", "", s3_prefix), "/", rel)
    upload_to_s3(s3, bucket, f, key)
  }
}

# ========== Set working directory (biomod2 writes relative to cwd) ==========
setwd(outdir)

# ========== Memory-Safe Settings ==========
tmp_dir <- file.path(outdir, "tmp")
dir.create(tmp_dir, showWarnings = FALSE)
terraOptions(memfrac = 0.5, tempdir = tmp_dir)

# ========== Load Ensemble Model ==========
model_dir  <- myRespName
model_file <- file.path(model_dir, paste(myRespName, modeling_id, "ensemble.models.out", sep = "."))
if (!file.exists(model_file)) {
  s3_model_prefix <- paste0(gsub("/+$", "", s3_output_prefix), "/", myRespName, "/")
  cat(">>> Model not found locally; attempting S3 download from", s3_model_prefix, "\n")
  download_s3_prefix(s3_client, s3_bucket, s3_model_prefix, file.path(outdir, myRespName))
}
if (!file.exists(model_file)) {
  cat("! Ensemble models file not found: ", model_file, "\n", sep = "")
  quit(status = 0)  # exit cleanly so SLURM array continues
}

loaded_name <- load(model_file)
myBiomodEM  <- get(loaded_name, inherits = FALSE)
if (!inherits(myBiomodEM, "BIOMOD.ensemble.models.out")) {
  stop("Loaded object is not a BIOMOD.ensemble.models.out: ", loaded_name)
}

# ========== Load Reference Environmental Layers ==========
if (!file.exists(proj_env_file)) {
  env_keys <- unique(Filter(nzchar, c(
    proj_env_file_s3_key,
    safe_s3_key(s3_input_prefix, basename(proj_env_file)),
    basename(proj_env_file)
  )))
  for (key in env_keys) {
    if (download_s3_object(s3_client, s3_bucket, key, proj_env_file)) break
  }
}
if (!file.exists(proj_env_file)) stop("Environmental raster not found locally or in S3: ", proj_env_file)
myExpl <- rast(proj_env_file)

# ========== Build lookup table for future env files ==========
scenario_env_files <- list(
  ssp126 = list(file = ssp126_env_file, s3_key = ssp126_env_file_s3_key),
  ssp245 = list(file = ssp245_env_file, s3_key = ssp245_env_file_s3_key),
  ssp585 = list(file = ssp585_env_file, s3_key = ssp585_env_file_s3_key)
)

# ========== Which ensemble types to use ==========
avail   <- biomod2::get_built_models(myBiomodEM)
keep_em <- avail[grepl("(_EMwmeanByTSS|_EMcvByTSS|_EMcaByTSS)(_|$)", avail)]
if (length(keep_em) == 0) {
  cat("! No EMwmeanByTSS/EMcvByTSS/EMcaByTSS types found — skipping species.\n")
  quit(status = 0)
}
cat("▶ Ensemble types to forecast:\n")
print(keep_em)

# ========== Run Future Projections ==========
scenarios <- c("ssp126", "ssp245", "ssp585") # can also run one scenario at a time for less computation

for (scenario in scenarios) {
  proj_name       <- paste0(scenario, "EM_", myRespName, "_", modeling_id)
  proj_future_dir <- file.path(model_dir, paste0("proj_", proj_name))

  scenario_info   <- scenario_env_files[[scenario]]
  env_path_future <- scenario_info$file
  s3_key_future   <- scenario_info$s3_key

  if (!file.exists(env_path_future)) {
    env_keys_future <- unique(Filter(nzchar, c(
      s3_key_future,
      safe_s3_key(s3_input_prefix, basename(env_path_future)),
      basename(env_path_future)
    )))
    for (key in env_keys_future) {
      if (download_s3_object(s3_client, s3_bucket, key, env_path_future)) break
    }
  }
  if (!file.exists(env_path_future)) {
    cat("! Missing env for ", scenario, ": ", env_path_future, " - skipping this scenario.\n", sep = "")
    next
  }

  myExpl_future <- rast(env_path_future)

  # strict check: band names must match current env
  if (!identical(names(myExpl_future), names(myExpl))) {
    stop("Layer names/order mismatch for ", scenario, ".\nCurrent: ",
         paste(names(myExpl), collapse = ", "),
         "\nFuture:  ", paste(names(myExpl_future), collapse = ", "))
  }

  cat("\n Running Future Ensemble Forecasting: ", myRespName, " | ", scenario, " | cores=", n_cores, "\n", sep = "")
  tryCatch({
    myBiomodEMProj_Future <- BIOMOD_EnsembleForecasting(
      bm.em         = myBiomodEM,
      proj.name     = proj_name,
      new.env       = myExpl_future,
      models.chosen = keep_em,
      nb.cpu        = n_cores,
      do.stack      = FALSE
    )
    cat("✔ Done: ", scenario, "\n", sep = "")
  }, error = function(e) {
    cat("✖ Failed: ", scenario, " — ", conditionMessage(e), "\n", sep = "")
  })
}

cat(">>> Done! Projections are in: ", normalizePath(model_dir, winslash = "/"), "\n", sep = "")

# ========== Upload outputs to S3 ==========
if (!is.null(s3_client) && s3_bucket != "") {
  cat(">>> Uploading outputs to s3://", s3_bucket, "/", s3_output_prefix, "\n", sep = "")
  upload_dir_to_s3(s3_client, s3_bucket, outdir, s3_output_prefix)
  cat(">>> Upload complete\n")
} else {
  cat(">>> Skipping S3 upload: no S3 client or bucket configured\n")
}
