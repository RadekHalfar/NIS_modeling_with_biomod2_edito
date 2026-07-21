# ========== Load Libraries ==========
library(biomod2)
library(dplyr)
library(terra)

# ========== paws dependency check ==========
if (!requireNamespace("paws", quietly = TRUE)) {
  stop("Package 'paws' is required for S3 access. Install it with install.packages('paws').")
}

# ========== Parameter Loader ==========
load_params <- function() {
  params_file <- Sys.getenv("PARAMS", unset = "/app/input/parameters.txt")
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
  get_vec <- function(key) {
    v <- raw[[key]]
    if (is.null(v) || v == "") stop(sprintf("Required parameter '%s' is missing or empty.", key))
    vals <- trimws(strsplit(v, ",")[[1]])
    vals <- vals[nchar(vals) > 0]
    if (length(vals) == 0) stop(sprintf("Required parameter '%s' is empty after parsing.", key))
    vals
  }
  require_str <- function(key) {
    v <- raw[[key]]
    if (is.null(v) || v == "" || v == "NULL") stop(sprintf("Required parameter '%s' is missing.", key))
    v
  }
  list(
    species_list = get_vec("species"),
    modeling_id = require_str("modeling_id"),
    n_cores     = get_num("n_cores", default = 1)
  )
}

p <- load_params()
species_list <- unique(p$species_list)
modeling_id <- p$modeling_id
n_cores     <- p$n_cores

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
s3_output_prefix <- Sys.getenv("S3_OUTPUT_PREFIX", "output")

# ========== S3 Helper Functions ==========
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

cat(">>> Species (", length(species_list), "):", paste(species_list, collapse = ", "), "\n")

# ========== Ensemble Modeling (per species) ==========
succeeded_species <- character(0)
failed_species <- character(0)
failed_reasons <- character(0)

for (myRespName in species_list) {
  cat("\n>>> Processing species:", myRespName, "\n")

  species_ok <- tryCatch({
    model_dir  <- myRespName
    model_file <- file.path(model_dir, paste(myRespName, modeling_id, "models.out", sep = "."))
    if (!file.exists(model_file)) {
      s3_model_prefix <- paste0(gsub("/+$", "", s3_output_prefix), "/", myRespName, "/")
      cat(">>> Model not found locally; attempting S3 download from", s3_model_prefix, "\n")
      download_s3_prefix(s3_client, s3_bucket, s3_model_prefix, file.path(outdir, myRespName))
    }
    if (!file.exists(model_file)) stop("Model file not found: ", model_file)

    loaded_name      <- load(model_file)
    myBiomodModelOut <- get(loaded_name)

    myBiomodEM <- BIOMOD_EnsembleModeling(
      bm.mod        = myBiomodModelOut,
      models.chosen = "all",
      em.by         = "all",
      em.algo       = c("EMwmean", "EMcv", "EMca"),
      EMwmean.decay = "proportional",
      metric.select = c("TSS", "AUCroc"),
      metric.select.thresh = c(0.6, 0.85),
      metric.eval   = c("TSS", "AUCroc"),
      var.import    = 0,
      nb.cpu        = n_cores
    )

    em_eval <- as.data.frame(get_evaluations(myBiomodEM))
    write.csv(em_eval,
              file = file.path(outdir, paste0("full_eval_EM_", myRespName, "_", modeling_id, ".csv")),
              row.names = FALSE)

    cat(">>> Done with ensemble for", myRespName, "\n")
    TRUE
  }, error = function(e) {
    msg <- conditionMessage(e)
    cat(">>> Species failed:", myRespName, "-", msg, "\n")
    failed_species <<- c(failed_species, myRespName)
    failed_reasons <<- c(failed_reasons, msg)
    FALSE
  })

  if (isTRUE(species_ok)) {
    succeeded_species <- c(succeeded_species, myRespName)
  }

  gc()
}

cat("\n>>> Species summary: succeeded=", length(succeeded_species),
    " failed=", length(failed_species), "\n", sep = "")
if (length(succeeded_species) > 0) {
  cat(">>> Succeeded:", paste(succeeded_species, collapse = ", "), "\n")
}
if (length(failed_species) > 0) {
  for (i in seq_along(failed_species)) {
    cat(">>> Failed:", failed_species[[i]], "-", failed_reasons[[i]], "\n")
  }
}
if (length(succeeded_species) == 0) {
  stop("No species completed successfully.")
}

# ========== Upload outputs to S3 ==========
if (!is.null(s3_client) && s3_bucket != "") {
  cat(">>> Uploading outputs to s3://", s3_bucket, "/", s3_output_prefix, "\n", sep = "")
  upload_dir_to_s3(s3_client, s3_bucket, outdir, s3_output_prefix)
  cat(">>> Upload complete\n")
} else {
  cat(">>> Skipping S3 upload: no S3 client or bucket configured\n")
}

