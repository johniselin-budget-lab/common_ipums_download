#!/usr/bin/env Rscript
# =============================================================================
# download_ipums.R  —  the one program you run.
#
# Reads config/parameters.yaml, builds an IPUMS extract, downloads it into the
# shared raw_data area following the on-drive convention, and writes a manifest
# describing exactly what was pulled.
#
#   module load R
#   Rscript download_ipums.R                      # uses config/parameters.yaml
#   Rscript download_ipums.R config/parameters.cps.example.yaml   # another file
#   Rscript download_ipums.R config/parameters.yaml --overwrite   # force re-pull
#
# LAYOUT (output.layout in the parameter file):
#   pooled   (default)  all `samples` go into ONE extract / folder / manifest.
#   per_year            one extract / folder / manifest PER sample, folder id =
#                       sample id (e.g. .../v2/us2019a/). Each year is immutable
#                       and re-runs pull only missing years, so the December
#                       refresh is cheap. With output.pooled_parquet: true, each
#                       year is also appended to a partitioned parquet dataset
#                       under .../v2/pooled/ for fast cross-year reads. A schema
#                       guard checks that all per-year files stay stackable.
#
# Re-running is safe: unless --overwrite is passed, an output folder that already
# holds a DDI is left untouched (in pooled mode the default folder id is a fresh
# timestamp, so normal re-runs create a new pull rather than clobbering an old one).
#
# Requires an IPUMS API key in config/api_codes.csv (see api_codes.example.csv).
# =============================================================================

suppressPackageStartupMessages({
  library(ipumsr)
  library(yaml)
  library(jsonlite)
})

# ---- Locate the project root (works under Rscript and interactive) ----------
find_root <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grep("^--file=", args)])
  if (length(file_arg) == 1 && nzchar(file_arg)) return(dirname(normalizePath(file_arg)))
  if (!is.null(sys.frame(1)$ofile)) return(dirname(normalizePath(sys.frame(1)$ofile)))
  getwd()
}
project_root <- find_root()

source(file.path(project_root, "R", "build_extract.R"))   # also defines %||%
source(file.path(project_root, "R", "utils.R"))

