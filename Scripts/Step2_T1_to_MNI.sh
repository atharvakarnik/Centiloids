#!/usr/bin/env bash
#
# ------------------------------------------------- #
#     Adapted from GAAIN's vld to DPPOS Dataset     #
# ------------------------------------------------- #
#
# Step2_T1_to_MNI.sh
#
# SLURM array script: one subject (site, sub, subLong) per task.
#
#SBATCH --propagate=NONE
#SBATCH --partition=all
#SBATCH --job-name=T1_MNI
#SBATCH --output=Logs/2DPPOS_Feb26PET/T1_MNI_%A_%a.log
#SBATCH --time=01:30:00
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

: "${T1_MNI_MODE:=Syn}"   # Syn (default) or SPMlike (now: tissue-prior guided unified-like)

threads="${SLURM_CPUS_PER_TASK:-8}"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${threads}"

REG_ROOT="${PROTO_DIR}/Registration_T1_to_MNI"
mkdir -p "${REG_ROOT}" "${LIST_DIR}"

# Logs
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
echo "MNI_TEMPLATE       : ${MNI_TEMPLATE}"
echo "Threads            : ${threads}"
echo "==============================================="

# Get subject from array index
idx="${SLURM_ARRAY_TASK_ID:-0}"
map_line=$(sed -n "$((idx + 1))p" "${SUBJECT_LIST}" || true)
if [ -z "${map_line}" ]; then
    echo "ERROR: Could not read subject line at index ${idx} from ${SUBJECT_LIST}"
    exit 1
fi

site=$(echo "${map_line}" | awk '{print $1}')
sub=$(echo "${map_line}" | awk '{print $2}')
subLong=$(echo "${map_line}" | awk '{print $3}')

t1="${REORIENT_DIR}/${subLong}/${subLong}_T1_LPS.nii.gz"
if [ ! -f "${t1}" ]; then
    echo "  !! Missing T1 for ${subLong}: ${t1}"
    echo "${site},${sub},${subLong},missing_T1" >> "${MISS_CSV}"
    exit 1
fi

out_dir="${REG_ROOT}/${subLong}"
mkdir -p "${out_dir}"

out_prefix="${out_dir}/${subLong}_T1_rMNI_"

# Expected final outputs (keep compatibility)
out_t1_mni="${out_dir}/${subLong}_T1_rMNI.nii.gz"
out_mni_t1="${out_dir}/${subLong}_MNI_rT1.nii.gz"

echo
echo "Subject: ${site} / ${sub} / ${subLong}"
echo "T1     : ${t1}"
echo "OutDir : ${out_dir}"
echo

# Optional mask (kept for future; not used by default)
mask="${DLICV_DIR}/${subLong}/${subLong}_T1_LPS_dlicvmask.nii.gz"
mask_used="none"
# args_mask=()
# if [ -f "${mask}" ]; then
#     args_mask=(-x "${mask}")
#     mask_used="dlicv_mask"
# fi

