# common_ipums_download

A single, shared source of IPUMS microdata for Budget Lab projects. Instead of
each project maintaining its own IPUMS extract code, this repo pulls **one common
set of ACS variables and samples** and stores it, with a manifest, in the shared
raw-data area:

```
/nfs/roberts/project/pi_nrs36/shared/raw_data/ACS/
```

Two things live here:

1. **`config/parameters.yaml`** — the parameter file: the variables, samples,
   per-variable options, storage format, save location, and folder id. **This is
   the only file you normally edit.**
2. **`download_ipums.R`** — the program: reads the parameter file, builds and
   submits the IPUMS extract, downloads it into the shared area following the
   on-drive convention, and writes a **manifest** describing the pull.

It is collection-agnostic — the same program pulls CPS (see
`config/parameters.cps.example.yaml`); only the parameter file changes.

## Quick start

```bash
module load R                                   # R 4.4.1 + CRAN bundle on the server
cp config/api_codes.example.csv config/api_codes.csv   # then paste your IPUMS API key
Rscript download_ipums.R                         # uses config/parameters.yaml
```

Get an API key at <https://account.ipums.org/api_keys>. `config/api_codes.csv`
is gitignored — the key never enters the repo. The `api_codes.csv` format
(`name,code` with an `"ipums"` row) is identical across Budget Lab repos, so the
same file works everywhere.

Other invocations:

```bash
Rscript download_ipums.R config/parameters.cps.yaml   # a different parameter file
Rscript download_ipums.R config/parameters.yaml --overwrite   # force a re-pull
```

Re-running is safe: unless `--overwrite` is passed, an output folder that already
holds a codebook is left untouched. Because the default folder id is a fresh UTC
timestamp, a normal re-run creates a *new* pull rather than clobbering an old one.

## What gets stored, and where

Output goes to `<save_location>/<version>/<id>/`, e.g.:

```
raw_data/ACS/v2/2026070813/
├── usa_00042.dat.gz        # native IPUMS fixed-width microdata, gzipped
├── usa_00042.xml           # DDI codebook — the self-documenting variable dictionary
├── variables.csv           # flat codebook (var name, label, type) extracted from the DDI
├── parameters_used.yaml    # exact snapshot of the parameters for this pull
└── manifest.json           # what this is: samples, variables, record count, file md5s, versions
```

This mirrors the shared-drive convention already used for CPS
(`CPS-Monthly/<timestamp>/cps.dat.gz + cps.xml`) and keeps the `v1/`, `v2/`
version layer used across `raw_data`.

**Why fixed-width `.dat.gz` + DDI, and not a CSV?** The legacy `ACS/v1/` stored a
single **uncompressed 1.3 GB `ipums_usa.csv`**. The native gzipped fixed-width
form is dramatically smaller on disk *and* the DDI `.xml` is a complete codebook
(labels, value labels, formats) — so the data is both compact and
self-documenting. Both `ipumsr::read_ipums_micro()` (R) and standard tooling read
it directly. Set `output.write_parquet: true` to *additionally* emit a columnar
parquet for fast repeated reads (needs the `arrow` package).

## The common variable set

`config/parameters.yaml` ships with the **union** of the ACS variables requested
by existing Budget Lab project extracts, grouped by topic (identifiers/weights,
geography, household structure, demographics, employment, income, health
insurance, housing, and the SPM block), with data-quality flags applied to the
income/housing/employment variables those projects flagged.

Design choices for a *common* source (documented inline in the file):

- **No case selection by default** — some existing project code kept only
  `GQ ∈ {1,2}`. The shared file keeps *all* records (including group quarters);
  downstream projects filter as needed.
- **Data-quality flags on** for income/housing/employment, so downstream code can
  screen allocated (imputed) values.
- **`us2020a` omitted** — there is no standard ACS 2020 1-year file.
- A **migration/place-of-work block** is included but commented out
  (single-project; adds width for a narrow use case).

To change what's pulled, edit `variables` / `samples` / `data_quality_flags` in
`parameters.yaml` and re-run. Adding a variable does not require touching any R.

## Files

| Path | Purpose |
|------|---------|
| `config/parameters.yaml` | The parameter file (default: common ACS). Edit this. |
| `config/parameters.cps.example.yaml` | Starter template for a CPS pull. |
| `config/api_codes.example.csv` | Template for your IPUMS key (copy to `api_codes.csv`). |
| `download_ipums.R` | The program: extract → download → manifest. |
| `R/build_extract.R` | Turns the parameter file into an `ipumsr` extract definition. |
| `R/utils.R` | API-key reader, transient-error retry, record counter. |

## Requirements

- R (on the server: `module load R` → R 4.4.1). Packages: **ipumsr**, **yaml**,
  **jsonlite** (all in the server CRAN bundle); **arrow** only if
  `write_parquet: true`.
- An IPUMS account + API key registered for the collection you're pulling
  (IPUMS USA for ACS, IPUMS CPS for CPS).
