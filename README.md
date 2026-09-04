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

There are **four** run folders in the shared area and there should never be more:
`ACS/acs_common_v2` and `CPS-ASEC/cps_asec_common` are the common extracts, and
`ACS/acs_common_repwt` and `CPS-ASEC/cps_asec_common_repwt` are their replicate-
weight layers. `docs/consolidation_plan.md` records how that shape was arrived at
and which folders are still being retired to reach it.

## Quick start

```bash
module load R/4.4.2-gfbf-2024a                  # pin the version; a bare `module load R` gives 4.4.1
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

**A multi-sample pull belongs in a batch job.** It is tens of minutes of mostly
waiting on IPUMS to build each extract, and a long process started from a login
shell gets reaped part-way through — which leaves a sample folder with its old
files already cleared and no replacement, recoverable only with another
`--overwrite` pass. Use `pull_ipums.sbatch`:

```bash
sbatch --output=$HOME/slurm-logs/%x-%j.out pull_ipums.sbatch \
       config/parameters.cps.yaml --overwrite
```

A finished job is not a successful one: check that the log ends with `Complete:`
and the expected sample count, and check each sample's `manifest.json`
`dropped_variables`.

Each pull needs a **run id** (`output.id`) — a specific, meaningful name you set
(an empty id is a hard error). Re-running is safe: unless `--overwrite` is passed,
an output folder that already holds a codebook is left untouched. Re-run with the
**same id** in `per_year` mode to add only the missing years; use a **new id** for
a fresh pull.

## What gets stored, and where

Output goes to `<save_location>/<id>/` — one named run folder directly under the
dataset (no version layer), e.g.:

```
raw_data/ACS/acs_common_v2/
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
ACS/acs_common_v2/
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
  open_dataset("…/ACS/acs_common_v2/pooled") |>
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
ACS/acs_common_v2/     # main lean extract (parameters.yaml)
ACS/acs_common_repwt/  # replicate-weights layer, same us<YYYY> subfolders
```

**Why separate, not baked into `parameters.yaml`.** The 160 replicate-weight
columns roughly **3–4×** the extract, measured on this pull: `us2022a` goes
203 MB → 552 MB and `us2024c` 610 MB → 2.0 GB. Only variance estimation needs them, so folding them into the
common file would tax *every* downstream repo — most of which only want point
estimates — on every read. Keeping them in an opt-in layer leaves the common
file lean and makes the weight matrix a load-only-when-needed artifact.

**Why the merge is lossless.** An IPUMS extract is deterministic given
`(collection, samples, no case selection)`: every record in a sample is returned,
uniquely keyed by `SAMPLE + SERIAL` (household) and `SAMPLE + SERIAL + PERNUM`
(person). `parameters.weights.yaml` requests the **same samples with no case
selection**, so its rows align 1:1 with the common extract. Join person-level `REPWTP`
on `SAMPLE + SERIAL + PERNUM`; household-level `REPWT` (constant within a
household) on `SAMPLE + SERIAL`. `HHWT`/`PERWT` are carried in both files as a
**merge checksum** — they must match row-for-row; a mismatch means the two
layers' universes drifted (someone changed `samples` or added a case selection on
one side) and both must be re-pulled to realign. Do the join lazily/per-year
(arrow/parquet), not eagerly — 160 columns × ~10M rows is large.

> **The weights `samples` must be a subset of the main pull.** The layer ships
> scoped to the years that need design-based SEs today — the `us2022a`/`us2023a`/
> `us2024a` 1-year files plus the most recent 5-year file (`us2024c`) — not all of
> the common ACS extract. Every ID in `parameters.weights.yaml` must also be in
> `parameters.yaml` (you merge onto the matching year), but it need not cover
> every year. Add IDs here if another project needs SEs for earlier years.

**CPS works the same way**, since 2026-09-04. `config/parameters.cps.weights.yaml`
is the CPS ASEC replicate-weights layer (`cps_asec_common_repwt`), merged onto
`cps_asec_common` on `SERIAL` (household) and `SERIAL + PERNUM` (person), with
`ASECWTH`/`ASECWT` — the CPS weight names, not the ACS `HHWT`/`PERWT` — as the
checksum. It covers all 11 samples, unlike the ACS layer, because
CPS-ASEC-Corrected re-estimates weights inside every replicate for every income
year in the panel.

This **reverses** the 2026-09-01 CPS-ASEC-Corrected decision to carry
`REPWT`/`REPWTP` inline on the grounds that the ASEC is small enough to absorb
them. Measurement said otherwise: without the replicate columns an ASEC year is
7.6–9.4 MB gzipped (measured 2026-08-27, 85 variables); with the 322 columns
inline it is 111–152 MB. Every consumer wanting only point estimates —
Tax-Simulator's `asec_tax_units.R`, CPS-ASEC-Corrected's own survey aggregates —
was reading ~130 MB a year to use ~20 MB of it. The split makes the common file
roughly 6× cheaper to read; the cost is a per-year join for the one project that
needs both halves on every run. See `docs/consolidation_plan.md` D2.

The 2026-09-01 pass also added the whole-supplement imputation status
(`UH_SUPREC_A2`, an unharmonized IPUMS variable), program receipt/amount detail,
the SPM and official-poverty blocks and the wider set of allocation flags; see
the in-file comments for what was API-verified and what each sample lacks.

## Shelter costs: folded in, layer retired

**Retired 2026-09-04.** `config/parameters.shelter.yaml` (`acs_shelter_1yr_v2`)
and ag3377's `acs_housing` were the two shelter/dwelling merge layers, and they
overlapped heavily — which is exactly the consolidation trigger below. Their 54
variables now live in `parameters.yaml`, pulled as `acs_common_v2`:

- **Shelter concepts** — `RENTGRS` (gross rent = contract rent + utilities) and
  `OWNCOST` (selected monthly owner costs). The common extract used to carry only
  `OWNERSHP` and **contract** `RENT`, so a SNAP model deducted contract rent for
  renters and **nothing at all for owners** — roughly two thirds of households —
  because for owners the excess-shelter statute's concept *is* SMOC.
- **Owner-cost components** — `MORTGAGE`, `MORTAMT1/2`, `TAXINCL`, `INSINCL`,
  `PROPINSR`, `CONDOFEE`, `MOBLHOME`.
- **Utilities** — `COSTELEC/GAS/WATR/FUEL`, `FUELHEAT`. Needed separately because
  `RENTGRS` and `OWNCOST` both embed *actual* utility bills, which a **Standard
  Utility Allowance** treatment (the state's flat allowance in place of the
  household's real bills) has to strip back out; the allowance varies by heating
  source, hence `FUELHEAT`.
- **Dwelling** — `ROOMS`, `BEDROOMS`, `UNITSSTR`, `BUILTYR2`, `MOVEDIN`,
  `KITCHEN`, `PLUMBING`, `ACREHOUS`, `RENTMEAL`, `VEHICLES`, plus `MULTYEAR` and
  `ADJUST` for the 5-year sample.
- **Enrollment / fertility** — `GRADEATT` and `GRADEATTD` (enrollment *level* —
  the only thing separating a college student from a high-school student, which
  the SNAP student rule turns on; `SCHOOL` says only whether someone is
  enrolled), `SCHLTYPE` (public vs private, for the school-meals offset) and
  `FERTYR` (a birth in the last year, for the WIC offset).

Availability was probed against the live API before committing to the re-pull:
**`us2006a` carries 31 of the 32 substantive names**, so the fold reaches back
across the whole 2006–2024 panel rather than only the recent years. The one
exception is `MULTYEAR`, a multi-year-file concept that exists only for
`us2024c`. `PLUMBING` has no data-quality flag in any sample probed, so none is
requested for it. See `docs/consolidation_plan.md` for the probe table and the
step-by-step plan.

`PROPTXAMT` is **not** a valid IPUMS USA variable name (the API rejects it;
confirmed 2026-08-27). Property tax is available only as the bracketed
`PROPTX99`, which the common extract already carries — and `OWNCOST` includes
property tax anyway, so nothing is lost.

`parameters.shelter.yaml` is kept, marked superseded, only until
Affordability-Index re-points at `acs_common_v2`; then it and both shelter
folders go.

## Retiring a merge layer

A merge layer is a **deliberate temporary**: it exists so one project can move
without taxing every other reader of the common file. Once enough projects want
the same variables, the layer has outlived its purpose and the variables belong
in `parameters.yaml`.

**This has been done once**, on 2026-09-04, folding the shelter and housing
layers in — `docs/consolidation_plan.md` is the worked example, with the actual
costs, probe results and consumer edits. What follows is the general procedure.

**Trigger to consolidate** — any of:

- a second project starts merging the same layer;
- the layer's variables become load-bearing for a published number rather than
  exploratory;
- two layers overlap (as `acs_housing` and `acs_shelter_1yr_v2` did, which is
  what triggered the 2026-09-04 consolidation).

**Why this is an all-or-nothing re-pull, not an incremental add.** In `per_year`
layout, re-running with the *same* `id` pulls **only missing years** — it will
not retrofit new variables into years already on disk. Forcing it needs
`--overwrite`, and a partial overwrite would leave the run's per-year files
carrying different variable sets, which the stackability guard is there to catch.
So folding a layer in means re-pulling **every** sample in `parameters.yaml`
(currently 2006–2024). That is the real cost, and it is why consolidation is a
scheduled operation rather than a casual one.

**Procedure.**

1. Add the layer's substantive variables to the matching group in
   `parameters.yaml` — `RENTGRS`/`OWNCOST`/`MORT*`/`COST*` to *Housing / tenure*,
   `GRADEATT` to *Demographics* — and their `data_quality_flags`. Drop the
   layer's join keys and checksums; the common file already has them.
2. Probe availability before committing to a long pull, and **probe it rather
   than assuming it** — the 2026-09 fold expected "real gaps in the 2000s" and
   found `us2006a` carried 31 of 32 candidates. `ipumsr` has no per-variable
   availability endpoint (`get_metadata()` covers samples only for microdata
   collections), so the check is: submit — never download — one extract per test
   sample carrying only the candidate variables, and read what the pruning loop
   removes. Probe the oldest and newest samples plus the 5-year file; those
   bracket the panel. The thing you are really guarding against is a name that
   is invalid outright (as `PROPTXAMT` is), because that produces a rejection
   with no droppable variable named and aborts the pull at the first sample.
   Real per-sample gaps are handled automatically and logged in each
   `manifest.json` under `dropped_variables` / `dropped_dq_flags`.
3. Bump `id` to a new run (as `acs_common` → `acs_common_v2`) rather than
   `--overwrite`-ing the run consumers are reading. **Downstream repos read the
   common extract by path**, so overwriting it changes data underneath running
   projects; a new id lets each consumer re-point deliberately and roll back by
   editing one line.
4. Re-pull. Verify record counts per sample match the old run exactly — the
   universe must not move.
5. Re-point consumers. In Affordability-Index that is `acs_common_root` in
   `config/local_paths.yaml`, plus deleting `acs_shelter_root` and the
   `shelter_root` plumbing in `R/02_income/01_pool_deflate.R`; `keep_cols` there
   also needs the new names, since it selects down from the superset.
6. Retire the layer: delete its parameter file, and fold any overlapping layer
   into the same pass so one story replaces two. Leave the old run folders in
   place until every consumer has moved, and remember a layer someone else
   pulled is **their** folder — its parameter file has to come into this repo
   first, or the variable list is lost with it.
7. Keep `parameters.weights.yaml` as a layer regardless. It is not a candidate:
   the 160 replicate-weight columns roughly 4× the extract and only variance
   estimation wants them, so it is opt-in **by design**, not by expedience.

**The rule of thumb:** layers are for variables *one* project needs *now*;
`parameters.yaml` is for variables *several* projects need *routinely*. Moving a
variable from the first category to the second is the intended lifecycle, not a
correction.

## Files

| Path | Purpose |
|------|---------|
| `config/parameters.yaml` | The parameter file (default: common ACS). Edit this. |
| `config/parameters.weights.yaml` | ACS replicate-weights layer (`REPWT`/`REPWTP`), merged onto the common ACS extract. |
| `config/parameters.cps.weights.yaml` | CPS ASEC replicate-weights layer (`REPWT`/`REPWTP`), merged onto `cps_asec_common`. |
| `config/parameters.shelter.yaml` | **Superseded** — folded into `parameters.yaml` 2026-09-04; kept until its readers move. |
| `config/parameters.cps.yaml` | The common CPS ASEC extract (`cps_asec_common`) — carries `REPWT`/`REPWTP` inline; see above. |
| `config/parameters.cps.example.yaml` | Starter template for a CPS pull. |
| `config/api_codes.example.csv` | Template for your IPUMS key (copy to `api_codes.csv`). |
| `download_ipums.R` | The program: extract → download → manifest. |
| `R/build_extract.R` | Turns the parameter file into an `ipumsr` extract definition. |
| `R/utils.R` | API-key reader, transient-error retry, record counter. |
| `pull_ipums.sbatch` | Slurm wrapper — the reliable venue for a real pull (see Quick start). |
| `docs/consolidation_plan.md` | Why there are four run folders and not eight; the plan, decisions, and remaining steps. |

## Requirements

- R (on the server: `module load R/4.4.2-gfbf-2024a` — pin the full version,
  since a bare `module load R` silently gives the Lmod default 4.4.1 from the
  2022b toolchain). Packages: **ipumsr**, **yaml**, **jsonlite** (all in the
  server CRAN bundle); **arrow** only if `write_parquet: true`.
- An IPUMS account + API key registered for the collection you're pulling
  (IPUMS USA for ACS, IPUMS CPS for CPS).
