#!/usr/bin/env bash
#
# Step4B_wrapper_SUVR_WC.sh - Adapted from 4B validation worker. Dual datapoints para-work (from Vld) is deprecated here
#
# Production cohort (good ol' DPPOS) Step4: extract SUVR_WC (CTX/WC) from the Step3 output PET in MNI.
# IMPORTANT !!!! -> Assumes this cohort is "FBP tracer" (Approach B downstream).
#
set -euo pipefail

############################################
# USER CONFIG
############################################
PROJ_DIR="${HOME}/Pipelines/Centiloids"
DATASET="DPPOS_Feb26PET"

LIST_DIR="${PROJ_DIR}/Lists/2${DATASET}"
PROTO_DIR="${PROJ_DIR}/Protocols/2${DATASET}"
ATLAS_DIR="${PROJ_DIR}/Data/Atlases"
SCRIPTS_DIR="${PROJ_DIR}/Scripts"

S3_REG_CSV="${LIST_DIR}/s3_petmni_registration.csv"

# Use PET_rMNI_s8 if smoothing done; else set 0 to use PET_rMNI
SMOOTH_FWHM_MM="0"  # IMPORTANT - Must match Step 3 var

VOI_CTX="${ATLAS_DIR}/voi_ctx_2mm.nii.gz"
VOI_WC="${ATLAS_DIR}/voi_WhlCbl_2mm.nii.gz"
############################################

mkdir -p "${LIST_DIR}" "${PROTO_DIR}" "${PROTO_DIR}/Centiloid_Scores_WC/per_subject"

need_file(){ [ -f "$1" ] || { echo "ERROR: missing $1"; exit 1; }; }
need_file "${S3_REG_CSV}"
need_file "${VOI_CTX}"
need_file "${VOI_WC}"
need_file "${SCRIPTS_DIR}/Step4B_SUVR_WC.sh"

SUBJECT_LIST="${LIST_DIR}/s4B_subjects.csv"        # no header
SELECTION_CSV="${LIST_DIR}/s4B_selection.csv"
MISSING_CSV="${LIST_DIR}/s4B_missing.csv"
STATUS_CSV="${LIST_DIR}/s4B_suvr_status.csv"

: > "${SUBJECT_LIST}"
echo "subLong,tracer,pet_rMNI,note" > "${SELECTION_CSV}"
echo "subLong,tracer,reason" > "${MISSING_CSV}"

# Step3 header expected:
# SITE,SUB,SUBLONG,PET_rT1,WARP,AFFINE,PET_rMNI,PET_rMNI_s8,NOTE
awk -F',' -v fwhm="${SMOOTH_FWHM_MM}" '
NR==1{next}
{
  sublong=$3
  pet=(fwhm=="0" ? $7 : $8)
  note=$9
  print sublong ",FBP," pet "," note
}' "${S3_REG_CSV}" | \
while IFS=',' read -r subLong tracer pet_rMNI note; do
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
  --job-name="${DATASET}_SUVR_WC" \
  --output="${PROJ_DIR}/Logs/2${DATASET}/S4B_SUVR_WC_%A_%a.log" \
  --time=00:10:00 --mem=2G --cpus-per-task=1 \
  --export=PROJ_DIR="${PROJ_DIR}",PROTO_DIR="${PROTO_DIR}",LIST_DIR="${LIST_DIR}",SUBJECT_LIST="${SUBJECT_LIST}",VOI_CTX="${VOI_CTX}",VOI_WC="${VOI_WC}",FSLOUTPUTTYPE='NIFTI_GZ' \
  --array="${ARRAY_RANGE}" "${SCRIPTS_DIR}/Step4B_SUVR_WC.sh")

echo "Step4B array job id: ${jobid}"

echo "Submitting finalize job (afterok:${jobid})"
sbatch \
  --job-name="${DATASET}_S4B_finalize" \
  --output="${PROJ_DIR}/Logs/2${DATASET}/S4B_finalize_%j.log" \
  --dependency=afterok:"${jobid}" \
  --time=00:05:00 --mem=2G --cpus-per-task=1 \
  --export=PROTO_DIR="${PROTO_DIR}",LIST_DIR="${LIST_DIR}",STATUS_CSV="${STATUS_CSV}",DATASET="${DATASET}" \
  --wrap='bash -lc "
set -euo pipefail
python - <<PY
import os, glob
import pandas as pd

proto=os.environ[\"PROTO_DIR\"]
status=os.environ[\"STATUS_CSV\"]

per_sub=os.path.join(proto, \"Centiloid_Scores_WC\", \"per_subject\")
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
print(df[\"SUVR_WC\"].describe())
PY
"'

echo "Submitted Step4B finalize."