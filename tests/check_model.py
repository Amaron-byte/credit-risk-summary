"""Проверяет, что семантическая модель соответствует витрине:
источник существует, каждая колонка есть во вьюхе, типы мер допустимы, имена уникальны.

    python3 tests/check_model.py   (нужны psql, PG* переменные и PyYAML)
"""
import subprocess
import sys
from pathlib import Path

import yaml

m = yaml.safe_load((Path(__file__).resolve().parents[1] / "semantic/portfolio.yml").read_text())
schema, view = m["source"].split(".")
cols = set(subprocess.run(
    ["psql", "-X", "-At", "-c",
     f"SELECT column_name FROM information_schema.columns WHERE table_schema='{schema}' AND table_name='{view}'"],
    check=True, capture_output=True, text=True).stdout.split())

errors = []
if not cols:
    errors.append(f"источник {m['source']} не найден")
names = [x["name"] for x in m["dimensions"] + m["measures"]]
if len(names) != len(set(names)):
    errors.append("повторяющиеся имена")
for kind in ("dimensions", "measures"):
    for x in m[kind]:
        need = {"name", "column", "type", "label"} | ({"format"} if kind == "measures" else set())
        if need - x.keys():
            errors.append(f"{x.get('name')}: нет полей {need - x.keys()}")
        if x["column"] not in cols:
            errors.append(f"{kind}.{x['name']}: колонки {x['column']} нет в {m['source']}")
        if kind == "measures" and x["type"] not in {"sum", "avg", "count"}:
            errors.append(f"{x['name']}: type {x['type']} не из sum/avg/count")

print(f"{m['model']}: {len(m['dimensions'])} измерений, {len(m['measures'])} мер, источник {m['source']}")
print("OK" if not errors else "\n".join(errors))
sys.exit(1 if errors else 0)
