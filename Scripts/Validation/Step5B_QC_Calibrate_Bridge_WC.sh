#!/usr/bin/env bash
#
# Step5B_QC_Calibrate_Bridge_WC.sh
#
# Level-3 WC bridge calibration:
#  1) Load fixed Level-2 WC anchor coefficients a,b from
#     Lists/2Validation/Tracer/centiloid_anchor_params_validation.csv
#  2) Fit our FBP SUVR_WC to standard PiB SUVR_WC:
#        SUVR_PiB_pred = m * SUVR_WC + n
#  3) Convert predicted PiB SUVR to CL using the fixed Level-2 anchors:
#        CL_pred = a * SUVR_PiB_pred + b
#  4) Save the direct deployable equation:
#        CL = (a*m) * SUVR_WC + (a*n + b)
#
# Inputs:
#   - ${PROJ_DIR}/Lists/2FB_Val_B_WC/s4B_suvr_status.csv
#   - ${PROJ_DIR}/Lists/2FB_Val_PiB/GAAIN/FBP_Centiloids_ref.csv
#   - ${PROJ_DIR}/Lists/2Validation/Tracer/centiloid_anchor_params_validation.csv
#
# Outputs:
#   - ${PROJ_DIR}/Protocols/2FB_Val_B_WC/Centiloid_B_WC/s5B_coefficients.csv
#   - ${PROJ_DIR}/Protocols/2FB_Val_B_WC/Centiloid_B_WC/s5B_compare_merged.csv
#   - ${PROJ_DIR}/Protocols/2FB_Val_B_WC/Centiloid_B_WC/s5B_summary.csv
#
set -euo pipefail

: "${PROJ_DIR:=${HOME}/Pipelines/Centiloids}"

LIST_DIR="${PROJ_DIR}/Lists/2FB_Val_B_WC"
PROTO_DIR="${PROJ_DIR}/Protocols/2FB_Val_B_WC"

REF_CSV="${PROJ_DIR}/Lists/2FB_Val_PiB/GAAIN/FBP_Centiloids_ref.csv"
S4_STATUS="${LIST_DIR}/s4B_suvr_status.csv"
AB_CSV="${PROJ_DIR}/Lists/2Validation/Tracer/centiloid_anchor_params_validation.csv"

OUT_DIR="${PROTO_DIR}/Centiloid_B_WC"
mkdir -p "${OUT_DIR}"

COEF_CSV="${OUT_DIR}/s5B_coefficients.csv"
MERGED_CSV="${OUT_DIR}/s5B_compare_merged.csv"
SUMMARY_CSV="${OUT_DIR}/s5B_summary.csv"

[ -f "${S4_STATUS}" ] || { echo "ERROR: missing ${S4_STATUS}"; exit 1; }
[ -f "${REF_CSV}" ] || { echo "ERROR: missing ${REF_CSV}"; exit 1; }
[ -f "${AB_CSV}" ] || { echo "ERROR: missing ${AB_CSV}"; exit 1; }

python - <<PY
import pandas as pd
import numpy as np

s4 = pd.read_csv("${S4_STATUS}")
ref = pd.read_csv("${REF_CSV}")
ab = pd.read_csv("${AB_CSV}")

def require_columns(df, required, label):
    missing = [c for c in required if c not in df.columns]
    if missing:
        raise SystemExit(f"{label} missing required columns: {missing}")

require_columns(s4, ["subLong", "tracer", "SUVR_WC", "note"], "S4_STATUS")
require_columns(ref, ["subLong", "SUVR_PiB_WC", "CL_PiB_WC"], "REF_CSV")
require_columns(ab, ["ref_region", "a", "b"], "AB_CSV")

# Normalize keys/labels
s4["subLong"] = s4["subLong"].astype(str).str.strip()
ref["subLong"] = ref["subLong"].astype(str).str.strip()
s4["tracer"] = s4["tracer"].astype(str).str.strip().str.upper()
s4["note"] = s4["note"].astype(str).str.strip()
ab["ref_region"] = ab["ref_region"].astype(str).str.strip().str.upper()

ab_wc = ab[ab["ref_region"].eq("WC")].copy()
if len(ab_wc) != 1:
    raise SystemExit(f"AB_CSV expected exactly 1 WC row, found {len(ab_wc)}")

try:
    a = float(pd.to_numeric(ab_wc.iloc[0]["a"], errors="raise"))
    b = float(pd.to_numeric(ab_wc.iloc[0]["b"], errors="raise"))
except Exception as exc:
    raise SystemExit(f"AB_CSV WC anchor coefficients must be numeric: {exc}")

# Keep OK rows with numeric SUVR_WC
s4_ok = s4[s4["note"].str.startswith("OK")].copy()
s4_ok["SUVR_WC"] = pd.to_numeric(s4_ok["SUVR_WC"], errors="coerce")
s4_ok = s4_ok.dropna(subset=["SUVR_WC"])

m = s4_ok.merge(ref, on="subLong", how="inner")

# Numeric conversions after merge
m["SUVR_PiB_WC"] = pd.to_numeric(m["SUVR_PiB_WC"], errors="coerce")
m["CL_PiB_WC"] = pd.to_numeric(m["CL_PiB_WC"], errors="coerce")
if "SUVR_FBP_WC" in m.columns:
    m["SUVR_FBP_WC"] = pd.to_numeric(m["SUVR_FBP_WC"], errors="coerce")
if "CL_FBP_WC" in m.columns:
    m["CL_FBP_WC"] = pd.to_numeric(m["CL_FBP_WC"], errors="coerce")

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

# PiB rows are QC-only. FBP rows drive the bridge fit.
pib = m[m["tracer"].eq("PIB")].copy()
fbp = m[m["tracer"].eq("FBP")].copy()

