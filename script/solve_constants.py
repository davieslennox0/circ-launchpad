"""Solve Circ curve constants exactly (integer wei). Run: python3 script/solve_constants.py
Targets (user, 2026-10-29): launch MC $4,000, graduation MC $69,000, MC = price x 1B, curveSupply + lpTokens == 1e27.
Prices are recon-time (RECON.md section 4). Graduation MC is prioritised; launch MC is reported."""
from decimal import Decimal as D, getcontext
getcontext().prec = 80
TOTAL = 10**27
LAUNCH_MC, GRAD_MC = D(4000), D(69000)
QUOTES = {"WOKB": (D("113.2322547"), 18), "BEM": (D("21.8777713"), 8)}

ratio = GRAD_MC / LAUNCH_MC                 # P_end / P0 = (vT0 / T_end)^2
vT0 = int((D(TOTAL) * ratio / (ratio - 1)).to_integral_value())
T_end = int((D(vT0) / ratio.sqrt()).to_integral_value())
curve = vT0 - T_end
lp = TOTAL - curve
ideal_lp = D(T_end) - D(T_end) ** 2 / D(vT0)  # R * T_end / Q_end, independent of vQuote0
print(f"vToken0     = {vT0}\ncurveSupply = {curve}\nlpTokens    = {lp}\n  ideal lp - lp = {ideal_lp - lp:.3f} wei")
for name, (usd, dec) in QUOTES.items():
    p_end_raw = GRAD_MC / D(10**9) / usd * D(10**dec) / D(10**18)   # quote-wei per token-wei
    vQ0 = int((p_end_raw * D(T_end) ** 2 / D(vT0)).to_integral_value())
    q_end = D(vQ0) * D(vT0) / D(T_end)
    R = q_end - vQ0
    unit = D(10**dec)
    mc = lambda q, t: q / t * D(10**18) / unit * usd * D(10**9)
    print(f"{name}: vQuote0 = {vQ0}  ({D(vQ0)/unit:.6f})  R = {R/unit:.6f} (${R/unit*usd:,.2f})"
          f"  launchMC ${mc(D(vQ0), D(vT0)):,.2f}  gradMC ${mc(q_end, D(T_end)):,.2f}")
