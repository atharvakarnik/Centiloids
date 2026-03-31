#!/usr/bin/env bash
# DynamicPET_aggregator.sh
#
# Input:
#   ${PROJ_DIR}/Data/NIFTIs_from_FBP/{Elder,Young}_{PiB,FBP}/${subLong}/*.nii.gz (+json)
# Output:
#   ${PROJ_DIR}/Data/Validation_FBP/${PET_GRP}/${subLong}/${subLong}_${PET_GRP}.nii.gz
#
# This script ONLY aggregates to 4D when needed. No motion correction / mean.

set -euo pipefail
shopt -s nullglob

PROJ_DIR="${HOME}/Pipelines/Centiloids"

IN_ROOT="${PROJ_DIR}/Data/NIFTIs_from_FBP"
OUT_ROOT="${PROJ_DIR}/Data/Validation_FBP"
LOG_DIR="${PROJ_DIR}/Lists/Validation_FBP"
mkdir -p "${OUT_ROOT}" "${LOG_DIR}"

LOG_OK="${LOG_DIR}/dyn_agg_ok.csv"
LOG_BAD="${LOG_DIR}/dyn_agg_bad.csv"

export FSLOUTPUTTYPE='NIFTI_GZ'

if [ ! -f "${LOG_OK}" ]; then
  echo "PET_GRP,SUBLONG,MODE,N_INPUTS,OUT_NII,NOTE" > "${LOG_OK}"
fi
if [ ! -f "${LOG_BAD}" ]; then
  echo "PET_GRP,SUBLONG,REASON" > "${LOG_BAD}"
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1"; exit 1; }; }
need_cmd fslnvols
need_cmd fslmerge
need_cmd python

# Python helper: sort nii list using JSON if present (AcquisitionTime / SeriesTime / InstanceNumber),
# else fallback to filename.
py_sort='
import json, os, re, sys

paths = sys.argv[1:]

def json_for_nii(p):
    # Get JSON
    if p.endswith(".nii.gz"):
        return p[:-7] + ".json"
    return os.path.splitext(p)[0] + ".json"

def parse_acq_time(s):
    """
    Parse "HH:MM:SS.ffffff" (or similar) into microseconds since midnight.
    Returns integer or None.
    """
    if not s:
        return None
    try:
        s = str(s).strip()

        # Case: "HH:MM:SS.ffffff"
        if ":" in s:
            hh, mm, rest = s.split(":")
            if "." in rest:
                ss, frac = rest.split(".", 1)
                us = int((frac + "000000")[:6])
            else:
                ss = rest
                us = 0
            hh = int(hh)
            mm = int(mm)
            ss = int(ss)
            return ((hh*3600 + mm*60 + ss) * 1_000_000) + us

        # Case: "HHMMSS.ffffff" or "HHMMSS"
        m = re.match(r"^(\d{2})(\d{2})(\d{2})(\.\d+)?$", s)
        if m:
            hh = int(m.group(1))
            mm = int(m.group(2))
            ss = int(m.group(3))
            frac = m.group(4)
            us = int((frac[1:] + "000000")[:6]) if frac else 0
            return ((hh*3600 + mm*60 + ss) * 1_000_000) + us

    except Exception:
        pass

    return None


meta = []

for p in paths:
    j = json_for_nii(p)
    acq_us = None

    if os.path.exists(j):
        try:
            with open(j, "r") as f:
                d = json.load(f)
            if "AcquisitionTime" in d:
                acq_us = parse_acq_time(d.get("AcquisitionTime"))
        except Exception:
            pass

    # Fallback numeric token from filename (only if AcquisitionTime missing)
    bn = os.path.basename(p)
    nums = re.findall(r"\d+", bn)
    fallback_num = int(nums[0]) if nums else 10**12

    meta.append((p, acq_us, fallback_num, bn))

# Sort priority:
# 1) AcquisitionTime (if available)
# 2) filename numeric fallback
# 3) basename (stable fallback)
def sort_key(m):
    p, acq_us, fallback_num, bn = m
    acq_key = acq_us if acq_us is not None else 10**18
    return (acq_key, fallback_num, bn)

