#!/bin/sh
#
# Step5_QC_compare_GAAIN.sh
#
# Compares our validation outputs (Step4) vs GAAIN reference scores.
# Produces:
#   - summary QC metrics per reference region (CG/WC/WC_B/Pons)
#   - merged per-subject table for debugging
#
# Usage:
#   bash Step5_QC_compare_GAAIN.sh
#
set -euo pipefail

PROJ_DIR="${PROJ_DIR:-${HOME}/Pipelines/Centiloids}"
LIST_DIR="${LIST_DIR:-${PROJ_DIR}/Lists/4Validation}"
PROTO_DIR="${PROTO_DIR:-${PROJ_DIR}/Protocols/4Validation}"

OURS_CSV="${OURS_CSV:-${LIST_DIR}/s4_suvrcl_status.csv}"
REF_CSV="${REF_CSV:-${LIST_DIR}/GAAIN/gaain_reference_scores.csv}"

OUT_DIR="${OUT_DIR:-${PROTO_DIR}/Centiloid_metrics}"
OUT_SUMMARY="${OUT_SUMMARY:-${OUT_DIR}/s5_QC_compare_gaain_summary.csv}"
OUT_MERGED="${OUT_MERGED:-${OUT_DIR}/s5_QC_compare_gaain_merged.csv}"

mkdir -p "${OUT_DIR}"

echo "=== Step5 QC Compare (GAAIN) ==="
echo "OURS_CSV    : ${OURS_CSV}"
echo "REF_CSV     : ${REF_CSV}"
echo "OUT_SUMMARY : ${OUT_SUMMARY}"
echo "OUT_MERGED  : ${OUT_MERGED}"
echo "================================"
echo

[ -f "${OURS_CSV}" ] || { echo "ERROR: Missing OURS_CSV: ${OURS_CSV}"; exit 1; }
[ -f "${REF_CSV}" ]  || { echo "ERROR: Missing REF_CSV : ${REF_CSV}"; exit 1; }

# 'module' is the basic command that should've been universally visible :/
if ! command -v module >/dev/null 2>&1; then
    if [ -f $CUBICLOCAL/lmod/lmod/init/bash ]; then
      # shellcheck disable=SC1091
      source $CUBICLOCAL/lmod/lmod/init/bash >/dev/null 2>&1 || true
    fi
fi

module load python/3.11 >/dev/null 2>&1 || {
  echo "WARN: could not module load python/3.11; relying on python in PATH"
}
command -v python >/dev/null 2>&1 || { echo "ERROR: python not found"; exit 1; }

python - "$OURS_CSV" "$REF_CSV" "$OUT_SUMMARY" "$OUT_MERGED" <<'PY'
import sys, numpy as np, pandas as pd

ours_path, ref_path, out_summary, out_merged = sys.argv[1:5]

ours = pd.read_csv(ours_path)
ref  = pd.read_csv(ref_path)

# Required columns
need_ours = {"subLong","group","note","SUVR_CG","SUVR_WC","SUVR_WC_B","SUVR_Pons","CL_CG","CL_WC","CL_WC_B","CL_Pons"}
need_ref  = {"subLong","SUVR_CG","SUVR_WC","SUVR_WC_B","SUVR_Pons","CL_CG","CL_WC","CL_WC_B","CL_Pons"}

missing_o = need_ours - set(ours.columns)
missing_r = need_ref  - set(ref.columns)
if missing_o: raise SystemExit(f"OURS_CSV missing columns: {sorted(missing_o)}")
if missing_r: raise SystemExit(f"REF_CSV missing columns: {sorted(missing_r)}")

ours["subLong"]=ours["subLong"].astype(str).str.strip()
ref["subLong"]=ref["subLong"].astype(str).str.strip()

# Keep OK only
ok = ours[ours["note"].astype(str).str.startswith("OK")].copy()

# Numeric conversion
for c in ["SUVR_CG","SUVR_WC","SUVR_WC_B","SUVR_Pons","CL_CG","CL_WC","CL_WC_B","CL_Pons"]:
    ok[c]=pd.to_numeric(ok[c], errors="coerce")
    ref[c]=pd.to_numeric(ref[c], errors="coerce")

