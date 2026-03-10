#!/usr/bin/env Rscript

# ========== Load Libraries ==========
library(biomod2)
library(terra)
library(dplyr)

if (!requireNamespace("paws", quietly = TRUE)) {
  stop("Package 'paws' is required. Install it with install.packages('paws').")
}

# ========== Parse Command Line Args ==========
# Usage: modeling_mixedPA.R <species> <algorithms> <PA_dist_min> <PA_dist_max>
#                           <CV_strategy> <CV_nb_rep> <CV_perc_or_NULL> <CV_k_or_NULL>
#                           <n_cores> <env_file> <outdir>
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 11) {
  stop("Usage: modeling_mixedPA.R <species> <algorithms> <PA_dist_min> <PA_dist_max> <CV_strategy> <CV_nb_rep> <CV_perc_or_NULL> <CV_k_or_NULL> <n_cores> <env_file> <outdir>")
}

myRespName   <- args[1]
algorithms   <- strsplit(args[2], ",")[[1]]
pa_dist_min  <- if (args[3] == "NULL" | args[3] == "") NULL else as.numeric(args[3])
pa_dist_max  <- if (args[4] == "NULL" | args[4] == "") NULL else as.numeric(args[4])
cv_strategy  <- args[5]
cv_nb_rep    <- as.numeric(args[6])
cv_perc      <- if (args[7] == "NULL" | args[7] == "") NULL else as.numeric(args[7])
cv_k         <- if (args[8] == "NULL" | args[8] == "") NULL else as.numeric(args[8])
n_cores      <- as.numeric(args[9])
env_file     <- args[10]
outdir       <- args[11]

dir.create(outdir, recursive = TRUE, showWarnings = FALSE)

cat(">>> Species:", myRespName, "\n")
cat(">>> Algorithms:", paste(algorithms, collapse = ", "), "\n")
cat(">>> Env file:", env_file, "\n")
cat(">>> Output dir:", outdir, "\n")

# ========== Input Diagnostics ==========
cat(">>> Input diagnostics start\n")
cat(">>> Working directory:", getwd(), "\n")
cat(">>> Expected occurrence file:", paste0(myRespName, "_merged_thinned_2025-08-19.csv"), "\n")

safe_list <- function(path) {
  if (!dir.exists(path)) {
    cat(">>> Directory missing:", path, "\n")
    return(invisible(NULL))
  }
  entries <- list.files(path, full.names = TRUE)
  cat(">>> Listing", path, "(showing up to 30):\n")
  if (length(entries) == 0) {
    cat(">>>   <empty>\n")
  } else {
    print(head(entries, 30))
  }
}

safe_list(".")
safe_list("input")
safe_list("/app")
safe_list("/app/input")

diag_roots <- c(".", "input", "/app", "/app/input")
diag_hits <- unique(unlist(lapply(diag_roots, function(root) {
  if (!dir.exists(root)) return(character(0))
  list.files(root, pattern = "_merged_thinned_2025-08-19\\.csv$", recursive = TRUE, full.names = TRUE)
})))

cat(">>> Found occurrence-like CSV files (up to 100):\n")
if (length(diag_hits) == 0) {
  cat(">>>   <none>\n")
} else {
  print(head(diag_hits, 100))
}
cat(">>> Input diagnostics end\n")

# ========== S3 Helpers (EDITO personal storage) ==========
build_s3_client <- function() {
  endpoint_raw <- Sys.getenv("AWS_S3_ENDPOINT", Sys.getenv("S3_ENDPOINT", ""))
  if (endpoint_raw == "") return(NULL)

  endpoint <- if (grepl("^https?://", endpoint_raw)) endpoint_raw else paste0("https://", endpoint_raw)
  region <- Sys.getenv("AWS_DEFAULT_REGION", "waw3-1")
  access_key <- Sys.getenv("AWS_ACCESS_KEY_ID", "")
  secret_key <- Sys.getenv("AWS_SECRET_ACCESS_KEY", "")
  session_token <- Sys.getenv("AWS_SESSION_TOKEN", "")

  if (access_key == "" || secret_key == "") return(NULL)

  creds <- list(
    access_key_id = access_key,
    secret_access_key = secret_key
  )
  if (session_token != "") creds$session_token <- session_token

  paws::s3(config = list(
    credentials = list(creds = creds),
    endpoint = endpoint,
    region = region
  ))
}

