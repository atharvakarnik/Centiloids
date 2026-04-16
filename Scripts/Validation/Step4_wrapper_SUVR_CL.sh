#!/bin/sh
#
# ------------------------------------------------- #
#     Adapted to GAAIN's dataset for validation     #
# ------------------------------------------------- #
#
# Step4_wrapper_SUVR_CL.sh
#
# Stage 4: ROI extraction + SUVR + Centiloid
#
# Usage:
#   bash Step4_wrapper_SUVR_CL.sh

set -euo pipefail

PROJ_DIR="${HOME}/Pipelines/Centiloids"
LIST_DIR="${PROJ_DIR}/Lists/4Validation"
PROTO_DIR="${PROJ_DIR}/Protocols/4Validation"
ATLAS_DIR="${PROJ_DIR}/Data/Atlases"
SCRIPTS_DIR="${PROJ_DIR}/Scripts/Validation"

mkdir -p "${LIST_DIR}" "${PROTO_DIR}/Centiloid_metrics/per_subject" "${LIST_DIR}/GAAIN"

# IMPORTANT - Step 3 Var for correct file picking
SMOOTH_FWHM_MM="0"      # Should match the var used in Step 3

# Inputs
S3_REG_CSV="${LIST_DIR}/s3_petmni_registration.csv"

# VOIs (2mm Centiloid standard)
VOI_CTX="${ATLAS_DIR}/voi_ctx_2mm.nii.gz"
VOI_CG="${ATLAS_DIR}/voi_CerebGry_2mm.nii.gz"
VOI_WC="${ATLAS_DIR}/voi_WhlCbl_2mm.nii.gz"
VOI_WCB="${ATLAS_DIR}/voi_WhlCblBrnStm_2mm.nii.gz"
VOI_PONS="${ATLAS_DIR}/voi_Pons_2mm.nii.gz"

# Lists / outputs
SUBJECT_LIST="${LIST_DIR}/s4_suvr_subjects.csv"      # no header: subLong,pet_rMNI,group
SELECTION_CSV="${LIST_DIR}/s4_suvr_selection.csv"
MISSING_CSV="${LIST_DIR}/s4_suvr_missing.csv"

STATUS_CSV="${LIST_DIR}/s4_suvrcl_status.csv"
GROUP_CSV="${PROTO_DIR}/Centiloid_metrics/s4_group_anchors.csv"
AB_CSV="${LIST_DIR}/Tracer/centiloid_anchor_params_validation.csv"

PER_SUB_DIR="${PROTO_DIR}/Centiloid_metrics/per_subject"
mkdir -p "$(dirname "${AB_CSV}")"

echo "=== Step4 Validation (GAAIN-style anchors) ==="
echo "S3_REG_CSV  : ${S3_REG_CSV}"
echo "SUBJECT_LIST: ${SUBJECT_LIST}"
echo "VOIs        :"
echo "  CTX  ${VOI_CTX}"
echo "  CG   ${VOI_CG}"
echo "  WC   ${VOI_WC}"
echo "  WC+B ${VOI_WCB}"
echo "  Pons ${VOI_PONS}"
echo "Outputs:"
echo "  STATUS ${STATUS_CSV}"
echo "  GROUP  ${GROUP_CSV}"
echo "  A/B    ${AB_CSV}"
echo "=============================================="
echo

[ -f "${S3_REG_CSV}" ] || { echo "ERROR: missing ${S3_REG_CSV}"; exit 1; }
for f in "${VOI_CTX}" "${VOI_CG}" "${VOI_WC}" "${VOI_WCB}" "${VOI_PONS}"; do
  [ -f "${f}" ] || { echo "ERROR: missing VOI ${f}"; exit 1; }
done

# Why do some cluster nodes don't even have 'module' command visible ??!
if ! command -v module >/dev/null 2>&1; then
  source /usr/share/Modules/init/bash 2>/dev/null || true
fi

module load python/3.11 >/dev/null 2>&1 || {
  echo "WARN: could not module load python/3.11; relying on python in PATH"
}
command -v python >/dev/null 2>&1 || { echo "ERROR: python not found"; exit 1; }

