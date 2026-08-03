#!/usr/bin/env bash
# Step0b_wrapper_PET_OrientFlipGate.sh
set -euo pipefail

# IMPORTANT : Check this var meticulously to state correct cohort!!! 
PET_TAG="PET"
# ---------------------------------------------------------------- #

PROJ_DIR="${HOME}/Pipelines/Centiloids"
LIST_DIR="${PROJ_DIR}/Lists/3Validation"
PROTO_DIR="${PROJ_DIR}/Protocols/3Validation"
REORIENT_DIR="${PROJ_DIR}/Data/Validation/ReOrientedLPS"
SCRIPTS_DIR="${PROJ_DIR}/Scripts/Validation"

S0_SEL="${LIST_DIR}/pet_preproc_selection.csv"           # produced by Step0
SUBJECT_LIST="${LIST_DIR}/s0b_orient_subjects.txt"
OUT_CSV="${LIST_DIR}/s0b_orient_flip_flags.csv"
MISSING_CSV="${LIST_DIR}/s0b_orient_missing.csv"

mkdir -p "${LIST_DIR}" "${PROTO_DIR}" "$(dirname "${OUT_CSV}")"

[ -f "${S0_SEL}" ] || { echo "ERROR: missing ${S0_SEL} (run Step0 first)"; exit 1; }

: > "${SUBJECT_LIST}"
if [ ! -f "${OUT_CSV}" ]; then echo "SITE,SUB,SUBLONG,PET_MEAN,T1,FLIPY,CC_ORIG,CC_FLIP,NOTE" > "${OUT_CSV}"; fi
if [ ! -f "${MISSING_CSV}" ]; then echo "SITE,SUB,SUBLONG,REASON" > "${MISSING_CSV}"; fi

# Build subject list by joining Step0 selection with available T1 folders
tail -n +2 "${S0_SEL}" | while IFS=',' read -r site sub input_nii mode nvol out3d out4d note; do
  [ -n "${site}" ] || continue
  [ -n "${sub}" ] || continue

  subLong="${sub}"
  t1="${REORIENT_DIR}/${subLong}/${subLong}_T1_LPS.nii.gz"
  pet_og="${out3d}"

  if [ ! -f "${pet_og}" ]; then
    echo "${site},${sub},${subLong},no_pet_mean" >> "${MISSING_CSV}"
    continue
  fi
  if [ ! -f "${t1}" ]; then
    echo "${site},${sub},${subLong},no_T1" >> "${MISSING_CSV}"
    continue
  fi

  echo "${site} ${sub} ${subLong}" >> "${SUBJECT_LIST}"
done

n=$(wc -l < "${SUBJECT_LIST}" | awk '{print $1}')
[ "${n}" -gt 0 ] || { echo "No subjects for Step0b."; exit 0; }

ARRAY_RANGE="0-$((n - 1))"

sbatch \
  --export=PROJ_DIR="${PROJ_DIR}",PROTO_DIR="${PROTO_DIR}",LIST_DIR="${LIST_DIR}",REORIENT_DIR="${REORIENT_DIR}",SUBJECT_LIST="${SUBJECT_LIST}",OUT_CSV="${OUT_CSV}",MISSING_CSV="${MISSING_CSV}",PET_TAG="${PET_TAG}",FSLOUTPUTTYPE='NIFTI_GZ' \
  --array="${ARRAY_RANGE}" "${SCRIPTS_DIR}/Step0b_PET_OrientFlipGate.sh"

echo "Submitted Step0b array."
