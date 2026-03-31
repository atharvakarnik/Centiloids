#!/bin/sh
# Step0b_PET_OrientFlipGate.sh
#SBATCH --job-name=PET_OrientGate
#SBATCH --partition=all
#SBATCH --propagate=NONE
#SBATCH --output=Logs/2Validation/PET_OrientGate_%A_%a.log
#SBATCH --time=00:20:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=4G

set -euo pipefail

: "${PROJ_DIR:?}"
: "${PROTO_DIR:?}"
: "${LIST_DIR:?}"
: "${REORIENT_DIR:?}"
: "${SUBJECT_LIST:?}"
: "${OUT_CSV:?}"
: "${MISSING_CSV:?}"
: "${PET_TAG:?PET_TAG is not set}"

export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${SLURM_CPUS_PER_TASK:-1}"
export OMP_PROC_BIND=true
export OMP_PLACES=cores

if [ -z "${SLURM_ARRAY_TASK_ID:-}" ]; then
  echo "ERROR: must run as array."
  exit 1
fi

idx="${SLURM_ARRAY_TASK_ID}"
line=$(sed -n "$((idx + 1))p" "${SUBJECT_LIST}" || true)
[ -n "${line}" ] || exit 0

site=$(echo "${line}" | awk '{print $1}')
sub=$(echo  "${line}" | awk '{print $2}')
subLong=$(echo "${line}" | awk '{print $3}')

# pet_og="${PROTO_DIR}/PET_Preproc/${site}/${sub}/${sub}_4D_mcf_mean.nii.gz"
# Patching to not use pet_og, prefering raw static from GAAIN
pet_og="${PROTO_DIR}/PET_Preproc/${site}/${sub}/${sub}_${PET_TAG}.nii.gz"
t1="${REORIENT_DIR}/${subLong}/${subLong}_T1_LPS.nii.gz"

if [ ! -f "${pet_og}" ]; then
  echo "${site},${sub},${subLong},no_pet_og" >> "${MISSING_CSV}"
  exit 0
fi
if [ ! -f "${t1}" ]; then
  echo "${site},${sub},${subLong},no_T1" >> "${MISSING_CSV}"
  exit 0
fi

workdir="${PROTO_DIR}/PET_OrientGate/${subLong}"
mkdir -p "${workdir}"

# Create y-flipped PET
pet_flip="${workdir}/${subLong}_${PET_TAG}_flipY.nii.gz"
if [ ! -f "${pet_flip}" ]; then
  fslswapdim "${pet_og}" x -y z "${pet_flip}"
fi

# Run quick rigid regs for scoring (we only need the resampled images)
out_o="${workdir}/${subLong}_pet2t1_orig.nii.gz"
out_f="${workdir}/${subLong}_pet2t1_flip.nii.gz"

flirt -in "${pet_og}" -ref "${t1}" -out "${out_o}" -dof 6 -cost normmi >/dev/null 2>&1 || true
flirt -in "${pet_flip}" -ref "${t1}" -out "${out_f}" -dof 6 -cost normmi >/dev/null 2>&1 || true

if [ ! -f "${out_o}" ] || [ ! -f "${out_f}" ]; then
  echo "${site},${sub},${subLong},${pet_og},${t1},NA,NA,NA,reg_failed" >> "${OUT_CSV}"
  exit 0
fi

# ANTs warp helper
rigid_score_warp() {
  mov="$1"; ref="$2"; out_img="$3"; out_prefix="$4"

  antsRegistration -d 3 \
    -o ["${out_prefix}","${out_prefix}Warped.nii.gz"] \
    --float 1 \
    --use-histogram-matching 0 \
    -r ["${ref}","${mov}",1] \
    -t Rigid[0.1] \
    -m MI["${ref}","${mov}",1,16,Regular,0.25] \
    -c [200x100x50x10,1e-6,10] \
    -s 3x2x1x0vox \
    -f 8x4x2x1 \
    -u 1 -z 1 >/dev/null 2>&1 || return 1

  mv -f "${out_prefix}Warped.nii.gz" "${out_img}" || return 1
  rm -f "${out_prefix}"0GenericAffine.mat "${out_prefix}"InverseWarped.nii.gz 2>/dev/null || true
  return 0
}

rigid_score_warp "${pet_og}"   "${t1}" "${out_o}" "${workdir}/${subLong}_orig2t1_" || true
rigid_score_warp "${pet_flip}" "${t1}" "${out_f}" "${workdir}/${subLong}_flip2t1_" || true

cc_orig="NA"
cc_flip="NA"

# Score via correlation (robust enough for flip decision)
if [ -f "${out_o}" ]; then
  cc_orig=$(fslcc -p 1 "${t1}" "${out_o}" 2>/dev/null | awk 'NR==1{print $3}' || echo "NA")
fi
if [ -f "${out_f}" ]; then
  cc_flip=$(fslcc -p 1 "${t1}" "${out_f}" 2>/dev/null | awk 'NR==1{print $3}' || echo "NA")
else
  echo "ERROR in producing flipped file for ${subLong}"
fi

# Choose higher CC; default to orig if NA
flipY="0"
note="OK"

module load python/3.11

python - <<PY >/dev/null 2>&1 || true
import math
co="${cc_orig}"; cf="${cc_flip}"
try: co=float(co)
except: co=float("nan")
try: cf=float(cf)
except: cf=float("nan")
PY

# bash-side compare with python for numeric safety
flipY=$(python - <<PY
import math
co="${cc_orig}"; cf="${cc_flip}"
try: co=float(co)
except: co=float("nan")
try: cf=float(cf)
except: cf=float("nan")
if math.isnan(co) and math.isnan(cf):
    print("0")
elif math.isnan(co):
    print("1")
elif math.isnan(cf):
    print("0")
else:
    print("1" if cf > co else "0")
PY
)

if [ "${flipY}" = "1" ]; then
  note="flipY_selected"
fi

echo "${site},${sub},${subLong},${pet_og},${t1},${flipY},${cc_orig},${cc_flip},${note}" >> "${OUT_CSV}"
echo "Done ${subLong}: flipY=${flipY} (cc_orig=${cc_orig}, cc_flip=${cc_flip})"
