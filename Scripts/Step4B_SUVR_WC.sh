#!/usr/bin/env bash
#
# Step4B_SUVR_WC.sh
#
#SBATCH --job-name=DPPOS_Jun26_SUVR_WC
#SBATCH --partition=all
#SBATCH --propagate=NONE
#SBATCH --time=00:20:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G

set -euo pipefail

# ---- Verbose failure context (minimal, but very effective) ----
on_err() {
  echo "ERROR: Step4B_SUVR_WC failed."
  echo "  host=$(hostname)"
  echo "  date=$(date)"
  echo "  SLURM_JOB_ID=${SLURM_JOB_ID:-NA}"
  echo "  SLURM_ARRAY_JOB_ID=${SLURM_ARRAY_JOB_ID:-NA}"
  echo "  SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-NA}"
  echo "  subLong=${subLong:-NA}"
  echo "  tracer=${tracer:-NA}"
  echo "  pet_rMNI=${pet_rMNI:-NA}"
  echo "  note(in)=${note:-NA}"
}
trap on_err ERR

: "${PROJ_DIR:?PROJ_DIR is not set}"
: "${PROTO_DIR:?PROTO_DIR is not set}"
: "${LIST_DIR:?LIST_DIR is not set}"
: "${SUBJECT_LIST:?SUBJECT_LIST is not set}"
: "${VOI_CTX:?VOI_CTX is not set}"
: "${VOI_WC:?VOI_WC is not set}"

OUT_DIR="${PROTO_DIR}/Centiloid_Scores_WC"
PER_SUB_DIR="${OUT_DIR}/per_subject"
mkdir -p "${PER_SUB_DIR}"

# ----- deterministic FSL/Lmod setup -----

ORIG_PATH="${PATH:-}"
export PATH="/usr/local/bin:/usr/bin:/bin${ORIG_PATH:+:${ORIG_PATH}}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export FSLOUTPUTTYPE="NIFTI_GZ"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: missing command: $1" >&2
        echo "PATH=${PATH}" >&2
        exit 127
    }
}

need_cmd mkdir

OUT_DIR="${PROTO_DIR}/Centiloid_Scores_WC"
PER_SUB_DIR="${OUT_DIR}/per_subject"
mkdir -p "${PER_SUB_DIR}"

LMOD_INIT="${LMOD_INIT:-/cubic/software/centos7/lmod/lmod/init/bash}"

if ! command -v module >/dev/null 2>&1; then
    echo "NOTE: Initializing Lmod from ${LMOD_INIT}"
    [[ -r "${LMOD_INIT}" ]] || {
        echo "ERROR: Lmod init file is not readable: ${LMOD_INIT}" >&2
        exit 127
    }
    set +u
    . "${LMOD_INIT}"
    set -u
fi

export OSrelease="${OSrelease:-centos7}"
export ARCH="${ARCH:-$(uname -m)}"

module use /cbica/share/modules
module load fsl/5.0.11

if [[ -z "${FSLDIR:-}" && -d /cbica/software/external/fsl/centos7/5.0.11 ]]; then
    export FSLDIR="/cbica/software/external/fsl/centos7/5.0.11"
fi

[[ -n "${FSLDIR:-}" ]] || {
    echo "ERROR: FSLDIR is not set after loading fsl/5.0.11" >&2
    exit 127
}

if [[ -r "${FSLDIR}/etc/fslconf/fsl.sh" ]]; then
    set +u
    . "${FSLDIR}/etc/fslconf/fsl.sh"
    set -u
fi

# FSL/module init may rewrite PATH. Restore core tools, keep original SLURM PATH, and put FSL first.
export PATH="${FSLDIR}/bin:/usr/local/bin:/usr/bin:/bin${ORIG_PATH:+:${ORIG_PATH}}"
hash -r

need_cmd fslstats
need_cmd fslmaths
need_cmd mv
need_cmd rm

echo "PATH               : ${PATH}"
echo "FSLDIR             : ${FSLDIR}"
echo "fslstats           : $(command -v fslstats)"
echo "fslmaths           : $(command -v fslmaths)"
echo "mv                 : $(command -v mv)"

# ----------------------------------------

read_nth_line() {
  local n="$1" file="$2" i=0 row
  while IFS= read -r row || [[ -n "${row}" ]]; do
    if [[ "${i}" -eq "${n}" ]]; then
      printf '%s\n' "${row}"
      return 0
    fi
    ((i+=1))
  done < "${file}"
  return 1
}