# Reset lists
: > "${SUBJECT_LIST}"
echo "subLong,pet_rMNI,group,note" > "${SELECTION_CSV}"
echo "subLong,reason" > "${MISSING_CSV}"

# Build subject list from s3 registration outputs
# Expected s3 columns (header):
# SITE,SUB,SUBLONG,PET_rT1,WARP,AFFINE,PET_rMNI,PET_rMNI_s8,NOTE
# We'll take PET_rMNI (col 7) in case no smoothening, but PET_rMNI_s{mmSmooth} in case of smoothening enabled
awk -F',' -v fwhm="$SMOOTH_FWHM_MM" '
NR==1 { next }
{
    if (fwhm == "0")
        print $3","$7","$9
    else
        print $3","$8","$9
}
' "${S3_REG_CSV}" | \
while IFS=',' read -r subLong pet_rMNI note; do
  note="${note:-}"

  if [[ "${note}" != OK* ]] && [[ "${note}" != already_done* ]]; then
    echo "${subLong},stage3_not_ok_${note}" >> "${MISSING_CSV}"
    continue
  fi
  if [ -z "${subLong}" ] || [ -z "${pet_rMNI}" ]; then
    echo "${subLong:-NA},bad_row_s3" >> "${MISSING_CSV}"
    continue
  fi
  if [ ! -f "${pet_rMNI}" ]; then
    echo "${subLong},pet_rMNI_missing" >> "${MISSING_CSV}"
    continue
  fi

  group="UNK"
  [[ "${subLong}" =~ ^AD ]] && group="AD100"
  [[ "${subLong}" =~ ^YC ]] && group="YC0"
  if [ "${group}" = "UNK" ]; then
    echo "${subLong},unknown_group" >> "${MISSING_CSV}"
    continue
  fi

  echo "${subLong},${pet_rMNI},${group}" >> "${SUBJECT_LIST}"
  echo "${subLong},${pet_rMNI},${group},selected" >> "${SELECTION_CSV}"
done

n=$(wc -l < "${SUBJECT_LIST}" | awk '{print $1}')
[ "${n}" -gt 0 ] || { echo "ERROR: no subjects in ${SUBJECT_LIST}"; exit 1; }

ARRAY_RANGE="0-$((n - 1))"
echo "Submitting SUVR array: ${ARRAY_RANGE} (n=${n})"

suvr_jobid=$(sbatch --parsable \
  --export=PROJ_DIR="${PROJ_DIR}",PROTO_DIR="${PROTO_DIR}",LIST_DIR="${LIST_DIR}",SUBJECT_LIST="${SUBJECT_LIST}",VOI_CTX="${VOI_CTX}",VOI_CG="${VOI_CG}",VOI_WC="${VOI_WC}",VOI_WCB="${VOI_WCB}",VOI_PONS="${VOI_PONS}",FSLOUTPUTTYPE='NIFTI_GZ' \
  --array="${ARRAY_RANGE}" "${SCRIPTS_DIR}/Step4_SUVR_CL.sh")

echo "SUVR array job id: ${suvr_jobid}"

rm -fv "${PROJ_DIR}/Logs/Validation/VAL_S4_finalize.log"

echo "Submitting finalize job (afterok:${suvr_jobid})"
sbatch \
  --job-name=VAL_S4_finalize \
  --output=Logs/4Validation/VAL_S4_finalize.log \
  --dependency=afterok:"${suvr_jobid}" \
  --time=00:10:00 --mem=2G --cpus-per-task=1 \
  --export=PER_SUB_DIR="${PER_SUB_DIR}",STATUS_CSV="${STATUS_CSV}",GROUP_CSV="${GROUP_CSV}",AB_CSV="${AB_CSV}" \
  --wrap='bash -lc "
set -euo pipefail
python - <<PY
import os, glob, math
import pandas as pd
import numpy as np

