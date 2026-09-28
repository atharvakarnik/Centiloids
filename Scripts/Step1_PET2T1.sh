#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted from GAAIN's vld to DPPOS Dataset     #
# ------------------------------------------------- #
#
# Step1_PET2T1.sh
#
# SLURM array script: one subject (site, sub, subLong) per task.
#
# Input:
#   - PET from Step 0: ${PROTO_DIR}/PET_Preproc/${site}/${sub}/${sub}_${PET_TAG}.nii.gz
#   - T1 (LPS):  ${REORIENT_DIR}/${subLong}/${subLong}_T1_LPS.nii.gz
#   - DLICV mask: ${DLICV_DIR}/${subLong}/${subLong}_T1_LPS_dlicvmask.nii.gz
#
# Output (no site folder):
#   - ${PROTO_DIR}/Registration_PET_to_T1/${subLong}/${subLong}_PET_rT1.nii.gz
#   - ${PROTO_DIR}/Registration_PET_to_T1/${subLong}/${subLong}_PET2T1.mat
#
# Submit via wrapper:
#   bash Step1_wrapper_PET2T1.sh
#
#SBATCH --job-name=PET2T1
#SBATCH --output=Logs/Jun26/PET2T1_%A_%a.log
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G

set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

: "${PROJ_DIR:?PROJ_DIR is not set}"
: "${PROTO_DIR:?PROTO_DIR is not set}"
: "${REORIENT_DIR:?REORIENT_DIR is not set}"
: "${DLICV_DIR:?DLICV_DIR is not set}"
: "${LIST_DIR:?LIST_DIR is not set}"
: "${SUBJECT_LIST:?SUBJECT_LIST is not set}"
: "${PET_TAG:?PET_TAG is not set}"

# Make the batch shell deterministic. Not depending COMPLETELY on the submit shell's PATH.
export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:${PATH}}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

prepend_path() {
    local var="$1" dir="$2" old="${!var-}"
    [[ -d "${dir}" ]] || return 0
    case ":${old}:" in
        *":${dir}:"*) ;;
        *) export "${var}=${dir}${old:+:${old}}" ;;
    esac
}

LMOD_INIT="${LMOD_INIT:-/cubic/software/centos7/lmod/lmod/init/bash}"

# ---------------------------------------------------
# For some reason... module command is not visible...
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
module load gcc/5.2.0
module load ants/2.3.1

export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${SLURM_CPUS_PER_TASK:-1}"
export OMP_PROC_BIND=true
export OMP_PLACES=cores
export FSLOUTPUTTYPE="NIFTI_GZ"

REG_ROOT="${PROTO_DIR}/Registration_PET_to_T1"
mkdir -p "${REG_ROOT}" "${LIST_DIR}"

# ------- CPU Time limit exceeded - debugging -------
# Show inherited CPU-time limit for debugging
echo "ulimit -St before: $(ulimit -St)"
echo "ulimit -Ht before: $(ulimit -Ht)"

# Try to remove inherited CPU-time cap
ulimit -St unlimited 2>/dev/null || true
ulimit -Ht unlimited 2>/dev/null || true

# Show effective limit after reset
echo "ulimit -St after : $(ulimit -St)"
echo "ulimit -Ht after : $(ulimit -Ht)"
# ---------------------------------------------------

# ------- I can't tolerate ANTs not visible to 10% nodes in the same parition! -------
ANTS_ROOT="${ANTS_ROOT:-/cbica/software/external/ants/centos7/2.3.1}"
ANTS_REQUIRED_CMD="antsRegistration"

[[ -x "${ANTS_ROOT}/bin/${ANTS_REQUIRED_CMD}" ]] || {
    echo "ERROR: Expected ANTs executable not found: ${ANTS_ROOT}/bin/${ANTS_REQUIRED_CMD}" >&2
    exit 127
}

export ANTSPATH="${ANTS_ROOT}/bin/"
prepend_path PATH "${ANTS_ROOT}/bin"
prepend_path LD_LIBRARY_PATH "${ANTS_ROOT}/lib"
prepend_path LD_LIBRARY_PATH "${ANTS_ROOT}/ITKv5-install/lib"
hash -r

ANTS_EXE="$(command -v "${ANTS_REQUIRED_CMD}")"
libstdcpp="$(ldd "${ANTS_EXE}" 2>/dev/null | awk '/libstdc\+\+/{print $3; exit}' || true)"

