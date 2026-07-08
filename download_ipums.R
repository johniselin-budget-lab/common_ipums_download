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
# Re-running is safe: unless --overwrite is passed, an output folder that already
# holds a DDI is left untouched (the default folder id is a fresh timestamp, so
# normal re-runs create a new pull rather than clobbering an old one).
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

# ---- Resolve output location: <save_location>/<version>/<id> ----------------
out          <- params$output %||% list()
save_location <- out$save_location %||% stop("output.save_location missing in parameters", call. = FALSE)
version       <- out$version %||% "v2"
id            <- out$id
if (is.null(id) || !nzchar(as.character(id))) {
  id <- format(Sys.time(), "%Y%m%d%H", tz = "UTC")   # matches CPS-Monthly convention
}
data_prefix     <- out$data_prefix %||% "usa"
keep_fixed_width <- isTRUE(out$keep_fixed_width %||% TRUE)
write_parquet    <- isTRUE(out$write_parquet %||% FALSE)
count_records    <- isTRUE(out$count_records %||% TRUE)

save_dir <- file.path(save_location, version, as.character(id))
cat("Output dir:  ", save_dir, "\n\n")

existing_ddi <- if (dir.exists(save_dir)) list.files(save_dir, pattern = "\\.xml$", full.names = TRUE) else character(0)
if (length(existing_ddi) > 0 && !overwrite) {
  cat("Output already contains a DDI (", basename(existing_ddi[1]), ").\n",
      "Nothing to do. Pass --overwrite to force a re-pull, or set a new output.id.\n", sep = "")
  quit(save = "no", status = 0)
}
dir.create(save_dir, recursive = TRUE, showWarnings = FALSE)

# ---- Authenticate -----------------------------------------------------------
ipums_key <- read_api_key(api_codes_path, "ipums")
set_ipums_api_key(ipums_key, save = TRUE, overwrite = TRUE)

# ---- Build, submit, wait, download ------------------------------------------
extract_def <- build_extract(params)
samples     <- unlist(params$samples, use.names = FALSE)

cat(">> Submitting", params$collection %||% "usa", "extract:",
    length(unlist(params$variables)), "variables,", length(samples), "samples\n")
cat("   Samples:", paste(samples, collapse = ", "), "\n")

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

cat(">> Downloading into", save_dir, "...\n")
ddi_path <- download_extract(ready, download_dir = save_dir, overwrite = TRUE)
ddi_path <- normalizePath(ddi_path, winslash = "/")
cat("   DDI:", basename(ddi_path), "\n")

# ---- Read the DDI for metadata + the record count ---------------------------
ddi      <- read_ipums_ddi(ddi_path)
var_info <- ipums_var_info(ddi)
dat_path <- list.files(save_dir, pattern = "\\.dat(\\.gz)?$", full.names = TRUE)[1]

n_records <- NA_integer_
if (count_records && !is.na(dat_path)) {
  cat(">> Counting records (streaming", basename(dat_path), ") ...\n")
  n_records <- count_gz_lines(dat_path)
  cat("   Records:", format(n_records, big.mark = ","), "\n")
}

# ---- Optional parquet -------------------------------------------------------
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

# ---- Snapshot the exact parameters used -------------------------------------
snapshot_path <- file.path(save_dir, "parameters_used.yaml")
file.copy(param_path, snapshot_path, overwrite = TRUE)

# ---- variables.csv: flat codebook from the DDI ------------------------------
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

# ---- Manifest ---------------------------------------------------------------
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

# ---- Done -------------------------------------------------------------------
cat("\n=== Complete:", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), "===\n")
cat("Wrote:\n")
cat("  ", manifest_path, "\n")
cat("  ", variables_csv, "\n")
cat("  ", snapshot_path, "\n")
for (f in file_rows) cat("   ", f$name, " (", round(f$bytes / 1e6, 1), " MB)\n", sep = "")
