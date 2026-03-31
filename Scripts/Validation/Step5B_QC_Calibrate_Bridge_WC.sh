#!/usr/bin/env bash
#
# Step5B_QC_Calibrate_Bridge_WC.sh
#
# Approach B:
#  1) Fit FBP -> PiB-equivalent SUVR using SUVR_FBP2PiB_WC
#  2) Fit PiB SUVR -> CL using CL_PiB_WC
#  3) Apply chain to compute CL for FBP: CL = a*(m*SUVR_FBP + c) + b
#
# Inputs:
#   - ${PROJ_DIR}/Lists/FB_Val_B_WC/s4B_suvr_status.csv
#   - ${PROJ_DIR}/Lists/FB_Val_PiB/GAAIN/gaain_reference_scores.csv
#
# Outputs:
#   - ${PROJ_DIR}/Protocols/FB_Val_B_WC/Centiloid_B_WC/s5B_coefficients.csv
#   - ${PROJ_DIR}/Protocols/FB_Val_B_WC/Centiloid_B_WC/s5B_compare_merged.csv
#   - ${PROJ_DIR}/Protocols/FB_Val_B_WC/Centiloid_B_WC/s5B_summary.csv
#
set -euo pipefail

: "${PROJ_DIR:=${HOME}/Pipelines/Centiloids}"

LIST_DIR="${PROJ_DIR}/Lists/2FB_Val_B_WC"
PROTO_DIR="${PROJ_DIR}/Protocols/2FB_Val_B_WC"

REF_CSV="${PROJ_DIR}/Lists/2FB_Val_PiB/GAAIN/FBP_Centiloids_ref.csv"
S4_STATUS="${LIST_DIR}/s4B_suvr_status.csv"

OUT_DIR="${PROTO_DIR}/Centiloid_B_WC"
mkdir -p "${OUT_DIR}"

COEF_CSV="${OUT_DIR}/s5B_coefficients.csv"
MERGED_CSV="${OUT_DIR}/s5B_compare_merged.csv"
SUMMARY_CSV="${OUT_DIR}/s5B_summary.csv"

[ -f "${S4_STATUS}" ] || { echo "ERROR: missing ${S4_STATUS}"; exit 1; }
[ -f "${REF_CSV}" ] || { echo "ERROR: missing ${REF_CSV}"; exit 1; }

python - <<PY
import pandas as pd
import numpy as np

s4 = pd.read_csv("${S4_STATUS}")
ref = pd.read_csv("${REF_CSV}")

# Normalize key
s4["subLong"] = s4["subLong"].astype(str)
ref["subLong"] = ref["subLong"].astype(str)

# Keep OK rows with numeric SUVR_WC
s4_ok = s4[s4["note"].astype(str).str.startswith("OK")].copy()
s4_ok["SUVR_WC"] = pd.to_numeric(s4_ok["SUVR_WC"], errors="coerce")
s4_ok = s4_ok.dropna(subset=["SUVR_WC"])

m = s4_ok.merge(ref, on="subLong", how="inner")

# Helper: linear fit y = p*x + q
def fit_lin(x, y):
    x = np.asarray(x, dtype=float)
    y = np.asarray(y, dtype=float)
    if len(x) < 3:
        return None
    p, q = np.polyfit(x, y, 1)
    yhat = p*x + q
    ss_res = np.sum((y - yhat)**2)
    ss_tot = np.sum((y - np.mean(y))**2) if len(y) > 1 else np.nan
    r2 = 1 - ss_res/ss_tot if ss_tot and ss_tot > 0 else np.nan
    rmse = float(np.sqrt(np.mean((y - yhat)**2)))
    return float(p), float(q), float(r2), float(rmse), int(len(x))

# --- Fit 1: PiB SUVR -> CL_PiB_WC ---
pib = m[m["tracer"].astype(str).str.upper().eq("PIB")].copy()
pib["CL_PiB_WC"] = pd.to_numeric(pib["CL_PiB_WC"], errors="coerce")
pib["SUVR_PiB_WC"] = pd.to_numeric(pib["SUVR_PiB_WC"], errors="coerce")  # ref suvr for diagnostics
pib = pib.dropna(subset=["CL_PiB_WC"])
fit_pib = fit_lin(pib["SUVR_WC"], pib["CL_PiB_WC"])  # using our SUVR_WC as x
if fit_pib is None:
    a=b=r2_pib=rmse_pib=np.nan
    n_pib=len(pib)
else:
    a,b,r2_pib,rmse_pib,n_pib = fit_pib

# --- Fit 2: FBP SUVR -> SUVR_FBP2PiB_WC (bridge) ---
fbp = m[m["tracer"].astype(str).str.upper().eq("FBP")].copy()
fbp["SUVR_FBP2PiB_WC"] = pd.to_numeric(fbp["SUVR_FBP2PiB_WC"], errors="coerce")
fbp["SUVR_FBP_WC"] = pd.to_numeric(fbp["SUVR_FBP_WC"], errors="coerce")  # ref suvr for diagnostics
fbp["CL_FBP_WC"] = pd.to_numeric(fbp["CL_FBP_WC"], errors="coerce")      # for final QC
fbp = fbp.dropna(subset=["SUVR_FBP2PiB_WC"])
fit_bridge = fit_lin(fbp["SUVR_WC"], fbp["SUVR_FBP2PiB_WC"])  # x=our FBP SUVR, y=ref PiB-eq SUVR
if fit_bridge is None:
    m_s=m_i=r2_br=rmse_br=np.nan
    n_br=len(fbp)
else:
    m_s,m_i,r2_br,rmse_br,n_br = fit_bridge

