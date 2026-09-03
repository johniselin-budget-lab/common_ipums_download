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

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: sbatch pull_ipums.sbatch <parameters file> [--overwrite]" >&2
  exit 2
fi

cd "${SLURM_SUBMIT_DIR:-$(pwd)}"
module load R/4.4.2-gfbf-2024a
Rscript download_ipums.R "$@"
