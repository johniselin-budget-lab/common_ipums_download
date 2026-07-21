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

Each pull needs a **run id** (`output.id`) — a specific, meaningful name you set
(an empty id is a hard error). Re-running is safe: unless `--overwrite` is passed,
an output folder that already holds a codebook is left untouched. Re-run with the
**same id** in `per_year` mode to add only the missing years; use a **new id** for
a fresh pull.

## What gets stored, and where

Output goes to `<save_location>/<id>/` — one named run folder directly under the
dataset (no version layer), e.g.:

```
raw_data/ACS/acs_common/
├── usa_00042.dat.gz        # native IPUMS fixed-width microdata, gzipped
├── usa_00042.xml           # DDI codebook — the self-documenting variable dictionary
├── variables.csv           # flat codebook (var name, label, type) extracted from the DDI
├── parameters_used.yaml    # exact snapshot of the parameters for this pull
└── manifest.json           # what this is: run id, samples, variables, record count, file md5s
```

Named runs sit alongside any legacy `raw_data/ACS/v1/` (left untouched). The data
files themselves mirror the format convention used for CPS
(`CPS-Monthly/<timestamp>/cps.dat.gz + cps.xml`).

**Why fixed-width `.dat.gz` + DDI, and not a CSV?** The legacy `ACS/v1/` stored a
single **uncompressed 1.3 GB `ipums_usa.csv`**. The native gzipped fixed-width
form is dramatically smaller on disk *and* the DDI `.xml` is a complete codebook
(labels, value labels, formats) — so the data is both compact and
self-documenting. Both `ipumsr::read_ipums_micro()` (R) and standard tooling read
it directly. Set `output.write_parquet: true` to *additionally* emit a columnar
parquet for fast repeated reads (needs the `arrow` package).

## Layout: pooled (default) vs. per-year

`output.layout` controls how the samples are packaged on disk.

**`pooled`** (default) — all `samples` go into **one** extract and manifest,
written straight into the run folder `<save_location>/<id>/`. One
guaranteed-uniform schema across every year; the trade-off is that adding a
newly-released year means re-pulling the whole extract.

**`per_year`** — **one** extract, folder, and manifest **per sample**, nested
under the run folder as `<save_location>/<id>/<sample>/`:

```
ACS/acs_common/
├── us2015a/   usa_us2015a.dat.gz  .xml  variables.csv  parameters_used.yaml  manifest.json
├── us2016a/   ...
├── us2024a/   ...
└── pooled/                      # only if output.pooled_parquet: true
    ├── year=2015/part-0.parquet
    ├── year=2016/part-0.parquet
    └── ...
```

Why you'd use it:

- **Cheap annual refresh.** Each year folder is immutable; a re-run skips folders
  that already hold a DDI and pulls only the missing year(s) — so December's
  refresh downloads one ~140 MB file instead of rebuilding the whole ~1.4 GB
  extract. (`--overwrite` forces a re-pull.)
- **Immutable, pinnable artifacts** — one md5-stable folder per year.
- **Failure isolation** — a rejected sample or hung build costs one year, not the
  batch.
- **Optional pooled read layer.** Set `output.pooled_parquet: true` and each year
  is *also* appended (one at a time, so memory stays bounded) to a partitioned
  parquet dataset under `<save_location>/<id>/pooled/`. Read it back with partition pruning:

  ```r
  library(arrow)
  open_dataset("…/ACS/acs_common/pooled") |>
    dplyr::filter(year == 2022) |> dplyr::select(perwt, inctot, statefip) |>
    dplyr::collect()
  ```

**The guard.** The per-year files are only stackable if every year carries the
*same* variable set, so the pipeline always requests the identical `variables`
list for each year and, after a `per_year` run, verifies that every year folder's
returned variables match — warning loudly (never deleting) on any drift. The
pooled-parquet append applies the same check per year and refuses to append a
year whose schema doesn't match the existing dataset. If you see a drift warning,
re-pull the affected years with one consistent variable list (`--overwrite`).

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
- **`us2020a` included, with a caveat** — this is the *experimental* 2020 ACS
  1-year file (the standard 2020 1-year release was cancelled due to COVID).
  IPUMS puts the COVID-adjusted experimental weights in **both** places: under the
  standard names `HHWT`/`PERWT` *and* under `EXPWTH`/`EXPWTP`. So pooling years and
  weighting on `PERWT` works fine — just know that 2020's weights are experimental,
  and `EXPWTH`/`EXPWTP` are carried as an explicit, self-documenting copy.
- A **migration/place-of-work block** is included but commented out
  (single-project; adds width for a narrow use case).

To change what's pulled, edit `variables` / `samples` / `data_quality_flags` in
`parameters.yaml` and re-run. Adding a variable does not require touching any R.

## Replicate weights: a separate merge-on layer

The common extract deliberately carries **only the point-estimate weights**
(`HHWT`/`PERWT`). The ACS **replicate weights** — `REPWT` (80 household columns)
and `REPWTP` (80 person columns), needed for design-based standard errors — live
in a **separate companion pull**, `config/parameters.weights.yaml`, and are
**merged onto the main file on demand**:

```bash
Rscript download_ipums.R config/parameters.weights.yaml
```

It writes a sibling run folder with the *same* per-year structure:

```
ACS/acs_common/        # main lean extract (parameters.yaml)
ACS/acs_common_repwt/  # replicate-weights layer, same us<YYYY> subfolders
```

**Why separate, not baked into `parameters.yaml`.** The 160 replicate-weight
columns roughly **4×** the extract (measured elsewhere: ~0.5 GB → ~2.2 GB for a
3-year pull). Only variance estimation needs them, so folding them into the
common file would tax *every* downstream repo — most of which only want point
estimates — on every read. Keeping them in an opt-in layer leaves the common
file lean and makes the weight matrix a load-only-when-needed artifact.

**Why the merge is lossless.** An IPUMS extract is deterministic given
`(collection, samples, no case selection)`: every record in a sample is returned,
uniquely keyed by `SAMPLE + SERIAL` (household) and `SAMPLE + SERIAL + PERNUM`
(person). `parameters.weights.yaml` requests the **same samples with no case
selection**, so its rows align 1:1 with `acs_common`. Join person-level `REPWTP`
on `SAMPLE + SERIAL + PERNUM`; household-level `REPWT` (constant within a
household) on `SAMPLE + SERIAL`. `HHWT`/`PERWT` are carried in both files as a
**merge checksum** — they must match row-for-row; a mismatch means the two
layers' universes drifted (someone changed `samples` or added a case selection on
one side) and both must be re-pulled to realign. Do the join lazily/per-year
(arrow/parquet), not eagerly — 160 columns × ~10M rows is large.

> **The weights `samples` must be a subset of the main pull.** The layer ships
> scoped to the years that need design-based SEs today — the `us2022a`/`us2023a`/
> `us2024a` 1-year files plus the most recent 5-year file (`us2024c`) — not all of
> `acs_common`. Every ID in `parameters.weights.yaml` must also be in
> `parameters.yaml` (you merge onto the matching year), but it need not cover
> every year. Add IDs here if another project needs SEs for earlier years.

## Files

| Path | Purpose |
|------|---------|
| `config/parameters.yaml` | The parameter file (default: common ACS). Edit this. |
| `config/parameters.weights.yaml` | Replicate-weights layer (`REPWT`/`REPWTP`), merged onto `acs_common`. |
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
