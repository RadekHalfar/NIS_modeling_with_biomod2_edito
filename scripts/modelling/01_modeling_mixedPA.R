#!/usr/bin/env Rscript

# ========== Load Libraries ==========
library(biomod2)
library(terra)
library(dplyr)

# ========== paws dependency check ==========
if (!requireNamespace("paws", quietly = TRUE)) {
  stop("Package 'paws' is required for S3 access. Install it with install.packages('paws').")
}

# ========== Parameter Loader ==========
load_params <- function() {
  params_file <- Sys.getenv("PARAMS", unset = "/app/input/parameters.txt")
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

  get_str <- function(key, default = NULL) {
    v <- raw[[key]]
    if (is.null(v) || v == "" || v == "NULL") return(default)
    v
  }
  get_num <- function(key, default = NULL) {
    v <- raw[[key]]
    if (is.null(v) || v == "" || v == "NULL") return(default)
    as.numeric(v)
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
    v <- get_str(key)
    if (is.null(v)) stop(sprintf("Required parameter '%s' is missing.", key))
    v
  }

  list(
    species_list    = get_vec("species"),
    algorithms      = get_vec("algorithms"),
    pa_dist_min     = get_num("pa_dist_min"),
    pa_dist_max     = get_num("pa_dist_max"),
    cv_strategy     = require_str("cv_strategy"),
    cv_nb_rep       = get_num("cv_nb_rep",  default = 3),
    cv_perc         = get_num("cv_perc"),
    cv_k            = get_num("cv_k"),
    n_cores         = get_num("n_cores",    default = 1),
    env_file        = get_str("env_file",        default = "/app/input/myExpl_shelf_DISTFIX.tif"),
    env_file_s3_key = get_str("env_file_s3_key", default = ""),
    modeling_date   = get_str("modeling_date",   default = format(Sys.Date(), "%Y-%m-%d")),
    occ_date_suffix = get_str("occ_date_suffix", default = "2025-08-19")
  )
}

p <- load_params()
species_list    <- unique(p$species_list)
algorithms      <- p$algorithms
pa_dist_min     <- p$pa_dist_min
pa_dist_max     <- p$pa_dist_max
cv_strategy     <- p$cv_strategy
cv_nb_rep       <- p$cv_nb_rep
cv_perc         <- p$cv_perc
cv_k            <- p$cv_k
n_cores         <- p$n_cores
env_file        <- p$env_file
env_file_s3_key <- p$env_file_s3_key
modeling_date   <- p$modeling_date
occ_date_suffix <- p$occ_date_suffix

# ========== Fixed Internal Paths ==========
outdir      <- "/app/output"
scripts_dir <- "/app/scripts"
input_dir   <- "/app/input"

dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(scripts_dir)) stop(sprintf("scripts_dir not found: %s", scripts_dir))
if (!dir.exists(input_dir))   stop(sprintf("input_dir not found: %s",   input_dir))

# ========== Memory-Safe Settings ==========
tmp_dir <- file.path(outdir, "tmp")
dir.create(tmp_dir, showWarnings = FALSE)
terraOptions(memfrac = 0.5, tempdir = tmp_dir)

cat(">>> Species (", length(species_list), "):", paste(species_list, collapse = ", "), "\n")
cat(">>> Algorithms:", paste(algorithms, collapse = ", "), "\n")
cat(">>> Env file:", env_file, "\n")
cat(">>> Output dir:", outdir, "\n")

