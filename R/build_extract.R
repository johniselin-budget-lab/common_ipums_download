# =============================================================================
# build_extract.R  —  turn parameters.yaml into an ipumsr extract definition.
#
# Collection-agnostic: works for collection "usa" (ACS) or "cps" (CPS), since
# both use ipumsr::define_extract_micro(). Only this file needs to understand
# the parameter schema; download_ipums.R handles submit/download/manifest.
# =============================================================================

suppressPackageStartupMessages({
  library(ipumsr)
})

#' Build an IPUMS micro extract definition from a parsed parameters list
#'
#' @param params The list returned by yaml::read_yaml("config/parameters.yaml")
#' @param samples Optional character vector of sample IDs to request instead of
#'   params$samples. Used by the per-year layout to pull one sample at a time
#'   while keeping the SAME variable list, so every year's file stays uniformly
#'   stackable. NULL (default) uses params$samples.
#' @return An ipumsr extract definition (unsubmitted)
build_extract <- function(params, samples = NULL) {

  collection <- params$collection %||% "usa"
  samples    <- samples %||% unlist(params$samples, use.names = FALSE)
  var_names  <- unlist(params$variables, use.names = FALSE)

  if (length(samples) == 0)   stop("No `samples` listed in parameters.yaml", call. = FALSE)
  if (length(var_names) == 0) stop("No `variables` listed in parameters.yaml", call. = FALSE)

  dq_flags  <- unlist(params$data_quality_flags, use.names = FALSE)
  case_sel  <- params$case_selections %||% list()

  # Validate that per-variable options reference variables actually requested.
  stray_dq <- setdiff(dq_flags, var_names)
  if (length(stray_dq) > 0) {
    stop("data_quality_flags names not in `variables`: ",
         paste(stray_dq, collapse = ", "), call. = FALSE)
  }
  case_vars <- toupper(names(case_sel))
  stray_cs  <- setdiff(case_vars, toupper(var_names))
  if (length(stray_cs) > 0) {
    stop("case_selections names not in `variables`: ",
         paste(stray_cs, collapse = ", "), call. = FALSE)
  }

  # Build the variable list: a plain string when no options apply, otherwise a
  # var_spec() carrying data-quality flags and/or case selections.
  case_sel_upper <- stats::setNames(case_sel, toupper(names(case_sel)))
  var_list <- lapply(var_names, function(v) {
    want_dq <- v %in% dq_flags
    cs      <- case_sel_upper[[toupper(v)]]
    has_cs  <- !is.null(cs) && length(cs) > 0
    if (!want_dq && !has_cs) return(v)          # plain string
    args <- list(name = v)
    if (want_dq) args$data_quality_flags <- TRUE
    if (has_cs)  args$case_selections    <- as.character(unlist(cs, use.names = FALSE))
    do.call(var_spec, args)
  })

  define_extract_micro(
    collection  = collection,
    description = params$description %||% "common_ipums_download extract",
    samples     = samples,
    variables   = var_list
  )
}

# Null-coalescing helper (base R has none).
`%||%` <- function(a, b) if (is.null(a)) b else a
