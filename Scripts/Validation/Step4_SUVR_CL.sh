#!/bin/sh
#
# ------------------------------------------------- #
#     Adapted to GAAIN's dataset for validation     #
# ------------------------------------------------- #
#
# Step4_SUVR_CL.sh
#
# Stage 4 worker: ROI means -> SUVR -> Centiloid
#
#SBATCH --job-name=Centiloid_SUVR
#SBATCH --partition=all
#SBATCH --propagate=NONE
#SBATCH --output=Logs/3Validation/SUVR_CL_%A_%a.log
#SBATCH --time=00:12:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G

set -euo pipefail

: "${PROJ_DIR:?PROJ_DIR is not set}"
: "${PROTO_DIR:?PROTO_DIR is not set}"
: "${LIST_DIR:?LIST_DIR is not set}"
: "${SUBJECT_LIST:?SUBJECT_LIST is not set}"

: "${VOI_CTX:?VOI_CTX is not set}"
: "${VOI_CG:?VOI_CG is not set}"
: "${VOI_WC:?VOI_WC is not set}"
: "${VOI_WCB:?VOI_WCB is not set}"
: "${VOI_PONS:?VOI_PONS is not set}"

METRICS_DIR="${PROTO_DIR}/Centiloid_metrics"
PER_SUB_DIR="${METRICS_DIR}/per_subject"
mkdir -p "${METRICS_DIR}" "${PER_SUB_DIR}"

if [ -z "${SLURM_ARRAY_TASK_ID:-}" ]; then
  echo "ERROR: SLURM_ARRAY_TASK_ID not set (must run as array)."
  exit 1
fi
idx="${SLURM_ARRAY_TASK_ID}"

line=$(sed -n "$((idx + 1))p" "${SUBJECT_LIST}" || true)
if [ -z "${line}" ]; then
  echo "No row for task ${idx} in ${SUBJECT_LIST}"
  exit 0
fi

# SUBJECT_LIST CSV (no header): subLong,pet_rMNI,group
IFS=',' read -r subLong pet_rMNI group <<< "${line}"

echo "Task ${idx} -> ${subLong} group=${group}"
echo "  PET : ${pet_rMNI}"

out_csv="${PER_SUB_DIR}/${subLong}_suvr.csv"
tmp="${out_csv}.tmp"

# Why do some cluster nodes don't even have 'module' command visible ??!
if ! command -v module >/dev/null 2>&1; then
  source /usr/share/Modules/init/bash 2>/dev/null || true
fi

module load python/3.11 >/dev/null 2>&1 || {
  echo "WARN: could not module load python/3.11; relying on python in PATH"
}
command -v python >/dev/null 2>&1 || { echo "ERROR: python not found"; exit 1; }

# Helper: validate numeric
is_num() {
  local x="${1:-}"
  [[ -n "${x}" ]] || return 1
  [[ "${x}" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]
}

safe_mean() {
  # Returns numeric mean or "NA"
  local img="$1" msk="$2"
  local out
  out=$(fslstats "$img" -n -k "$msk" -M 2>/dev/null || true)
  out="$(echo "$out" | awk '{print $1}')"   # trims whitespace + keeps the first token
  [[ "$out" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]] && echo "$out" || echo "NA"
}

# Basic checks
if [ ! -f "${pet_rMNI}" ]; then
  echo "${subLong},${group},${pet_rMNI},NA,NA,NA,NA,NA,NA,NA,NA,NA,pet_missing" > "${tmp}"
  mv -f "${tmp}" "${out_csv}"
  exit 0
fi

for m in "${VOI_CTX}" "${VOI_CG}" "${VOI_WC}" "${VOI_WCB}" "${VOI_PONS}"; do
  [ -f "${m}" ] || { echo "ERROR: Missing mask ${m}"; exit 1; }
done

# Means
mean_ctx=$(safe_mean "${pet_rMNI}" "${VOI_CTX}" || true)
mean_cg=$(safe_mean "${pet_rMNI}" "${VOI_CG}" || true)
mean_wc=$(safe_mean "${pet_rMNI}" "${VOI_WC}" || true)
mean_wcb=$(safe_mean "${pet_rMNI}" "${VOI_WCB}" || true)
mean_pons=$(safe_mean "${pet_rMNI}" "${VOI_PONS}"|| true)

note="OK"

# Validate mean_ctx first
if ! is_num "${mean_ctx:-}"; then
  note="mean_ctx_failed"
fi

# Compute SUVRs (only if ref mean valid & >0)
calc_suvr () {
  python - "$1" "$2" <<'PY' 2>/dev/null
import sys
t=float(sys.argv[1]); r=float(sys.argv[2])
print(f"{t/r:.6f}" if r>0 else "NA")
PY
}

suvr_cg="NA"; suvr_wc="NA"; suvr_wcb="NA"; suvr_pons="NA"

if [ "${note}" = "OK" ]; then
  if is_num "${mean_cg:-nan}" "${mean_cg:-nan}" && python - <<PY >/dev/null 2>&1
r=float("${mean_cg}"); import sys; sys.exit(0 if r>0 else 1)
PY
  then suvr_cg=$(calc_suvr "${mean_ctx}" "${mean_cg}"); else note="${note};ref_cg_bad"; fi

  if is_num "${mean_wc:-}" && python - <<PY >/dev/null 2>&1
r=float("${mean_wc}"); import sys; sys.exit(0 if r>0 else 1)
PY
  then suvr_wc=$(calc_suvr "${mean_ctx}" "${mean_wc}"); else note="${note};ref_wc_bad"; fi

  if is_num "${mean_wcb:-nan}" "${mean_wcb:-nan}" && python - <<PY >/dev/null 2>&1
r=float("${mean_wcb}"); import sys; sys.exit(0 if r>0 else 1)
PY
  then suvr_wcb=$(calc_suvr "${mean_ctx}" "${mean_wcb}"); else note="${note};ref_wcb_bad"; fi

  if is_num "${mean_pons:-nan}" "${mean_pons:-nan}" && python - <<PY >/dev/null 2>&1
r=float("${mean_pons}"); import sys; sys.exit(0 if r>0 else 1)
PY
  then suvr_pons=$(calc_suvr "${mean_ctx}" "${mean_pons}"); else note="${note};ref_pons_bad"; fi
fi

# Output row (single-line CSV for this subject)
# Columns:
# subLong,group,pet_rMNI,mean_ctx,mean_CG,mean_WC,mean_WC_B,mean_Pons,SUVR_CG,SUVR_WC,SUVR_WC_B,SUVR_Pons,note
echo "${subLong},${group},${pet_rMNI},${mean_ctx:-NA},${mean_cg:-NA},${mean_wc:-NA},${mean_wcb:-NA},${mean_pons:-NA},${suvr_cg},${suvr_wc},${suvr_wcb},${suvr_pons},${note}" > "${tmp}"
mv -f "${tmp}" "${out_csv}"

echo "Wrote: ${out_csv}"