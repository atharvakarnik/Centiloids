#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted from GAAIN's vld to DPPOS Dataset     #
# ------------------------------------------------- #
#
# Step1_PET2T1.sh
#
# SLURM array script: one subject (site, sub, subLong) per task.
#
# Input:
#   - PET Orig:  ${PROTO_DIR}/PET_Preproc/${site}/${sub}/${sub}_PET_5070.nii.gz
#   - T1 (LPS):  ${REORIENT_DIR}/${subLong}/${subLong}_T1_LPS.nii.gz
#
# Output (no site folder):
#   - ${PROTO_DIR}/Registration_PET_to_T1/${subLong}/${subLong}_PET_rT1.nii.gz
#   - ${PROTO_DIR}/Registration_PET_to_T1/${subLong}/${subLong}_PET2T1.mat
#
# Submit via wrapper:
#   bash Step1_wrapper_PET2T1.sh
#
#SBATCH --job-name=PET2T1
#SBATCH --output=Logs/2DPPOS_Feb26PET/PET2T1_%A_%a.log
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G

set -euo pipefail

: "${PROJ_DIR:?PROJ_DIR is not set}"
: "${PROTO_DIR:?PROTO_DIR is not set}"
: "${REORIENT_DIR:?REORIENT_DIR is not set}"
: "${LIST_DIR:?LIST_DIR is not set}"
: "${SUBJECT_LIST:?SUBJECT_LIST is not set}"
: "${S0B_CSV:?S0B_CSV is not set}"
: "${PET_TAG:?PET_TAG is not set}"

export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${SLURM_CPUS_PER_TASK:-1}"
export OMP_PROC_BIND=true
export OMP_PLACES=cores

REG_ROOT="${PROTO_DIR}/Registration_PET_to_T1"
mkdir -p "${REG_ROOT}" "${LIST_DIR}"

# Stage-1 registration logs
SELECTION_CSV="${LIST_DIR}/s1_pet2t1_registration.csv"
MISSING_CSV="${LIST_DIR}/s1_pet2t1_missing.csv"

if [ ! -f "${SELECTION_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,PET_OG,T1,NOTE" > "${SELECTION_CSV}"
fi

if [ ! -f "${MISSING_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,REASON" > "${MISSING_CSV}"
fi

echo "=== Step1: PET->T1 registration (array task) ==="
echo "PROJ_DIR           : ${PROJ_DIR}"
echo "PROTO_DIR          : ${PROTO_DIR}"
echo "REORIENT_DIR       : ${REORIENT_DIR}"
echo "REG_ROOT           : ${REG_ROOT}"
echo "SUBJECT_LIST (csv) : ${SUBJECT_LIST}"
echo "SLURM_ARRAY_TASK_ID: ${SLURM_ARRAY_TASK_ID:-not_set}"
echo "================================================"
echo

if [ -z "${SLURM_ARRAY_TASK_ID:-}" ]; then
    echo "ERROR: SLURM_ARRAY_TASK_ID is not set."
    exit 1
fi

if [ ! -f "${SUBJECT_LIST}" ]; then
    echo "ERROR: SUBJECT_LIST not found: ${SUBJECT_LIST}"
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

echo "Array task ${idx} -> SITE=${site}, SUB=${sub}, SUBLONG=${subLong}"

# pet_mean="${PROTO_DIR}/PET_Preproc/${site}/${sub}/${sub}_4D_mcf_mean.nii.gz" # PATCHED - No MoCorr in GAAIN
pet_og="${PROTO_DIR}/PET_Preproc/${site}/${sub}/${sub}_${PET_TAG}.nii.gz"
pet_flip="${PROTO_DIR}/PET_OrientGate/${subLong}/${subLong}_${PET_TAG}_flipY.nii.gz"

# Read flipY decision from Step0b output
flipY=$(awk -F',' -v s="${site}" -v u="${sub}" -v sl="${subLong}" '
  NR==1{next}
  $1==s && $2==u && $3==sl {print $6; exit}
' "${S0B_CSV}" 2>/dev/null || echo "")

# Default to unflipped if missing/NA
pet_in="${pet_og}"
pet_note="flipY=0_or_missing"

if [ "${flipY}" = "1" ]; then
  if [ -f "${pet_flip}" ]; then
    pet_in="${pet_flip}"
    pet_note="flipY=1_used_flipfile"
  else
    # fall back if flip file missing
    pet_note="flipY=1_but_flipfile_missing_used_orig"
  fi
fi
t1="${REORIENT_DIR}/${subLong}/${subLong}_T1_LPS.nii.gz"

if [ ! -f "${pet_og}" ]; then
    echo "  [${site}/${sub}/${subLong}] mean PET not found: ${pet_og}"
    echo "${site},${sub},${subLong},no_pet_og" >> "${MISSING_CSV}"
    exit 0
fi

if [ ! -f "${t1}" ]; then
    echo "  [${site}/${sub}/${subLong}] T1 not found: ${t1}"
    echo "${site},${sub},${subLong},no_T1_file" >> "${MISSING_CSV}"
    exit 0
fi

out_dir="${REG_ROOT}/${subLong}"
mkdir -p "${out_dir}"

out_pet_rT1="${out_dir}/${subLong}_PET_rT1.nii.gz"
out_mat="${out_dir}/${subLong}_PET2T1.mat"

if [ -f "${out_pet_rT1}" ]; then
    echo "  -> Registered PET already exists; skipping."
    echo "${site},${sub},${subLong},${pet_og},${t1},already_registered" >> "${SELECTION_CSV}"
    exit 0
fi

# Will try iteration with ANTs instead of FLIRT

# echo "  -> Running FLIRT (PET mean -> T1)..."
# flirt \
#     -in "${pet_in}" \
#     -ref "${t1}" \
#     -out "${out_pet_rT1}" \
#     -omat "${out_mat}" \
#     -dof 6 \
#     -cost normmi

# if [ ! -f "${out_pet_rT1}" ]; then
#     echo "  !! FLIRT output missing for ${site}/${sub}/${subLong}."
#     echo "${site},${sub},${subLong},registration_failed_no_output" >> "${MISSING_CSV}"
#     exit 1
# fi

echo "  -> Running ANTs rigid (PET -> T1)..."

prefix="${out_dir}/${subLong}_PET2T1_"

antsRegistration -d 3 \
  -o ["${prefix}","${prefix}Warped.nii.gz"] \
  --float 1 \
  --use-histogram-matching 0 \
  -r ["${t1}","${pet_in}",1] \
  -t Rigid[0.1] \
  -m MI["${t1}","${pet_in}",1,32,Regular,0.25] \
  -c [1000x500x250x100,1e-6,10] \
  -s 3x2x1x0vox \
  -f 8x4x2x1 \
  -u 1 -z 1

# Move ANTs outputs to expected filenames
mv -f "${prefix}Warped.nii.gz" "${out_pet_rT1}"
# mv -f "${prefix}0GenericAffine.mat" "${out_mat}"

# Optional: keep directory clean
rm -f "${prefix}"InverseWarped.nii.gz 2>/dev/null || true

echo "${site},${sub},${subLong},${pet_og},${t1},OK;${pet_note}" >> "${SELECTION_CSV}"
echo "  -> Registration complete."

echo
echo "Task ${idx} complete."