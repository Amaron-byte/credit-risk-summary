"""Независимая сверка: пересчитывает метрики из CSV на pandas (без SQL)
и сравнивает с reporting.v_metrics / v_breakdown / v_metrics_change.

Запуск (нужен psql в PATH и переменные PGHOST/PGPORT/PGUSER/PGDATABASE):
    python3 tests/reconcile.py
Код выхода 0 — всё сошлось, 1 — есть расхождения.
"""
import io
import subprocess
import sys
from pathlib import Path

from decimal import Decimal, ROUND_HALF_UP

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
TOL_KZT = 0         # суммы считаются в Decimal с тем же округлением, что в Postgres → должны совпасть до копейки
TOL_SHARE = 1e-9    # допуск по долям


def sql(query: str) -> pd.DataFrame:
    out = subprocess.run(["psql", "-X", "--csv", "-c", query],
                         check=True, capture_output=True, text=True).stdout
    return pd.read_csv(io.StringIO(out))


def r2(x: Decimal) -> Decimal:
    return x.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def expected() -> tuple[pd.DataFrame, pd.DataFrame]:
    p = pd.read_csv(ROOT / "data/portfolio.csv", parse_dates=["report_date"],
                    dtype={"principal_outstanding": str})
    fx = pd.read_csv(ROOT / "data/fx.csv", parse_dates=["date"], dtype={"rate_kzt": str})

    p = p.drop_duplicates()
    assert not p.duplicated(["report_date", "loan_id"]).any(), "конфликтующие дубли"

    # курс строго на дату среза (на обе даты он есть — проверяем, а не подбираем)
    fx = fx.rename(columns={"date": "report_date"})
    p = p.merge(fx, on=["report_date", "currency"], how="left")
    p.loc[p.currency == "KZT", "rate_kzt"] = "1"
    assert p.rate_kzt.notna().all(), "нет курса на дату среза"
    # Decimal + ROUND_HALF_UP = поведение numeric round() в Postgres; float дал бы копеечный шум
    p["kzt"] = [r2(Decimal(a) * Decimal(b)) for a, b in zip(p.principal_outstanding, p.rate_kzt)]

    # списание необратимо
    p = p.sort_values(["loan_id", "report_date"])
    p["wo_ever"] = p.groupby("loan_id").written_off.cummax()
    p = p[p.wo_ever == 0].copy()

    npl = (p.days_past_due > 90) | (p.restructured == 1)
    rate = pd.Series(Decimal("0.01"), index=p.index, dtype=object)
    rate[(p.days_past_due >= 31) & (p.days_past_due <= 90)] = Decimal("0.10")
    rate[npl] = Decimal("0.50")
    zero = Decimal(0)
    p["par30_kzt"] = [k if d > 30 else zero for k, d in zip(p.kzt, p.days_past_due)]
    p["par90_kzt"] = [k if d > 90 else zero for k, d in zip(p.kzt, p.days_past_due)]
    p["npl_kzt"] = [k if n else zero for k, n in zip(p.kzt, npl)]
    p["prov_kzt"] = [r2(k * r) for k, r in zip(p.kzt, rate)]

    rows = []
    for d, g in p.groupby("report_date"):
        tot = sum(g.kzt)
        by_group = g.groupby("group_id").kzt.apply(lambda s: sum(s, Decimal(0)))
        top10 = sum(sorted(by_group, reverse=True)[:10])
        rows.append(dict(report_date=d.date().isoformat(), loans=len(g),
                         portfolio_kzt=float(tot),
                         par30=float(sum(g.par30_kzt) / tot), par90=float(sum(g.par90_kzt) / tot),
                         npl=float(sum(g.npl_kzt) / tot), provisions_kzt=float(sum(g.prov_kzt)),
                         top10_concentration=float(top10 / tot)))
    m = pd.DataFrame(rows)

    br = []
    for dim in ["sector", "program"]:
        a = p.groupby(["report_date", dim]).agg(
            portfolio_kzt=("kzt", lambda s: float(sum(s))),
            npl_kzt=("npl_kzt", lambda s: float(sum(s)))).reset_index()
        a["dimension"], a["dim_value"] = dim, a[dim]
        br.append(a[["report_date", "dimension", "dim_value", "portfolio_kzt", "npl_kzt"]])
    b = pd.concat(br)
    b["report_date"] = b.report_date.dt.date.astype(str)
    return m, b


def main() -> int:
    exp_m, exp_b = expected()
    got_m = sql("SELECT report_date, loans, portfolio_kzt, par30, par90, npl, "
                "provisions_kzt, top10_concentration FROM reporting.v_metrics ORDER BY 1")
    got_b = sql("SELECT report_date, dimension, dim_value, portfolio_kzt, npl_kzt "
                "FROM reporting.v_breakdown")
    got_c = sql("SELECT metric, value, prev_value, delta FROM reporting.v_metrics_change "
                "WHERE prev_value IS NOT NULL")

    errors = []
    mm = exp_m.merge(got_m, on="report_date", suffixes=("_exp", "_sql"))
    if len(mm) != len(exp_m):
        errors.append(f"даты не совпали: {list(got_m.report_date)}")
    for col in ["loans", "portfolio_kzt", "provisions_kzt",
                "par30", "par90", "npl", "top10_concentration"]:
        tol = TOL_SHARE if col in {"par30", "par90", "npl", "top10_concentration"} else TOL_KZT
        diff = (mm[f"{col}_exp"] - mm[f"{col}_sql"]).abs().max()
        status = "OK " if diff <= tol else "ERR"
        if diff > tol:
            errors.append(col)
        print(f"{status} v_metrics.{col:<20} max|Δ| = {diff:.3g}")

    bb = exp_b.merge(got_b, on=["report_date", "dimension", "dim_value"], suffixes=("_exp", "_sql"))
    for col in ["portfolio_kzt", "npl_kzt"]:
        diff = (bb[f"{col}_exp"] - bb[f"{col}_sql"]).abs().max()
        ok = diff <= TOL_KZT and len(bb) == len(exp_b) == len(got_b)
        errors += [] if ok else [f"breakdown.{col}"]
        print(f"{'OK ' if ok else 'ERR'} v_breakdown.{col:<18} max|Δ| = {diff:.3g} ({len(bb)} строк)")

    # сумма разрезов = итог
    for dim in ["sector", "program"]:
        s = got_b[got_b.dimension == dim].groupby("report_date").portfolio_kzt.sum()
        diff = (s.values - got_m.set_index("report_date").portfolio_kzt.loc[s.index].values)
        ok = abs(diff).max() <= 0.01  # сумма float из CSV, допуск 1 тиын
        errors += [] if ok else [f"sum {dim}"]
        print(f"{'OK ' if ok else 'ERR'} Σ по {dim:<8} = портфель")

    # изменения: delta = value - prev_value и совпадает с pandas
    e = exp_m.set_index("report_date")
    for _, r in got_c.iterrows():
        if r.metric in e.columns:
            d_exp = e[r.metric].iloc[1] - e[r.metric].iloc[0]
            tol = TOL_SHARE if r.metric in {"par30", "par90", "npl", "top10_concentration"} else 0.01
            ok = abs(d_exp - r.delta) <= tol
            errors += [] if ok else [f"delta {r.metric}"]
            print(f"{'OK ' if ok else 'ERR'} v_metrics_change.{r.metric:<20} Δ = {r.delta:.6g}")

    print("\nИтог:", "всё сошлось" if not errors else f"РАСХОЖДЕНИЯ: {errors}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