echo "ANTS_EXE           : ${ANTS_EXE}"
echo "libstdc++          : ${libstdcpp:-not_found}"

[[ -n "${libstdcpp:-}" && "${libstdcpp}" != /lib64/* ]] || {
    echo "ERROR: ANTs is using old or unresolved libstdc++: ${libstdcpp:-not_found}" >&2
    exit 126
}

# --------------------------------------------------------------------------------------

# Stage-1 registration logs
SELECTION_CSV="${LIST_DIR}/s1_pet2t1_registration.csv"
MISSING_CSV="${LIST_DIR}/s1_pet2t1_missing.csv"

if [ ! -f "${SELECTION_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,PET_OG,T1,NOTE" > "${SELECTION_CSV}"
fi

if [ ! -f "${MISSING_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,REASON" > "${MISSING_CSV}"
fi

echo "=== Step1: PET->T1 registration (array task) ==="
echo "PROJ_DIR           : ${PROJ_DIR}"
echo "PROTO_DIR          : ${PROTO_DIR}"
echo "REORIENT_DIR       : ${REORIENT_DIR}"
echo "DLICV_DIR          : ${DLICV_DIR}"
echo "REG_ROOT           : ${REG_ROOT}"
echo "SUBJECT_LIST (csv) : ${SUBJECT_LIST}"
echo "SLURM_ARRAY_TASK_ID: ${SLURM_ARRAY_TASK_ID:-not_set}"
echo "================================================"
echo

if [ -z "${SLURM_ARRAY_TASK_ID:-}" ]; then
    echo "ERROR: SLURM_ARRAY_TASK_ID is not set."
    exit 1
fi

if [ ! -f "${SUBJECT_LIST}" ]; then
    echo "ERROR: SUBJECT_LIST not found: ${SUBJECT_LIST}"
    exit 1
fi

idx="${SLURM_ARRAY_TASK_ID}"
line=$(sed -n "$((idx + 1))p" "${SUBJECT_LIST}" || true)

if [ -z "${line}" ]; then
    echo "No subject found for SLURM_ARRAY_TASK_ID=${idx}."
    exit 0
fi

site=$(echo "${line}" | awk '{print $1}')
sub=$(echo  "${line}" | awk '{print $2}')
subLong=$(echo "${line}" | awk '{print $3}')

echo "Array task ${idx} -> SITE=${site}, SUB=${sub}, SUBLONG=${subLong}"

pet_og="${PROTO_DIR}/PET_Preproc/${site}/${sub}/${sub}_${PET_TAG}.nii.gz"
t1_raw="${REORIENT_DIR}/${subLong}/${subLong}_T1_LPS.nii.gz"
dlicv_mask="${DLICV_DIR}/${subLong}/${subLong}_T1_LPS_dlicvmask.nii.gz"
t1_preproc_dir="${PROTO_DIR}/T1_Preproc/${subLong}"
t1_n4="${t1_preproc_dir}/${subLong}_T1_N4.nii.gz"
t1_n4_brain="${t1_preproc_dir}/${subLong}_T1_N4_brain.nii.gz"
t1_preproc_helper="${PROJ_DIR}/Scripts/T1_preprocess_N4.sh"

if [ ! -f "${pet_og}" ]; then
    echo "  [${site}/${sub}/${subLong}] Step 0 PET not found: ${pet_og}"
    echo "${site},${sub},${subLong},no_pet_og" >> "${MISSING_CSV}"
    exit 0
fi

if [ ! -f "${t1_raw}" ]; then
    echo "  [${site}/${sub}/${subLong}] T1 not found: ${t1_raw}"
    echo "${site},${sub},${subLong},no_T1_file" >> "${MISSING_CSV}"
    exit 0
fi

if [ ! -f "${dlicv_mask}" ]; then
    echo "  [${site}/${sub}/${subLong}] Required DLICV mask not found: ${dlicv_mask}"
    echo "${site},${sub},${subLong},no_DLICV_mask" >> "${MISSING_CSV}"
    exit 0
fi

if [ ! -f "${t1_preproc_helper}" ]; then
    echo "  [${site}/${sub}/${subLong}] T1 preprocessing helper not found: ${t1_preproc_helper}"
    echo "${site},${sub},${subLong},no_T1_preprocess_helper" >> "${MISSING_CSV}"
    exit 1
fi

if ! bash "${t1_preproc_helper}" "${t1_raw}" "${dlicv_mask}" "${PROTO_DIR}" "${subLong}"; then
    echo "  [${site}/${sub}/${subLong}] Shared T1 preprocessing failed."
    echo "${site},${sub},${subLong},T1_preprocess_failed" >> "${MISSING_CSV}"
    exit 1
fi

if [ ! -f "${t1_n4}" ] || [ ! -f "${t1_n4_brain}" ]; then
    echo "  [${site}/${sub}/${subLong}] Shared T1 preprocessing outputs are missing."
    echo "${site},${sub},${subLong},T1_preprocess_outputs_missing" >> "${MISSING_CSV}"
    exit 1
fi

out_dir="${REG_ROOT}/${subLong}"
mkdir -p "${out_dir}"

out_pet_rT1="${out_dir}/${subLong}_PET_rT1.nii.gz"
out_mat="${out_dir}/${subLong}_PET2T1.mat"

if [ -f "${out_pet_rT1}" ] && [ -f "${out_mat}" ]; then
    echo "  -> Registered PET and rigid transform already exist; skipping."
    echo "${site},${sub},${subLong},${pet_og},${t1_n4_brain},already_registered" >> "${SELECTION_CSV}"
    exit 0
fi

for cmd in fslstats fslmaths fslval fslroi cluster antsRegistration antsApplyTransforms; do
    command -v "${cmd}" >/dev/null 2>&1 || {
        echo "ERROR: Required command not found: ${cmd}" >&2
        echo "${site},${sub},${subLong},missing_command_${cmd}" >> "${MISSING_CSV}"
        exit 127
    }
done

pet2t1_workdir=""
if [ ! -f "${out_mat}" ]; then
    pet2t1_workdir="${out_dir}/pet2t1_estimation_work"
    mkdir -p "${pet2t1_workdir}"

    pet_thresh_mask="${pet2t1_workdir}/${subLong}_PET_thresh_mask.nii.gz"
    pet_cluster_sizes="${pet2t1_workdir}/${subLong}_PET_cluster_sizes.nii.gz"
    pet_lcc="${pet2t1_workdir}/${subLong}_PET_lcc.nii.gz"
    pet_crop="${pet2t1_workdir}/${subLong}_PET_crop.nii.gz"
    pet_smooth="${pet2t1_workdir}/${subLong}_PET_crop_s1p5.nii.gz"

    pet_p98=$(fslstats "${pet_og}" -P 98)
    if ! awk -v value="${pet_p98}" 'BEGIN { exit !(value + 0 > 0) }'; then
        echo "  !! Invalid PET P98 for ${site}/${sub}/${subLong}: ${pet_p98}"
        echo "${site},${sub},${subLong},invalid_PET_P98" >> "${MISSING_CSV}"
        exit 1
    fi
    pet_threshold=$(awk -v value="${pet_p98}" 'BEGIN { printf "%.12g", 0.02 * value }')

    echo "  -> Building adaptive PET crop (P98=${pet_p98}, threshold=${pet_threshold})..."
    fslmaths "${pet_og}" -thr "${pet_threshold}" -bin "${pet_thresh_mask}"
    cluster --in="${pet_thresh_mask}" --thresh=0.5 --osize="${pet_cluster_sizes}" >/dev/null

    max_cluster_size=$(fslstats "${pet_cluster_sizes}" -R | awk '{print $2}')
    if ! awk -v value="${max_cluster_size}" 'BEGIN { exit !(value + 0 > 0) }'; then
        echo "  !! PET foreground cluster could not be identified."
        echo "${site},${sub},${subLong},PET_crop_no_component" >> "${MISSING_CSV}"
        exit 1
    fi
    fslmaths "${pet_cluster_sizes}" -thr "${max_cluster_size}" -bin "${pet_lcc}"

    read -r bbox_x bbox_nx bbox_y bbox_ny bbox_z bbox_nz <<< "$(fslstats "${pet_lcc}" -w)"
    if [ "${bbox_nx}" -le 0 ] || [ "${bbox_ny}" -le 0 ] || [ "${bbox_nz}" -le 0 ]; then
        echo "  !! Invalid PET foreground bounding box."
        echo "${site},${sub},${subLong},PET_crop_invalid_bbox" >> "${MISSING_CSV}"
        exit 1
    fi

    dim_x=$(fslval "${pet_og}" dim1 | awk '{print int($1)}')
    dim_y=$(fslval "${pet_og}" dim2 | awk '{print int($1)}')
    dim_z=$(fslval "${pet_og}" dim3 | awk '{print int($1)}')
    pix_x=$(fslval "${pet_og}" pixdim1)
    pix_y=$(fslval "${pet_og}" pixdim2)
    pix_z=$(fslval "${pet_og}" pixdim3)

    margin_voxels() {
        awk -v pixdim="$1" 'BEGIN {
            if (pixdim <= 0) exit 1
            value = 30.0 / pixdim
            rounded = int(value)
            if (value > rounded) rounded++
            print rounded
        }'
    }

    expand_axis() {
        local bbox_start="$1" bbox_size="$2" margin="$3" dim="$4"
        local crop_start crop_end
        crop_start=$((bbox_start - margin))
        crop_end=$((bbox_start + bbox_size + margin))
        [ "${crop_start}" -ge 0 ] || crop_start=0
        [ "${crop_end}" -le "${dim}" ] || crop_end="${dim}"
        printf '%d %d\n' "${crop_start}" "$((crop_end - crop_start))"
    }

    margin_x=$(margin_voxels "${pix_x}")
    margin_y=$(margin_voxels "${pix_y}")
    margin_z=$(margin_voxels "${pix_z}")
    read -r crop_x crop_nx <<< "$(expand_axis "${bbox_x}" "${bbox_nx}" "${margin_x}" "${dim_x}")"
    read -r crop_y crop_ny <<< "$(expand_axis "${bbox_y}" "${bbox_ny}" "${margin_y}" "${dim_y}")"
    read -r crop_z crop_nz <<< "$(expand_axis "${bbox_z}" "${bbox_nz}" "${margin_z}" "${dim_z}")"

    fslroi "${pet_og}" "${pet_crop}" \
        "${crop_x}" "${crop_nx}" "${crop_y}" "${crop_ny}" "${crop_z}" "${crop_nz}"
    fslmaths "${pet_crop}" -s 1.5 "${pet_smooth}"

    echo "  -> Estimating rigid PET -> T1 transform..."
    prefix="${pet2t1_workdir}/${subLong}_PET2T1_"
    if ! antsRegistration -d 3 \
      -o ["${prefix}","${prefix}Warped.nii.gz"] \
      --float 1 \
      --winsorize-image-intensities [0.005,0.995] \
      --use-histogram-matching 0 \
      -r ["${t1_n4_brain}","${pet_smooth}",1] \
      -t Rigid[0.1] \
      -m MI["${t1_n4_brain}","${pet_smooth}",1,64,Regular,0.50] \
      -c [1000x500x250x100,1e-6,10] \
      -s 3x2x1x0vox \
      -f 8x4x2x1 \
      -u 1 -z 1; then
        echo "${site},${sub},${subLong},PET2T1_rigid_failed" >> "${MISSING_CSV}"
        exit 1
    fi

    generated_mat="${prefix}0GenericAffine.mat"
    if [ ! -f "${generated_mat}" ]; then
        echo "  !! Rigid transform was not created: ${generated_mat}"
        echo "${site},${sub},${subLong},PET2T1_transform_missing" >> "${MISSING_CSV}"
        exit 1
    fi
    mv -f "${generated_mat}" "${out_mat}"
fi

echo "  -> Applying rigid transform to original canonical PET for QC..."
if ! antsApplyTransforms -d 3 \
    -i "${pet_og}" \
    -r "${t1_n4_brain}" \
    -n Linear \
    -t "${out_mat}" \
    -o "${out_pet_rT1}"; then
    echo "${site},${sub},${subLong},PET_rT1_apply_failed" >> "${MISSING_CSV}"
    exit 1
fi

if [ ! -f "${out_pet_rT1}" ]; then
    echo "${site},${sub},${subLong},PET_rT1_missing" >> "${MISSING_CSV}"
    exit 1
fi

if [ -n "${pet2t1_workdir}" ] && [ -d "${pet2t1_workdir}" ]; then
    rm -rf "${pet2t1_workdir}"
fi

echo "${site},${sub},${subLong},${pet_og},${t1_n4_brain},OK" >> "${SELECTION_CSV}"
echo "  -> Registration complete."

echo
echo "Task ${idx} complete."
