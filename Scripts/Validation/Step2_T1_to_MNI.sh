#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted to GAAIN's dataset for validation     #
# ------------------------------------------------- #
#
# Step2_T1_to_MNI.sh
#
# SLURM array script: one subject (site, sub, subLong) per task.
#
# Input:
#   - T1: ${REORIENT_DIR}/${subLong}/${subLong}_T1_LPS.nii.gz
#   - Optional mask: ${DLICV_DIR}/${subLong}_T1_LPS_dlicvmask.nii.gz
#   - Template: ${MNI_TEMPLATE}
#
# Output in ${PROTO_DIR}/Registration_T1_to_MNI/${subLong}/:
#   - ${subLong}_T1_rMNI.nii.gz     (T1 in MNI space)
#   - ${subLong}_MNI_rT1.nii.gz     (MNI in T1 space)
#   - ${subLong}_T1_rMNI_0GenericAffine.mat
#   - ${subLong}_T1_rMNI_1Warp.nii.gz
#   - ${subLong}_T1_rMNI_1InverseWarp.nii.gz
#
# Submit via wrapper:
#   bash Step2_wrapper_T1_to_MNI.sh
#
#SBATCH --propagate=NONE
#SBATCH --partition=all
#SBATCH --job-name=T1_MNI
#SBATCH --output=Logs/2FB_Val_FBP/T1_MNI_%A_%a.log
#SBATCH --time=6:30:00
#SBATCH --cpus-per-task=8
#SBATCH --mem-per-cpu=6G

set -euo pipefail

: "${PROJ_DIR:?PROJ_DIR is not set}"
: "${PROTO_DIR:?PROTO_DIR is not set}"
: "${REORIENT_DIR:?REORIENT_DIR is not set}"
: "${DLICV_DIR:?DLICV_DIR is not set}"
: "${ATLAS_DIR:?ATLAS_DIR is not set}"
: "${LIST_DIR:?LIST_DIR is not set}"
: "${SUBJECT_LIST:?SUBJECT_LIST is not set}"
: "${MNI_TEMPLATE:?MNI_TEMPLATE is not set}"

: "${T1_MNI_MODE:=Syn}"   # Syn (default) or SPMlike (tissue-prior guided unified-like)

threads="${SLURM_CPUS_PER_TASK:-8}"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${threads}"
export OMP_NUM_THREADS="${threads}"

REG_ROOT="${PROTO_DIR}/Registration_T1_to_MNI"
mkdir -p "${REG_ROOT}" "${LIST_DIR}"

# Stage-2 logs
REG_CSV="${LIST_DIR}/s2_t1mni_registration.csv"
MISS_CSV="${LIST_DIR}/s2_t1mni_missing.csv"

