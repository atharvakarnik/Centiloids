#!/usr/bin/env bash
set -euo pipefail

PROJ_DIR="${HOME}/Pipelines/Centiloids"
SRC_ROOTS=(${PROJ_DIR}/Data/NIFTIs_from_FBP/Elder_MRI ${PROJ_DIR}/Data/NIFTIs_from_FBP/Young_MRI)
DST_ROOT="${PROJ_DIR}/Data/Validation_FBP/ReOrientedLPS"

export FSLOUTPUTTYPE='NIFTI_GZ'

hdr_block() {
  # Print the key header info we care about (orients + both matrices)
  local f="$1"
  fslhd "$f" | awk '
    /^qform_code|^sform_code|^qform_[xyz]orient|^sform_[xyz]orient|^qto_xyz:|^sto_xyz:/ {print}
  '
}

is_form_known() {
  local form="$1" f="$2"
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

is_LPS() {
  local f="$1"
  fslhd "$f" | awk '
    /^sform_xorient/ {x=$2}
    /^sform_yorient/ {y=$2}
    /^sform_zorient/ {z=$2}
    END{exit(!(x=="Right-to-Left" && y=="Anterior-to-Posterior" && z=="Inferior-to-Superior"))}'
}

for root in "${SRC_ROOTS[@]}"; do
  for d in "$root"/*; do
    [[ -d "$d" ]] || continue
    id="${d##*/}"
    in="$(ls "$d"/*.nii.gz 2>/dev/null | head -n1)" || continue

    out_dir="$DST_ROOT/$id"
    out="$out_dir/${id}_T1_LPS.nii.gz"
    mkdir -p "$out_dir"

    q_known=0; s_known=0
    is_form_known q "$in" && q_known=1 || true
    is_form_known s "$in" && s_known=1 || true

    if [[ $q_known -eq 1 && $s_known -eq 0 ]]; then
      echo "[$id] Copying qform → sform (before):"
      hdr_block "$in" | awk '/^qform_code|^qform_[xyz]orient|^qto_xyz:/{print}'
      fslorient -copyqform2sform "$in"
      echo "[$id] After copy (sform now):"
      hdr_block "$in" | awk '/^sform_code|^sform_[xyz]orient|^sto_xyz:/{print}'
      echo
    elif [[ $q_known -eq 0 && $s_known -eq 1 ]]; then
      echo "[$id] Copying sform → qform (before):"
      hdr_block "$in" | awk '/^sform_code|^sform_[xyz]orient|^sto_xyz:/{print}'
      fslorient -copysform2qform "$in"
      echo "[$id] After copy (qform now):"
      hdr_block "$in" | awk '/^qform_code|^qform_[xyz]orient|^qto_xyz:/{print}'
      echo
    fi

    if is_LPS "$in"; then
      cp -f "$in" "$out"
    else
      echo "[$id] Reorienting to LPS (current sform orientation):"
      fslhd "$in" | awk '/^sform_[xyz]orient/{print}'
      fslswapdim "$in" -x -y z "$out"
      echo "[$id] Reoriented saved to: $out"
      echo
    fi
  done
done