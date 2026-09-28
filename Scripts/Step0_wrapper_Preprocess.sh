#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted from GAAIN's vld to DPPOS Dataset     #
# ------------------------------------------------- #
#
# Step0_wrapper_Preprocess.sh
#
# Wrapper script:
#   1) Defines common variables (not exported).
#   2) Builds subject list (SITE SUB SUBLONG).
#   3) Determines N for SLURM array.
#   4) Submits array job that runs Step0_Preprocess.sh,
#      passing variables explicitly via --export.
#
# Usage:
#   bash Step0_wrapper_Preprocess.sh

set -euo pipefail

##############################
# Project paths & setup      #
##############################

PROJ_DIR="${HOME}/Pipelines/Centiloids"

# IMPORTANT : Check this var meticulously to state correct cohort!!! 
PET_TAG="PET_3D"
# ---------------------------------------------------------------- #

SCRIPTS_DIR="${PROJ_DIR}/Scripts"
LIST_DIR="${PROJ_DIR}/Lists/Jun26"
PROTO_DIR="${PROJ_DIR}/Protocols/Jun26"
DATA_DIR="${PROJ_DIR}/Data/Nifti/Jun26PET_PET"
REORIENT_DIR="${PROJ_DIR}/Data/ReOrientedLPS"
DLICV_DIR="${PROJ_DIR}/Data/DLICV"

mkdir -p "${SCRIPTS_DIR}" "${LIST_DIR}" "${PROTO_DIR}"

# Subject list used by the array script
SUBJECT_LIST="${LIST_DIR}/pet_subjects.txt"
MISSING_CSV="${LIST_DIR}/pet_preproc_missing.csv"

echo "=== Step0: Wrapper for PET and T1 preprocessing ==="
echo "PROJ_DIR    : ${PROJ_DIR}"
echo "SCRIPTS_DIR : ${SCRIPTS_DIR}"
echo "PET_TAG     : ${PET_TAG}"
echo "LIST_DIR    : ${LIST_DIR}"
echo "PROTO_DIR   : ${PROTO_DIR}"
echo "DATA_DIR    : ${DATA_DIR}"
echo "REORIENT_DIR: ${REORIENT_DIR}"
echo "DLICV_DIR   : ${DLICV_DIR}"
echo "SUBJECT_LIST: ${SUBJECT_LIST}"
echo "============================================"
echo

# Sanity check: data dir must exist
if [ ! -d "${DATA_DIR}" ]; then
    echo "ERROR: DATA_DIR does not exist: ${DATA_DIR}"
    echo "Make sure ${PROJ_DIR}/Data/Nifti is a symlink to ${HOME}/Data/Nifti"
    exit 1
fi

if [ ! -d "${REORIENT_DIR}" ]; then
    echo "ERROR: REORIENT_DIR does not exist: ${REORIENT_DIR}"
    exit 1
fi

if [ ! -d "${DLICV_DIR}" ]; then
    echo "ERROR: DLICV_DIR does not exist: ${DLICV_DIR}"
    exit 1
fi

##############################
# 1. Build subject list      #
##############################

echo "Building subject list..."

# Truncate any existing list
: > "${SUBJECT_LIST}"

if [ ! -f "${MISSING_CSV}" ]; then
    echo "SITE,SUBJECT,REASON" > "${MISSING_CSV}"
fi

shopt -s nullglob

for site_dir in "${DATA_DIR}"/*; do
    [ -d "${site_dir}" ] || continue
    site="$(basename "${site_dir}")"

    for sub_dir in "${site_dir}"/*; do
        [ -d "${sub_dir}" ] || continue
        sub="$(basename "${sub_dir}")"

        dirs=( "${REORIENT_DIR}/${sub}"*/ )
        if ((${#dirs[@]} == 0)); then
            echo "  [${site}/${sub}] No matching ReOrientedLPS directory found."
            echo "${site},${sub},no_T1_dir_found" >> "${MISSING_CSV}"
            continue
        fi

        # Preserve the production mapping behavior used by the later wrappers.
        subLong="$(basename "${dirs[0]}")"
        echo "${site} ${sub} ${subLong}" >> "${SUBJECT_LIST}"
    done
done

n=$(wc -l < "${SUBJECT_LIST}")

if [ "${n}" -eq 0 ]; then
    echo "ERROR: No subjects found under ${DATA_DIR}."
    echo "Check your directory structure."
    exit 1
fi

echo "Subject list created with ${n} entries."
echo "  -> ${SUBJECT_LIST}"
echo

##############################
# 2. Submit SLURM array      #
##############################

ARRAY_RANGE="0-$((n - 1))"

echo "Submitting SLURM array job for ${ARRAY_RANGE} subs"

# Pass all required variables explicitly via --export
sbatch \
    --export=PROJ_DIR="${PROJ_DIR}",DATA_DIR="${DATA_DIR}",REORIENT_DIR="${REORIENT_DIR}",DLICV_DIR="${DLICV_DIR}",LIST_DIR="${LIST_DIR}",PROTO_DIR="${PROTO_DIR}",SUBJECT_LIST="${SUBJECT_LIST}",PET_TAG="${PET_TAG}",FSLOUTPUTTYPE='NIFTI_GZ',HOME="${HOME}",FSLDIR="${FSLDIR}" \
    --array="${ARRAY_RANGE}" "${SCRIPTS_DIR}/Step0_Preprocess.sh"

echo "Submitted!"