fbp_fit = fbp.dropna(subset=["SUVR_WC", "SUVR_PiB_WC"]).copy()
fit_bridge = fit_lin(fbp_fit["SUVR_WC"], fbp_fit["SUVR_PiB_WC"])
if fit_bridge is None:
    raise SystemExit(
        "Bridge fit requires at least 3 FBP rows with OK Step4B status, "
        "numeric SUVR_WC, successful ref merge, and numeric SUVR_PiB_WC"
    )
m_s, m_i, r2_br, rmse_br, n_br = fit_bridge

# Save coefficients
coef = pd.DataFrame([
    ["PiB_SUVR_to_CL", a, b, np.nan, np.nan, np.nan],
    ["FBP_to_PiB_eq_SUVR", m_s, m_i, r2_br, rmse_br, n_br],
    ["FBP_ours_to_CL_direct_WC", a*m_s, a*m_i + b, np.nan, np.nan, np.nan],
], columns=["model","slope","intercept","R2","RMSE","n"])
coef.to_csv("${COEF_CSV}", index=False)

# Build merged diagnostics tables
rows=[]

# PiB: QC only using fixed Level-2 anchors
if len(pib) > 0:
    pib2 = pib.copy()
    pib2["SUVR_ref"] = pib2["SUVR_PiB_WC"]
    pib2["SUVR_diff"] = pib2["SUVR_WC"] - pib2["SUVR_ref"]
    pib2["SUVR_pctdiff"] = np.where(
        pib2["SUVR_ref"].notna() & (pib2["SUVR_ref"] != 0),
        100.0 * pib2["SUVR_diff"] / pib2["SUVR_ref"],
        np.nan,
    )
    pib2["CL_ref"] = pib2["CL_PiB_WC"]
    pib2["CL_pred"] = a * pib2["SUVR_WC"] + b
    pib2["CL_diff"] = pib2["CL_pred"] - pib2["CL_ref"]
    pib2["SUVR_pibeq_pred"] = np.nan
    pib2["SUVR_pibeq_ref"] = np.nan
    pib2["SUVR_pibeq_diff"] = np.nan
    pib2["CL_chain_pred"] = np.nan
    pib2["CL_chain_ref"] = np.nan
    pib2["CL_chain_diff"] = np.nan
    rows.append(pib2)

# FBP: bridge to standard PiB SUVR, then chain to CL using fixed anchors
if len(fbp) > 0:
    fbp2 = fbp.copy()
    if "SUVR_FBP_WC" in fbp2.columns:
        fbp2["SUVR_ref"] = fbp2["SUVR_FBP_WC"]
        fbp2["SUVR_diff"] = fbp2["SUVR_WC"] - fbp2["SUVR_ref"]
        fbp2["SUVR_pctdiff"] = np.where(
            fbp2["SUVR_ref"].notna() & (fbp2["SUVR_ref"] != 0),
            100.0 * fbp2["SUVR_diff"] / fbp2["SUVR_ref"],
            np.nan,
        )
    else:
        fbp2["SUVR_ref"] = np.nan
        fbp2["SUVR_diff"] = np.nan
        fbp2["SUVR_pctdiff"] = np.nan

    # Primary bridge evaluation target is standard PiB SUVR, not auxiliary FBP-side SUVR.
    fbp2["SUVR_pibeq_ref"] = fbp2["SUVR_PiB_WC"]
    fbp2["SUVR_pibeq_pred"] = m_s * fbp2["SUVR_WC"] + m_i
    fbp2["SUVR_pibeq_diff"] = fbp2["SUVR_pibeq_pred"] - fbp2["SUVR_pibeq_ref"]

    # Primary CL evaluation target is PiB-standard CL, not auxiliary FBP-side CL.
    fbp2["CL_chain_pred"] = a * fbp2["SUVR_pibeq_pred"] + b
    fbp2["CL_chain_ref"] = fbp2["CL_PiB_WC"]
    fbp2["CL_chain_diff"] = fbp2["CL_chain_pred"] - fbp2["CL_chain_ref"]
    fbp2["CL_ref"] = fbp2["CL_PiB_WC"]
    fbp2["CL_pred"] = fbp2["CL_chain_pred"]
    fbp2["CL_diff"] = fbp2["CL_pred"] - fbp2["CL_ref"]
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
    if len(t) == 0:
        return [tracer, 0, np.nan, np.nan, np.nan, np.nan, np.nan, np.nan]
    cl_diff = pd.to_numeric(t["CL_diff"], errors="coerce")
    suvr_pctdiff = pd.to_numeric(t["SUVR_pctdiff"], errors="coerce")
    suvr_pibeq_diff = pd.to_numeric(t["SUVR_pibeq_diff"], errors="coerce")
    mad_cl = float(cl_diff.abs().mean()) if cl_diff.notna().any() else np.nan
    rmse_cl = float(np.sqrt((cl_diff ** 2).mean())) if cl_diff.notna().any() else np.nan
    mad_suvr = float(suvr_pctdiff.abs().mean()) if suvr_pctdiff.notna().any() else np.nan
    mad_bridge = float(suvr_pibeq_diff.abs().mean()) if suvr_pibeq_diff.notna().any() else np.nan
    rmse_bridge = float(np.sqrt((suvr_pibeq_diff ** 2).mean())) if suvr_pibeq_diff.notna().any() else np.nan
    med_cl = float(cl_diff.abs().median()) if cl_diff.notna().any() else np.nan
    return [tracer, int(len(t)), mad_cl, rmse_cl, mad_suvr, mad_bridge, rmse_bridge, med_cl]

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