# Save coefficients
coef = pd.DataFrame([
    ["PiB_SUVR_to_CL", a, b, r2_pib, rmse_pib, n_pib],
    ["FBP_to_PiB_eq_SUVR", m_s, m_i, r2_br, rmse_br, n_br],
], columns=["model","slope","intercept","R2","RMSE","n"])
coef.to_csv("${COEF_CSV}", index=False)

# Build merged diagnostics tables
rows=[]

# PiB: predict CL from our SUVR
if fit_pib is not None:
    pib2 = pib.copy()
    pib2["SUVR_ref"] = pib2["SUVR_PiB_WC"]
    pib2["SUVR_diff"] = pib2["SUVR_WC"] - pib2["SUVR_ref"]
    pib2["SUVR_pctdiff"] = np.where(pib2["SUVR_ref"].notna() & (pib2["SUVR_ref"]!=0),
                                    100.0*pib2["SUVR_diff"]/pib2["SUVR_ref"], np.nan)
    pib2["CL_ref"] = pib2["CL_PiB_WC"]
    pib2["CL_pred"] = a*pib2["SUVR_WC"] + b
    pib2["CL_diff"] = pib2["CL_pred"] - pib2["CL_ref"]
    pib2["SUVR_pibeq_pred"] = np.nan
    pib2["SUVR_pibeq_ref"] = np.nan
    pib2["SUVR_pibeq_diff"] = np.nan
    pib2["CL_chain_pred"] = np.nan
    pib2["CL_chain_ref"] = np.nan
    pib2["CL_chain_diff"] = np.nan
    rows.append(pib2)

# FBP: predict PiB-eq SUVR, then CL via PiB mapping
if fit_bridge is not None and fit_pib is not None:
    fbp2 = fbp.copy()
    fbp2["SUVR_ref"] = fbp2["SUVR_FBP_WC"]
    fbp2["SUVR_diff"] = fbp2["SUVR_WC"] - fbp2["SUVR_ref"]
    fbp2["SUVR_pctdiff"] = np.where(fbp2["SUVR_ref"].notna() & (fbp2["SUVR_ref"]!=0),
                                    100.0*fbp2["SUVR_diff"]/fbp2["SUVR_ref"], np.nan)

    # Bridge QC
    fbp2["SUVR_pibeq_ref"] = fbp2["SUVR_FBP2PiB_WC"]
    fbp2["SUVR_pibeq_pred"] = m_s*fbp2["SUVR_WC"] + m_i
    fbp2["SUVR_pibeq_diff"] = fbp2["SUVR_pibeq_pred"] - fbp2["SUVR_pibeq_ref"]

    # Chain CL using PiB mapping
    fbp2["CL_chain_pred"] = a*fbp2["SUVR_pibeq_pred"] + b
    fbp2["CL_chain_ref"] = fbp2["CL_FBP_WC"]  # reference FBP CL for comparison
    fbp2["CL_chain_diff"] = fbp2["CL_chain_pred"] - fbp2["CL_chain_ref"]

    # Also provide direct CL columns (not fitted here; these are chain)
    fbp2["CL_ref"] = fbp2["CL_FBP_WC"]
    fbp2["CL_pred"] = fbp2["CL_chain_pred"]
    fbp2["CL_diff"] = fbp2["CL_chain_diff"]

    rows.append(fbp2)

merged = pd.concat(rows, ignore_index=True) if rows else pd.DataFrame()

keep = [
    "subLong","tracer","Age","Cohort",
    "SUVR_WC","SUVR_ref","SUVR_diff","SUVR_pctdiff",
    "SUVR_pibeq_ref","SUVR_pibeq_pred","SUVR_pibeq_diff",
    "CL_ref","CL_pred","CL_diff",
    "CL_chain_ref","CL_chain_pred","CL_chain_diff",
    "pet_rMNI","note"
]
for c in keep:
    if c not in merged.columns:
        merged[c] = np.nan
merged = merged[keep]
merged.to_csv("${MERGED_CSV}", index=False)

# Summary metrics
def summarize(df, tracer):
    t = df[df["tracer"].astype(str).str.upper().eq(tracer.upper())].copy()
    if len(t)==0:
        return [tracer, 0, np.nan, np.nan, np.nan, np.nan, np.nan, np.nan]
    # CL diffs (for PiB: CL_pred vs CL_PiB_WC; for FBP: chain vs CL_FBP_WC)
    mad_cl = float(t["CL_diff"].abs().mean())
    rmse_cl = float(np.sqrt(np.mean((t["CL_diff"])**2)))
    mad_suvr = float(t["SUVR_pctdiff"].abs().mean(skipna=True))
    # bridge only meaningful for FBP
    mad_bridge = float(t["SUVR_pibeq_diff"].abs().mean(skipna=True))
    rmse_bridge = float(np.sqrt(np.nanmean((t["SUVR_pibeq_diff"])**2))) if t["SUVR_pibeq_diff"].notna().any() else np.nan
    return [tracer, int(len(t)), mad_cl, rmse_cl, mad_suvr, mad_bridge, rmse_bridge, float(t["CL_diff"].abs().median())]

summary = pd.DataFrame([
    summarize(merged, "PiB"),
    summarize(merged, "FBP"),
], columns=[
    "tracer","n_merged",
    "mean_abs_CL_diff","rmse_CL_diff",
    "mean_abs_SUVR_pctdiff",
    "mean_abs_SUVR_pibeq_diff","rmse_SUVR_pibeq_diff",
    "median_abs_CL_diff"
])
summary.to_csv("${SUMMARY_CSV}", index=False)

print("Wrote:", "${COEF_CSV}")
print("Wrote:", "${MERGED_CSV}")
print("Wrote:", "${SUMMARY_CSV}")
print("\nCoefficients:")
print(coef.to_string(index=False))
print("\nSummary:")
print(summary.to_string(index=False))
PY
