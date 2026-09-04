#!/bin/bash
#SBATCH --job-name=ipums_pull
#SBATCH --partition=day
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
#SBATCH --time=08:00:00
#
# No --output here: #SBATCH lines cannot expand $HOME or ~, and a bare
# pattern lands in the submit directory (inside the repo). Pass the log
# location at submit time.
#
# Run download_ipums.R as a batch job. A pull of many samples takes tens of
# minutes of mostly waiting on IPUMS to build each extract, and long-running
# processes started from a login shell get reaped part-way through, which
# leaves a sample folder with its old data files already cleared and no
# replacement (recovering that needs another --overwrite pass). Batch is the
# reliable venue.
#
#   sbatch --output=$HOME/slurm-logs/%x-%j.out pull_ipums.sbatch \
#          config/parameters.cps.yaml --overwrite
#
# A finished job is not a successful one:
# check that the log ends with "Complete:" and the expected sample count, and
# check each sample's manifest.json dropped_variables.
#
# RUN ONE PULL AT A TIME. download_ipums.R calls set_ipums_api_key(save = TRUE),
# which rewrites ~/.Renviron, so two concurrent jobs race on that file. If you
# must queue a second pull, chain it:
#   sbatch --dependency=afterany:<first job id> --output=... pull_ipums.sbatch ...
#
# DO NOT EDIT download_ipums.R (or anything it sources) WHILE A JOB IS RUNNING.
# Rscript reads and parses the script file INCREMENTALLY, so an in-place rewrite
# shifts the byte offsets under the running interpreter and it dies parsing
# garbage at whatever point it had reached. Confirmed 2026-09-04: the
# acs_common_v2 job pulled all 20 samples, printed "Complete", then exited 1 with
#   Error: unexpected ')' in ".null(m))"
# a mangled `if (!is.null(m))` from the tail of the file. The DATA was intact --
# everything before the read position had already been parsed and run -- but the
# job reports FAILED, which is indistinguishable at a glance from a real failure.
# Note this survives `sed -i` (which replaces the inode, leaving the running
# process on the old one) and bites on an in-place truncate-and-rewrite, which is
# what most editors and scripts do. Copy the repo, or wait for the job.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: sbatch pull_ipums.sbatch <parameters file> [--overwrite]" >&2
  exit 2
fi

cd "${SLURM_SUBMIT_DIR:-$(pwd)}"
module load R/4.4.2-gfbf-2024a
Rscript download_ipums.R "$@"
