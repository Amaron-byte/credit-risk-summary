#!/usr/bin/env bash
# Выгружает вьюхи reporting.* в dashboard/data/*.json для статичного дашборда.
# Идемпотентно: файлы перезаписываются. Нужны psql и переменные PG* (или PSQL="docker compose exec -T db psql -U postgres -d risk").
set -euo pipefail
cd "$(dirname "$0")/.."
PSQL=${PSQL:-psql}
OUT=dashboard/data
mkdir -p "$OUT"

q() {  # q <file> <select ...>
  $PSQL -X -q -At -v ON_ERROR_STOP=1 -c "SELECT coalesce(json_agg(t), '[]'::json) FROM ($2) t" > "$OUT/$1"
  echo "  $OUT/$1"
}

echo "Экспорт данных дашборда:"
q metrics.json "SELECT report_date, prev_date, sort_order, metric, label, unit,
                       round(value, 8) AS value, round(prev_value, 8) AS prev_value,
                       round(delta, 8) AS delta, round(delta_pp, 4) AS delta_pp,
                       round(delta_pct, 4) AS delta_pct
                FROM reporting.v_metrics_change ORDER BY report_date, sort_order"
q breakdown.json "SELECT report_date, dimension, dim_value, loans, portfolio_kzt, par30_kzt, par90_kzt,
                         npl_kzt, provisions_kzt, round(portfolio_share, 6) AS portfolio_share,
                         round(par30, 6) AS par30, round(par90, 6) AS par90, round(npl, 6) AS npl
                  FROM reporting.v_breakdown ORDER BY report_date, dimension, dim_value"
q top_groups.json "SELECT report_date, rank, group_id, loans, principal_kzt, npl_kzt, round(share, 6) AS share
                   FROM reporting.v_top_groups WHERE rank <= 10 ORDER BY report_date, rank"
q dpd_buckets.json "SELECT report_date, dpd_bucket, count(*) AS loans, sum(principal_kzt) AS principal_kzt,
                           sum(provision_kzt) AS provisions_kzt
                    FROM reporting.v_portfolio GROUP BY report_date, dpd_bucket ORDER BY 1, 2"
q migration.json "SELECT bucket_from, bucket_to, loans, principal_kzt_to FROM reporting.v_dpd_migration"
q dq_checks.json "SELECT check_name, description, value, severity FROM reporting.v_dq_checks"
