#!/usr/bin/env Rscript
# =============================================================================
# compare_runs.R  —  check a new run against the run it supersedes.
#
# A per_year run is only a safe replacement if the record UNIVERSE did not move:
# same samples, same record count in each. This reads the two runs' manifests and
# reports, per sample, whether the counts agree and what the new run gained or
# lost from the variable set. It never writes or deletes anything.
#
#   module load R/4.4.2-gfbf-2024a
#   Rscript R/compare_runs.R <old run dir> <new run dir> [VAR ...]
#
# Any VAR arguments are variables whose PRESENCE in the new run you want asserted
# per sample — use it for the thing the re-pull was for, e.g. the SPM block that
# acs_common's 2024 samples were missing:
#
#   Rscript R/compare_runs.R .../ACS/acs_common .../ACS/acs_common_v2 SPMPOV RENTGRS
#
# Exit status is 1 if any sample's record count disagrees, so it can gate a
# consumer re-point in a script.
# =============================================================================

suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("usage: Rscript R/compare_runs.R <old run dir> <new run dir> [VAR ...]",
       call. = FALSE)
}
old_dir  <- args[[1]]
new_dir  <- args[[2]]
must_have <- toupper(args[-(1:2)])

for (d in c(old_dir, new_dir)) {
  if (!dir.exists(d)) stop("Run directory not found: ", d, call. = FALSE)
}

# A per_year run holds one manifest per sample subfolder; a pooled run holds one
# at the top. Read whichever shape is on disk, keyed by sample folder name.
read_manifests <- function(run_dir) {
  paths <- list.files(run_dir, pattern = "^manifest[.]json$",
                      recursive = TRUE, full.names = TRUE)
  if (length(paths) == 0) stop("No manifest.json under ", run_dir, call. = FALSE)
  stats::setNames(lapply(paths, jsonlite::read_json, simplifyVector = TRUE),
                  basename(dirname(paths)))
}

old <- read_manifests(old_dir)
new <- read_manifests(new_dir)

cat("=== compare_runs.R ===\n")
cat("old: ", old_dir, "  (", length(old), " samples)\n", sep = "")
cat("new: ", new_dir, "  (", length(new), " samples)\n\n", sep = "")

only_old <- setdiff(names(old), names(new))
only_new <- setdiff(names(new), names(old))
if (length(only_old)) cat("!! samples in OLD only: ", paste(only_old, collapse = ", "), "\n", sep = "")
if (length(only_new)) cat("   samples in NEW only: ", paste(only_new, collapse = ", "), "\n", sep = "")

shared <- intersect(names(old), names(new))
count_mismatch <- character(0)
missing_required <- character(0)

for (s in shared) {
  o <- old[[s]]; n <- new[[s]]
  # This script deliberately does not source build_extract.R (which defines
  # %||% but pulls in ipumsr), so unwrap the counts explicitly.
  n_o <- if (is.null(o$n_records)) NA else o$n_records
  n_n <- if (is.null(n$n_records)) NA else n$n_records
  same <- !is.na(n_o) && !is.na(n_n) && identical(as.numeric(n_o), as.numeric(n_n))
  if (!same) count_mismatch <- c(count_mismatch, s)

  vo <- unlist(o$variables, use.names = FALSE)
  vn <- unlist(n$variables, use.names = FALSE)
  gained <- setdiff(vn, vo)
  lost   <- setdiff(vo, vn)

  cat(sprintf("%-13s records %-11s -> %-11s %s\n", s,
              format(n_o, big.mark = ","), format(n_n, big.mark = ","),
              if (same) "OK" else "*** MISMATCH ***"))
  cat(sprintf("%-13s vars %d -> %d   (+%d / -%d)\n", "", length(vo), length(vn),
              length(gained), length(lost)))
  if (length(lost))   cat("              LOST: ", paste(sort(lost), collapse = ", "), "\n", sep = "")
  if (length(gained)) cat("              gained: ", paste(sort(gained), collapse = ", "), "\n", sep = "")

  if (length(must_have)) {
    absent <- setdiff(must_have, toupper(vn))
    if (length(absent)) {
      missing_required <- c(missing_required, s)
      cat("              !! REQUIRED BUT ABSENT: ", paste(absent, collapse = ", "), "\n", sep = "")
    }
  }
}

cat("\n--- summary ---\n")
cat("samples compared:            ", length(shared), "\n", sep = "")
cat("record-count mismatches:     ",
    if (length(count_mismatch)) paste(count_mismatch, collapse = ", ") else "none", "\n", sep = "")
if (length(must_have)) {
  cat("samples missing a required var: ",
      if (length(missing_required)) paste(missing_required, collapse = ", ") else "none", "\n", sep = "")
}
if (length(count_mismatch) > 0) {
  cat("\nA record-count mismatch means the row UNIVERSE moved between the two runs.\n",
      "Do NOT re-point consumers: a merge layer keyed on SAMPLE+SERIAL[+PERNUM]\n",
      "will no longer align 1:1. Check `samples` and `case_selections` on both\n",
      "sides before anything else.\n", sep = "")
  quit(status = 1)
}
cat("\nUniverse unchanged: every shared sample has the same record count.\n")