if [ "${T1_MNI_MODE}" = "Syn" ]; then
    echo " -> Using antsRegistrationSyN.sh (baseline)"
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
    echo " -> Using tissue-prior guided 'unified-like' normalization (FSL priors + Atropos + multi-channel ANTs)"

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

    init_ai="${work}/${subLong}_init_ai.mat"
    echo "    [2/6] antsAI rigid initialization..."
    antsAI \
      -d 3 \
      -m MI["${MNI_TEMPLATE}","${t1_n4}",32,Regular,0.25] \
      -t Rigid[0.1] \
      -s [1,0.015] \
      -g [40,0x40x40] \
      -c [10,1e-6,10] \
      -o "${init_ai}" \
      -v 1

    # Initial low-DOF alignment to pull priors into subject space reliably
    init_prefix="${work}/${subLong}_init_"
    echo "    [3/6] Initial Rigid+Affine (for prior warping)..."
    antsRegistration \
      -d 3 \
      --float 1 \
      --verbose 0 \
      --winsorize-image-intensities [0.005,0.995] \
      --use-histogram-matching 0 \
      --initial-moving-transform "${init_ai}" \
      -o ["${init_prefix}","${init_prefix}Warped.nii.gz","${init_prefix}InverseWarped.nii.gz"] \
      -r ["${MNI_TEMPLATE}","${t1_n4}",0] \
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
    echo "    [4/6] Warping priors to subject space..."
    antsApplyTransforms -d 3 -r "${t1_n4}" -i "${prior_gm}"  -o "$(printf "${prior_subj_pat}" 1)" -n Linear -t ["${init_aff}",1]
    antsApplyTransforms -d 3 -r "${t1_n4}" -i "${prior_wm}"  -o "$(printf "${prior_subj_pat}" 2)" -n Linear -t ["${init_aff}",1]
    antsApplyTransforms -d 3 -r "${t1_n4}" -i "${prior_csf}" -o "$(printf "${prior_subj_pat}" 3)" -n Linear -t ["${init_aff}",1]

    # Atropos segmentation with priors -> subject tissue posteriors
    post_pat="${work}/${subLong}_post_%02d.nii.gz"
    seg="${work}/${subLong}_seg.nii.gz"
    echo "    [5/6] Atropos segmentation (GM/WM/CSF posteriors)..."

    # Build a robust binary mask from warped priors: (GM + WM + CSF) > thr
    prior1="$(printf "${prior_subj_pat}" 1)"
    prior2="$(printf "${prior_subj_pat}" 2)"
    prior3="$(printf "${prior_subj_pat}" 3)"

    prior_sum="${work}/${subLong}_prior_sum.nii.gz"
    seg_mask="${work}/${subLong}_atropos_mask.nii.gz"

    # Sum priors
    ImageMath 3 "${prior_sum}" + "${prior1}" "${prior2}"
    ImageMath 3 "${prior_sum}" + "${prior_sum}" "${prior3}"

    # Threshold (default 0.20; drop to 0.10 if mask is too small)
    prior_thr=0.20
    ThresholdImage 3 "${prior_sum}" "${seg_mask}" "${prior_thr}" 1000 1 0

    Atropos -d 3 \
      -a "${t1_n4}" \
      -i "PriorProbabilityImages[3,${prior_subj_pat},0.25]" \
      -x "${seg_mask}" \
      -m "[0.2,1x1x1]" \
      -c "[5,0]" \
      -o ["${seg}","${post_pat}"] \
      -v 1      # Set to 1 for initial fail-fearing debug. Though, set 0 to care for disk space.

    # Now do multi-channel registration: T1 + (GM/WM/CSF) channels
    # fixed: template T1, template priors; moving: subject T1, subject posteriors
    echo "    [6/6] Multi-channel registration (T1 + tissue channels)..."
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

# Sanity check: registration outputs
if [ ! -f "${out_prefix}Warped.nii.gz" ]; then
    echo "  !! Registration output (Warped) missing for ${subLong}."
    echo "${site},${sub},${subLong},missing_warped" >> "${MISS_CSV}"
    exit 1
fi
if [ ! -f "${out_prefix}InverseWarped.nii.gz" ]; then
    echo "  !! Registration output (InverseWarped) missing for ${subLong}."
    echo "${site},${sub},${subLong},missing_inversewarped" >> "${MISS_CSV}"
    exit 1
fi
if [ ! -f "${out_prefix}0GenericAffine.mat" ]; then
    echo "  !! Registration output (Affine) missing for ${subLong}."
    echo "${site},${sub},${subLong},missing_affine" >> "${MISS_CSV}"
    exit 1
fi

# Rename/link outputs to match expected names
cp -f "${out_prefix}Warped.nii.gz" "${out_t1_mni}"
cp -f "${out_prefix}InverseWarped.nii.gz" "${out_mni_t1}"

echo "${site},${sub},${subLong},${t1},${MNI_TEMPLATE},${mask_used},ok_${T1_MNI_MODE}" >> "${REG_CSV}"

echo "Done: ${subLong}"
echo "  T1_rMNI : ${out_t1_mni}"
echo "  MNI_rT1 : ${out_mni_t1}"
