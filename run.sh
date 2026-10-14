#!/usr/bin/env bash
# Полный прогон: загрузка → вьюхи → сверка → данные дашборда.
# Повторный запуск безопасен (TRUNCATE + reload, CREATE OR REPLACE VIEW).
#
#   ./run.sh            — через docker compose (postgres:16 поднимается сам)
#   ./run.sh --local    — через локальный psql и переменные PGHOST/PGPORT/PGUSER/PGDATABASE
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "--local" ]]; then
  PSQL="psql"
  RUN_SQL() { psql -X -q -v ON_ERROR_STOP=1 -f "$1"; }
else
  docker compose up -d --wait db
  PSQL="docker compose exec -T -w /repo db psql -U postgres -d risk"
  RUN_SQL() { $PSQL -X -q -v ON_ERROR_STOP=1 -f "/repo/$1"; }
  export PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=risk
fi

echo "== 1. raw";        RUN_SQL sql/01_raw.sql
echo "== 2. reporting";  RUN_SQL sql/02_reporting.sql
echo "== 3. метрики";    $PSQL -X -c "SELECT label, round(prev_value, 4) AS \"01.09\", round(value, 4) AS \"01.10\", round(delta_pp, 2) AS delta_pp, round(delta_pct, 2) AS delta_pct FROM reporting.v_metrics_change WHERE prev_value IS NOT NULL ORDER BY sort_order"
echo "== 4. данные дашборда"; PSQL="$PSQL" ./scripts/export_dashboard_data.sh
if command -v psql >/dev/null && python3 -c "import pandas" 2>/dev/null; then
  echo "== 5. независимая сверка (pandas) и проверка YAML-модели"; python3 tests/reconcile.py; python3 tests/check_model.py
else
  echo "== 5. сверка пропущена: нужны psql и pandas на хосте (python3 tests/reconcile.py)"
fi
echo "Готово. Дашборд: python3 -m http.server -d dashboard 8000 → http://localhost:8000"
