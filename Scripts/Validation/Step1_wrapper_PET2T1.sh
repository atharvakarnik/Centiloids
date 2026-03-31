#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted to GAAIN's dataset for validation     #
# ------------------------------------------------- #
#
# Step1_wrapper_PET2T1.sh
#
# Build subject list for PET->T1 registration and submit SLURM array.
# Usage:
#   bash Step1_wrapper_PET2T1.sh

set -euo pipefail

# IMPORTANT : Check this var meticulously to state correct cohort!!! 
PET_TAG="PET_PiB"
# ---------------------------------------------------------------- #

PROJ_DIR="${HOME}/Pipelines/Centiloids"

LIST_DIR="${PROJ_DIR}/Lists/2Validation"
PROTO_DIR="${PROJ_DIR}/Protocols/2Validation"
PREPROC_PET_ROOT="${PROTO_DIR}/PET_Preproc"
REORIENT_DIR="${PROJ_DIR}/Data/Validation/ReOrientedLPS"
SCRIPTS_DIR="${PROJ_DIR}/Scripts/Validation"

mkdir -p "${LIST_DIR}" "${PROTO_DIR}"

# Step 0b Reorient Flags
S0B_CSV="${LIST_DIR}/s0b_orient_flip_flags.csv"

# Stage-1 list files (CSV with s1_ prefix)
SUBJECT_LIST="${LIST_DIR}/s1_pet2t1_subjects.csv"
MISSING_T1_CSV="${LIST_DIR}/s1_pet2t1_missing_T1.csv"
SELECTION_CSV="${LIST_DIR}/s1_pet2t1_selection_T1.csv"

echo "=== Step1: Wrapper for PET->T1 registration ==="
echo "PROJ_DIR       : ${PROJ_DIR}"
echo "PREPROC_PET    : ${PREPROC_PET_ROOT}"
echo "REORIENT_DIR   : ${REORIENT_DIR}"
echo "LIST_DIR       : ${LIST_DIR}"
echo "SUBJECT_LIST   : ${SUBJECT_LIST}"
echo "==============================================="
echo

if [ ! -d "${PREPROC_PET_ROOT}" ]; then
    echo "ERROR: PREPROC_PET_ROOT does not exist: ${PREPROC_PET_ROOT}"
    exit 1
fi

if [ ! -d "${REORIENT_DIR}" ]; then
    echo "ERROR: REORIENT_DIR does not exist: ${REORIENT_DIR}"
    exit 1
fi

# Truncate subject list
: > "${SUBJECT_LIST}"

# CSV logs (append, but create header if missing)
if [ ! -f "${MISSING_T1_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,REASON" > "${MISSING_T1_CSV}"
fi

if [ ! -f "${SELECTION_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,NOTE" > "${SELECTION_CSV}"
fi

shopt -s nullglob

echo "Building subject list by matching PET_Preproc to ReOrientedLPS..."

for site_dir in "${PREPROC_PET_ROOT}"/*; do
    [ -d "${site_dir}" ] || continue
    site="$(basename "${site_dir}")"

    for sub_dir in "${site_dir}"/*; do
        [ -d "${sub_dir}" ] || continue
        sub="$(basename "${sub_dir}")"

        pet_og="${sub_dir}/${sub}_${PET_TAG}.nii.gz"
        if [ ! -f "${pet_og}" ]; then
            echo "  [${site}/${sub}] mean PET not found, skipping."
            echo "${site},${sub},,no_preproc_pet_og" >> "${MISSING_T1_CSV}"
            continue
        fi

        candidates=()
        # Direct match to ReOrientedLPS/ADXX/ADXX_T1_LPS.nii.gz
        direct_dir="${REORIENT_DIR}/${sub}"
        direct_t1="${direct_dir}/${sub}_T1_LPS.nii.gz"
        candidates+=( "${sub}" )

        if ((${#candidates[@]} == 0)); then
            echo "  [${site}/${sub}] No matching ReOrientedLPS T1 found."
            echo "${site},${sub},,no_T1_found" >> "${MISSING_T1_CSV}"
            continue
        fi

        # If multiple, choose lexicographically last (assumes date-like suffix)
        if ((${#candidates[@]} == 1)); then
            subLong="${candidates[0]}"
            note="unique_match"
        else
            subLong="$(printf '%s\n' "${candidates[@]}" | sort | tail -n 1)"
            note="multi_match_used_latest"
        fi

        echo "  [${site}/${sub}] -> subLong=${subLong} (${note})"
        # Space-separated fields; changed to comma-separated in downstream flow
        echo "${site} ${sub} ${subLong}" >> "${SUBJECT_LIST}"
        echo "${site},${sub},${subLong},${note}" >> "${SELECTION_CSV}"
    done
done

n=$(wc -l < "${SUBJECT_LIST}")

if [ "${n}" -eq 0 ]; then
    echo "No valid subjects for PET->T1 registration. Exiting."
    exit 0
fi

echo
echo "Subject list created with ${n} entries:"
echo "  -> ${SUBJECT_LIST}"
echo

ARRAY_RANGE="0-$((n - 1))"

echo "Submitting SLURM array job for ${ARRAY_RANGE}..."

sbatch \
    --export=PROJ_DIR="${PROJ_DIR}",PROTO_DIR="${PROTO_DIR}",REORIENT_DIR="${REORIENT_DIR}",LIST_DIR="${LIST_DIR}",SUBJECT_LIST="${SUBJECT_LIST}",S0B_CSV="${S0B_CSV}",PET_TAG="${PET_TAG}",FSLOUTPUTTYPE='NIFTI_GZ' \
    --array="${ARRAY_RANGE}" "${SCRIPTS_DIR}/Step1_PET2T1.sh"

echo "Submitted!"