# Consolidating the shared IPUMS runs

**Status:** agreed 2026-09-04. Steps 0–3 are repo-side and done; steps 4–8 are
pulls and consumer edits.

The shared raw-data area accumulated eight run folders across two collections,
of which three have no reader and two are the same idea pulled twice. This is the
plan to get to **four**, and only four:

```
ACS/acs_common_v2         the common ACS extract, point-estimate weights only
ACS/acs_common_repwt      ACS replicate weights, opt-in, scoped to 4 samples
CPS-ASEC/cps_asec_common       the common CPS ASEC extract, point-estimate weights only
CPS-ASEC/cps_asec_common_repwt CPS ASEC replicate weights, opt-in, all 11 samples
```

The shape is deliberate and symmetric: **one common file per collection, with the
replicate weights beside it in a merge-on layer.** Everything else is either
folded into the common file or deleted.

## Where things stood, 2026-09-04

| Folder | Size | Samples | Owner | Read by |
|---|---|---|---|---|
| `ACS/acs_common` | 3.9 G | 20 | ji252 | Affordability-Index, caleitc_laborsupply, Tax-Simulator `state_weights.R` |
| `ACS/acs_common_repwt` | 3.6 G | 4 | ji252 | **nobody** |
| `ACS/acs_shelter_1yr` | 173 M | 3 | ji252 | nobody (superseded by v2) |
| `ACS/acs_shelter_1yr_v2` | 176 M | 3 | ji252 | Affordability-Index |
| `ACS/acs_housing` | 265 M | 1 | **ag3377** | **nobody** |
| `ACS/v1` | 1.3 G | 1 CSV | **jmk263** | — |
| `CPS-ASEC/cps_asec_common` | 1.4 G | 11 | ji252 | Tax-Simulator `asec_tax_units.R`, CPS-ASEC-Corrected |
| `CPS-ASEC/v1` | 2.4 G | 7 | **jmk263** | Safety-Net, Reports |

Findings that drove the plan:

1. **`acs_common`'s two newest samples are thin.** `us2024a` dropped 35 requested
   variables and `us2024c` dropped 33 — the entire SPM (Supplemental Poverty
   Measure) block plus `ADJGINC`, `MOOP`, `MEDICAREB`, `OFFPOV`, `TAXID` — because
   both were pulled 2026-07-09/07-21, before IPUMS integrated those blocks into
   the newly released samples. `us2023a` dropped only two. **The common ACS
   extract has no SPM poverty for 2024 at all.** This is a data defect, not a
   filing problem, and re-pulling is the only fix; it is what makes the
   all-or-nothing re-pull below worth its cost.
2. **The ACS replicate-weight layer is dead, and duplicated.** Nothing reads
   `acs_common_repwt`. Meanwhile Affordability-Index submits its own 5-year
   extract with `include_repwt = TRUE` (`R/01_download/02_acs_5yr.R:162`) into
   `data/raw/acs5yr` — 2.0 GB, so `us2024c`'s replicate weights exist twice on
   this filer and the shared copy is the unused one.
3. **The CPS common extract is duplicated too.** Affordability-Index calls
   `download_cps_asec()` unconditionally (`01_download_data.R:87`) and reads
   `cps_asec_common` nowhere, though the README names it as a consumer.
4. **`acs_housing` is orphaned and came from a drifted fork.** Pulled by ag3377
   on 2026-08-17; no reader; and its `parameters.housing.yaml` exists only in
   `/nfs/roberts/project/pi_nrs36/ag3377/common_ipums_download/`, a copy of this
   repo whose `download_ipums.R` predates the 2026-08-19 CPS data-quality-flag
   fix and which lacks `pull_ipums.sbatch`, `parameters.shelter.yaml` and
   `parameters.cps.yaml`. Two programs write into one shared namespace and one is
   missing a bug fix. This is the structural risk; the disk is not.
5. **`SCHLCOLL` was silently lost.** Committed and pulled 2026-08-27 on branch
   `cps-schlcoll`, never merged, so the 2026-09-03 re-pull dropped it again. Now
   merged (`719fc47`); it lands on the next CPS pull.

## Decisions

