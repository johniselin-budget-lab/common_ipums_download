# Note for ag3377 — `acs_housing` and your copy of this repo

Draft; send as-is or in your own words. Two separate things: the folder, and the
fork. The second matters more.

## 1. `acs_housing` has been folded into the common extract

Your `acs_housing` run (`us2024c`, pulled 2026-08-17) and the
`acs_shelter_1yr_v2` shelter layer overlapped heavily. That is the consolidation
trigger this repo's README documents, so on **2026-09-04** both were folded into
the common ACS extract, pulled as a new run id **`acs_common_v2`**:

```
/nfs/roberts/project/pi_nrs36/shared/raw_data/ACS/acs_common_v2/
```

Everything `acs_housing` carried is in there — `ROOMS`, `BEDROOMS`, `UNITSSTR`,
`BUILTYR2`, `MOVEDIN`, `KITCHEN`, `PLUMBING`, `ACREHOUS`, `RENTMEAL`,
`VEHICLES`, `MULTYEAR`, `ADJUST`, the `COST*` block, `FUELHEAT`, `RENTGRS` — plus
their allocation flags, and now also `OWNCOST` and the owner-cost components your
layer deliberately left out. Two things you gain:

- **All 20 samples, not just `us2024c`.** Availability was probed against the API
  first, and `us2006a` carries 31 of the 32 names, so the housing block now runs
  2006–2024. Only `MULTYEAR` is 5-year-only, as expected.
- **One codebook.** The variables are in the common extract's own DDI, so the
  N/A-sentinel screen no longer has to consult a second one. That was a real
  footgun: `OWNCOST` codes `99999` = "not in universe" for every renter, and
  screened against the wrong codebook that sentinel survives and gets deflated
  into a plausible-looking five-figure shelter cost.

Record counts in `acs_common_v2` are identical to `acs_common` sample-for-sample,
so nothing computed off the old path moves.

**What we'd like to do:** delete `/…/raw_data/ACS/acs_housing` (265 MB). It is
your folder, nothing in the tree reads it, and its variables are all preserved
above — but it is yours, so we are asking rather than doing. The old `acs_common`,
`acs_shelter_1yr` and `acs_shelter_1yr_v2` have already gone.

`parameters.housing.yaml` itself does not survive the fold — its variables are in
`config/parameters.yaml` now. If you were relying on being able to re-pull that
exact layer, say so before we delete.

## 2. Your copy of the repo is a fork, and it has drifted

`/nfs/roberts/project/pi_nrs36/ag3377/common_ipums_download/` is a copy rather
than a clone, and it has fallen behind in ways that will bite you:

- **`download_ipums.R` predates the 2026-08-19 CPS data-quality-flag fix.** It
  only recognises `"X has data quality flags, but none are available"` and not
  `"X does not have any data quality flags"`, which is the phrasing IPUMS CPS
  returns because flags there attach to the component variables (`OINCWAGE`,
  `OINCBUS`, `INCLONGJ`) rather than the aggregates. Any CPS pull from your copy
  hard-fails.
- **It predates the 2026-09-04 transient-retry fix.** A 504 gateway timeout at
  submit time aborts the whole run and reports it as *"the sample may be
  unreleased or invalid"* — a wrong diagnosis that costs you an afternoon. This
  bit us on the first CPS weights pull.
- **No `pull_ipums.sbatch`**, so pulls run from a login shell, where a long one
  gets reaped part-way and leaves a sample folder cleared with no replacement.
- No `parameters.shelter.yaml` or `parameters.cps.yaml`.

Two programs writing into one shared namespace, one of them missing bug fixes, is
the thing most likely to produce a bad shared artifact. Could you switch to a
clone with a remote?

```bash
git clone git@github.com:johniselin-budget-lab/common_ipums_download.git
```

Your `R/check_existing_acs.R` has no upstream equivalent and the idea was a good
one — the same check got written twice independently, which is why upstream now
has `R/compare_runs.R` (verifies a new run against the one it supersedes: same
record universe, what the variable set gained or lost, exits non-zero on a
mismatch). If yours does something that one does not, send it as a PR.

## Context

`docs/consolidation_plan.md` in this repo has the full picture: what the shared
area held, the five decisions, the API probe results, and what is left.
