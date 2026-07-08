# =============================================================================
# utils.R  —  shared helpers for the common IPUMS download pipeline.
#
#   read_api_key()          parse an API key from config/api_codes.csv
#   wait_for_extract_retry() poll IPUMS, retrying transient server errors
#   count_gz_lines()        stream-count data rows in a gzipped file
#
# read_api_key / wait_for_extract_retry mirror the helpers used in other Budget
# Lab project repos so the api_codes.csv format is identical across projects.
# =============================================================================

#' Read an API key from a CSV file
#'
#' Searches column 1 for a row matching `label` (case-insensitive), returns the
#' value in column 2 (quotes/whitespace stripped). Format (config/api_codes.csv):
#'   name,code
#'   "ipums","YOUR_KEY"
#'
#' @param api_codes_path Path to the CSV file containing API keys
#' @param label Label to search for in column 1 (e.g. "ipums")
#' @return Character string with the API key
read_api_key <- function(api_codes_path, label) {
  if (!file.exists(api_codes_path)) {
    stop("API codes file not found at: ", api_codes_path, "\n",
         "  Copy config/api_codes.example.csv -> config/api_codes.csv and fill it in.",
         call. = FALSE)
  }

  api_codes <- tryCatch(
    read.delim(api_codes_path, sep = ",", header = TRUE, stringsAsFactors = FALSE),
    error = function(e) {
      read.delim(api_codes_path, sep = ",", header = FALSE, stringsAsFactors = FALSE)
    }
  )

  key <- NA_character_
  if (ncol(api_codes) >= 2) {
    col1 <- tolower(trimws(as.character(api_codes[[1]])))
    idx  <- which(col1 == tolower(label))
    if (length(idx) >= 1) {
      key <- as.character(api_codes[idx[1], 2])
    }
  }

  key <- trimws(gsub('"', '', key))

  if (is.na(key) || key == "") {
    stop("Could not parse a '", label, "' API key from: ", api_codes_path, call. = FALSE)
  }

  key
}

#' Wait for an IPUMS extract, retrying transient API errors
#'
#' ipumsr::wait_for_extract() polls get_extract_info(); IPUMS occasionally
#' returns a transient 5xx or drops the connection mid-poll, which would
#' otherwise abort the run. This re-polls the SAME submitted extract (no
#' resubmission) on transient errors only; non-transient errors (rejected
#' variable/sample, 4xx) propagate immediately.
#'
#' @param submitted  Object returned by ipumsr::submit_extract()
#' @param max_tries  Max wait attempts (default 6)
#' @param sleep_secs Seconds between attempts (default 30)
#' @return The ready extract object from wait_for_extract()
wait_for_extract_retry <- function(submitted, max_tries = 6, sleep_secs = 30) {
  for (attempt in seq_len(max_tries)) {
    res <- tryCatch(ipumsr::wait_for_extract(submitted), error = function(e) e)
    if (!inherits(res, "error")) return(res)

    msg       <- conditionMessage(res)
    transient <- grepl("status 5[0-9][0-9]", msg) ||
      grepl("timed out|timeout|connection|temporarily", msg, ignore.case = TRUE)
    if (!transient || attempt == max_tries) stop(res)

    message("   Transient IPUMS API error (attempt ", attempt, "/", max_tries,
            "): ", msg, "\n   Re-polling the same extract in ", sleep_secs, "s ...")
    Sys.sleep(sleep_secs)
  }
}

#' Count data rows in a (possibly gzipped) file without loading it into memory
#'
#' Streams the connection in blocks so a multi-GB fixed-width .dat.gz can be
#' counted with a fixed memory footprint.
#'
#' @param path Path to the .dat.gz (or plain .dat) file
#' @param block Lines to read per iteration (default 1e6)
#' @return Integer number of lines (records)
count_gz_lines <- function(path, block = 1e6L) {
  con <- gzfile(path, open = "rb")
  on.exit(close(con))
  n <- 0L
  repeat {
    chunk <- readLines(con, n = block, warn = FALSE)
    if (length(chunk) == 0L) break
    n <- n + length(chunk)
  }
  n
}