**D1 — Fold the shelter and housing layers into the common ACS extract, under a
new run id `acs_common_v2`.** The README's own retirement trigger is met twice
over: two layers overlap, and a second project (ag3377's) entered the pattern.
The new id rather than `--overwrite` is what lets each consumer re-point one line
at a time and roll back by editing that line.

**D2 — Split the CPS replicate weights out of `cps_asec_common` into
`cps_asec_common_repwt`.** This reverses the 2026-09-01 CPS-ASEC-Corrected
decision to carry them inline. Measured, not argued:

| | per year | 11 years |
|---|---|---|
| CPS ASEC without replicate weights (85 vars, measured 2026-08-27) | 7.6–9.4 MB | ~95 MB |
| with the 322 replicate columns inline (as pulled 2026-09-03) | 111–152 MB | 1.4 G |
| projected split — common, at today's 180 requested vars | ~18–20 MB | ~220 MB |
| projected split — `cps_asec_common_repwt` | ~115 MB | ~1.3 G |

Total disk barely moves; the join keys get duplicated. The gain is on the read
side: Tax-Simulator's `asec_tax_units.R` and CPS-ASEC-Corrected's survey
aggregates read ~20 MB a year instead of ~130 MB, roughly 6× cheaper. The cost
lands on one project: CPS-ASEC-Corrected re-estimates weights inside every
replicate, so it needs both halves on every run and gains a per-year join. That
cost is accepted in exchange for a cheap common file for every consumer that does
no variance estimation, and for symmetry with the ACS side.

**D3 — `acs_common_repwt` stays scoped to `us2022a`/`us2023a`/`us2024a`/`us2024c`.**
It is not a consolidation candidate: the 160 replicate columns roughly quadruple
the extract (measured: 203 M → 552 M for `us2022a`; 610 M → 2.0 G for `us2024c`)
and only variance estimation wants them, so it is opt-in **by design**. Extending
it to all 20 ACS samples would cost roughly 11 GB to serve no current consumer.
Add samples when a project needs standard errors for an earlier year, and not
before.

**D4 — Additive pulls first, overwriting pulls last.** Every new artifact
(`acs_common_v2`, `cps_asec_common_repwt`) is written to a folder nothing reads,
verified, and only then do consumers move and the superseded folders go. The one
genuinely destructive step — re-pulling `cps_asec_common` without the replicate
columns — happens only after `cps_asec_common_repwt` exists and has been checked,
so the replicates are never absent from the shared area.

**D5 — The fork is reconciled before the fold.** `parameters.housing.yaml` comes
into this repo (its variables are folded into `parameters.yaml`, so the file
itself does not survive), and ag3377 works from a clone with a remote rather than
a copy. Otherwise the consolidation lands here and a second, older program can
still write into the shared namespace.

## Availability: checked, not assumed

The README's retirement procedure says to sanity-check availability before
committing to a long pull, warning to "expect real gaps in the 2000s".
**Probed 2026-09-04 against the live API — that warning was wrong for these
variables.** `ipumsr` 0.10.0 exposes no per-variable availability endpoint
(`get_metadata()` covers samples only for microdata collections), so the probe
submitted one extract per test sample carrying only the 32 candidates and read
what the pruning loop removed:

| sample | candidates unavailable | data-quality flags unavailable |
|---|---|---|
| `us2024a` | `MULTYEAR` | `PLUMBING` |
| `us2006a` | `MULTYEAR` | `PLUMBING`, `OWNCOST`, `RENTGRS` |
| `us2024c` | none | `PLUMBING`, `ACREHOUS` |

So:

- **All 32 candidate names are valid** — no `PROPTXAMT`-style outright rejection,
  which is the failure that would otherwise abort the pull at the first sample.
- **`us2006a` carries 31 of 32**, including `RENTGRS`, `OWNCOST`, all four
  `COST*`, `FUELHEAT`, `GRADEATT`, `SCHLTYPE`, `FERTYR`, `ROOMS`, `BEDROOMS`,
  `UNITSSTR`, `BUILTYR2`, `MOVEDIN`, `KITCHEN`, `PLUMBING`, `RENTMEAL`,
  `ACREHOUS`, `VEHICLES`. The fold reaches back across the whole panel, not just
  the recent years.
- `MULTYEAR` is multi-year-sample-only, so it is carried for `us2024c` and pruned
  for the nineteen 1-year samples — the same known-and-documented asymmetry
  `EXPWTH`/`EXPWTP` already have for `us2020a`.
- `PLUMBING`'s data-quality flag does not exist in any probed sample, so it is
  **not** requested. The `OWNCOST`/`RENTGRS`/`ACREHOUS` flag gaps are per-sample
  and the pruning loop handles them, recording each in that year's
  `manifest.json` under `dropped_dq_flags`.

## What the fold adds

54 variables that `acs_common` lacked, from the union of `acs_shelter_1yr_v2` and
`acs_housing` (32 substantive + their allocation flags):

- **Shelter concepts** — `RENTGRS` (gross rent = contract rent + utilities),
  `OWNCOST` (selected monthly owner costs), `MORTGAGE`, `MORTAMT1`, `MORTAMT2`,
  `TAXINCL`, `INSINCL`, `PROPINSR`, `CONDOFEE`, `MOBLHOME`.
- **Utilities** — `COSTELEC`, `COSTGAS`, `COSTWATR`, `COSTFUEL`, `FUELHEAT`.
- **Dwelling** (from ag3377's layer) — `ROOMS`, `BEDROOMS`, `UNITSSTR`,
  `BUILTYR2`, `MOVEDIN`, `KITCHEN`, `PLUMBING`, `ACREHOUS`, `RENTMEAL`,
  `VEHICLES`, plus `MULTYEAR` and `ADJUST` for the 5-year sample.
- **Enrollment / fertility** — `GRADEATT`, `GRADEATTD`, `SCHLTYPE`, `FERTYR`.

## Steps

- [x] **0. Merge and clean the branches.** `cps-schlcoll` merged (`719fc47`);
      `shelter-merge-layer` was already contained in main. Both local branches and
      the remote `shelter-merge-layer` deleted.
- [x] **1. Fix the README drift** (`0cb29e0`).
- [x] **2. Probe availability** for the 32 candidates (table above).
- [x] **3. Repo-side changes.** `parameters.yaml` carries the folded variables and
      `id: acs_common_v2`; `parameters.cps.weights.yaml` is the new CPS weights
      layer; `parameters.cps.yaml` no longer requests `REPWT`/`REPWTP`;
      `parameters.shelter.yaml` marked superseded, kept until step 6.
- [ ] **4. Pull `acs_common_v2`** — 20 samples, additive, nothing reads it yet.
      Verify: record counts match `acs_common` sample-for-sample (the universe
      must not move), the SPM block is present for `us2024a`/`us2024c`, and each
      `manifest.json`'s `dropped_variables` holds no surprises.
- [ ] **5. Pull `cps_asec_common_repwt`** — 11 samples, additive.
      Verify record counts against `cps_asec_common` sample-for-sample.
- [ ] **6. Re-point consumers**, one line each:
      - Affordability-Index `config/local_paths.yaml`: `acs_common_root` →
        `acs_common_v2`; delete `acs_shelter_root` and the `shelter_root`
        plumbing in `R/02_income/01_pool_deflate.R` (its `keep_cols` needs the
        new names, since it selects down from the superset).
      - caleitc_laborsupply `config/local_paths.yaml`: `acs_common_root`.
      - Tax-Simulator `src/data/state_weights.R:94` and its comment at `:188`.
      - Affordability-Index: retire the private 5-year extract in favour of
        `acs_common_v2` + `acs_common_repwt`, and the private CPS extract in
        favour of `cps_asec_common`.
- [ ] **7. Re-pull `cps_asec_common` without the replicate columns**
      (`--overwrite`). The one destructive step; safe only once step 5 is
      verified. This is also the pull that restores `SCHLCOLL`. Then re-point
      CPS-ASEC-Corrected to join the two halves on `SERIAL` (household) and
      `SERIAL + PERNUM` (person), with `ASECWTH`/`ASECWT` as the merge checksum.
- [ ] **8. Delete the superseded folders** (see below).

## What gets deleted, and what does not

**Delete, once the step-6 consumers have moved:**

| Folder | Size | Why it can go |
|---|---|---|
| `ACS/acs_shelter_1yr` | 173 M | superseded by v2, no reader. **Deletable now** — independent of every other step. |
| `ACS/acs_shelter_1yr_v2` | 176 M | folded into `acs_common_v2`; after Affordability-Index re-points |
| `ACS/acs_housing` | 265 M | folded in; **ag3377's folder — needs their sign-off**, and D5 must land first or the variable list is lost |
| `ACS/acs_common` | 3.9 G | after all three consumers move to `acs_common_v2` |

**Keep:** `acs_common_repwt`. Per D3 it is opt-in by design. The fix for it being
unread is not to delete or re-pull it but to point Affordability-Index's rent
surface at it and retire that repo's 2.0 GB private copy.

**Do not touch — another owner's, and still live:** both `v1` trees, 3.7 G
combined, belong to **jmk263**, and `CPS-ASEC/v1/2025031013/historical/` is still
read by Safety-Net (`src/medicaid_snap_baseline_dist.R:21`) and Reports
(`2025/ctc_refundability_insurance/src/main.R:18`) — through a stale
`/gpfs/gibbs/project/sarin/` path, at that. Leave them.

**Net disk is a wash:** roughly 4.5 G reclaimed against ~1.6 G added by 54 more
variables across 20 years. Disk is not the reason to do this. The reason is that
a downstream repo goes from needing to know about six ACS folders and two
variable lists to two folders and one.