# =============================================================================
# pull_one() — build, submit, wait, download, and describe ONE extract.
#   Used for both layouts: pooled calls it once with all samples; per_year calls
#   it once per sample. `param_path` (the parameter file to snapshot) is a
#   script-level constant set by the driver below.
# =============================================================================
pull_one <- function(params, samples, save_dir, id, overwrite) {
  out              <- params$output %||% list()
  save_location    <- out$save_location
  version          <- out$version %||% "v2"
  data_prefix      <- out$data_prefix %||% "usa"
  keep_fixed_width <- isTRUE(out$keep_fixed_width %||% TRUE)
  write_parquet    <- isTRUE(out$write_parquet %||% FALSE)
  count_records    <- isTRUE(out$count_records %||% TRUE)

  cat("Output dir:  ", save_dir, "\n", sep = "")

  existing_ddi <- if (dir.exists(save_dir)) list.files(save_dir, pattern = "\\.xml$", full.names = TRUE) else character(0)
  if (length(existing_ddi) > 0 && !overwrite) {
    cat("  [", id, "] already contains a DDI (", basename(existing_ddi[1]),
        ") — skipping. Pass --overwrite to force a re-pull.\n", sep = "")
    return(invisible(NULL))
  }
  dir.create(save_dir, recursive = TRUE, showWarnings = FALSE)

  # ---- Build, submit, wait, download ----------------------------------------
  extract_def <- build_extract(params, samples = samples)

  cat(">> Submitting ", params$collection %||% "usa", " extract [", id, "]: ",
      length(unlist(params$variables)), " variables, ", length(samples), " samples\n", sep = "")
  cat("   Samples: ", paste(samples, collapse = ", "), "\n", sep = "")

  submitted <- tryCatch(
    submit_extract(extract_def),
    error = function(e) {
      msg <- conditionMessage(e)
      if (grepl("not available", msg, ignore.case = TRUE)) {
        stop("IPUMS rejected one or more variables for these samples. ",
             "Fix `variables` in the parameter file and retry.\n  ", msg, call. = FALSE)
      }
      if (grepl("sample", msg, ignore.case = TRUE)) {
        stop("IPUMS rejected a sample (", paste(samples, collapse = ", "), ") — ",
             "likely the newest ACS 1-year sample is not yet released.\n",
             "  See https://usa.ipums.org/usa-action/samples and adjust `samples`.\n  ",
             msg, call. = FALSE)
      }
      stop(e)
    }
  )

  cat("   Submitted (extract ", submitted$number %||% NA, "). Waiting for IPUMS to build it ...\n", sep = "")
  ready <- wait_for_extract_retry(submitted)

  cat(">> Downloading into ", save_dir, " ...\n", sep = "")
  ddi_path <- download_extract(ready, download_dir = save_dir, overwrite = TRUE)
  ddi_path <- normalizePath(ddi_path, winslash = "/")
  cat("   DDI:", basename(ddi_path), "\n")

  # ---- Read the DDI for metadata + the record count -------------------------
  ddi      <- read_ipums_ddi(ddi_path)
  var_info <- ipums_var_info(ddi)
  dat_path <- list.files(save_dir, pattern = "\\.dat(\\.gz)?$", full.names = TRUE)[1]

  n_records <- NA_integer_
  if (count_records && !is.na(dat_path)) {
    cat(">> Counting records (streaming", basename(dat_path), ") ...\n")
    n_records <- count_gz_lines(dat_path)
    cat("   Records:", format(n_records, big.mark = ","), "\n")
  }

  # ---- Optional per-file parquet --------------------------------------------
  parquet_path <- NA_character_
  if (write_parquet) {
    if (requireNamespace("arrow", quietly = TRUE)) {
      cat(">> Reading microdata to write parquet ...\n")
      micro <- read_ipums_micro(ddi, verbose = FALSE)
      names(micro) <- tolower(names(micro))
      parquet_path <- file.path(save_dir, paste0(data_prefix, "_", id, ".parquet"))
      arrow::write_parquet(micro, parquet_path)
      cat("   Parquet:", basename(parquet_path), "\n")
      rm(micro); gc()
    } else {
      cat("   write_parquet = TRUE but the 'arrow' package is not installed — skipping.\n")
    }
  }

  # ---- Snapshot the exact parameters used -----------------------------------
  snapshot_path <- file.path(save_dir, "parameters_used.yaml")
  file.copy(param_path, snapshot_path, overwrite = TRUE)

  # ---- variables.csv: flat codebook from the DDI ----------------------------
  keep_cols <- intersect(
    c("var_name", "var_label", "var_desc", "rectype", "start", "end",
      "imp_decim", "var_type", "code_instr"),
    names(var_info)
  )
  vars_flat <- as.data.frame(var_info[, keep_cols, drop = FALSE])
  # collapse any list columns to a scalar for CSV safety
  for (j in names(vars_flat)) {
    if (is.list(vars_flat[[j]])) {
      vars_flat[[j]] <- vapply(vars_flat[[j]], function(x) paste(as.character(x), collapse = " | "), character(1))
    }
  }
  variables_csv <- file.path(save_dir, "variables.csv")
  utils::write.csv(vars_flat, variables_csv, row.names = FALSE)

  # ---- Manifest -------------------------------------------------------------
  data_files <- list.files(save_dir, full.names = TRUE)
  file_rows <- lapply(data_files, function(f) {
    list(
      name  = basename(f),
      bytes = as.numeric(file.info(f)$size),
      md5   = unname(tools::md5sum(f))
    )
  })

  manifest <- list(
    dataset          = basename(save_location),
    collection       = params$collection %||% "usa",
    description      = params$description %||% NA,
    version          = version,
    id               = as.character(id),
    save_dir         = save_dir,
    created_utc      = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    created_by       = Sys.getenv("USER", unset = NA),
    ipums_extract_number = submitted$number %||% NA,
    samples          = as.list(samples),
    n_variables      = nrow(var_info),
    variables        = as.list(var_info$var_name),
    data_quality_flags = as.list(unlist(params$data_quality_flags, use.names = FALSE)),
    case_selections  = params$case_selections %||% list(),
    n_records        = if (is.na(n_records)) NA else n_records,
    storage          = list(
      keep_fixed_width = keep_fixed_width,
      parquet          = if (is.na(parquet_path)) NA else basename(parquet_path),
      ddi_codebook     = basename(ddi_path)
    ),
    files            = file_rows,
    software         = list(
      R      = R.version.string,
      ipumsr = as.character(utils::packageVersion("ipumsr"))
    ),
    parameters_file  = basename(snapshot_path)
  )

  manifest_path <- file.path(save_dir, "manifest.json")
  write_json(manifest, manifest_path, pretty = TRUE, auto_unbox = TRUE, null = "null")

  cat("   Wrote manifest: ", manifest_path, "\n", sep = "")
  for (f in file_rows) cat("     ", f$name, " (", round(f$bytes / 1e6, 1), " MB)\n", sep = "")

  invisible(manifest)
}

