#!/usr/bin/env bash
set -euo pipefail

# PET_reorient_validate.sh
#
# Usage:
#   PET_reorient_validate.sh IN_NII OUT_NII
#
# What it does:
#   1) Ensure qform/sform consistency: if only one is valid, copy it to the other
#      (header-only edit on the input file.
#   2) Reorient to FSL "standard" orientation using fslreorient2std (writes OUT_NII).
#   3) Replace NaNs with 0 (prevents propagation into SUVR computations).
#   4) Fail-fast sanity checks: positive dims/pixdims and finite intensity range.

IN_NII="${1:?IN_NII required}"
OUT_NII="${2:?OUT_NII required}"

export FSLOUTPUTTYPE='NIFTI_GZ'

# ---- helpers ----

is_form_known() {
  # Returns 0 if form (q or s) is known, else 1.
  local form="$1"
  local f="$2"
  fslhd "$f" | awk -v F="$form" '
    BEGIN{code=0; xo="Unknown"; yo="Unknown"; zo="Unknown"}
    F=="q" && /^qform_code/    {code=$2}
    F=="q" && /^qform_xorient/ {xo=$2}
    F=="q" && /^qform_yorient/ {yo=$2}
    F=="q" && /^qform_zorient/ {zo=$2}
    F=="s" && /^sform_code/    {code=$2}
    F=="s" && /^sform_xorient/ {xo=$2}
    F=="s" && /^sform_yorient/ {yo=$2}
    F=="s" && /^sform_zorient/ {zo=$2}
    END{exit(!(code>0 && xo!="Unknown" && yo!="Unknown" && zo!="Unknown"))}'
}

basic_sanity() {
  local f="$1"

  # Check dims/pixdims are positive
  fslhd "$f" | awk '
    /^dim[1-3]/    {if ($2<=0) bad=1}
    /^pixdim[1-3]/ {if ($2<=0) bad=1}
    END{exit(bad?1:0)}' || {
      echo "[ERROR] Bad geometry (non-positive dim/pixdim) in: $f" >&2
      return 2
    }

  # Check intensity range is finite (not NaN)
  local r
  r="$(fslstats "$f" -R 2>/dev/null || true)"
  if [[ -z "$r" ]] || [[ "$r" == *nan* ]] || [[ "$r" == *NaN* ]]; then
    echo "[ERROR] Non-finite intensity range (NaN) in: $f" >&2
    return 3
  fi
}

# ---- main ----

# Input exists?
if [[ ! -f "$IN_NII" ]]; then
  echo "[ERROR] Input file not found: $IN_NII" >&2
  exit 1
fi

# Ensure output directory exists
mkdir -p "$(dirname "$OUT_NII")"

# 1) Fix header consistency on input (header-only in-place edit)
q_known=0; s_known=0
is_form_known q "$IN_NII" && q_known=1 || true
is_form_known s "$IN_NII" && s_known=1 || true

if [[ $q_known -eq 1 && $s_known -eq 0 ]]; then
  fslorient -copyqform2sform "$IN_NII"
elif [[ $q_known -eq 0 && $s_known -eq 1 ]]; then
  fslorient -copysform2qform "$IN_NII"
fi

# 2) Reorient to standard LAS (since our FSLDIR's MNI template is LAS)
fslreorient2std "$IN_NII" "$OUT_NII"

# 3) Remove NaNs (in-place on output)
fslmaths "$OUT_NII" -nan "$OUT_NII"

# 4) Sanity check output
basic_sanity "$OUT_NII"