m = ok.merge(ref, on="subLong", how="inner", suffixes=("_ours","_ref"))
# Need group from ours
m["group"]=m["group"].astype(str)

# Drop rows missing region essentials (handled per-region)
m.to_csv(out_merged, index=False)

def linreg(x, y):
    x=np.asarray(x, float); y=np.asarray(y, float)
    if len(x) < 3:
        return (np.nan, np.nan, np.nan)
    slope, intercept = np.polyfit(x, y, 1)
    yhat = slope*x + intercept
    ss_res = float(np.sum((y - yhat)**2))
    ss_tot = float(np.sum((y - y.mean())**2)) if len(y) else float("nan")
    r2 = 1.0 - ss_res/ss_tot if ss_tot > 0 else np.nan
    return (float(slope), float(intercept), float(r2))

rows=[]

regions = [("CG","CerebGry"),("WC","WhlCbl"),("WC_B","WhlCblBrnStm"),("Pons","Pons")]

for reg, _ in regions:
    suvr_o=f"SUVR_{reg}_ours"; suvr_r=f"SUVR_{reg}_ref"
    cl_o=f"CL_{reg}_ours";     cl_r=f"CL_{reg}_ref"

    mm = m.dropna(subset=[suvr_o, suvr_r, cl_o, cl_r, "group"]).copy()
    # Regression our CL vs ref CL
    slope, intercept, r2 = linreg(mm[cl_r], mm[cl_o])
    rows.append(["ALL", reg, "regress_ourCL_vs_refCL", len(mm), slope, intercept, r2, np.nan])

    # Group mean SUVR %diff
    for grp in ["YC0","AD100"]:
        g = mm[mm["group"].eq(grp)]
        if len(g)==0:
            rows.append([grp, reg, "meanSUVR_pctdiff", 0, np.nan, np.nan, np.nan, np.nan])
            continue
        mu_ours=float(g[suvr_o].mean())
        mu_ref=float(g[suvr_r].mean())
        pctdiff=100.0*(mu_ours-mu_ref)/mu_ref if mu_ref!=0 else np.nan
        rows.append([grp, reg, "meanSUVR_pctdiff", len(g), np.nan, np.nan, np.nan, float(pctdiff)])

qc = pd.DataFrame(rows, columns=["scope","ref_region","metric","n","slope","intercept","r2","pctdiff"])

# Doc-style pass/fail flags per region (regression thresholds + meanSUVR thresholds)
def reg_ok(row):
    if pd.isna(row["slope"]) or pd.isna(row["intercept"]) or pd.isna(row["r2"]): return False
    return (0.98 <= row["slope"] <= 1.02) and (-2.0 <= row["intercept"] <= 2.0) and (row["r2"] > 0.98)

def pct_ok(subdf):
    ok=True
    for grp in ["YC0","AD100"]:
        r=subdf[(subdf["scope"]==grp) & (subdf["metric"]=="meanSUVR_pctdiff")]
        if len(r)==1 and pd.notna(r["pctdiff"].iloc[0]):
            ok = ok and (abs(float(r["pctdiff"].iloc[0])) < 2.0)
    return ok

qc["regression_ok"]=False
qc["meanSUVR_ok"]=False

for reg,_ in regions:
    rreg = qc[(qc["scope"]=="ALL") & (qc["ref_region"]==reg) & (qc["metric"]=="regress_ourCL_vs_refCL")]
    ok_r = (len(rreg)==1 and reg_ok(rreg.iloc[0]))
    ok_p = pct_ok(qc[qc["ref_region"]==reg])
    qc.loc[qc["ref_region"]==reg, "regression_ok"] = ok_r
    qc.loc[qc["ref_region"]==reg, "meanSUVR_ok"] = ok_p

qc.to_csv(out_summary, index=False)

print("Wrote:", out_summary)
print("Wrote:", out_merged)
print("\n=== Quick readout (ALL regression rows) ===")
print(qc[(qc["scope"]=="ALL") & (qc["metric"]=="regress_ourCL_vs_refCL")].to_string(index=False))
PY

echo
echo "Done. Outputs:"
echo "  - ${OUT_SUMMARY}"
echo "  - ${OUT_MERGED}"