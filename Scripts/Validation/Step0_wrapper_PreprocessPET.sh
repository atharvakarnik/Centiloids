#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted to GAAIN's dataset for validation     #
# ------------------------------------------------- #
#
# Step0_wrapper_PreprocessPET.sh
#
# Wrapper script:
#   1) Defines common variables (not exported).
#   2) Builds subject list (SITE SUB).
#   3) Determines N for SLURM array.
#   4) Submits array job that runs Step0_PreprocessPET.sh,
#      passing variables explicitly via --export.
#
# Usage:
#   bash Step0_wrapper_PreprocessPET.sh

set -euo pipefail

##############################
# Project paths & setup      #
##############################

PROJ_DIR="${HOME}/Pipelines/Centiloids"

# IMPORTANT : Check this var meticulously to state correct cohort!!! 
PET_TAG="PET"
# ---------------------------------------------------------------- #

SCRIPTS_DIR="${PROJ_DIR}/Scripts/Validation"
LIST_DIR="${PROJ_DIR}/Lists/3Validation"
PROTO_DIR="${PROJ_DIR}/Protocols/3Validation"
DATA_DIR="${PROJ_DIR}/Data/Validation/fullPET_PET"

mkdir -p "${SCRIPTS_DIR}" "${LIST_DIR}" "${PROTO_DIR}"

# Subject list used by the array script
SUBJECT_LIST="${LIST_DIR}/pet_subjects.txt"

echo "=== Step0: Wrapper for PET preprocessing ==="
echo "PROJ_DIR    : ${PROJ_DIR}"
echo "SCRIPTS_DIR : ${SCRIPTS_DIR}"
echo "PET_TAG     : ${PET_TAG}"
echo "LIST_DIR    : ${LIST_DIR}"
echo "PROTO_DIR   : ${PROTO_DIR}"
echo "DATA_DIR    : ${DATA_DIR}"
echo "SUBJECT_LIST: ${SUBJECT_LIST}"
echo "============================================"
echo

# Sanity check: data dir must exist
if [ ! -d "${DATA_DIR}" ]; then
    echo "ERROR: DATA_DIR does not exist: ${DATA_DIR}"
    echo "Make sure ${PROJ_DIR}/Data/Nifti is a symlink to ${HOME}/Data/Nifti"
    exit 1
fi

##############################
# 1. Build subject list      #
##############################

echo "Building subject list..."

# Truncate any existing list
: > "${SUBJECT_LIST}"

shopt -s nullglob

for site_dir in "${DATA_DIR}"/*; do
    [ -d "${site_dir}" ] || continue
    site="$(basename "${site_dir}")"

    for sub_dir in "${site_dir}"/*; do
        [ -d "${sub_dir}" ] || continue
        sub="$(basename "${sub_dir}")"
        echo "${site} ${sub}" >> "${SUBJECT_LIST}"
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
    --export=PROJ_DIR="${PROJ_DIR}",DATA_DIR="${DATA_DIR}",LIST_DIR="${LIST_DIR}",PROTO_DIR="${PROTO_DIR}",SUBJECT_LIST="${SUBJECT_LIST}",PET_TAG="${PET_TAG}",FSLOUTPUTTYPE='NIFTI_GZ' \
    --array="${ARRAY_RANGE}" "${SCRIPTS_DIR}/Step0_PreprocessPET.sh"

echo "Submitted!"
