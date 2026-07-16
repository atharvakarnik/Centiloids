#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted from GAAIN's vld to DPPOS Dataset     #
# ------------------------------------------------- #
#
# Step0_PreprocessPET.sh
# SLURM array script: one subject per task.
#
# Supports both:
#  - Static PET (3D)  -> copy only to ${SUB}_PET_3D.nii.gz
#  - Dynamic PET (4D) -> mcflirt -> mean -> ${SUB}_PET_4D_mcf.nii.gz
#
# Expected input layout in DPPOS-style B) :
#   ${DATA_DIR}/${SITE}/${SUB}/${SUB}_${SITE}.nii.gz
#
# Outputs:
#   ${PROTO_DIR}/PET_Preproc/${SITE}/${SUB}/${SUB}_PET_3D.nii.gz      (3D, downstream canonical)
#   ${PROTO_DIR}/PET_Preproc/${SITE}/${SUB}/${SUB}_PET_4D_mcf.nii.gz  (4D, only for dynamic)
#
# Logs:
#   ${LIST_DIR}/pet_preproc_selection.csv
#   ${LIST_DIR}/pet_preproc_missing.csv

#SBATCH --partition=all
#SBATCH --propagate=NONE
#SBATCH --job-name=PET_Preproc
#SBATCH --output=Logs/Jun26/PET_Preproc_%A_%a.log
#SBATCH --time=00:10:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G

set -euo pipefail
shopt -s nullglob

############################# fslnvols is causing some issue ######################################
: "${FSLDIR:?FSLDIR is not set (export it in wrapper or set it here)}"
export PATH="${FSLDIR}/bin:${PATH}"

# Idk why FSL is not visible in some nodes, so have to do this. Future scope - containerize this!!
if ! command -v module >/dev/null 2>&1; then
  # Literally witnessed 'module' command not found in some nodes!
  source /usr/share/Modules/init/bash
  module load fsl/5.0.11 >/dev/null 2>&1 || true
  # shellcheck disable=SC1090
  source "${FSLDIR}/etc/fslconf/fsl.sh"
fi

####################################################################################################

MCRMMBA_EXE="${HOME}/.local/bin/micromamba"
export MAMBA_ROOT_PREFIX="${HOME}/micromamba"
export FSLOUTPUTTYPE='NIFTI_GZ'

eval "$(${MCRMMBA_EXE} shell hook --shell bash)"
micromamba activate HypoThal_QC

##############################
# Environment sanity checks  #
##############################
: "${PROJ_DIR:?PROJ_DIR is not set}"
: "${DATA_DIR:?DATA_DIR is not set}"
: "${LIST_DIR:?LIST_DIR is not set}"
: "${PROTO_DIR:?PROTO_DIR is not set}"
: "${SUBJECT_LIST:?SUBJECT_LIST is not set}"
: "${PET_TAG:?PET_TAG is not set}"

# Derived output root
OUT_ROOT="${PROTO_DIR}/PET_Preproc"
mkdir -p "${LIST_DIR}" "${PROTO_DIR}" "${OUT_ROOT}"

PET_FIXER="${PROJ_DIR}/Scripts/PET_reorient_validate.sh"

if [[ ! -x "${PET_FIXER}" ]]; then
  echo "[ERROR] Missing or non-executable: ${PET_FIXER}" >&2
  exit 1
fi

FAIL_LOG="${OUT_ROOT}/failed_subjects.csv"    # If any 3D PET (either static or mean-ed 4D) fails sanity check

# create header once
if [ ! -f "${FAIL_LOG}" ]; then
  echo "Site,Subject,Reason" >> "${FAIL_LOG}"
fi

# Basic tool checks (fail fast) ... since suprisingly enough, nodes aren't unanimous for PATHs
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1"; exit 1; }; }
need_cmd fslnvols
need_cmd fslmaths
need_cmd mcflirt

# CSV logs (append mode; headers created only if missing)
SELECTION_CSV="${LIST_DIR}/pet_preproc_selection.csv"
MISSING_CSV="${LIST_DIR}/pet_preproc_missing.csv"

if [ ! -f "${SELECTION_CSV}" ]; then
  echo "SITE,SUBJECT,INPUT_NII,MODE,NVOL,OUT_3D,OUT_4D,NOTE" > "${SELECTION_CSV}"
fi
if [ ! -f "${MISSING_CSV}" ]; then
  echo "SITE,SUBJECT,REASON" > "${MISSING_CSV}"
fi

echo "=== Step0: PET preprocessing (array task) ==="
echo "DATA_DIR : ${DATA_DIR}"
echo "PET_TAG  : ${PET_TAG}"
echo "OUT_ROOT : ${OUT_ROOT}"
echo "LIST_DIR : ${LIST_DIR}"
echo "SUBJECT_LIST: ${SUBJECT_LIST}"
echo "SLURM_ARRAY_TASK_ID: ${SLURM_ARRAY_TASK_ID:-not_set}"
echo "============================================="
echo