resolve_bucket <- function() {
  bucket <- Sys.getenv("S3_BUCKET", "")
  if (bucket != "") return(bucket)
  edito_user <- Sys.getenv("EDITO_USERNAME", "")
  if (edito_user != "") return(paste0("oidc-", edito_user))
  ""
}

safe_s3_key <- function(prefix, filename) {
  if (prefix == "") return(filename)
  paste0(gsub("/+$", "", prefix), "/", filename)
}

download_s3_object <- function(s3, bucket, key, dest_path) {
  if (is.null(s3) || bucket == "" || key == "") return(FALSE)
  dir.create(dirname(dest_path), recursive = TRUE, showWarnings = FALSE)

  ok <- tryCatch({
    obj <- s3$get_object(Bucket = bucket, Key = key)
    body <- obj$Body

    if (is.raw(body)) {
      writeBin(body, dest_path)
    } else if (is.character(body)) {
      writeBin(charToRaw(paste(body, collapse = "")), dest_path)
    } else {
      stop("Unsupported response body type from S3")
    }
    TRUE
  }, error = function(e) {
    cat(">>> S3 download failed for", paste0("s3://", bucket, "/", key), "-", conditionMessage(e), "\n")
    FALSE
  })

  if (ok) {
    cat(">>> Downloaded", paste0("s3://", bucket, "/", key), "->", dest_path, "\n")
  }
  ok
}

s3_client <- build_s3_client()
s3_bucket <- resolve_bucket()
s3_input_prefix <- Sys.getenv("S3_INPUT_PREFIX", "input")
local_input_dir <- Sys.getenv("LOCAL_INPUT_DIR", "input")

# ========== Load Occurrences ==========
occ_filename <- paste0(myRespName, "_merged_thinned_2025-08-19.csv")
occ_candidates <- c(
  file.path(occ_filename),
  file.path("input", occ_filename),
  file.path(local_input_dir, occ_filename)
)
occ_existing <- occ_candidates[file.exists(occ_candidates)]
if (length(occ_existing) == 0) {
  s3_keys <- unique(c(
    safe_s3_key(s3_input_prefix, occ_filename),
    occ_filename
  ))
  target_path <- file.path(local_input_dir, occ_filename)

  for (key in s3_keys) {
    if (download_s3_object(s3_client, s3_bucket, key, target_path)) break
  }

  occ_existing <- occ_candidates[file.exists(occ_candidates)]
  if (file.exists(target_path)) occ_existing <- c(occ_existing, target_path)

  if (length(occ_existing) == 0) {
    stop(paste("Occurrence file not found locally or in S3. Tried:", paste(occ_candidates, collapse = ", ")))
  }
}
occ_path <- occ_existing[1]
cat(">>> Using occurrence file:", occ_path, "\n")

occ_data <- read.csv(occ_path)
myResp   <- as.numeric(occ_data$occurrenceStatus) # 1 / 0
myRespXY <- occ_data[, c("longitude", "latitude")]
colnames(myRespXY) <- c("X_WGS84","Y_WGS84")

