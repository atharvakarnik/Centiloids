#!/usr/bin/env bash
set -euo pipefail

ROOT="Protocols/Validation_ANTs_SS/PET_Preproc/GAAIN"
OUTCSV="PiB_sform_copied_IDs.csv"

# fresh CSV (header + content)
echo "ID" > "$OUTCSV"

# find "bad" files: any Unknown sform orientation
find "$ROOT" -type f -name "*_PET_5070_synthstrip.nii.gz" -print0 |
while IFS= read -r -d '' f; do
  hdr="$(fslhd "$f" 2>/dev/null)" || { echo "WARN: cannot read header: $f" >&2; continue; }

  echo "$hdr" | awk '
    $1=="sform_xorient" && $2=="Unknown" {bad=1}
    $1=="sform_yorient" && $2=="Unknown" {bad=1}
    $1=="sform_zorient" && $2=="Unknown" {bad=1}
    END{exit bad?0:1}
  ' || continue

  base="$(basename "$f")"
  id="${base%_PET_5070.nii.gz}"

  # Record IDs
  echo "$id" >> "$OUTCSV"

  # Preserve original as copy in same folder (only if not already present)
  backup="$(dirname "$f")/${id}_PET_5070_synthstrip_ogPreserved.nii.gz"
  if [[ ! -f "$backup" ]]; then
    cp -p "$f" "$backup"
  fi

  # Copy qform -> sform in-place on the original file
  fslorient -copyqform2sform "$f"
done

# de-duplicate & sort IDs (keep header)
{ echo "ID"; tail -n +2 "$OUTCSV" | sort -u; } > "${OUTCSV}.tmp" && mv "${OUTCSV}.tmp" "$OUTCSV"

echo "Done."
echo "IDs written to: $OUTCSV"