meta_sorted = sorted(meta, key=sort_key)

for m in meta_sorted:
    print(m[0])
'

for PET_GRP in Elder_PiB Elder_FBP Young_PiB Young_FBP; do
  in_grp="${IN_ROOT}/${PET_GRP}"
  [ -d "${in_grp}" ] || { echo "WARN: missing ${in_grp}, skipping"; continue; }

  for sub_dir in "${in_grp}"/*; do
    [ -d "${sub_dir}" ] || continue
    subLong="$(basename "${sub_dir}")"

    nii_list=( "${sub_dir}"/*.nii.gz )
    if [ ${#nii_list[@]} -eq 0 ]; then
      echo "${PET_GRP},${subLong},no_nii_found" >> "${LOG_BAD}"
      continue
    fi

    out_dir="${OUT_ROOT}/${PET_GRP}/${subLong}"
    mkdir -p "${out_dir}"
    out_nii="${out_dir}/${subLong}_${PET_GRP}.nii.gz"

    # If output exists, skip (idempotent)
    if [ -f "${out_nii}" ]; then
      echo "${PET_GRP},${subLong},already_done,${#nii_list[@]},${out_nii},exists" >> "${LOG_OK}"
      continue
    fi

    if [ ${#nii_list[@]} -eq 1 ]; then
      nvol=$(fslnvols "${nii_list[0]}" 2>/dev/null || echo 0)
      if [ "${nvol}" -gt 1 ]; then
        cp -f "${nii_list[0]}" "${out_nii}"
        echo "${PET_GRP},${subLong},already_4D,1,${out_nii},copied" >> "${LOG_OK}"
      else
        # single 3D file; still write it (downstream can treat as static)
        cp -f "${nii_list[0]}" "${out_nii}"
        echo "${PET_GRP},${subLong},single_3D,1,${out_nii},copied" >> "${LOG_OK}"
      fi
      continue
    fi

    # Multiple nii.gz: decide whether we need to merge
    # If any file is already 4D, prefer the first 4D and ignore others (safer than mixing series)
    chosen_4d=""
    for f in "${nii_list[@]}"; do
      nvol=$(fslnvols "${f}" 2>/dev/null || echo 0)
      if [ "${nvol}" -gt 1 ]; then
        chosen_4d="${f}"
        break
      fi
    done

    if [ -n "${chosen_4d}" ]; then
      cp -f "${chosen_4d}" "${out_nii}"
      echo "${PET_GRP},${subLong},picked_existing_4D,${#nii_list[@]},${out_nii},used_existing_4D" >> "${LOG_OK}"
      continue
    fi

    # All are 3D: sort and merge
    sorted=$(python - <<PY ${nii_list[@]}
${py_sort}
PY
)
    mapfile -t sorted_list < <(printf "%s\n" "${sorted}" | sed '/^$/d')

    if [ ${#sorted_list[@]} -lt 2 ]; then
      echo "${PET_GRP},${subLong},merge_failed_insufficient_sorted" >> "${LOG_BAD}"
      continue
    fi

    # Write to a clean temp name in the same directory, then atomically move into place
    tmp="${out_dir}/${subLong}_${PET_GRP}.tmp.nii.gz"
    rm -f "${tmp}"

    if ! fslmerge -t "${tmp}" "${sorted_list[@]}"; then
    echo "${PET_GRP},${subLong},fslmerge_failed" >> "${LOG_BAD}"
    rm -f "${tmp}"
    continue
    fi

    if [ ! -f "${tmp}" ]; then
    echo "${PET_GRP},${subLong},fslmerge_no_output_tmp_missing" >> "${LOG_BAD}"
    continue
    fi

    mv -f "${tmp}" "${out_nii}"
    echo "${PET_GRP},${subLong},merged_3D_to_4D,${#sorted_list[@]},${out_nii},fslmerge" >> "${LOG_OK}"
  done
done

echo "Done. OK log: ${LOG_OK} ; BAD log: ${LOG_BAD}"