#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted to GAAIN's dataset for validation     #
# ------------------------------------------------- #
#
# Step0_PreprocessPET.sh
# SLURM array script: one subject per task.
#
# Supports both:
#  - Static PET (3D)  -> copy only to ${SUB}_PET_5070.nii.gz
#  - Dynamic PET (4D) -> mcflirt -> mean -> ${SUB}_PET_5070.nii.gz
#
# Expected new input layout (FBP calibration aggregation output):
#   ${DATA_DIR}/${SITE}/${SUB}/${SUB}_${SITE}.nii.gz
#
# Outputs:
#   ${PROTO_DIR}/PET_Preproc/${SITE}/${SUB}/${SUB}_PET_5070.nii.gz     (3D, downstream canonical)
#   ${PROTO_DIR}/PET_Preproc/${SITE}/${SUB}/${SUB}_4D_mcf.nii.gz       (4D, only for dynamic)
#
# Logs:
#   ${LIST_DIR}/pet_preproc_selection.csv
#   ${LIST_DIR}/pet_preproc_missing.csv

#SBATCH --propagate=NONE
#SBATCH --job-name=PET_Preproc
#SBATCH --output=Logs/2Validation/PET_Preproc_%A_%a.log
#SBATCH --time=00:10:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G

set -euo pipefail
shopt -s nullglob

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

# Basic tool checks (fail fast) ... since suprisingly enough, nodes aren't unanimous for PATH!S
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

  #  Preferred - Kept for DPPOS/any other cohorts with specific names, irrelevant for GAAIN, so commenting out
  #  local preferred="${sub_dir}/${sub}_${site}.nii.gz"
  #  if [ -f "${preferred}" ]; then
  #    echo "${preferred}"
  #    return 0
  #  fi

  # Fallback: if for some reason there are multiple nii.gz,
  # try to pick something plausible but keep it conservative.
  local candidates=( "${sub_dir}"/*.nii.gz )
  if [ ${#candidates[@]} -eq 0 ]; then
    return 1
  fi

  # If exactly one, use it.
  if [ ${#candidates[@]} -eq 1 ]; then
    echo "${candidates[0]}"
    return 0
  fi

  # Otherwise, prefer files containing PET/Brain/Amyloid/Florbetapir/AV45 and not NAC.
  for f in "${candidates[@]}"; do
    bn="$(basename "${f}")"
    if [[ "${bn}" =~ NAC ]]; then
      continue
    fi
    if [[ "${bn}" =~ PET ]] || [[ "${bn}" =~ Brain ]] || [[ "${bn}" =~ BRAIN ]] || \
       [[ "${bn}" =~ Florbetapir ]] || [[ "${bn}" =~ FLORBETAPIR ]] || \
       [[ "${bn}" =~ AV45 ]] || [[ "${bn}" =~ Amyloid ]]; then
      echo "${f}"
      return 0
    fi
  done

  # Last resort: first candidate :(
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
    local out_4d="${out_dir}/${sub}_${PET_TAG}_4D_mcf.nii.gz"

    # Idempotency: if final 3D exists, we consider done
    if [ -f "${out_3d}" ]; then
        echo "  -> ${out_3d} exists; skipping."
        echo "${site},${sub},${input_nii},${mode},${nvol},${out_3d},${out_4d},already_processed" >> "${SELECTION_CSV}"
        return
    fi

    if [ "${mode}" = "static" ]; then
        echo "  -> Static PET (3D). Copying as downstream canonical ${PET_TAG}..."
        cp -f "${input_nii}" "${out_3d}"

        if [ ! -f "${out_3d}" ]; then
            echo "  !! Copy failed for ${site}/${sub}"
            echo "${site},${sub},Copy failed" >> "${MISSING_CSV}"
            return
        fi

        echo "${site},${sub},${input_nii},${mode},${nvol},${out_3d},,OK_rawcopy" >> "${SELECTION_CSV}"
        echo "  -> Done."
        return
    fi

    echo "  -> Dynamic PET (4D, nvol=${nvol}). Running mcflirt + mean..."

    # mcflirt output root (without extension)
    local mc_root="${out_dir}/${sub}_4D_mcf"
    local mc_nii="${mc_root}.nii.gz"

    # Motion correct
    # Note: -report can be noisy; keep as your preference
    if ! mcflirt -in "${input_nii}" -out "${mc_root}" -plots -report; then
        echo "  !! mcflirt failed for ${site}/${sub}"
        echo "${site},${sub},mcflirt_failed" >> "${MISSING_CSV}"
        return
    fi

    if [ ! -f "${mc_nii}" ]; then
        echo "  !! mcflirt output missing: ${mc_nii}"
        echo "${site},${sub},mcflirt_output_missing" >> "${MISSING_CSV}"
        return
    fi

    mv -f "${mc_nii}" "${out_4d}"

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

    # Optional motion plot
    # par_file="${mc_root}.par"
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