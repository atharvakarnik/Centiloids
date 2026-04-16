#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted to GAAIN's dataset for validation     #
# ------------------------------------------------- #
#
# Step2_wrapper_T1_to_MNI.sh
#
# Build subject list for T1->MNI registration and submit SLURM array.
# Usage:
#   bash Step2_wrapper_T1_to_MNI.sh

set -euo pipefail

PROJ_DIR="${HOME}/Pipelines/Centiloids"

LIST_DIR="${PROJ_DIR}/Lists/4FB_Val_FBP"
PROTO_DIR="${PROJ_DIR}/Protocols/4FB_Val_FBP"
REORIENT_DIR="${PROJ_DIR}/Data/Validation_FBP/ReOrientedLPS"
DLICV_DIR="${PROJ_DIR}/Data/DLICV"      # No mask used for validation datatset, though it's safe to keep as-is here
ATLAS_DIR="${PROJ_DIR}/Data/Atlases"
SCRIPTS_DIR="${PROJ_DIR}/Scripts/Validation"

mkdir -p "${LIST_DIR}" "${PROTO_DIR}"

# MNI Template
# MNI_TEMPLATE="${ATLAS_DIR}/MNI152_T1_1mm.nii.gz"      # Good choice overall, but have to use SPM-provided for GAAIN-validation
MNI_TEMPLATE="${ATLAS_DIR}/MNI152_T1_2mm.nii.gz"        # Replaced avg152T1 for Git Issue #1


# ----------------------------
# Step2 Registration Mode
# ----------------------------
#   Syn     : Original antsRegistrationSyN.sh workflow
#   SPMlike : SPM-unified-like workflow using tissue priors (FSL priors) via Atropos + multi-channel ANTs reg
#
# Manually set before running Step2:
# T1_MNI_MODE="Syn"
T1_MNI_MODE="SPMlike"

# Stage-1 mapping list
S1_SELECTION="${LIST_DIR}/s1_pet2t1_selection_T1.csv"

# Stage-2 list files (CSV with s2_ prefix)
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
    echo "Please copy a T1-weighted MNI152NLin6 template here, e.g.:"
    echo "  cp \$FSLDIR/data/standard/MNI152_T1_1mm.nii.gz ${MNI_TEMPLATE}"
    exit 1
fi

if [ ! -f "${S1_SELECTION}" ]; then
    echo "ERROR: Stage-1 selection file not found:"
    echo "  ${S1_SELECTION}"
    exit 1
fi

# Truncate subject list
: > "${SUBJECT_LIST}"

# CSV logs (append, but create header if missing)
if [ ! -f "${MISSING_T1_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,REASON" > "${MISSING_T1_CSV}"
fi

if [ ! -f "${SELECTION_T1_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,MASK_NOTE" > "${SELECTION_T1_CSV}"
fi

echo "Building Stage-2 subject list from ${S1_SELECTION}..."

# Skip header, read CSV lines
tail -n +2 "${S1_SELECTION}" | while IFS=',' read -r site sub subLong note; do
    [ -n "${site}" ] || continue
    [ -n "${sub}" ] || continue
    [ -n "${subLong}" ] || continue

    t1="${REORIENT_DIR}/${subLong}/${subLong}_T1_LPS.nii.gz"

    if [ ! -f "${t1}" ]; then
        echo "  [${site}/${sub}/${subLong}] T1 not found: ${t1}"
        echo "${site},${sub},${subLong},no_T1_file" >> "${MISSING_T1_CSV}"
        continue
    fi

    mask="${DLICV_DIR}/${subLong}/${subLong}_T1_LPS_dlicvmask.nii.gz"
    mask_note="no_mask"
    if [ -f "${mask}" ]; then
        mask_note="mask_available"
    fi

    echo "  [${site}/${sub}] -> ${subLong} (T1 OK, ${mask_note})"

    # Space-separated fields in CSV file for array mapping
    echo "${site} ${sub} ${subLong}" >> "${SUBJECT_LIST}"
    echo "${site},${sub},${subLong},${mask_note}" >> "${SELECTION_T1_CSV}"
done

################ VERY TEMPORARY OVERRIDE !! ################
# SUBJECT_LIST="${LIST_DIR}/s2_t1mni_subjects_onlyAD32.csv" ##
############################################################

n=$(wc -l < "${SUBJECT_LIST}")

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
    --export=PROJ_DIR="${PROJ_DIR}",PROTO_DIR="${PROTO_DIR}",REORIENT_DIR="${REORIENT_DIR}",DLICV_DIR="${DLICV_DIR}",ATLAS_DIR="${ATLAS_DIR}",LIST_DIR="${LIST_DIR}",PATH="${PATH}",SUBJECT_LIST="${SUBJECT_LIST}",MNI_TEMPLATE="${MNI_TEMPLATE}",FSLOUTPUTTYPE='NIFTI_GZ',T1_MNI_MODE="${T1_MNI_MODE}" \
    --array="${ARRAY_RANGE}" "${SCRIPTS_DIR}/Step2_T1_to_MNI.sh"

echo "Submitted!"