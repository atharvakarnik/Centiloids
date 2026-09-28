# Centiloid production pipeline guidance

## Scope and repository layout

- The production pipeline consists of the shell scripts directly inside `Scripts/`.
- Make pipeline changes only to those production scripts unless the user explicitly expands the scope.
- `Scripts/Validation/` is a frozen audit copy built for a different input dataset. Do not inspect, edit, copy from, compare against, or cite its contents.
- `Data/` holds input NIfTI images, templates, atlases, and masks. `Protocols/` holds pipeline outputs. Both directories are intentionally untracked, so assume their paths and expected files are correct unless the user specifically asks to diagnose them.
- `Lists/` contains intermediary subject mappings, selections, missing-subject reports, registration records, calibration coefficients, and other audit CSV/text files. Preserve their schemas and downstream contracts when editing scripts.
- Workers are generally submitted as SLURM arrays by a corresponding `*_wrapper_*.sh` script. Wrappers configure cohort paths and options, construct subject lists, initialize logs, and submit workers; workers process one subject per array task.

## Production workflow

1. **Step 0 — PET and T1 preprocessing:** `Step0_Preprocess.sh` selects the appropriate PET NIfTI for each site/subject. Static PET is reoriented and validated; dynamic PET is motion-corrected, averaged to a 3D image, then reoriented and validated. It also invokes the idempotent T1 helper with the required mask from `${PROJ_DIR}/Data/DLICV`, writing full-head `T1_N4` and `T1_N4_brain` below `Protocols/<batch>/T1_Preproc/`. The canonical downstream PET is written below `Protocols/<batch>/PET_Preproc/`. `PET_reorient_validate.sh` remains the PET helper for header consistency, standard orientation, NaN removal, and basic geometry/intensity checks.
2. **Step 1 — PET-to-T1 registration:** Consume Step 0's `T1_N4_brain` directly. Adaptively crop and modestly smooth a temporary PET derivative only to estimate a rigid PET-to-T1 transform; retain that transform and apply it separately to the unchanged canonical Step 0 PET to create `PET_rT1` for QC.
3. **Step 2 — T1-to-MNI registration:** Consume Step 0's full-head `T1_N4` directly, register it to the configured MNI template without duplicating N4 preprocessing, and retain the forward transform files below `Protocols/<batch>/Registration_T1_to_MNI/` for later reuse.
4. **Step 3 — PET-to-MNI transform application:** Resample the original canonical Step 0 PET directly to MNI in one `antsApplyTransforms` call using the retained PET-to-T1 rigid transform followed by the T1-to-MNI affine and warp. `PET_rT1` is not the quantitative source image. Optional post-MNI smoothing is controlled by `SMOOTH_FWHM_MM`, which must agree with the Step 4 wrapper.
5. **Step 4 — mask-based uptake extraction:** Use the MNI-space cortical target and whole-cerebellum masks on each MNI-space PET, record mean uptake values, calculate whole-cerebellum-referenced SUVR, and consolidate per-subject results.
6. **Step 5 — Centiloid calculation:** Read the consolidated SUVR results and the shared coefficients in `Lists/Calibrated_Coeff/centiloid_coefficients_FBP_WC.csv`, apply the FBP-to-PiB-equivalent and PiB-SUVR-to-Centiloid transforms, and write one batch-level Centiloid CSV. Its result fields are `ID`, `SUVR_WC`, `SUVR_pibeq`, `Centiloid_WC`, `SUV_Ctx`, and `SUV_WC`, with the audit `note` retained; tracer and source-image path are omitted.

## Development rules

- Preserve the direct dependency chain Step 0 -> Step 1 -> Step 2 -> Step 3 -> Step 4 -> Step 5.
- Treat `PET_TAG`, `DATASET`, `LIST_DIR`, `PROTO_DIR`, templates, masks, the shared calibration file, CSV headers, status/note values, and filename patterns as interfaces between stages. Check both the worker and its wrapper when changing one of these interfaces.
- Keep scripts fail-fast (`set -euo pipefail` or the existing stricter variant), array-task-safe, rerunnable where existing output checks provide idempotency, and explicit about missing inputs.
- Preserve the site/subject/long-subject mapping used by subject lists. Do not assume paths may be rewritten merely because the corresponding data is absent from this clone.
- Maintain compatibility with the repository's SLURM/HPC environment and its existing FSL, ANTs, Lmod, micromamba, and Python/pandas setup unless a requested change explicitly replaces one of them.
- Do not run production jobs from a development checkout. For shell changes, at minimum run `bash -n` on every modified shell script; use `shellcheck` when available. Full execution requires the untracked data, software modules, and SLURM environment.
- Keep changes focused. Do not silently alter registration parameters, templates, masks, smoothing, tracer assumptions, calibration coefficients, batch labels, or output schemas while addressing unrelated work.
