#!/usr/bin/env bash
#
# Step4B_wrapper_SUVR_WC.sh
#
# Approach B: Extract SUVR_WC (CTX/WC) for BOTH tracers when Steps 0-3 were run separately
# into different LIST_DIR / PROTO_DIR roots (PiB run and FBP run).
#
# Outputs are written under a "Centiloid_B_WC" namespace.
#
set -euo pipefail

############################################
# USER CONFIG
############################################
PROJ_DIR="${HOME}/Pipelines/Centiloids"

LIST_DIR_PIB="${PROJ_DIR}/Lists/2FB_Val_PiB"
S3_REG_CSV_PIB="${LIST_DIR_PIB}/s3_petmni_registration.csv"

LIST_DIR_FBP="${PROJ_DIR}/Lists/2FB_Val_FBP"
S3_REG_CSV_FBP="${LIST_DIR_FBP}/s3_petmni_registration.csv"

LIST_DIR_OUT="${PROJ_DIR}/Lists/2FB_Val_B_WC"
PROTO_DIR_OUT="${PROJ_DIR}/Protocols/2FB_Val_B_WC"
LOG_DIR="${PROJ_DIR}/Logs/2FB_Val_B_WC"

ATLAS_DIR="${PROJ_DIR}/Data/Atlases"
SCRIPTS_DIR="${PROJ_DIR}/Scripts/Validation"

# IMPORTANT - Must match Step 3 var
SMOOTH_FWHM_MM="0"

# VOIs
VOI_CTX="${ATLAS_DIR}/voi_ctx_2mm.nii.gz"
VOI_WC="${ATLAS_DIR}/voi_WhlCbl_2mm.nii.gz"
############################################

mkdir -p "${LIST_DIR_OUT}" "${PROTO_DIR_OUT}" \
  "${PROTO_DIR_OUT}/Centiloid_B_WC/per_subject" \
  "${LOG_DIR}"

need_file(){ [ -f "$1" ] || { echo "ERROR: missing $1"; exit 1; }; }
need_file "${S3_REG_CSV_PIB}"
need_file "${S3_REG_CSV_FBP}"
need_file "${VOI_CTX}"
need_file "${VOI_WC}"
need_file "${SCRIPTS_DIR}/Step4B_SUVR_WC.sh"

SUBJECT_LIST="${LIST_DIR_OUT}/s4B_subjects.csv"        # no header
SELECTION_CSV="${LIST_DIR_OUT}/s4B_selection.csv"
MISSING_CSV="${LIST_DIR_OUT}/s4B_missing.csv"
STATUS_CSV="${LIST_DIR_OUT}/s4B_suvr_status.csv"

: > "${SUBJECT_LIST}"
echo "subLong,tracer,pet_rMNI,note" > "${SELECTION_CSV}"
echo "subLong,tracer,reason" > "${MISSING_CSV}"

append_from_s3 () {
  local tracer="$1"
  local csv="$2"
  awk -F',' -v fwhm="${SMOOTH_FWHM_MM}" -v tracer="${tracer}" '
  NR==1 { next }
  {
    sublong=$3
    pet = (fwhm=="0" ? $7 : $8)
    note=$9
    print sublong "," tracer "," pet "," note
  }' "${csv}"
}

# PiB
append_from_s3 "PiB" "${S3_REG_CSV_PIB}" | while IFS=',' read -r subLong tracer pet_rMNI note; do
  note="${note:-}"
  if [[ "${note}" != OK* ]] && [[ "${note}" != already_done* ]]; then
    echo "${subLong},${tracer},stage3_not_ok_${note}" >> "${MISSING_CSV}"
    continue
  fi
  if [ -z "${subLong}" ] || [ -z "${pet_rMNI}" ]; then
    echo "${subLong:-NA},${tracer},bad_row_s3" >> "${MISSING_CSV}"
    continue
  fi
  if [ ! -f "${pet_rMNI}" ]; then
    echo "${subLong},${tracer},pet_missing" >> "${MISSING_CSV}"
    continue
  fi
  echo "${subLong},${tracer},${pet_rMNI},${note}" >> "${SUBJECT_LIST}"
  echo "${subLong},${tracer},${pet_rMNI},selected_${note}" >> "${SELECTION_CSV}"
