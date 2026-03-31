#!/usr/bin/env bash
#
# Step5B_ApplyCoefficients.sh
#
# Production Step5 (no validation): apply Approach B coefficients to your cohort.
#
# Inputs:
#  - ${LIST_DIR}/s4B_suvr_status.csv
#  - coefficients CSV (stored in Lists/<DATASET>/Calibration/)
#
set -euo pipefail

: "${PROJ_DIR:=${HOME}/Pipelines/Centiloids}"
: "${DATASET:=2DPPOS_Feb26PET}"

LIST_DIR="${PROJ_DIR}/Lists/${DATASET}"
PROTO_DIR="${PROJ_DIR}/Protocols/${DATASET}"

S4_STATUS="${LIST_DIR}/s4B_suvr_status.csv"
COEF_CSV="${LIST_DIR}/Calibration/centiloid_coefficients_FBP_WC.csv"

OUT_DIR="${PROTO_DIR}/Centiloid_Scores_WC"
mkdir -p "${OUT_DIR}"

OUT_CSV="${OUT_DIR}/s5B_centiloids.csv"

[ -f "${S4_STATUS}" ] || { echo "ERROR: missing ${S4_STATUS}"; exit 1; }
[ -f "${COEF_CSV}" ] || { echo "ERROR: missing ${COEF_CSV}"; exit 1; }

python - <<PY
import pandas as pd
import numpy as np

s4 = pd.read_csv("${S4_STATUS}")
coef = pd.read_csv("${COEF_CSV}")

# Pull coefficients
def get_row(model):
    r = coef[coef["model"].astype(str).str.strip().eq(model)]
    if len(r) != 1:
        raise ValueError(f"Expected exactly 1 row for model={model}, got {len(r)}")
    return r.iloc[0]

r1 = get_row("PiB_SUVR_to_CL")
a = float(r1["slope"]); b = float(r1["intercept"])

r2 = get_row("FBP_to_PiB_eq_SUVR")
m = float(r2["slope"]); c = float(r2["intercept"])

# Clean SUVR
s4["SUVR_WC"] = pd.to_numeric(s4["SUVR_WC"], errors="coerce")
s4["note"] = s4["note"].astype(str)

# Only compute for OK rows with SUVR
ok = s4[s4["note"].str.startswith("OK")].copy()
ok = ok.dropna(subset=["SUVR_WC"])

# Apply Approach B chain
ok["SUVR_pibeq"] = m*ok["SUVR_WC"] + c
ok["CL"] = a*ok["SUVR_pibeq"] + b

# Keep useful columns
keep = ["subLong","tracer","SUVR_WC","SUVR_pibeq","CL","mean_ctx","mean_wc","pet_rMNI","note"]
for col in keep:
    if col not in ok.columns:
        ok[col] = np.nan

# Sort and write
ok = ok[keep].sort_values(["tracer","subLong"])
ok.to_csv("${OUT_CSV}", index=False)

print("Wrote:", "${OUT_CSV}")
print("Applied coefficients:")
print(f"a={a}, b={b}, m={m}, c={c}")
print("\nCL summary:")
print(ok["CL"].describe())
PY