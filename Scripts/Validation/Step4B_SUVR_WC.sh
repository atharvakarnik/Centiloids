#!/usr/bin/env bash
#
# Step4B_SUVR_WC.sh  (DROP-IN REPLACEMENT)
#
#SBATCH --job-name=FB_SUVR_WC_B
#SBATCH --partition=all
#SBATCH --propagate=NONE
#SBATCH --time=00:20:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G

set -euo pipefail

############################################
# Required env from wrapper
############################################
: "${PROJ_DIR:?PROJ_DIR is not set}"
: "${PROTO_DIR:?PROTO_DIR is not set}"
: "${LIST_DIR:?LIST_DIR is not set}"
: "${SUBJECT_LIST:?SUBJECT_LIST is not set}"
: "${VOI_CTX:?VOI_CTX is not set}"
: "${VOI_WC:?VOI_WC is not set}"

############################################
# Output layout
############################################
OUT_DIR="${PROTO_DIR}/Centiloid_B_WC"
PER_SUB_DIR="${OUT_DIR}/per_subject"
mkdir -p "${OUT_DIR}" "${PER_SUB_DIR}"

############################################
# Logging helpers
############################################
ts() { date +"%Y-%m-%d %H:%M:%S%z"; }
log() { echo "[$(ts)] [S4B:${SLURM_JOB_ID:-nojob}:${SLURM_ARRAY_TASK_ID:-noarr}] $*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }

############################################
# Read array index & subject row
############################################
idx="${SLURM_ARRAY_TASK_ID:-}"
if [ -z "${idx}" ]; then
  log "ERROR: SLURM_ARRAY_TASK_ID not set"
  exit 1
fi

line="$(sed -n "$((idx + 1))p" "${SUBJECT_LIST}" || true)"
if [ -z "${line}" ]; then
  log "No row for task ${idx}; exiting cleanly"
  exit 0
fi

IFS=',' read -r subLong tracer pet_rMNI note <<< "${line}"

out_csv="${PER_SUB_DIR}/${subLong}_${tracer}_suvr_wc.csv"
# Use mktemp in same directory for atomicity on NFS
tmp="$(mktemp "${out_csv}.tmp.XXXXXX")"

# Ensure we clean tmp on exit if something weird happens before mv
cleanup_tmp() { rm -f "${tmp}" >/dev/null 2>&1 || true; }
trap cleanup_tmp EXIT

# In case of ANY unhandled error, still emit an output CSV with reason
write_fail_csv() {
  local reason="$1"
  # best-effort write; do not crash if variables are odd
  {
    echo "${subLong:-NA},${tracer:-NA},${pet_rMNI:-NA},NA,NA,NA,${reason}"
  } > "${tmp}" 2>/dev/null || true
  mv -f "${tmp}" "${out_csv}" 2>/dev/null || true
}
trap 'rc=$?; log "UNHANDLED ERROR (rc=${rc}). Writing failure CSV."; write_fail_csv "worker_unhandled_error_rc${rc}"; exit 0' ERR

log "BEGIN subject=${subLong} tracer=${tracer}"
log "pet_rMNI=${pet_rMNI}"
log "VOI_CTX=${VOI_CTX}"
log "VOI_WC=${VOI_WC}"
log "hostname=$(hostname || true) pwd=$(pwd || true)"

############################################
# Make sure FSL/fslstats exists (robust)
############################################
ensure_fsl() {
  if need_cmd fslstats; then
    return 0
  fi

  # If FSLDIR is already set, try PATH update + source config
  if [ -n "${FSLDIR:-}" ]; then
    export PATH="${FSLDIR}/bin:${PATH}"
    # shellcheck disable=SC1090
    if [ -f "${FSLDIR}/etc/fslconf/fsl.sh" ]; then
      # shellcheck disable=SC1090
      source "${FSLDIR}/etc/fslconf/fsl.sh" >/dev/null 2>&1 || true
    fi

    if need_cmd fslstats; then
      return 0
    fi
  fi

  # Try modules if available (or initialize them if missing)
  if ! command -v module >/dev/null 2>&1; then
    if [ -f /usr/share/Modules/init/bash ]; then
      # shellcheck disable=SC1091
      source /usr/share/Modules/init/bash >/dev/null 2>&1 || true
    fi
  fi

  if command -v module >/dev/null 2>&1; then
    module load fsl/5.0.11 >/dev/null 2>&1 || true

    # If module load set FSLDIR, try PATH update + source config
    if [ -n "${FSLDIR:-}" ]; then
      export PATH="${FSLDIR}/bin:${PATH}"
      # shellcheck disable=SC1090
      if [ -f "${FSLDIR}/etc/fslconf/fsl.sh" ]; then
        # shellcheck disable=SC1090
        source "${FSLDIR}/etc/fslconf/fsl.sh" >/dev/null 2>&1 || true
      fi
    fi

    if need_cmd fslstats; then
      return 0
    fi
  fi

  # Last resort: known cluster install
  if [ -x /cbica/software/external/fsl/centos7/5.0.11/bin/fslstats ]; then
    export FSLDIR=/cbica/software/external/fsl/centos7/5.0.11
    export PATH="${FSLDIR}/bin:${PATH}"
    # shellcheck disable=SC1090
    if [ -f "${FSLDIR}/etc/fslconf/fsl.sh" ]; then
      # shellcheck disable=SC1090
      source "${FSLDIR}/etc/fslconf/fsl.sh" >/dev/null 2>&1 || true
    fi
  fi

  need_cmd fslstats
}

if ! ensure_fsl; then
  log "ERROR: fslstats not available after attempts. FSLDIR='${FSLDIR:-}' PATH='${PATH}'"
  write_fail_csv "missing_fslstats"
  exit 0
fi

if ! need_cmd python; then
  log "ERROR: python not available in PATH='${PATH}'"
  write_fail_csv "missing_python"
  exit 0
fi

export FSLOUTPUTTYPE='NIFTI_GZ'

############################################
# Utility funcs
############################################
is_num() { [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]; }

safe_mean_retry() {
  local img="$1" msk="$2"
  local tries=3
  local t=1
  local out="" rc=0 err=""

  while [ $t -le $tries ]; do
    err=""
    out=""
    # capture stderr for debugging; do not let fslstats failure kill worker
    err="$( (fslstats "$img" -n -k "$msk" -M) 2>&1 1>"${tmp}.mean.out" )" || rc=$? || true
    out="$(cat "${tmp}.mean.out" 2>/dev/null || true)"
    rm -f "${tmp}.mean.out" >/dev/null 2>&1 || true

    out="$(echo "$out" | awk '{print $1}')"
    if is_num "$out"; then
      echo "$out"
      return 0
    fi

    log "WARN: fslstats mean attempt ${t}/${tries} failed or non-numeric."
    log "      img='${img}' msk='${msk}' rc='${rc:-0}' out='${out}'"
    if [ -n "${err}" ]; then
      log "      fslstats stderr: ${err}"
    fi
    sleep 1
    t=$((t+1))
  done

  echo "NA"
  return 0
}

calc_suvr_py() {
  local t="$1" r="$2"
  # be explicit, and never let python error abort the worker
  python - "$t" "$r" <<'PY' 2>&1 || true
import sys
try:
    t=float(sys.argv[1])
    r=float(sys.argv[2])
    if r > 0:
        print(f"{t/r:.6f}")
    else:
        print("NA")
except Exception as e:
    # print to stdout as NA to preserve CSV shape; details already in slurm log via bash
    print("NA")
PY
}

############################################
# Main computation
############################################
note_out="OK"

if [ ! -f "${pet_rMNI}" ]; then
  log "PET missing: ${pet_rMNI}"
  echo "${subLong},${tracer},${pet_rMNI},NA,NA,NA,pet_missing" > "${tmp}"
  mv -f "${tmp}" "${out_csv}"
  log "WROTE ${out_csv}"
  exit 0
fi

if [ ! -f "${VOI_CTX}" ]; then
  log "ERROR: VOI_CTX missing: ${VOI_CTX}"
  write_fail_csv "voi_ctx_missing"
  exit 0
fi
if [ ! -f "${VOI_WC}" ]; then
  log "ERROR: VOI_WC missing: ${VOI_WC}"
  write_fail_csv "voi_wc_missing"
  exit 0
fi

mean_ctx="$(safe_mean_retry "${pet_rMNI}" "${VOI_CTX}")"
mean_wc="$(safe_mean_retry "${pet_rMNI}" "${VOI_WC}")"

log "mean_ctx=${mean_ctx} mean_wc=${mean_wc}"

suvr_wc="NA"

if ! is_num "${mean_ctx}"; then
  note_out="mean_ctx_failed"
fi

if ! is_num "${mean_wc}"; then
  note_out="${note_out};ref_wc_bad"
fi

# Only compute SUVR if both means are numeric and WC is positive
if [[ "${note_out}" == OK* ]]; then
  if python - <<PY >/dev/null 2>&1
r=float("${mean_wc}")
import sys
sys.exit(0 if r>0 else 1)
PY
  then
    suvr_wc="$(calc_suvr_py "${mean_ctx}" "${mean_wc}")"
    if ! is_num "${suvr_wc}"; then
      note_out="suvr_calc_failed"
      suvr_wc="NA"
    fi
  else
    note_out="ref_wc_nonpos"
  fi
fi

echo "${subLong},${tracer},${pet_rMNI},${mean_ctx},${mean_wc},${suvr_wc},${note_out}" > "${tmp}"
mv -f "${tmp}" "${out_csv}"
log "WROTE ${out_csv} note=${note_out}"