if [ ! -f "${REG_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,T1,MNI_TEMPLATE,MASK_USED,NOTE" > "${REG_CSV}"
fi

if [ ! -f "${MISS_CSV}" ]; then
    echo "SITE,SUB,SUBLONG,REASON" > "${MISS_CSV}"
fi

echo "=== Step2: T1->MNI registration (array task) ==="
echo "T1_MNI_MODE        : ${T1_MNI_MODE}"
echo "Threads            : ${threads}"
echo "PROJ_DIR           : ${PROJ_DIR}"
echo "PROTO_DIR          : ${PROTO_DIR}"
echo "REORIENT_DIR       : ${REORIENT_DIR}"
echo "DLICV_DIR          : ${DLICV_DIR}"
echo "REG_ROOT           : ${REG_ROOT}"
echo "MNI_TEMPLATE       : ${MNI_TEMPLATE}"
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

if [ ! -f "${MNI_TEMPLATE}" ]; then
    echo "ERROR: MNI_TEMPLATE not found at runtime: ${MNI_TEMPLATE}"
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

t1="${REORIENT_DIR}/${subLong}/${subLong}_T1_LPS.nii.gz"
mask="${DLICV_DIR}/${subLong}/${subLong}_T1_LPS_dlicvmask.nii.gz"

if [ ! -f "${t1}" ]; then
    echo "  [${site}/${sub}/${subLong}] T1 not found: ${t1}"
    echo "${site},${sub},${subLong},no_T1_file" >> "${MISS_CSV}"
    exit 0
fi

mask_used="none"
# args_mask=()
# if [ -f "${mask}" ]; then
#     mask_used="dlicv_mask"
#     args_mask=( -x "${mask}" )
# fi
# NOTE: Validation workflow does not use a mask by default; keep block above for future.

out_dir="${REG_ROOT}/${subLong}"
mkdir -p "${out_dir}"

out_t1_mni="${out_dir}/${subLong}_T1_rMNI.nii.gz"
out_mni_t1="${out_dir}/${subLong}_MNI_rT1.nii.gz"
out_prefix="${out_dir}/${subLong}_T1_rMNI_"

# If output exists, skip
if [ -f "${out_t1_mni}" ]; then
    echo "  -> T1_rMNI already exists; skipping."
    echo "${site},${sub},${subLong},${t1},${MNI_TEMPLATE},${mask_used},already_registered" >> "${REG_CSV}"
    exit 0
fi

if [ "${T1_MNI_MODE}" = "Syn" ]; then
    echo "  -> Using antsRegistrationSyN.sh (baseline)"
    echo "     Threads: ${threads}, Mask used: ${mask_used}"
    INIT_MAT="${out_dir}/${subLong}_T1_rMNI_init.mat"

    antsAI \
        -d 3 \
        -m MI["${MNI_TEMPLATE}","${t1}",32,Regular,0.25] \
        -t Rigid[0.1] \
        -s [1,0.015] \
        -g [40,0x40x40] \
        -c [10,1e-6,10] \
        -o "${INIT_MAT}" \
        -v 1

    antsRegistrationSyN.sh \
        -d 3 \
        -f "${MNI_TEMPLATE}" \
        -m "${t1}" \
        -i "${INIT_MAT}" \
        -o "${out_prefix}" \
        -n "${threads}"
        # "${args_mask[@]}"  # enable if you want to constrain with mask

elif [ "${T1_MNI_MODE}" = "SPMlike" ]; then
    echo "  -> Using tissue-prior guided 'unified-like' normalization (FSL priors + Atropos + multi-channel ANTs reg)"

    PRIORS_DIR="${ATLAS_DIR}/TissuePriors/FSL"
    prior_gm="${PRIORS_DIR}/avg152T1_gray.nii.gz"
    prior_wm="${PRIORS_DIR}/avg152T1_white.nii.gz"
    prior_csf="${PRIORS_DIR}/avg152T1_csf.nii.gz"

    for f in "${prior_gm}" "${prior_wm}" "${prior_csf}"; do
        if [ ! -f "${f}" ]; then
            echo "ERROR: Missing tissue prior: ${f}"
            echo "${site},${sub},${subLong},missing_tissue_prior" >> "${MISS_CSV}"
            exit 1
        fi
    done

    work="${out_dir}/unifiedlike_work"
    mkdir -p "${work}"

    t1_n4="${work}/${subLong}_T1_N4.nii.gz"
    echo "    [1/5] N4 bias correction..."
    N4BiasFieldCorrection -d 3 -i "${t1}" -o "${t1_n4}" -v 1

    # Initial low-DOF alignment to pull priors into subject space reliably
    init_prefix="${work}/${subLong}_init_"
    echo "    [2/5] Initial Rigid+Affine (for prior warping)..."
    antsRegistration \
      -d 3 \
      --float 1 \
      --verbose 0 \
      --winsorize-image-intensities [0.005,0.995] \
      --use-histogram-matching 0 \
      -o ["${init_prefix}","${init_prefix}Warped.nii.gz","${init_prefix}InverseWarped.nii.gz"] \
      -r ["${MNI_TEMPLATE}","${t1_n4}",1] \
      -t Rigid[0.1] \
      -m MI["${MNI_TEMPLATE}","${t1_n4}",1,32,Regular,0.25] \
      -c [1000x500x250x100,1e-6,10] \
      -s 3x2x1x0vox -f 8x4x2x1 \
      -t Affine[0.1] \
      -m MI["${MNI_TEMPLATE}","${t1_n4}",1,32,Regular,0.25] \
      -c [1000x500x250x100,1e-6,10] \
      -s 3x2x1x0vox -f 8x4x2x1

    init_aff="${init_prefix}0GenericAffine.mat"
    if [ ! -f "${init_aff}" ]; then
        echo "ERROR: Initial affine missing: ${init_aff}"
        echo "${site},${sub},${subLong},init_affine_missing" >> "${MISS_CSV}"
        exit 1
    fi

    # Warp priors (template space) into subject space using inverse affine
    # Create Atropos prior set as %02d in subject space (01=GM, 02=WM, 03=CSF)
    prior_subj_pat="${work}/${subLong}_prior_subj_%02d.nii.gz"
    echo "    [3/5] Warping priors to subject space..."
    antsApplyTransforms -d 3 -r "${t1_n4}" -i "${prior_gm}"  -o "$(printf "${prior_subj_pat}" 1)" -n Linear -t ["${init_aff}",1]
    antsApplyTransforms -d 3 -r "${t1_n4}" -i "${prior_wm}"  -o "$(printf "${prior_subj_pat}" 2)" -n Linear -t ["${init_aff}",1]
    antsApplyTransforms -d 3 -r "${t1_n4}" -i "${prior_csf}" -o "$(printf "${prior_subj_pat}" 3)" -n Linear -t ["${init_aff}",1]

    # Atropos segmentation with priors -> subject tissue posteriors
    post_pat="${work}/${subLong}_post_%02d.nii.gz"
    seg="${work}/${subLong}_seg.nii.gz"
    echo "    [4/5] Atropos segmentation (GM/WM/CSF posteriors)..."

    # Build a binary mask from the warped priors (operate only where priors indicate brain)
    prior1="$(printf "${prior_subj_pat}" 1)"
    prior2="$(printf "${prior_subj_pat}" 2)"
    prior3="$(printf "${prior_subj_pat}" 3)"

    prior_sum="${work}/${subLong}_prior_sum.nii.gz"
    seg_mask="${work}/${subLong}_atropos_mask.nii.gz"

    ImageMath 3 "${prior_sum}" + "${prior1}" "${prior2}"
    ImageMath 3 "${prior_sum}" + "${prior_sum}" "${prior3}"

    # Threshold: values > 0.20 are "in brain".
    ThresholdImage 3 "${prior_sum}" "${seg_mask}" 0.20 1000 1 0
    
    Atropos -d 3 \
      -a "${t1_n4}" \
      -i "PriorProbabilityImages[3,${prior_subj_pat},0.25]" \
      -x "${seg_mask}" \
      -m "[0.2,1x1x1]" \
      -c "[5,0]" \
      -o ["${seg}","${post_pat}"] \
      -v 1  # 1 only in case of debugging. Set 0 if you care for your drive space :)

    # Now do multi-channel registration: T1 + (GM/WM/CSF) channels
    # fixed: template T1, template priors; moving: subject T1, subject posteriors
    echo "    [5/5] Multi-channel registration (T1 + tissue channels)..."
    antsRegistration \
      -d 3 \
      --float 1 \
      --verbose 1 \
      --winsorize-image-intensities [0.005,0.995] \
      --use-histogram-matching 0 \
      --initial-moving-transform "${init_aff}" \
      -o ["${out_prefix}","${out_prefix}Warped.nii.gz","${out_prefix}InverseWarped.nii.gz"] \
      -r ["${MNI_TEMPLATE}","${t1_n4}",0] \
      -t Rigid[0.1] \
      -m MI["${MNI_TEMPLATE}","${t1_n4}",1,32,Regular,0.25] \
      -c [500x250x100x50,1e-6,10] \
      -s 3x2x1x0vox -f 8x4x2x1 \
      -t Affine[0.1] \
      -m MI["${MNI_TEMPLATE}","${t1_n4}",1,32,Regular,0.25] \
      -c [500x250x100x50,1e-6,10] \
      -s 3x2x1x0vox -f 8x4x2x1 \
      -t SyN[0.05,3,0] \
      -m CC["${MNI_TEMPLATE}","${t1_n4}",1,4] \
      -m CC["${prior_gm}","$(printf "${post_pat}" 1)",0.5,4] \
      -m CC["${prior_wm}","$(printf "${post_pat}" 2)",0.5,4] \
      -m CC["${prior_csf}","$(printf "${post_pat}" 3)",0.5,4] \
      -c [100x70x50x20,1e-6,10] \
      -s 3x2x1x0vox -f 8x4x2x1

else
    echo "ERROR: Unknown T1_MNI_MODE='${T1_MNI_MODE}'. Use 'Syn' or 'SPMlike'."
    exit 1
fi

required_files=(
  "${out_prefix}0GenericAffine.mat"
  "${out_prefix}1Warp.nii.gz"
  "${out_prefix}1InverseWarp.nii.gz"
  "${out_prefix}Warped.nii.gz"
  "${out_prefix}InverseWarped.nii.gz"
)

missing=0
for f in "${required_files[@]}"; do
  if [ ! -f "${f}" ]; then
    echo "  !! Missing expected registration output: ${f}"

    case "${f}" in
      *0GenericAffine.mat)    reason="missing_affine" ;;
      *1Warp.nii.gz)          reason="missing_warp" ;;
      *1InverseWarp.nii.gz)   reason="missing_inversewarp" ;;
      *InverseWarped.nii.gz)  reason="missing_inversewarped" ;;
      *Warped.nii.gz)         reason="missing_warped" ;;
      *)                      reason="missing_output" ;;
    esac

    echo "${site},${sub},${subLong},${reason}" >> "${MISS_CSV}"
    missing=1
  fi
done

if [ "${missing}" -ne 0 ]; then
  echo "ERROR: Missing outputs for ID ${subLong}"   # Better indexing for log file
  exit 1
fi

# Rename/copy outputs to pipeline-stable names (Step 3 compatibility)
cp -f "${out_prefix}Warped.nii.gz"        "${out_t1_mni}"
cp -f "${out_prefix}InverseWarped.nii.gz" "${out_mni_t1}"

echo "${site},${sub},${subLong},${t1},${MNI_TEMPLATE},${mask_used},ok_${T1_MNI_MODE}" >> "${REG_CSV}"
echo "  -> T1->MNI registration complete."
echo
echo "Task ${idx} complete."