idx="${SLURM_ARRAY_TASK_ID:-}"
[ -n "${idx}" ] || { echo "ERROR: SLURM_ARRAY_TASK_ID not set"; exit 1; }

# Print once per task (useful in logs, very low noise)
echo "INFO: task=${idx} reading subject row from ${SUBJECT_LIST}"

[[ "${idx}" =~ ^[0-9]+$ ]] || {
  echo "ERROR: SLURM_ARRAY_TASK_ID is not numeric: ${idx}" >&2
  exit 1
}

line="$(read_nth_line "${idx}" "${SUBJECT_LIST}" || true)"

if [ -z "${line}" ]; then
  echo "WARN: No row for task ${idx} (SUBJECT_LIST shorter than expected). Exiting 0."
  exit 0
fi

# NOTE: subject list is CSV with 4 fields (subLong,tracer,pet_rMNI,note)
# If pet paths ever contain commas, this will break; log the raw line for debugging.
IFS=',' read -r subLong tracer pet_rMNI note <<< "${line}"

echo "INFO: subLong=${subLong} tracer=${tracer}"
echo "INFO: pet_rMNI=${pet_rMNI}"
echo "INFO: note(in)=${note:-}"

out_csv="${PER_SUB_DIR}/${subLong}_${tracer}_suvr_wc.csv"
tmp="${out_csv}.tmp"

is_num() { [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]; }

safe_mean() {
  local img="$1" msk="$2"
  local out

  if ! out="$(fslstats "$img" -n -k "$msk" -M 2>&1)"; then
    echo "WARN: fslstats failed for img=${img} mask=${msk}" >&2
    echo "WARN: fslstats stderr/stdout: ${out}" >&2
    echo "NA"
    return 0
  fi

  read -r out _ <<< "${out}"
  [[ "${out}" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]] && echo "${out}" || echo "NA"
}

is_pos_nonzero() {
  local x="${1:-}" mant
  is_num "${x}" || return 1
  [[ "${x}" == -* ]] && return 1
  x="${x#+}"
  mant="${x%%[eE]*}"
  mant="${mant//./}"
  [[ "${mant}" =~ [1-9] ]]
}

calc_suvr() {
  local img="$1" ref="$2" mask="$3" tmp_img="$4"

  if ! fslmaths "${img}" -div "${ref}" "${tmp_img}" >/dev/null 2>&1; then
    echo "NA"
    return 0
  fi

  safe_mean "${tmp_img}" "${mask}"
}

note_out="OK"

if [ ! -f "${pet_rMNI}" ]; then
  echo "WARN: pet missing: ${pet_rMNI}"
  echo "${subLong},${tracer},${pet_rMNI},NA,NA,NA,pet_missing" > "${tmp}"
  mv -f "${tmp}" "${out_csv}"
  echo "INFO: wrote ${out_csv}"
  exit 0
fi

if [ ! -f "${VOI_CTX}" ]; then
  echo "ERROR: VOI_CTX missing: ${VOI_CTX}"
  exit 1
fi
if [ ! -f "${VOI_WC}" ]; then
  echo "ERROR: VOI_WC missing: ${VOI_WC}"
  exit 1
fi

mean_ctx="$(safe_mean "${pet_rMNI}" "${VOI_CTX}")"
mean_wc="$(safe_mean "${pet_rMNI}" "${VOI_WC}")"

echo "INFO: mean_ctx=${mean_ctx} mean_wc=${mean_wc}"

suvr_wc="NA"
if ! is_num "${mean_ctx}"; then note_out="mean_ctx_failed"; fi
if ! is_num "${mean_wc}"; then note_out="${note_out};ref_wc_bad"; fi

if [[ "${note_out}" == OK* ]]; then
  if is_pos_nonzero "${mean_wc}"; then
    tmp_suvr_img="${PER_SUB_DIR}/${subLong}_${tracer}_tmp_suvr_wc.nii.gz"
    suvr_wc="$(calc_suvr "${pet_rMNI}" "${mean_wc}" "${VOI_CTX}" "${tmp_suvr_img}")"
    rm -f "${tmp_suvr_img}" 2>/dev/null || true

    if ! is_num "${suvr_wc}"; then
      note_out="suvr_calc_failed"
      suvr_wc="NA"
    fi
  else
    note_out="ref_wc_nonpos"
  fi
fi

echo "INFO: SUVR_WC=${suvr_wc} note_out=${note_out}"

echo "${subLong},${tracer},${pet_rMNI},${mean_ctx},${mean_wc},${suvr_wc},${note_out}" > "${tmp}"
mv -f "${tmp}" "${out_csv}"
echo "INFO: wrote ${out_csv}"