per_sub=os.environ[\"PER_SUB_DIR\"]
status_csv=os.environ[\"STATUS_CSV\"]
group_csv=os.environ[\"GROUP_CSV\"]
ab_csv=os.environ[\"AB_CSV\"]

rows=[]
for f in sorted(glob.glob(os.path.join(per_sub, \"*_suvr.csv\"))):
    line=open(f).read().strip()
    if not line: 
        continue
    parts=line.split(\",\")
    if len(parts) < 13:
        continue
    # subLong,group,pet,mean_ctx,mean_CG,mean_WC,mean_WC_B,mean_Pons,SUVR_CG,SUVR_WC,SUVR_WC_B,SUVR_Pons,note
    rows.append(parts[:13])

df=pd.DataFrame(rows, columns=[
    \"subLong\",\"group\",\"pet_rMNI\",
    \"mean_ctx\",\"mean_CG\",\"mean_WC\",\"mean_WC_B\",\"mean_Pons\",
    \"SUVR_CG\",\"SUVR_WC\",\"SUVR_WC_B\",\"SUVR_Pons\",
    \"note\"
])

# numeric conversions
for c in [\"mean_ctx\",\"mean_CG\",\"mean_WC\",\"mean_WC_B\",\"mean_Pons\",\"SUVR_CG\",\"SUVR_WC\",\"SUVR_WC_B\",\"SUVR_Pons\"]:
    df[c]=pd.to_numeric(df[c], errors=\"coerce\")

ok=df[df[\"note\"].astype(str).str.startswith(\"OK\")].copy()

def anchors_for(col):
    yc=ok.loc[ok[\"group\"].eq(\"YC0\"), col].dropna()
    ad=ok.loc[ok[\"group\"].eq(\"AD100\"), col].dropna()
    if len(yc)==0 or len(ad)==0:
        return (np.nan,np.nan,np.nan,np.nan,len(yc),len(ad))
    mu_yc=float(yc.mean()); mu_ad=float(ad.mean())
    denom=(mu_ad-mu_yc)
    if denom==0:
        return (mu_yc,mu_ad,np.nan,np.nan,len(yc),len(ad))
    a=100.0/denom
    b=-a*mu_yc
    return (mu_yc,mu_ad,a,b,len(yc),len(ad))

metrics=[]
params=[]

for region in [\"CG\",\"WC\",\"WC_B\",\"Pons\"]:
    col=f\"SUVR_{region}\"
    mu_yc, mu_ad, a, b, nyc, nad = anchors_for(col)
    metrics.append([region, nyc, nad, mu_yc, mu_ad, a, b])
    params.append([region, a, b])

    cl_col=f\"CL_{region}\"
    if np.isnan(a) or np.isnan(b):
        df[cl_col]=pd.NA
    else:
        df[cl_col]=df[col].apply(lambda x: a*x + b if pd.notna(x) else pd.NA)

metrics_df=pd.DataFrame(metrics, columns=[\"ref_region\",\"n_YC0\",\"n_AD100\",\"mu_YC0\",\"mu_AD100\",\"a\",\"b\"])
os.makedirs(os.path.dirname(group_csv), exist_ok=True)
metrics_df.to_csv(group_csv, index=False)

params_df=pd.DataFrame(params, columns=[\"ref_region\",\"a\",\"b\"])
os.makedirs(os.path.dirname(ab_csv), exist_ok=True)
params_df.to_csv(ab_csv, index=False)

# Final status output includes all reference-region CL columns (for Step5 QC)
out_cols=[\"subLong\",\"group\",\"pet_rMNI\",
          \"SUVR_CG\",\"SUVR_WC\",\"SUVR_WC_B\",\"SUVR_Pons\",
          \"CL_CG\",\"CL_WC\",\"CL_WC_B\",\"CL_Pons\",
          \"note\"]
df_out=df[out_cols].sort_values([\"group\",\"subLong\"])
os.makedirs(os.path.dirname(status_csv), exist_ok=True)
df_out.to_csv(status_csv, index=False)

print(\"Wrote:\", status_csv)
print(\"Wrote:\", group_csv)
print(\"Wrote:\", ab_csv)
print(metrics_df.to_string(index=False))
PY
"'

echo "Submitted Step4 finalize."