# =============================================================================
# append_year_to_pooled() — hybrid layer: append ONE year's microdata to the
#   partitioned parquet dataset at <save_location>/<version>/pooled/, one year
#   at a time so memory stays bounded to a single sample. Guards against schema
#   drift: if the incoming year's columns don't match the existing pooled set,
#   the append is refused (the pooled dataset must stay uniformly stackable).
# =============================================================================
append_year_to_pooled <- function(manifest, save_location, version) {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    cat("   pooled_parquet = TRUE but the 'arrow' package is not installed — skipping pooled append.\n")
    return(invisible(NULL))
  }
  pooled_dir <- file.path(save_location, version, "pooled")
  ddi        <- read_ipums_ddi(file.path(manifest$save_dir, manifest$storage$ddi_codebook))
  micro      <- read_ipums_micro(ddi, verbose = FALSE)
  names(micro) <- tolower(names(micro))

  if (!"year" %in% names(micro)) {
    cat("   Pooled append skipped for [", manifest$id, "]: no YEAR column to partition on.\n", sep = "")
    rm(micro); gc(); return(invisible(NULL))
  }

  # ---- Schema guard ---------------------------------------------------------
  if (dir.exists(pooled_dir) && length(list.files(pooled_dir, recursive = TRUE)) > 0) {
    existing_cols <- names(arrow::open_dataset(pooled_dir))
    new_cols      <- names(micro)
    missing <- setdiff(setdiff(existing_cols, new_cols), "year")   # in pooled, not in new year
    extra   <- setdiff(setdiff(new_cols, existing_cols), "year")   # in new year, not in pooled
    if (length(missing) > 0 || length(extra) > 0) {
      cat("   !! POOLED SCHEMA MISMATCH for [", manifest$id, "] — NOT appending.\n", sep = "")
      if (length(missing) > 0) cat("      in pooled but missing from ", manifest$id, ": ",
                                   paste(missing, collapse = ", "), "\n", sep = "")
      if (length(extra) > 0)   cat("      in ", manifest$id, " but not in pooled: ",
                                   paste(extra, collapse = ", "), "\n", sep = "")
      cat("      The per-year variable list has drifted; the pooled parquet was left untouched.\n")
      cat("      Re-pull all years with one consistent `variables` list (use --overwrite) to rebuild it.\n")
      rm(micro); gc(); return(invisible(NULL))
    }
  }

  arrow::write_dataset(micro, pooled_dir, partitioning = "year",
                       existing_data_behavior = "overwrite")
  cat("   Pooled: appended [", manifest$id, "] -> ", file.path(pooled_dir, "year=..."), "\n", sep = "")
  rm(micro); gc()
  invisible(pooled_dir)
}

# =============================================================================
# check_per_year_consistency() — guard run after a per_year pass. Every year
#   folder present must carry the SAME returned variable set, else the per-year
#   files are not uniformly stackable. Reads each manifest.json; warns loudly
#   (never deletes). Works even when pooled_parquet is off.
# =============================================================================
check_per_year_consistency <- function(save_location, version, samples) {
  var_sets <- list()
  for (s in samples) {
    mp <- file.path(save_location, version, s, "manifest.json")
    if (file.exists(mp)) {
      m <- jsonlite::read_json(mp, simplifyVector = TRUE)
      var_sets[[s]] <- sort(unlist(m$variables, use.names = FALSE))
    }
  }
  if (length(var_sets) < 2) return(invisible(TRUE))

  ref_name <- names(var_sets)[1]
  ref      <- var_sets[[ref_name]]
  ok <- TRUE
  for (nm in names(var_sets)[-1]) {
    missing <- setdiff(ref, var_sets[[nm]])
    extra   <- setdiff(var_sets[[nm]], ref)
    if (length(missing) > 0 || length(extra) > 0) {
      ok <- FALSE
      cat("   !! SCHEMA DRIFT: [", nm, "] differs from [", ref_name, "]\n", sep = "")
      if (length(missing) > 0) cat("      missing in ", nm, ": ", paste(missing, collapse = ", "), "\n", sep = "")
      if (length(extra) > 0)   cat("      extra in ",   nm, ": ", paste(extra,   collapse = ", "), "\n", sep = "")
    }
  }
  if (!ok) {
    cat("   The per-year datasets are NOT uniformly stackable. Re-pull the drifted years\n",
        "   with a single consistent `variables` list (use --overwrite).\n", sep = "")
  } else {
    cat("   Schema guard: all ", length(var_sets), " per-year datasets share an identical variable set.\n", sep = "")
  }
  invisible(ok)
}

