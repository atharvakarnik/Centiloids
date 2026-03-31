#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted from GAAIN's vld to DPPOS Dataset     #
# ------------------------------------------------- #
#
# Step2_wrapper_T1_to_MNI.sh
#
# Build subject list for T1->MNI registration and submit SLURM array.
# Usage:
#   bash Step2_wrapper_T1_to_MNI.sh

set -euo pipefail

PROJ_DIR="${HOME}/Pipelines/Centiloids"

LIST_DIR="${PROJ_DIR}/Lists/2DPPOS_Feb26PET"
PROTO_DIR="${PROJ_DIR}/Protocols/2DPPOS_Feb26PET"
REORIENT_DIR="${PROJ_DIR}/Data/ReOrientedLPS"
DLICV_DIR="${PROJ_DIR}/Data/DLICV"      # Optional masks (not used in worker unless you enable it)
ATLAS_DIR="${PROJ_DIR}/Data/Atlases"
SCRIPTS_DIR="${PROJ_DIR}/Scripts"

mkdir -p "${LIST_DIR}" "${PROTO_DIR}"

# MNI Template
# MNI_TEMPLATE="${ATLAS_DIR}/MNI152_T1_1mm.nii.gz"
MNI_TEMPLATE="${ATLAS_DIR}/avg152T1.nii.gz"

# ----------------------------
# Step2 Registration Mode
# ----------------------------
#   Syn     : Original antsRegistrationSyN.sh workflow
#   SPMlike : SPM-unified-like workflow using tissue priors (FSL priors) via Atropos + multi-channel ANTs reg
#
T1_MNI_MODE="SPMlike"
# T1_MNI_MODE="Syn"

# Stage-1 mapping list
S1_SELECTION="${LIST_DIR}/s1_pet2t1_selection_T1.csv"

# Stage-2 list files
SUBJECT_LIST="${LIST_DIR}/s2_t1mni_subjects.csv"
MISSING_T1_CSV="${LIST_DIR}/s2_t1mni_missing_T1.csv"
SELECTION_T1_CSV="${LIST_DIR}/s2_t1mni_selection_T1.csv"

echo "=== Step2: Wrapper for T1->MNI registration ==="
echo "PROJ_DIR       : ${PROJ_DIR}"
echo "REORIENT_DIR   : ${REORIENT_DIR}"
echo "DLICV_DIR      : ${DLICV_DIR}"
echo "ATLAS_DIR      : ${ATLAS_DIR}"
echo "MNI_TEMPLATE   : ${MNI_TEMPLATE}"
echo "T1_MNI_MODE    : ${T1_MNI_MODE}"
echo "LIST_DIR       : ${LIST_DIR}"
echo "S1_SELECTION   : ${S1_SELECTION}"
echo "SUBJECT_LIST   : ${SUBJECT_LIST}"
echo "==============================================="
echo

if [ ! -f "${MNI_TEMPLATE}" ]; then
    echo "ERROR: MNI template not found:"
    echo "  ${MNI_TEMPLATE}"
    exit 1
fi

if [ ! -f "${S1_SELECTION}" ]; then
    echo "ERROR: Step1 selection file not found:"
    echo "  ${S1_SELECTION}"
    echo "Run Step1 first."
    exit 1
fi

# Reset stage-2 files
rm -f "${SUBJECT_LIST}" "${MISSING_T1_CSV}" "${SELECTION_T1_CSV}"
touch "${SUBJECT_LIST}" "${MISSING_T1_CSV}" "${SELECTION_T1_CSV}"

echo "SITE,SUB,SUBLONG,REASON" > "${MISSING_T1_CSV}"
echo "SITE,SUB,SUBLONG,MASK_NOTE" > "${SELECTION_T1_CSV}"

# Parse Step1 selection list (CSV: site,sub,subLong,...)
# Keep only unique site/sub/subLong and check T1 exists.
tail -n +2 "${S1_SELECTION}" | awk -F',' '{print $1,$2,$3}' | sort -u | while read -r site sub subLong; do
    t1="${REORIENT_DIR}/${subLong}/${subLong}_T1_LPS.nii.gz"
    if [ ! -f "${t1}" ]; then
        echo "  !! Missing T1 for ${subLong}"
        echo "${site},${sub},${subLong},no_T1_file" >> "${MISSING_T1_CSV}"
        continue
    fi

    mask="${DLICV_DIR}/${subLong}/${subLong}_T1_LPS_dlicvmask.nii.gz"
    mask_note="no_mask"
    if [ -f "${mask}" ]; then
        mask_note="mask_available"
    fi

    echo "  [${site}/${sub}] -> ${subLong} (T1 OK, ${mask_note})"

    # Space-separated fields in subject list for array mapping
    echo "${site} ${sub} ${subLong}" >> "${SUBJECT_LIST}"
    echo "${site},${sub},${subLong},${mask_note}" >> "${SELECTION_T1_CSV}"
done

n=$(wc -l < "${SUBJECT_LIST}" | tr -d ' ')

if [ "${n}" -eq 0 ]; then
    echo "No valid subjects for T1->MNI registration. Exiting."
    exit 0
fi

echo
echo "Stage-2 subject list created with ${n} entries:"
echo "  -> ${SUBJECT_LIST}"
echo

ARRAY_RANGE="0-$((n - 1))"

echo "Submitting SLURM array job for ${ARRAY_RANGE}..."

sbatch \
  --export=PROJ_DIR="${PROJ_DIR}",PROTO_DIR="${PROTO_DIR}",REORIENT_DIR="${REORIENT_DIR}",DLICV_DIR="${DLICV_DIR}",ATLAS_DIR="${ATLAS_DIR}",LIST_DIR="${LIST_DIR}",SUBJECT_LIST="${SUBJECT_LIST}",MNI_TEMPLATE="${MNI_TEMPLATE}",FSLOUTPUTTYPE='NIFTI_GZ',T1_MNI_MODE="${T1_MNI_MODE}" \
  --array="${ARRAY_RANGE}" "${SCRIPTS_DIR}/Step2_T1_to_MNI.sh"

echo "Submitted!"