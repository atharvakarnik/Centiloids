#!/usr/bin/env bash
# Shared, idempotent DLICV-masked T1 preprocessing for Steps 1 and 2.

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 RAW_T1 DLICV_MASK PROTO_DIR SUBLONG" >&2
    exit 2
fi

raw_t1="$1"
dlicv_mask="$2"
proto_dir="$3"
subLong="$4"

export FSLOUTPUTTYPE="NIFTI_GZ"

if [ ! -f "${raw_t1}" ]; then
    echo "ERROR: Raw T1 not found: ${raw_t1}" >&2
    exit 1
fi
if [ ! -f "${dlicv_mask}" ]; then
    echo "ERROR: Required DLICV mask not found: ${dlicv_mask}" >&2
    exit 1
fi

for cmd in N4BiasFieldCorrection fslmaths; do
    command -v "${cmd}" >/dev/null 2>&1 || {
        echo "ERROR: Required command not found: ${cmd}" >&2
        exit 127
    }
done

out_dir="${proto_dir}/T1_Preproc/${subLong}"
t1_n4="${out_dir}/${subLong}_T1_N4.nii.gz"
t1_n4_brain="${out_dir}/${subLong}_T1_N4_brain.nii.gz"
mkdir -p "${out_dir}"

if [ -f "${t1_n4}" ] && [ -f "${t1_n4_brain}" ]; then
    echo "T1 preprocessing already complete: ${subLong}"
    exit 0
fi

tmp_dir=$(mktemp -d "${out_dir}/.t1_preproc.XXXXXX")
cleanup() {
    rm -rf "${tmp_dir}"
}
trap cleanup EXIT

if [ ! -f "${t1_n4}" ]; then
    tmp_n4="${tmp_dir}/${subLong}_T1_N4.nii.gz"
    N4BiasFieldCorrection -d 3 \
        -i "${raw_t1}" \
        -x "${dlicv_mask}" \
        -o "${tmp_n4}" \
        -s 4 -b '[180]' -c '[50x50x50x50,0]'

    [ -f "${tmp_n4}" ] || {
        echo "ERROR: N4 output was not created: ${tmp_n4}" >&2
        exit 1
    }
    mv -f "${tmp_n4}" "${t1_n4}"
fi

if [ ! -f "${t1_n4_brain}" ]; then
    tmp_brain="${tmp_dir}/${subLong}_T1_N4_brain.nii.gz"
    fslmaths "${t1_n4}" -mas "${dlicv_mask}" "${tmp_brain}"

    [ -f "${tmp_brain}" ] || {
        echo "ERROR: Brain-masked N4 output was not created: ${tmp_brain}" >&2
        exit 1
    }
    mv -f "${tmp_brain}" "${t1_n4_brain}"
fi

echo "T1_N4       : ${t1_n4}"
echo "T1_N4_brain : ${t1_n4_brain}"