# =============================================================================
# Driver
# =============================================================================

# ---- Parse command-line arguments -------------------------------------------
cli        <- commandArgs(trailingOnly = TRUE)
overwrite  <- "--overwrite" %in% cli
param_arg  <- cli[!grepl("^--", cli)]
param_path <- if (length(param_arg) >= 1) param_arg[1] else file.path(project_root, "config", "parameters.yaml")
if (!file.exists(param_path)) stop("Parameter file not found: ", param_path, call. = FALSE)

api_codes_path <- file.path(project_root, "config", "api_codes.csv")

cat("=== download_ipums.R ===\n")
cat("Start:       ", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), "\n")
cat("Project root:", project_root, "\n")
cat("Parameters:  ", param_path, "\n\n")

params <- yaml::read_yaml(param_path)

# ---- Resolve output location + layout ---------------------------------------
out            <- params$output %||% list()
save_location  <- out$save_location %||% stop("output.save_location missing in parameters", call. = FALSE)
version        <- out$version %||% "v2"
layout         <- out$layout %||% "pooled"
pooled_parquet <- isTRUE(out$pooled_parquet %||% FALSE)

samples <- unlist(params$samples, use.names = FALSE)
if (length(samples) == 0) stop("No `samples` listed in parameters", call. = FALSE)

if (!layout %in% c("pooled", "per_year")) {
  stop("Unknown output.layout: '", layout, "'. Use 'pooled' or 'per_year'.", call. = FALSE)
}

# ---- Authenticate (once) ----------------------------------------------------
ipums_key <- read_api_key(api_codes_path, "ipums")
set_ipums_api_key(ipums_key, save = TRUE, overwrite = TRUE)

# ---- Run --------------------------------------------------------------------
if (identical(layout, "per_year")) {
  cat(">> Layout: per_year  (", length(samples), " samples, one extract each)\n", sep = "")
  if (pooled_parquet) {
    cat("   pooled_parquet = TRUE: each year is also appended to ",
        file.path(save_location, version, "pooled"), "\n", sep = "")
  }
  cat("\n")

  n_pulled <- 0L
  for (s in samples) {
    save_dir <- file.path(save_location, version, s)   # folder id = sample id
    m <- pull_one(params, samples = s, save_dir = save_dir, id = s, overwrite = overwrite)
    if (!is.null(m)) {
      n_pulled <- n_pulled + 1L
      if (pooled_parquet) append_year_to_pooled(m, save_location, version)
    }
    cat("\n")
  }

  # Guard: confirm every per-year folder shares one variable set.
  cat(">> Checking per-year schema consistency ...\n")
  check_per_year_consistency(save_location, version, samples)

  cat("\n=== Complete:", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), "===\n")
  cat("Pulled ", n_pulled, " of ", length(samples), " samples into ",
      file.path(save_location, version), "\n", sep = "")

} else {   # pooled (default) — all samples in one extract, exactly as before
  id <- out$id
  if (is.null(id) || !nzchar(as.character(id))) {
    id <- format(Sys.time(), "%Y%m%d%H", tz = "UTC")   # matches CPS-Monthly convention
  }
  cat(">> Layout: pooled  (all ", length(samples), " samples in one extract)\n\n", sep = "")

  save_dir <- file.path(save_location, version, as.character(id))
  m <- pull_one(params, samples = samples, save_dir = save_dir, id = id, overwrite = overwrite)

  cat("\n=== Complete:", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), "===\n")
  if (is.null(m)) {
    cat("Nothing to do — output already present. Pass --overwrite to force, or set a new output.id.\n")
  }
}