# ========== S3 Client ==========
build_s3_client <- function() {
  endpoint_raw  <- Sys.getenv("AWS_S3_ENDPOINT", "")
  access_key    <- Sys.getenv("AWS_ACCESS_KEY_ID",     "")
  secret_key    <- Sys.getenv("AWS_SECRET_ACCESS_KEY", "")
  session_token <- Sys.getenv("AWS_SESSION_TOKEN",     "")
  region        <- Sys.getenv("AWS_DEFAULT_REGION",    "waw3-1")

  all_empty <- endpoint_raw == "" && access_key == "" && secret_key == ""
  if (all_empty) {
    cat(">>> S3 not configured (AWS_S3_ENDPOINT/AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY unset); running in local-only mode.\n")
    return(NULL)
  }

  missing <- c(
    if (endpoint_raw == "") "AWS_S3_ENDPOINT",
    if (access_key == "")   "AWS_ACCESS_KEY_ID",
    if (secret_key == "")   "AWS_SECRET_ACCESS_KEY"
  )
  if (length(missing) > 0) {
    stop(sprintf(
      "S3 is partially configured but missing: %s. Set all of AWS_S3_ENDPOINT, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, or none of them for local-only mode.",
      paste(missing, collapse = ", ")
    ))
  }

  endpoint <- if (grepl("^https?://", endpoint_raw)) {
    endpoint_raw
  } else {
    paste0("https://", endpoint_raw)
  }

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

# ========== Load Environmental Data ==========
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
if (!file.exists(env_file)) stop(paste("Environmental raster not found locally or in S3:", env_file))

myExpl <- rast(env_file)

# ========== Set working directory so biomod2 writes outputs to /app/output ==========
setwd(outdir)

# ========== Mixed PA builder (Version 1 style) ==========
set.seed(123)

build_bm_format_mix <- function(myRespName, myResp, myRespXY, myExpl,
                                pa_dist_min, pa_dist_max, PA.nb.absences,
                                nb_rep = 3, mix_ratio = 1/2, dedup = TRUE, verbose = TRUE) {
  logf <- function(...) if (isTRUE(verbose)) cat(sprintf(...), "\n")

  # assumes you already defined: myRespName, myResp, myRespXY (cols X_WGS84,Y_WGS84), myExpl,
  # pa_dist_min, pa_dist_max, PA.nb.absences

  std_pa_names <- paste0("PA", seq_len(nb_rep))
  nb_abs_disk   <- as.integer(ceiling(PA.nb.absences * mix_ratio))
  nb_abs_random <- max(1L, PA.nb.absences - nb_abs_disk)
  logf(">> mix: nb_rep=%d  ratio=%.2f  PAs/rep=%d  (disk=%d, random=%d)",
       nb_rep, mix_ratio, PA.nb.absences, nb_abs_disk, nb_abs_random)

  # build vect with 'sp'
  df_sp <- data.frame(myRespXY$X_WGS84, myRespXY$Y_WGS84, myResp)
  names(df_sp) <- c("X_WGS84", "Y_WGS84", "sp")
  myResp_spat <- terra::vect(df_sp, geom = c("X_WGS84","Y_WGS84"), crs = "EPSG:4326")

  # generate PAs
  logf(">> bm_PseudoAbsences: disk...")
  t1 <- system.time({
    part_disk <- bm_PseudoAbsences(
      resp.var     = myResp_spat,
      expl.var     = myExpl,
      nb.rep       = nb_rep,
      strategy     = "disk",
      nb.absences  = nb_abs_disk,
      dist.min     = pa_dist_min,
      dist.max     = pa_dist_max,
      seed.val     = 123
    )
  }); logf(".. disk done in %.2f s", t1[3])

  logf(">> bm_PseudoAbsences: random...")
  t2 <- system.time({
    part_rand <- bm_PseudoAbsences(
      resp.var     = myResp_spat,
      expl.var     = myExpl,
      nb.rep       = nb_rep,
      strategy     = "random",
      nb.absences  = nb_abs_random,
      seed.val     = 123
    )
  }); logf(".. random done in %.2f s", t2[3])

  PART1 <- do.call(cbind, part_disk)
  PART2 <- do.call(cbind, part_rand)
  logf(">> PART1 cols: %s", paste(names(PART1), collapse = ", "))
  logf(">> PART2 cols: %s", paste(names(PART2), collapse = ", "))

  # detectors
  find_pa_cols <- function(df, nb_rep) {
    cols <- grep("^PA\\d+$", names(df), value = TRUE)
    if (length(cols) == nb_rep) return(cols)
    cols <- grep("PA\\d+$", names(df), value = TRUE)           # handles 'pa.tab.PA1' etc.
    if (length(cols) >= nb_rep) return(tail(cols, nb_rep))
    logical_cols <- names(df)[vapply(df, is.logical, TRUE)]
    if (length(logical_cols) >= nb_rep) return(tail(logical_cols, nb_rep))
    stop("Could not detect PA replicate columns.")
  }
  find_coord_cols <- function(df) {
    cand <- list(
      c("X_WGS84","Y_WGS84"),
      c("xy.x","xy.y"),
      c("lon","lat"),
      c("longitude","latitude"),
      c("x","y"), c("X","Y")
    )
    for (p in cand) if (all(p %in% names(df))) return(p)
    x <- grep("(X_WGS84|^xy\\.x$|lon|long|^x$)", names(df), ignore.case = TRUE, value = TRUE)
    y <- grep("(Y_WGS84|^xy\\.y$|lat|^y$)",      names(df), ignore.case = TRUE, value = TRUE)  # <- keep this corrected if you copy manually
    if (length(x) >= 1 && length(y) >= 1) return(c(x[1], y[1]))
    stop("Could not detect coordinate columns.")
  }

  pa_cols1 <- find_pa_cols(PART1, nb_rep)
  pa_cols2 <- find_pa_cols(PART2, nb_rep)
  coord1   <- find_coord_cols(PART1)
  xcol <- coord1[1]; ycol <- coord1[2]
  if (!"sp" %in% names(PART1)) stop("Column 'sp' not found in PART1.")
  if (!"sp" %in% names(PART2)) stop("Column 'sp' not found in PART2.")
  logf(">> Detected coord cols: x='%s', y='%s'", xcol, ycol)
  logf(">> Detected PA cols (disk): %s", paste(pa_cols1, collapse = ", "))
  logf(">> Detected PA cols (rand): %s", paste(pa_cols2, collapse = ", "))

  # subset PA rows
  n_pa1 <- sum(is.na(PART1$sp)); n_pa2 <- sum(is.na(PART2$sp))
  logf(">> PA rows: disk=%d  random=%d", n_pa1, n_pa2)
  P1 <- PART1[is.na(PART1$sp), c(xcol, ycol, pa_cols1), drop = FALSE]
  P2 <- PART2[is.na(PART2$sp), c(xcol, ycol, pa_cols2), drop = FALSE]

  # normalize names
  names(P1)[1:2] <- c("X_WGS84","Y_WGS84")
  names(P2)[1:2] <- c("X_WGS84","Y_WGS84")
  names(P1)[(ncol(P1)-nb_rep+1):ncol(P1)] <- std_pa_names
  names(P2)[(ncol(P2)-nb_rep+1):ncol(P2)] <- std_pa_names

  # combine & optionally dedup
  PA.table <- rbind(P1, P2)
  logf(">> Combined PA rows (pre-dedup): %d", nrow(PA.table))
  if (dedup) {
    before <- nrow(PA.table)
    PA.table <- stats::aggregate(
      PA.table[, std_pa_names, drop = FALSE],
      by = PA.table[, c("X_WGS84", "Y_WGS84"), drop = FALSE],
      FUN = function(x) any(x, na.rm = TRUE)
    )
    after <- nrow(PA.table)
    logf(">> Dedup: %d -> %d unique PA coords", before, after)
  }

  # BIOMOD inputs
  ind_pres <- which(myResp == 1)
  pres_xy  <- myRespXY[ind_pres, , drop = FALSE]
  newXY    <- rbind(pres_xy, as.data.frame(PA.table[, c("X_WGS84","Y_WGS84")]))
  newResp  <- c(rep(1, nrow(pres_xy)), rep(NA, nrow(PA.table)))
  logf(">> Final table sizes: pres=%d  PA=%d  total=%d",
       nrow(pres_xy), nrow(PA.table), nrow(newXY))

  pres_mat <- matrix(TRUE, nrow = nrow(pres_xy), ncol = nb_rep,
                     dimnames = list(NULL, std_pa_names))
  newPA <- rbind(pres_mat, as.matrix(PA.table[, std_pa_names, drop = FALSE]))

  logf(">> Calling BIOMOD_FormatingData ...")
  fmt <- BIOMOD_FormatingData(
    resp.name     = myRespName,
    resp.var      = newResp,
    resp.xy       = newXY,
    expl.var      = myExpl,
    PA.strategy   = "user.defined",
    PA.user.table = newPA,
    filter.raster = FALSE  # Not activated as occurrences were already thinned with d=10km
  )
  logf(">> Done.")
  return(fmt)
}

# ========== Cross-validation setup ==========
cv_args <- list(
  CV.strategy  = cv_strategy,
  CV.nb.rep    = cv_nb_rep,
  CV.perc      = cv_perc,
  OPT.strategy = 'bigboss',
  var.import   = 0,
  metric.eval  = c('TSS','AUCroc','POD',"POFD",'SR','BIAS'),
  nb.cpu       = n_cores,
  seed.val     = 123
)
if (cv_strategy %in% c("kfold", "block", "strat", "env")) cv_args$CV.k <- cv_k

# modeling id
env_name   <- tools::file_path_sans_ext(basename(env_file))
modeling_id <- paste(modeling_date, "mix50", cv_strategy, env_name, sep = "_") 

# ========== Run Modeling (per species) ==========
succeeded_species <- character(0)
failed_species <- character(0)
failed_reasons <- character(0)

for (myRespName in species_list) {
  cat("\n>>> Processing species:", myRespName, "\n")

  species_ok <- tryCatch({
    occ_filename <- paste0(myRespName, "_merged_thinned_", occ_date_suffix, ".csv")
    occ_path     <- file.path(input_dir, occ_filename)

    if (!file.exists(occ_path)) {
      s3_keys <- unique(c(
        safe_s3_key(s3_input_prefix, occ_filename),
        occ_filename
      ))
      for (key in s3_keys) {
        if (download_s3_object(s3_client, s3_bucket, key, occ_path)) break
      }
    }
    if (!file.exists(occ_path)) stop(paste("Occurrence file not found locally or in S3:", occ_path))
    cat(">>> Using occurrence file:", occ_path, "\n")

    occ_data <- read.csv(occ_path)
    myResp   <- as.numeric(occ_data$occurrenceStatus) # 1 / 0
    myRespXY <- occ_data[, c("longitude", "latitude")]
    colnames(myRespXY) <- c("X_WGS84", "Y_WGS84")

    # === Screen presences against the env stack (CRS + extent + NA) ===
    pv <- terra::vect(myRespXY, geom = c("X_WGS84", "Y_WGS84"), crs = "EPSG:4326")

    # (A) Which raster cell does each presence hit? (use extract with cells=TRUE)
    ext_cells <- terra::extract(myExpl[[1]], pv, cells = TRUE)  # columns: ID, cell, <layer values>
    cells <- ext_cells$cell
    out_of_extent <- is.na(cells)

    # (B) Any NA in ANY predictor band at those locations?
    ext_vals <- terra::extract(myExpl, pv)  # first column is ID
    na_any <- rowSums(is.na(ext_vals[, -1, drop = FALSE])) > 0

    keep_env <- !(out_of_extent | na_any)

    n_raw  <- sum(myResp == 1, na.rm = TRUE)
    myResp <- myResp[keep_env]
    myRespXY <- myRespXY[keep_env, , drop = FALSE]
    n_kept <- sum(myResp == 1, na.rm = TRUE)

    cat(sprintf(">>> Presences (raw): %d | outside extent: %d | NA in env: %d | kept: %d\n",
                n_raw, sum(out_of_extent, na.rm = TRUE), sum(na_any, na.rm = TRUE), n_kept))

    if (n_kept < 10) stop(paste("Species", myRespName, "has fewer than 10 usable presences after screening."))

    # === Now compute PAs/rep based on the KEPT presences ===
    if (n_kept <= 100) {
      PA.nb.absences <- min(n_kept * 3, 500)
    } else {
      PA.nb.absences <- n_kept * 3
    }
    cat(">>> Using PAs/rep:", PA.nb.absences, "\n")

    myBiomodData.PA <- build_bm_format_mix(
      myRespName = myRespName,
      myResp = myResp,
      myRespXY = myRespXY,
      myExpl = myExpl,
      pa_dist_min = pa_dist_min,
      pa_dist_max = pa_dist_max,
      PA.nb.absences = PA.nb.absences
    )

    cat(">>> Pseudo-absence summary:\n")
    print(table(myBiomodData.PA@data.species))

    myBiomodModelOut <- do.call(BIOMOD_Modeling, c(
      list(
        bm.format   = myBiomodData.PA,
        models      = algorithms,
        modeling.id = modeling_id
      ),
      cv_args
    ))

    eval <- get_evaluations(myBiomodModelOut)
    eval_df <- as.data.frame(eval)
    write.csv(eval_df,
              file = file.path(outdir, paste0("eval_", myRespName, "_", modeling_id, ".csv")),
              row.names = FALSE)

    cat(">>> Done for", myRespName, "\n")
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