done

# FBP
append_from_s3 "FBP" "${S3_REG_CSV_FBP}" | while IFS=',' read -r subLong tracer pet_rMNI note; do
  note="${note:-}"
  if [[ "${note}" != OK* ]] && [[ "${note}" != already_done* ]]; then
    echo "${subLong},${tracer},stage3_not_ok_${note}" >> "${MISSING_CSV}"
    continue
  fi
  if [ -z "${subLong}" ] || [ -z "${pet_rMNI}" ]; then
    echo "${subLong:-NA},${tracer},bad_row_s3" >> "${MISSING_CSV}"
    continue
  fi
  if [ ! -f "${pet_rMNI}" ]; then
    echo "${subLong},${tracer},pet_missing" >> "${MISSING_CSV}"
    continue
  fi
  echo "${subLong},${tracer},${pet_rMNI},${note}" >> "${SUBJECT_LIST}"
  echo "${subLong},${tracer},${pet_rMNI},selected_${note}" >> "${SELECTION_CSV}"
done

n=$(wc -l < "${SUBJECT_LIST}" | awk '{print $1}')
[ "${n}" -gt 0 ] || { echo "ERROR: no subjects in ${SUBJECT_LIST}"; exit 1; }

ARRAY_RANGE="0-$((n - 1))"
echo "Submitting Step4B array: ${ARRAY_RANGE} (n=${n})"

jobid=$(sbatch --parsable \
  --job-name=FB_SUVR_WC_B \
  --partition=all \
  --propagate=NONE \
  --output="${LOG_DIR}/S4B_SUVR_WC_%A_%a.log" \
  --time=00:20:00 --mem=2G --cpus-per-task=1 \
  --export=PROJ_DIR="${PROJ_DIR}",PROTO_DIR="${PROTO_DIR_OUT}",LIST_DIR="${LIST_DIR_OUT}",SUBJECT_LIST="${SUBJECT_LIST}",VOI_CTX="${VOI_CTX}",VOI_WC="${VOI_WC}",FSLOUTPUTTYPE='NIFTI_GZ' \
  --array="${ARRAY_RANGE}" "${SCRIPTS_DIR}/Step4B_SUVR_WC.sh")

echo "Step4B array job id: ${jobid}"

echo "Submitting finalize job (afterok:${jobid})"
sbatch \
  --partition=all \
  --job-name=FB_S4B_finalize \
  --output="${LOG_DIR}/S4B_finalize_%j.log" \
  --dependency=afterok:"${jobid}" \
  --time=00:05:00 --mem=2G --cpus-per-task=1 \
  --export=PROTO_DIR="${PROTO_DIR_OUT}",LIST_DIR="${LIST_DIR_OUT}",STATUS_CSV="${STATUS_CSV}" \
  --wrap='bash -lc "
set -euo pipefail
python - <<PY
import os, glob
import pandas as pd

proto=os.environ[\"PROTO_DIR\"]
status=os.environ[\"STATUS_CSV\"]

per_sub=os.path.join(proto, \"Centiloid_B_WC\", \"per_subject\")
rows=[]
for f in sorted(glob.glob(os.path.join(per_sub, \"*_suvr_wc.csv\"))):
    line=open(f).read().strip()
    if not line:
        continue
    parts=line.split(\",\")
    if len(parts) < 7:
        continue
    rows.append(parts[:7])

df=pd.DataFrame(rows, columns=[\"subLong\",\"tracer\",\"pet_rMNI\",\"mean_ctx\",\"mean_wc\",\"SUVR_WC\",\"note\"])
for c in [\"mean_ctx\",\"mean_wc\",\"SUVR_WC\"]:
    df[c]=pd.to_numeric(df[c], errors=\"coerce\")

os.makedirs(os.path.dirname(status), exist_ok=True)
df.sort_values([\"tracer\",\"subLong\"]).to_csv(status, index=False)
print(\"Wrote:\", status)
print(df.groupby(\"tracer\")[\"SUVR_WC\"].describe())
PY
"'

echo "Submitted Step4B finalize."
