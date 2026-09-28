#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted from GAAIN's vld to DPPOS Dataset     #
# ------------------------------------------------- #
#
# Step3_wrapper_PET_to_MNI.sh
#
# Build subject list for one-shot native PET -> PET(MNI) resampling & smoothing,
# then submit SLURM array.
#
# Usage:
#   bash Step3_wrapper_PET_to_MNI.sh

set -euo pipefail

# IMPORTANT : Check this var meticulously to state correct cohort!!!
PET_TAG="PET_3D"
# ---------------------------------------------------------------- #

PROJ_DIR="${HOME}/Pipelines/Centiloids"

LIST_DIR="${PROJ_DIR}/Lists/Jun26"
PROTO_DIR="${PROJ_DIR}/Protocols/Jun26"
REG_PET_T1_DIR="${PROTO_DIR}/Registration_PET_to_T1"
REG_T1_MNI_DIR="${PROTO_DIR}/Registration_T1_to_MNI"
PREPROC_PET_ROOT="${PROTO_DIR}/PET_Preproc"
ATLAS_DIR="${PROJ_DIR}/Data/Atlases"
SCRIPTS_DIR="${PROJ_DIR}/Scripts"

mkdir -p "${LIST_DIR}" "${PROTO_DIR}"

# MNI_TEMPLATE="${ATLAS_DIR}/MNI152_T1_1mm.nii.gz"      # Need to use SPM-provided 2mm template for GAAIN-validation
MNI_TEMPLATE="${ATLAS_DIR}/MNI152_T1_2mm.nii.gz"        # Replaced avg152T1

# Stage 2 registration log (used as source for subjects)
S2_REG_CSV="${LIST_DIR}/s2_t1mni_registration.csv"

# Stage 3 list/log files (s3_ prefix)
SUBJECT_LIST="${LIST_DIR}/s3_petmni_subjects.csv"
MISSING_CSV="${LIST_DIR}/s3_petmni_missing.csv"
SELECTION_CSV="${LIST_DIR}/s3_petmni_registration.csv"

SMOOTH_FWHM_MM="0"      # Smoothing switch (in mm, 0 is None)

echo "=== Step3: Wrapper for native PET->PET(MNI) ==="
echo "PROJ_DIR         : ${PROJ_DIR}"
echo "PROTO_DIR        : ${PROTO_DIR}"
echo "PET_TAG          : ${PET_TAG}"
echo "PREPROC_PET_ROOT : ${PREPROC_PET_ROOT}"
echo "REG_PET_T1_DIR   : ${REG_PET_T1_DIR}"
echo "REG_T1_MNI_DIR   : ${REG_T1_MNI_DIR}"
echo "ATLAS_DIR        : ${ATLAS_DIR}"
echo "MNI_TEMPLATE     : ${MNI_TEMPLATE}"
echo "S2_REG_CSV       : ${S2_REG_CSV}"
echo "SUBJECT_LIST     : ${SUBJECT_LIST}"
echo "==========================================="
echo

if [ ! -f "${MNI_TEMPLATE}" ]; then
    echo "ERROR: MNI template not found:"
    echo "  ${MNI_TEMPLATE}"
    exit 1
fi

if [ ! -f "${S2_REG_CSV}" ]; then
    echo "ERROR: Stage-2 registration CSV not found:"
    echo "  ${S2_REG_CSV}"
    exit 1
fi

# Truncate subject list
: > "${SUBJECT_LIST}"

# CSV logs (append, but create header if missing)
if [ ! -f "${MISSING_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,REASON" > "${MISSING_CSV}"
fi

if [ ! -f "${SELECTION_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,PET_OG,WARP,AFFINE,PET_rMNI,PET_rMNI_s8,NOTE" > "${SELECTION_CSV}"
fi

echo "Building Stage-3 subject list from ${S2_REG_CSV}..."

# S2_REG_CSV format:
# SITE,SUB,SUBLONG,T1,MNI_TEMPLATE,MASK_USED,NOTE
tail -n +2 "${S2_REG_CSV}" | while IFS=',' read -r site sub subLong t1_path mni_tmpl mask_used note; do
    [ -n "${site}" ] || continue
    [ -n "${sub}" ] || continue
    [ -n "${subLong}" ] || continue

    # Only proceed for successful or pre-existing T1->MNI regs
    case "${note}" in
        OK|already_registered|ok_Syn|ok_SPMlike) ;;
        *) 
            echo "  [${site}/${sub}/${subLong}] Stage-2 NOTE='${note}', skipping for Stage 3."
            continue
            ;;
    esac

    pet_og="${PREPROC_PET_ROOT}/${site}/${sub}/${sub}_${PET_TAG}.nii.gz"
    pet2t1="${REG_PET_T1_DIR}/${subLong}/${subLong}_PET2T1.mat"
    warp_dir="${REG_T1_MNI_DIR}/${subLong}"
    warp="${warp_dir}/${subLong}_T1_rMNI_1Warp.nii.gz"
    affine="${warp_dir}/${subLong}_T1_rMNI_0GenericAffine.mat"

    if [ ! -f "${pet_og}" ]; then
        echo "  [${site}/${sub}/${subLong}] Canonical Step-0 PET missing: ${pet_og}"
        echo "${site},${sub},${subLong},no_PET_OG" >> "${MISSING_CSV}"
        continue
    fi

    if [ ! -f "${pet2t1}" ]; then
        echo "  [${site}/${sub}/${subLong}] PET->T1 rigid transform missing: ${pet2t1}"
        echo "${site},${sub},${subLong},no_PET2T1_transform" >> "${MISSING_CSV}"
        continue
    fi

    if [ ! -f "${warp}" ] || [ ! -f "${affine}" ]; then
        echo "  [${site}/${sub}/${subLong}] Missing T1->MNI transforms."
        echo "${site},${sub},${subLong},missing_transforms" >> "${MISSING_CSV}"
        continue
    fi

    echo "  [${site}/${sub}] -> ${subLong} (native PET & transforms OK)"
    # Space-separated fields in CSV for array mapping
    echo "${site} ${sub} ${subLong}" >> "${SUBJECT_LIST}"
done

n=$(wc -l < "${SUBJECT_LIST}")

if [ "${n}" -eq 0 ]; then
    echo "No valid subjects for PET(T1)->PET(MNI). Exiting."
    exit 0
fi

echo
echo "Stage-3 subject list created with ${n} entries:"
echo "  -> ${SUBJECT_LIST}"
echo

ARRAY_RANGE="0-$((n - 1))"

echo "Submitting SLURM array job for ${ARRAY_RANGE}..."

sbatch \
    --export=PROJ_DIR="${PROJ_DIR}",PROTO_DIR="${PROTO_DIR}",LIST_DIR="${LIST_DIR}",MNI_TEMPLATE="${MNI_TEMPLATE}",SUBJECT_LIST="${SUBJECT_LIST}",PET_TAG="${PET_TAG}",SMOOTH_FWHM_MM="${SMOOTH_FWHM_MM}",FSLOUTPUTTYPE='NIFTI_GZ' \
    --array="${ARRAY_RANGE}" "${SCRIPTS_DIR}/Step3_PET_to_MNI.sh"

echo "Submitted!"
