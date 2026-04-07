#!/bin/sh
#
# ------------------------------------------------- #
#     Adapted to GAAIN's dataset for validation     #
# ------------------------------------------------- #
#
# Step3_PET_to_MNI.sh (Validation-friendly)
# PET(T1) -> PET(MNI/template grid), optional smoothing.
#
# Exports expected:
#   PROJ_DIR, PROTO_DIR, LIST_DIR, SUBJECT_LIST, MNI_TEMPLATE
#   SMOOTH_FWHM_MM (e.g., "0" for validation, "8" for cohort)
#
#SBATCH --partition=all
#SBATCH --propagate=NONE
#SBATCH --job-name=PET_MNI
#SBATCH --output=Logs/3FB_Val_FBP/PET_MNI_%A_%a.log
#SBATCH --time=00:45:00
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=2G

set -euo pipefail

# ---- required env ----
: "${PROJ_DIR:?PROJ_DIR is not set}"
: "${PROTO_DIR:?PROTO_DIR is not set}"
: "${LIST_DIR:?LIST_DIR is not set}"
: "${SUBJECT_LIST:?SUBJECT_LIST is not set}"
: "${MNI_TEMPLATE:?MNI_TEMPLATE is not set}"
: "${SMOOTH_FWHM_MM:=0}"   # default: no smoothing unless wrapper sets it

module load ants/2.3.1 >/dev/null 2>&1 || true

REG_PET_T1_DIR="${PROTO_DIR}/Registration_PET_to_T1"
REG_T1_MNI_DIR="${PROTO_DIR}/Registration_T1_to_MNI"
REG_PET_MNI_DIR="${PROTO_DIR}/Registration_PET_to_MNI"
mkdir -p "${REG_PET_MNI_DIR}" "${LIST_DIR}"

# logs
SELECTION_CSV="${LIST_DIR}/s3_petmni_registration.csv"
MISSING_CSV="${LIST_DIR}/s3_petmni_missing.csv"

if [ ! -f "${SELECTION_CSV}" ]; then
  echo "SITE,SUB,SUBLONG,PET_rT1,WARP,AFFINE,PET_rMNI,PET_rMNI_s8,NOTE" > "${SELECTION_CSV}"
fi
if [ ! -f "${MISSING_CSV}" ]; then
  echo "SITE,SUB,SUBLONG,REASON" > "${MISSING_CSV}"
fi

# array sanity
if [ -z "${SLURM_ARRAY_TASK_ID:-}" ]; then
  echo "ERROR: SLURM_ARRAY_TASK_ID is not set."
  exit 1
fi

idx="${SLURM_ARRAY_TASK_ID}"
line=$(sed -n "$((idx + 1))p" "${SUBJECT_LIST}" || true)
if [ -z "${line}" ]; then
  echo "No subject found for SLURM_ARRAY_TASK_ID=${idx}."
  exit 0
fi

site=$(echo "${line}" | awk '{print $1}')
sub=$(echo  "${line}" | awk '{print $2}')
subLong=$(echo "${line}" | awk '{print $3}')

pet_rT1="${REG_PET_T1_DIR}/${subLong}/${subLong}_PET_rT1.nii.gz"
warp="${REG_T1_MNI_DIR}/${subLong}/${subLong}_T1_rMNI_1Warp.nii.gz"
affine="${REG_T1_MNI_DIR}/${subLong}/${subLong}_T1_rMNI_0GenericAffine.mat"

echo "=== Step3 (task ${idx}) ==="
echo "subLong        : ${subLong}"
echo "MNI_TEMPLATE   : ${MNI_TEMPLATE}"
echo "SMOOTH_FWHM_MM : ${SMOOTH_FWHM_MM}"
echo "PET_rT1        : ${pet_rT1}"
echo "warp/affine    : ${warp} | ${affine}"
echo

if [ ! -f "${pet_rT1}" ]; then
  echo "${site},${sub},${subLong},no_PET_rT1" >> "${MISSING_CSV}"
  exit 0
fi
if [ ! -f "${warp}" ] || [ ! -f "${affine}" ]; then
  echo "${site},${sub},${subLong},missing_transforms" >> "${MISSING_CSV}"
  exit 0
fi
if [ ! -f "${MNI_TEMPLATE}" ]; then
  echo "${site},${sub},${subLong},missing_MNI_template" >> "${MISSING_CSV}"
  exit 1
fi

out_dir="${REG_PET_MNI_DIR}/${subLong}"
mkdir -p "${out_dir}"

out_pet_mni="${out_dir}/${subLong}_PET_rMNI.nii.gz"
out_pet_mni_s8="${out_dir}/${subLong}_PET_rMNI_s8.nii.gz"

# If the required outputs already exist, skip
if [ "${SMOOTH_FWHM_MM}" = "0" ]; then
  if [ -f "${out_pet_mni}" ]; then
    echo "${site},${sub},${subLong},${pet_rT1},${warp},${affine},${out_pet_mni},,already_done_no_smooth" >> "${SELECTION_CSV}"
    exit 0
  fi
else
  if [ -f "${out_pet_mni_s8}" ]; then
    echo "${site},${sub},${subLong},${pet_rT1},${warp},${affine},${out_pet_mni},${out_pet_mni_s8},already_done_smoothed" >> "${SELECTION_CSV}"
    exit 0
  fi
fi

# threads
threads="${SLURM_CPUS_PER_TASK:-1}"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${threads}"
export OMP_NUM_THREADS="${threads}"

echo "Applying transforms with antsApplyTransforms (threads=${threads})..."
antsApplyTransforms -d 3 -i "${pet_rT1}" -r "${MNI_TEMPLATE}" -t "${warp}" -t "${affine}" -o "${out_pet_mni}"

if [ ! -f "${out_pet_mni}" ]; then
  echo "${site},${sub},${subLong},ants_missing_pet_mni" >> "${MISSING_CSV}"
  exit 1
fi

# Optional smoothing
if [ "${SMOOTH_FWHM_MM}" = "0" ]; then
  echo "${site},${sub},${subLong},${pet_rT1},${warp},${affine},${out_pet_mni},,OK_no_smoothing" >> "${SELECTION_CSV}"
  exit 0
fi

# sigma (vox) = (FWHM_mm / 2.355) / voxsize_mm
voxsize_mm=$(fslval "${out_pet_mni}" pixdim1)
sigma_vox=$(python - <<PY
fwhm=float("${SMOOTH_FWHM_MM}")
vox=float("${voxsize_mm}")
print((fwhm/2.355)/vox)
PY
)

echo "Smoothing with FWHM=${SMOOTH_FWHM_MM}mm -> sigma=${sigma_vox} vox (vox=${voxsize_mm}mm)..."
fslmaths "${out_pet_mni}" -s "${sigma_vox}" "${out_pet_mni_s8}"

if [ ! -f "${out_pet_mni_s8}" ]; then
  echo "${site},${sub},${subLong},smoothing_failed" >> "${MISSING_CSV}"
  exit 1
fi

echo "${site},${sub},${subLong},${pet_rT1},${warp},${affine},${out_pet_mni},${out_pet_mni_s8},OK_smoothed" >> "${SELECTION_CSV}"

echo
echo "Task ${idx} complete."