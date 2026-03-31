#!/usr/bin/env bash
#
# Step4B_SUVR_WC.sh
#
#SBATCH --job-name=DPPOS_Feb26PET_SUVR_WC
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

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1"; exit 1; }; }
need_cmd fslstats
need_cmd python

idx="${SLURM_ARRAY_TASK_ID:-}"
[ -n "${idx}" ] || { echo "ERROR: SLURM_ARRAY_TASK_ID not set"; exit 1; }

# Print once per task (useful in logs, very low noise)
echo "INFO: task=${idx} reading subject row from ${SUBJECT_LIST}"

line="$(sed -n "$((idx + 1))p" "${SUBJECT_LIST}" || true)"
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
  # Keep stderr for debugging if it fails
  if ! out=$(fslstats "$img" -n -k "$msk" -M 2>&1); then
    echo "WARN: fslstats failed for img=${img} mask=${msk}"
    echo "WARN: fslstats stderr/stdout: ${out}"
    echo "NA"
    return 0
  fi
  out="$(echo "$out" | awk '{print $1}')"
  [[ "$out" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]] && echo "$out" || echo "NA"
}

calc_suvr () {
  python - "$1" "$2" <<'PY'
import sys
t=float(sys.argv[1]); r=float(sys.argv[2])
print(f"{t/r:.6f}" if r>0 else "NA")
PY
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
  if python - <<PY >/dev/null 2>&1
r=float("${mean_wc}"); import sys; sys.exit(0 if r>0 else 1)
PY
  then
    suvr_wc="$(calc_suvr "${mean_ctx}" "${mean_wc}")"
  else
    note_out="ref_wc_nonpos"
  fi
fi

echo "INFO: SUVR_WC=${suvr_wc} note_out=${note_out}"

echo "${subLong},${tracer},${pet_rMNI},${mean_ctx},${mean_wc},${suvr_wc},${note_out}" > "${tmp}"
mv -f "${tmp}" "${out_csv}"
echo "INFO: wrote ${out_csv}"