# ========== Load Environmental Data ==========
if (!file.exists(env_file)) {
  env_key_override <- Sys.getenv("ENV_FILE_S3_KEY", "")
  env_keys <- unique(Filter(nzchar, c(
    env_key_override,
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

myExpl <- rast(env_file)


# === Screen presences against the env stack (CRS + extent + NA) ===
pv <- terra::vect(myRespXY, geom = c("X_WGS84","Y_WGS84"), crs = "EPSG:4326")

# Reproject presences to raster CRS if needed
#if (!terra::compareGeom(myExpl, pv, stopOnError = FALSE)) {
# pv <- terra::project(pv, terra::crs(myExpl))
#  xy_r <- as.data.frame(terra::geom(pv)[, c("x","y")])
#  names(xy_r) <- c("X_WGS84","Y_WGS84")
#  myRespXY <- xy_r
#}

# (A) Which raster cell does each presence hit? (use extract with cells=TRUE)
ext_cells <- terra::extract(myExpl[[1]], pv, cells = TRUE)  # columns: ID, cell, <layer values>
cells <- ext_cells$cell
out_of_extent <- is.na(cells)

# (B) Any NA in ANY predictor band at those locations?
ext_vals <- terra::extract(myExpl, pv)                      # first column is ID
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






# ========== Calculation of the number of pseudoabsences ==========
#n_presences <- sum(myResp == 1)
#if (n_presences < 10) stop(paste("Species", myRespName, "has fewer than 10 presences."))

# Number of pseudo-absences
#if (n_presences <= 100) {
#  PA.nb.absences <- min(n_presences * 3, 500)
#} else {
#  PA.nb.absences <- n_presences * 3
#}
#cat(">>> Presences:", n_presences, " | PAs/rep:", PA.nb.absences, "\n")



# ========== Mixed PA builder (Version 1 style) ==========
set.seed(123)

build_bm_format_mix <- function(nb_rep = 3, mix_ratio = 1/2, dedup = TRUE, verbose = TRUE) {
  logf <- function(...) if (isTRUE(verbose)) cat(sprintf(...), "\n")

  # assumes you already defined: myRespName, myResp, myRespXY (cols X_WGS84,Y_WGS84), myExpl,
  # pa_dist_min, pa_dist_max, PA.nb.absences

  std_pa_names <- paste0("PA", seq_len(nb_rep))
  nb_abs_disk   <- as.integer(ceiling(PA.nb.absences * mix_ratio))
  nb_abs_random <- max(1L, PA.nb.absences - nb_abs_disk)
  logf(">> mix: nb_rep=%d  ratio=%.2f  PAs/rep=%d  (disk=%d, random=%d)",
       nb_rep, mix_ratio, PA.nb.absences, nb_abs_disk, nb_abs_random)

  # build vect with 'sp'
  df_sp <- data.frame(
    X_WGS84 = myRespXY$X_WGS84,
    Y_WGS84 = myRespXY$Y_WGS84,
    sp      = myResp
  )
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
    PA.table <- PA.table |>
      dplyr::group_by(X_WGS84, Y_WGS84) |>
      dplyr::summarise(dplyr::across(all_of(std_pa_names), ~ any(.x, na.rm = TRUE)),
                       .groups = "drop")
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
    filter.raster = FALSE
  )
  logf(">> Done.")
  return(fmt)
}



myBiomodData.PA <- build_bm_format_mix()

cat(">>> Pseudo-absence summary:\n")
print(table(myBiomodData.PA@data.species))

# ========== Cross-validation setup ==========
cv_args <- list(
  CV.strategy  = cv_strategy,
  CV.nb.rep    = cv_nb_rep,
  CV.perc      = cv_perc,
  OPT.strategy = 'bigboss',
  var.import   = 0,
  metric.eval  = c('TSS','ROC','POD',"POFD",'SR','BIAS'),
  nb.cpu       = n_cores,
  seed.val     = 123
)
if (cv_strategy %in% c("kfold", "block", "strat", "env")) cv_args$CV.k <- cv_k

# modeling id
env_name   <- tools::file_path_sans_ext(basename(env_file))
modeling_id <- paste(format(Sys.Date()), "mix50", cv_strategy, env_name, sep = "_")

# ========== Run Modeling ==========
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


