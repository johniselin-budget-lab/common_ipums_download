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

1. **`acs_common`'s two newest samples are thin, and re-pulling does NOT fix
   it.** `us2024a` drops 35 requested variables and `us2024c` drops 33 — the
   entire SPM (Supplemental Poverty Measure) block plus `ADJGINC`, `MOOP`,
   `MEDICAREB`, `OFFPOV`, `TAXID` — where `us2023a` drops only two. **The common
   ACS extract has no SPM poverty for 2024 at all.**

   I assumed this was a timing artefact: both were pulled 2026-07-09/07-21, just
   after release, and I expected IPUMS to have integrated the block by now, which
   made the re-pull look like it would pay for itself twice over. **That was
   wrong.** The 2026-09-04 `acs_common_v2` pull dropped the identical 33-variable
   SPM/poverty block for both samples — IPUMS still does not offer it for the
   2024 files. The gap is upstream and no pull from here will close it; it closes
   when IPUMS integrates the block, and the only action available is to re-pull
   those two samples (cheap, two folders) once it does.

   The 2006–2008 and `us2020a` absences are separate and legitimate: SPM begins
   around 2009, and `us2020a` is the experimental COVID sample.

   So the consolidation stands on its own merits — one common file instead of
   six folders and two variable lists — and not on an SPM fix that did not
   happen.
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
| **measured, after the split — common** | **13.7–17.8 MB** | **172 MB** |
| **measured, after the split — `cps_asec_common_repwt`** | ~96–110 MB | 1.2 G |

Total disk barely moves; the join keys get duplicated. The gain is on the read
side: Tax-Simulator's `asec_tax_units.R` and CPS-ASEC-Corrected's survey
aggregates read ~16 MB a year instead of ~134 MB — **8.6× cheaper measured**,
against the ~6× projected. The cost
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

**Measured on the completed pull: +52 to +54 columns per sample** (53 for
`us2024c`), the spread being which data-quality flags a given year offers. Every
sample gained; none lost a single variable. From the union of
`acs_shelter_1yr_v2` and `acs_housing` (32 substantive names + their allocation
flags):

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
- [x] **4. Pull `acs_common_v2`** — done 2026-09-04, 20/20 samples, 4.7 G.
      `R/compare_runs.R` confirms **every sample's record count is identical** to
      `acs_common` (`us2024c` 16,095,728 → 16,095,728), +52/+54 columns, nothing
      lost, and `RENTGRS`/`OWNCOST`/`GRADEATT` present in all 20 including
      2006–2008. The SPM assertion failed for `us2024a`/`us2024c` — see the
      correction in finding 1; that is upstream, not a pull defect.

      The Slurm job reports **FAILED (exit 1)** despite pulling everything: the
      script was edited in place while it ran, which shifts byte offsets under
      Rscript's incremental parser (see the warning now in `pull_ipums.sbatch`).
      All 20 folders were checked artifact-by-artifact and are complete. Original
      instruction, for a clean re-run:
      Verify with `R/compare_runs.R`, asserting the variables the re-pull was
      actually for:

      ```bash
      Rscript R/compare_runs.R \
        /nfs/roberts/project/pi_nrs36/shared/raw_data/ACS/acs_common \
        /nfs/roberts/project/pi_nrs36/shared/raw_data/ACS/acs_common_v2 \
        RENTGRS OWNCOST GRADEATT
      ```

      It exits non-zero on any record-count mismatch, which is the signal that
      the row universe moved and no consumer may be re-pointed. Then check the
      SPM block came back for `us2024a`/`us2024c` (finding 1) — those two samples
      are the reason this pull is worth its cost:

      ```bash
      Rscript R/compare_runs.R \
        .../ACS/acs_common .../ACS/acs_common_v2 SPMPOV SPMTHRESH SPMTOTRES OFFPOV
      ```
- [x] **5. Pull `cps_asec_common_repwt`** — done 2026-09-04, 11/11 samples,
      1.2 G, exit 0. Record counts identical to `cps_asec_common` in all eleven;
      332 columns each (322 replicates + keys + the `ASECWTH`/`ASECWT`
      checksums); the schema guard reports all 11 years share an identical
      variable set. The large negative variable delta against the common file is
      expected and correct — this layer deliberately carries no substantive
      variables. It also needed the submit-time transient-retry fix: the first
      attempt died on sample 1 to a 504 gateway timeout that the old code
      reported as an unreleased sample.