#########################################
# Helper: choose input PET NIfTI        #
#########################################
pick_input_pet() {
  local site="$1"
  local sub="$2"
  local sub_dir="${DATA_DIR}/${site}/${sub}"

  local candidates=( "${sub_dir}"/*.nii.gz )
  if [ ${#candidates[@]} -eq 0 ]; then
    return 1
  fi
  if [ ${#candidates[@]} -eq 1 ]; then
    echo "${candidates[0]}"
    return 0
  fi

  # Score-and-pick: prefer true 4D (dynamic), else best 3D (static).
  local best_f=""
  local best_score=-999999

  for f in "${candidates[@]}"; do
    local bn score nvol
    bn="$(basename "${f}")"
    score=0

    # 1) Hard excludes: clearly not the PET image we want (aggregated from actual list-parsing)
    #    (CT / topogram / scout / dose report / QClear / protocol exports / stats, etc.)
    if [[ "${bn}" =~ Topogram|TOPOGRAM|Scout|SCOUT|Dose|REPORT|QCLEAR|Protocol|PROTOCOL|Statistics|STATISTICS|ROI ]]; then
      continue
    fi
    # Exclude CT-only series (keep CTAC *if it’s part of a PET-labeled/dynamic series)
    if [[ "${bn}" =~ (^|_)CT($|_)|CT_Brain|CTAC|CT_SLICES|Head-Low_Dose_CT|AC_CT ]] && \
       ! [[ "${bn}" =~ PET|Dynamic|DYN|Amyloid|Florbetapir|AV45|\[DY_|\[BR_ ]]; then
      continue
    fi

    # 2) Prefer AC over NAC
    if [[ "${bn}" =~ NAC ]]; then
      score=$((score - 50))
    fi
    if [[ "${bn}" =~ (^|_)AC($|_)|_AC_|AC_ ]]; then
      score=$((score + 10))
    fi

    # 3) Prefer PET-ish labels (broad enough to cover peculiar sites)
    #    - Medstar: DYNAMIC_PET_AC / STATIC_PET_AC / PET_AC...
    #    - Jefferson: PET_Brain_AC_DYN / ...STATIC
    #    - Chicago: AC_PET_Dynamic / NAC_PET_Static ...
    #    - Colorado: [DY_CTAC_*]_Dynamic_Brain / [BR_CTAC_*]_Dynamic_Brain (no literal "PET")
    if [[ "${bn}" =~ PET|Amyloid|Florbetapir|AV45|Dynamic_Brain|\[DY_|\[BR_ ]]; then
      score=$((score + 10))
    fi
    # Extra bump for explicit tracer/task words common in your trees
    if [[ "${bn}" =~ Amyloid|Florbetapir|AV45 ]]; then
      score=$((score + 10))
    fi

    # 4) Dynamic preference:
    #    Use actual volumes as the primary truth, naming only as a secondary hint.
    nvol="$(fslnvols "${f}" 2>/dev/null || echo 1)"
    if [ "${nvol}" -gt 1 ]; then
      score=$((score + 1000))   # true dynamic wins
    fi
    if [[ "${bn}" =~ Dynamic|DYNAMIC|_DYN|DYN_ ]]; then
      score=$((score + 50))     # naming hint
    fi
    if [[ "${bn}" =~ Static|STATIC ]]; then
      score=$((score + 5))      # only a mild bump; static is fallback
    fi

    # 5) Optional: de-prefer "summed" derivatives if raw dynamic exists
    if [[ "${bn}" =~ SUMMED|Summed|Suv|SUV ]] && [ "${nvol}" -le 1 ]; then
      score=$((score - 5))
    fi

    if [ "${score}" -gt "${best_score}" ]; then
      best_score="${score}"
      best_f="${f}"
    fi
  done

  if [ -n "${best_f}" ]; then
    echo "${best_f}"
    return 0
  fi

  # Absolute last resort
  echo "${candidates[0]}"
  return 0
}

#########################################
# Helper: process_subject               #
#########################################
process_subject() {
    local site="$1"
    local sub="$2"
    local sub_dir="${DATA_DIR}/${site}/${sub}"

    if [ ! -d "${sub_dir}" ]; then
        echo "  [${site}/${sub}] Subject directory not found: ${sub_dir}"
        echo "${site},${sub},Subject directory not found" >> "${MISSING_CSV}"
        return
    fi

    echo "Processing SITE=${site}, SUB=${sub}..."

    local input_nii
    if ! input_nii="$(pick_input_pet "${site}" "${sub}")"; then
        echo "  -> No NIfTI found under ${sub_dir}"
        echo "${site},${sub},No NIfTI found" >> "${MISSING_CSV}"
        return
    fi

    if [ ! -f "${input_nii}" ]; then
        echo "  -> Input missing: ${input_nii}"
        echo "${site},${sub},Input missing" >> "${MISSING_CSV}"
        return
    fi

    # Determine dynamic vs static by actual volumes
    local nvol mode
    nvol="$(fslnvols "${input_nii}" 2>/dev/null || echo 1)"
    if [ "${nvol}" -gt 1 ]; then
        mode="dynamic"
    else
        mode="static"
    fi

    local out_dir="${OUT_ROOT}/${site}/${sub}"
    mkdir -p "${out_dir}"

    local out_3d="${out_dir}/${sub}_${PET_TAG}.nii.gz"
    local out_4d="${out_dir}/${sub}_PET_4D_mcf.nii.gz"

    # Idempotency: if final 3D exists, we consider done
    if [ -f "${out_3d}" ]; then
        echo "  -> ${out_3d} exists; skipping."
        echo "${site},${sub},${input_nii},${mode},${nvol},${out_3d},${out_4d},already_processed" >> "${SELECTION_CSV}"
        return
    fi

    if [ "${mode}" = "static" ]; then
        echo "  -> Static PET (3D). Reorient/validate -> downstream canonical ${PET_TAG}..."

        if ! "${PET_FIXER}" "${input_nii}" "${out_3d}"; then
            echo "  !! PET_FIXER failed for static ${site}/${sub}"
            echo "${site},${sub},FAILED_SANITY_STATIC" >> "${FAIL_LOG}"
            echo "${site},${sub},PET_FIXER_failed_static" >> "${MISSING_CSV}"
            return
        fi

        if [ ! -f "${out_3d}" ]; then
            echo "  !! Output missing after PET_FIXER: ${out_3d}"
            echo "${site},${sub},Output missing after PET_FIXER (static)" >> "${MISSING_CSV}"
            return
        fi

        echo "${site},${sub},${input_nii},${mode},${nvol},${out_3d},,OK_static_petfix" >> "${SELECTION_CSV}"
        echo "  -> Done."
        return
    fi

    echo "  -> Dynamic PET (4D, nvol=${nvol}). Running mcflirt + mean..."

    # mcflirt output root (without extension)
    local out_4d_root="${out_dir}/${sub}_PET_4D_mcf"
    # ${out_4d} consistent with this root already decalred. 

    # Motion correct
    # Note: -report can be noisy; keep as your preference
    if ! mcflirt -in "${input_nii}" -out "${out_4d_root}" -plots -report; then
        echo "  !! mcflirt failed for ${site}/${sub}"
        echo "${site},${sub},mcflirt_failed" >> "${MISSING_CSV}"
        return
    fi

    if [ ! -f "${out_4d}" ]; then
        echo "  !! mcflirt output missing: ${out_4d}"
        echo "${site},${sub},mcflirt_output_missing" >> "${MISSING_CSV}"
        return
    fi

    # Mean over time dimension to produce downstream canonical 3D
    if ! fslmaths "${out_4d}" -Tmean "${out_3d}"; then
        echo "  !! fslmaths -Tmean failed for ${site}/${sub}"
        echo "${site},${sub},Tmean_failed" >> "${MISSING_CSV}"
        return
    fi

    if [ ! -f "${out_3d}" ]; then
        echo "  !! Mean output missing: ${out_3d}"
        echo "${site},${sub},Mean_output_missing" >> "${MISSING_CSV}"
        return
    fi

    # Reorient/validate the final 3D mean in-place
    if ! "${PET_FIXER}" "${out_3d}" "${out_3d}"; then
        echo "  !! PET_FIXER failed for dynamic mean ${site}/${sub}"
        echo "${site},${sub},FAILED_SANITY_DYNAMIC" >> "${FAIL_LOG}"
        echo "${site},${sub},PET_FIXER_failed_dynamic" >> "${MISSING_CSV}"
        return
    fi

    # Optional motion plot
    # par_file="${out_4d_root}.par"
    # if [ -f "${par_file}" ]; then
    #   fsl_tsplot -i "${par_file}" \
    #     -t "MCFLIRT motion parameters: ${site}/${sub}" \
    #     -u 1 --start=1 -w 640 -h 144 \
    #     -o "${out_dir}/${sub}_4D_mcf_motion.png" || true
    # fi

    echo "${site},${sub},${input_nii},${mode},${nvol},${out_3d},${out_4d},OK_mcflirt_Tmean" >> "${SELECTION_CSV}"
    echo "  -> Done."
}

#########################################
# Array index -> subject mapping        #
#########################################
if [ -z "${SLURM_ARRAY_TASK_ID:-}" ]; then
  echo "ERROR: SLURM_ARRAY_TASK_ID is not set. Run via wrapper as an array job."
  exit 1
fi

if [ ! -f "${SUBJECT_LIST}" ]; then
  echo "ERROR: SUBJECT_LIST not found: ${SUBJECT_LIST}"
  exit 1
fi

idx="${SLURM_ARRAY_TASK_ID}"
line="$(sed -n "$((idx + 1))p" "${SUBJECT_LIST}" || true)"

if [ -z "${line}" ]; then
  echo "ERROR: No line found for index ${idx} in ${SUBJECT_LIST}"
  exit 1
fi

site="$(echo "${line}" | awk "{print \$1}")"
sub="$(echo "${line}" | awk "{print \$2}")"

process_subject "${site}" "${sub}"