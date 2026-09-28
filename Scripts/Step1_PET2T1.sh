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
#   - T1 from Step 0: ${PROTO_DIR}/T1_Preproc/${subLong}/${subLong}_T1_N4_brain.nii.gz
#
# Output (no site folder):
#   - ${PROTO_DIR}/Registration_PET_to_T1/${subLong}/${subLong}_PET_rT1.nii.gz
#   - ${PROTO_DIR}/Registration_PET_to_T1/${subLong}/${subLong}_PET2T1.mat
#
# Submit via wrapper:
#   bash Step1_wrapper_PET2T1.sh
#
#SBATCH --job-name=PET2T1
#SBATCH --output=Logs/Aug26/PET2T1_%A_%a.log
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G

set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

: "${PROJ_DIR:?PROJ_DIR is not set}"
: "${PROTO_DIR:?PROTO_DIR is not set}"
: "${LIST_DIR:?LIST_DIR is not set}"
: "${SUBJECT_LIST:?SUBJECT_LIST is not set}"
: "${PET_TAG:?PET_TAG is not set}"

# Make the batch shell deterministic. Not depending COMPLETELY on the submit shell's PATH.
ORIG_PATH="${PATH:-}"
export PATH="/usr/local/bin:/usr/bin:/bin${ORIG_PATH:+:${ORIG_PATH}}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

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

MODULE_ROOT="${MODULE_ROOT:-/cbica/share/modules}"
FSL_MODULE="${FSL_MODULE:-fsl/5.0.11}"
GCC_MODULE="${GCC_MODULE:-gcc/5.2.0}"
ANTS_MODULE="${ANTS_MODULE:-ants/2.3.1}"
export FSLDIR="${FSLDIR:-/cbica/software/external/fsl/centos7/5.0.11}"
ANTS_ROOT="${ANTS_ROOT:-/cbica/software/external/ants/centos7/2.3.1}"

module use "${MODULE_ROOT}"
module load "${FSL_MODULE}"
module load "${GCC_MODULE}"
module load "${ANTS_MODULE}"

[[ -d "${FSLDIR}/bin" ]] || {
    echo "ERROR: Expected FSL bin directory not found: ${FSLDIR}/bin" >&2
    exit 127
}

if [[ -r "${FSLDIR}/etc/fslconf/fsl.sh" ]]; then
    set +u
    . "${FSLDIR}/etc/fslconf/fsl.sh"
    set -u
fi

# FSL/module initialization can replace PATH. Rebuild it explicitly using the
# same core and FSL locations used by the production Step-4 worker, with the
# Step-2 ANTs installation first.
export PATH="${ANTS_ROOT}/bin:${FSLDIR}/bin:/usr/local/bin:/usr/bin:/bin${ORIG_PATH:+:${ORIG_PATH}}"
hash -r

for core_cmd in sed awk grep mkdir; do
    command -v "${core_cmd}" >/dev/null 2>&1 || {
        echo "ERROR: Required core command not found after module setup: ${core_cmd}" >&2
        echo "PATH=${PATH}" >&2
        exit 127
    }
done

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

# ------- Pin ANTs and its proven GCC runtime on every compute node -------
ANTS_MODULE_LIB="${ANTS_MODULE_LIB:-/cbica/software/external/ANTs/centos7/2.3.1/lib}"
GCC_ROOT="${GCC_ROOT:-/cbica/software/external/gcc/centos7/5.2.0}"
GCC_LIBSTDCPP="${GCC_LIBSTDCPP:-${GCC_ROOT}/lib64/libstdc++.so.6}"
ANTS_REGISTRATION="${ANTS_ROOT}/bin/antsRegistration"
ANTS_APPLY_TRANSFORMS="${ANTS_ROOT}/bin/antsApplyTransforms"

for ants_exe in "${ANTS_REGISTRATION}" "${ANTS_APPLY_TRANSFORMS}"; do
    [[ -x "${ants_exe}" ]] || {
        echo "ERROR: Expected ANTs executable not found: ${ants_exe}" >&2
        exit 127
    }
done

export ANTSPATH="${ANTS_ROOT}/bin/"