- [x] **6. Re-point consumers** — done 2026-09-04. The two `local_paths.yaml`
      files are gitignored, so those re-points needed no commit; the code and
      template changes are committed on a branch per repo, **not pushed**.
      - **Affordability-Index** (`c0801b1`, branch
        `snap-intensive-scalar-and-d22-units`) — `acs_common_root` →
        `acs_common_v2`; `acs_shelter_root` deleted; and the whole shelter merge
        removed from `pool_deflate_acs()`: the `shelter_root` parameter,
        `shelter_xml()`/`read_shelter()`, the 1:1 alignment check, the
        `HHWT`/`PERWT`/`OWNERSHP`/`RENT` checksum loop and both joins. The
        per-year read is now read + select. `keep_cols` gains the shelter block,
        which it must — it selects this repo's schema down from a superset.
        `docs/11_snap_imputation.md` §7d rewritten, since it documented the
        machinery that was just deleted.
      - **Tax-Simulator** (`3c43050d6`, branch `state-tax`) —
        `state_weights.R:94` and its path comment. `asec_tax_units.R` needed no
        change: the CPS common extract kept its name and reads no replicate
        weights, so D2's split is transparent to it.
      - **caleitc_laborsupply** (`ea9ee84`) and **multnomah-county-tax**
        (`f5b71b0`) — both were on `main`, so each got a branch
        `acs-common-v2-repoint`. Committed example paths and one error message;
        multnomah's are commented-out examples, it reads no shared ACS path
        today.

      **The sentinel screen is the part that mattered.** Dropping the merge
      layer means one codebook instead of two, and `OWNCOST` codes
      99999 = "not in universe" for every renter — screened against the wrong
      codebook that sentinel survives and is deflated into a plausible-looking
      five-figure shelter cost. Verified rather than assumed: against
      `acs_common_v2/us2024a`, `.na_codes_for()` finds 99999 in the *common* DDI,
      screening 13,613 of 50,000 rows, leaving a median owner cost of $980/month
      and median gross rent of $1,055/month. All 18 shelter columns survive
      `keep_cols` in all three years.

      Still open from this step, and deliberately not attempted: retiring
      Affordability-Index's own 5-year extract (`data/raw/acs5yr`, 2.0 G, with
      replicate weights) in favour of `acs_common_v2` + `acs_common_repwt`, and
      its own CPS extract (`data/raw/cps`) in favour of `cps_asec_common`. Those
      are pipeline changes in that repo rather than path re-points, and want
      their own pass — but they are what would finally give `acs_common_repwt` a
      reader.

- [x] **7. Re-pull `cps_asec_common` without the replicate columns** — done
      2026-09-04, job 24874487, 11/11 samples, exit 0, 17 minutes. **1,471 MB ->
      172 MB, 8.6x smaller**, better than the ~6x projected (the inline replicate
      block compresses worse than the 85-variable measurement implied). Every
      record count identical; exactly one variable gained per sample —
      `SCHLCOLL`, restored after being lost in the 2026-09-03 re-pull — and zero
      non-replicate variables lost. All 11 folders complete; the schema-drift
      warnings are byte-identical to the 2026-09-03 run, i.e. the same legitimate
      per-year availability (`HOUSSUB` retired after 2015; the `INCPEN*`/`SRCRINT*`
      retirement-income detail only from 2019), not new drift.

      Before running it: the 11 pre-overwrite manifests were copied to
      `~/ipums-manifests-preoverwrite-20260904/`, so the exact old variable lists
      and record counts survive the folders being rewritten. Original
      instruction:
      (`--overwrite`). The one destructive step; safe only once step 5 is
      verified, and it has a window in which the folder's old files are cleared
      and the new ones not yet down — which is why it runs in batch, never from a
      login shell. This is also the pull that restores `SCHLCOLL`. Verify record
      counts held with `R/compare_runs.R` against `cps_asec_common_repwt`, which
      by then is the only run carrying the old universe. The split's arithmetic
      now checks out on real files: the weights layer alone is 96 MB for
      `cps2025_03s` against 111 MB for the inline common file, so the common file
      after the split should land near 15-20 MB a year as projected. Then
      re-point
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
