#!/usr/bin/env bash
#
#
# Self-launching SLURM array job: one array task per *patient top-level directory*
# under the input root. Each task finds all leaf ".../DICOM" folders inside that
# patient directory and runs dcm2niix on each.
#
#
set -euo pipefail

# -----------------------
# User-configurable paths
# -----------------------
DCM2NIIX="${HOME}/Data/dcm2niix/build/bin/dcm2niix"
PROJ_DIR="${HOME}/Pipelines/Centiloids"
XT_GRP="Young_MRI"
INROOT="${PROJ_DIR}/Data/DICOMS_from_FBP/${XT_GRP}"
OUTROOT="${PROJ_DIR}/Data/${XT_GRP}"

# Where to store the generated subject list (stable across reruns)
LISTDIR="${PROJ_DIR}/FBP_ExtScript/${XT_GRP}_slurm_lists"
SUBJLIST="${LISTDIR}/subjects.txt"

# -----------------------
# SLURM directives
# -----------------------
#SBATCH --job-name=${XT_GRP}_FBP_Xtract
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=8G
#SBATCH --time=04:00:00
#SBATCH --output=Logs/%x_%A_%a.log

# -----------------------
# Helpers
# -----------------------
die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# -----------------------
# Preflight checks
# -----------------------
[ -x "$DCM2NIIX" ] || die "dcm2niix not found/executable at: $DCM2NIIX"
[ -d "$INROOT" ]    || die "Input directory does not exist: $INROOT"
mkdir -p "$OUTROOT" "$LISTDIR"

need_cmd find
need_cmd sort
need_cmd wc
need_cmd sed
need_cmd mkdir
need_cmd basename

# -----------------------
# If not running as an array task, generate list and submit array
# -----------------------
if [[ -z "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  # Build list of immediate subdirectories (each treated as one "patient")
  # Only include directories with at least one nested "DICOM" folder.
  tmp="${SUBJLIST}.tmp.$$"
  : > "$tmp"

  while IFS= read -r -d '' subjdir; do
    if find "$subjdir" -type d -name DICOM -print -quit | grep -q .; then
      printf '%s\n' "$subjdir" >> "$tmp"
    fi
  done < <(find "$INROOT" -mindepth 1 -maxdepth 1 -type d -print0)

  sort -u "$tmp" > "$SUBJLIST"
  rm -f "$tmp"

  n=$(wc -l < "$SUBJLIST" | sed 's/[[:space:]]//g')
  [[ "$n" -ge 1 ]] || die "No subjects found under $INROOT that contain a DICOM leaf folder."

  echo "Prepared subject list: $SUBJLIST ($n subjects)"
  echo "Submitting SLURM array: 1-$n"
  sbatch --array=1-"$n" "$0"
  exit 0
fi

# -----------------------
# Array task: process one subject
# -----------------------
module load pigz/2.8

task_id="${SLURM_ARRAY_TASK_ID}"
subjdir="$(sed -n "${task_id}p" "$SUBJLIST")"
[[ -n "$subjdir" ]] || die "Could not read subject path for SLURM_ARRAY_TASK_ID=${task_id} from $SUBJLIST"
[[ -d "$subjdir" ]] || die "Subject directory does not exist: $subjdir"

subj="$(basename "$subjdir")"
outdir="${OUTROOT}/${subj}"
mkdir -p "$outdir"

echo "[$(date)] Task ${task_id}: Subject=${subj}"
echo "Input:  $subjdir"
echo "Output: $outdir"
echo "Using:  $DCM2NIIX"
echo

# Find all DICOM leaf directories inside this subject folder
dicomdirs=()

while IFS= read -r -d '' dcmdir; do
  dicomdirs+=("$dcmdir")
done < <(find "$subjdir" -type d -name DICOM -print0 | sort -z)

if [[ "${#dicomdirs[@]}" -eq 0 ]]; then
  echo "WARNING: No DICOM directories found under subject: $subjdir"
  exit 0
fi

# Run conversion on each DICOM directory found

for dcmdir in "${dicomdirs[@]}"; do
  echo "Converting: $dcmdir"

  "$DCM2NIIX" \
    -z y \
    -b y \
    -ba y \
    -m 2 \
    -o "$outdir" \
    -f "%d_%s_%j" \
    "$dcmdir"

  echo
done

echo "[$(date)] Done: Subject=${subj}"