# Put the library ordering observed in a successful Step-2 compute-node log
# first. Keep the module-generated tail because Step 1 additionally uses FSL.
# The gcc/5.2.0 module exposes these runtime libraries but no `gcc` executable.
module_library_path="${LD_LIBRARY_PATH:-}"
proven_ants_library_path="${ANTS_ROOT}/ITKv5-install/lib:${ANTS_ROOT}/lib:${ANTS_MODULE_LIB}:${GCC_ROOT}/lib64:${GCC_ROOT}/lib"
export LD_LIBRARY_PATH="${proven_ants_library_path}${module_library_path:+:${module_library_path}}"

if [[ ! -r "${GCC_LIBSTDCPP}" ]]; then
    echo "ERROR: Proven GCC runtime is not readable: ${GCC_LIBSTDCPP}" >&2
    exit 126
fi
hash -r

echo "MODULE_ROOT        : ${MODULE_ROOT}"
echo "FSL_MODULE         : ${FSL_MODULE}"
echo "GCC_MODULE         : ${GCC_MODULE}"
echo "ANTS_MODULE        : ${ANTS_MODULE}"
echo "ANTS_REGISTRATION  : ${ANTS_REGISTRATION}"
echo "ANTS_APPLY_XFORMS  : ${ANTS_APPLY_TRANSFORMS}"
echo "ANTSPATH           : ${ANTSPATH}"
echo "FSLDIR             : ${FSLDIR}"
echo "PATH               : ${PATH}"
echo "sed                : $(command -v sed)"
echo "awk                : $(command -v awk)"
echo "Expected libstdc++ : ${GCC_LIBSTDCPP}"
echo "LD_LIBRARY_PATH    : ${LD_LIBRARY_PATH}"

if command -v ldd >/dev/null 2>&1 && command -v grep >/dev/null 2>&1; then
    ldd_output="$(ldd "${ANTS_REGISTRATION}" 2>&1 || true)"
    libstdcpp="$(awk '/libstdc\+\+/{
        if ($2 == "=>" && $3 ~ /^\//) { print $3; exit }
        if ($1 ~ /^\//) { print $1; exit }
    }' <<< "${ldd_output}")"
    echo "ANTs libstdc++     : ${libstdcpp:-not_found}"

    if [[ -z "${libstdcpp}" || ! -r "${libstdcpp}" ]]; then
        echo "ERROR: Could not resolve libstdc++.so.6 for ${ANTS_REGISTRATION}" >&2
        echo "ldd output:" >&2
        echo "${ldd_output}" >&2
        exit 126
    fi

    if [[ "${libstdcpp}" == /lib64/* ]]; then
        echo "ERROR: ANTs is using old system libstdc++: ${libstdcpp}" >&2
        exit 126
    fi

    if [[ "${libstdcpp}" != "${GCC_LIBSTDCPP}" ]]; then
        echo "ERROR: ANTs resolved an unexpected libstdc++: ${libstdcpp}" >&2
        echo "Expected: ${GCC_LIBSTDCPP}" >&2
        exit 126
    fi

    if ! grep -a -q 'GLIBCXX_3\.4\.20' "${libstdcpp}"; then
        echo "ERROR: ${libstdcpp} lacks GLIBCXX_3.4.20" >&2
        exit 126
    fi
fi

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
t1_preproc_dir="${PROTO_DIR}/T1_Preproc/${subLong}"
t1_n4_brain="${t1_preproc_dir}/${subLong}_T1_N4_brain.nii.gz"

if [ ! -f "${pet_og}" ]; then
    echo "  [${site}/${sub}/${subLong}] Step 0 PET not found: ${pet_og}"
    echo "${site},${sub},${subLong},no_pet_og" >> "${MISSING_CSV}"
    exit 0
fi

if [ ! -f "${t1_n4_brain}" ]; then
    echo "  [${site}/${sub}/${subLong}] Step-0 T1_N4_brain not found: ${t1_n4_brain}"
    echo "${site},${sub},${subLong},no_T1_N4_brain" >> "${MISSING_CSV}"
    exit 0
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

for cmd in fslstats fslmaths fslval fslroi cluster; do
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
    if ! "${ANTS_REGISTRATION}" -d 3 \
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
if ! "${ANTS_APPLY_TRANSFORMS}" -d 3 \
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
