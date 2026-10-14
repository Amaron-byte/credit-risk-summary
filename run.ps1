# run.ps1 — полный прогон для Windows (PowerShell): то же, что run.sh.
# Загрузка -> вьюхи -> метрики -> данные дашборда -> независимая сверка.
# Повторный запуск безопасен (TRUNCATE + reload, CREATE OR REPLACE VIEW).
#
# Запуск из папки репозитория:
#   powershell -ExecutionPolicy Bypass -File run.ps1
# Нужны: Docker Desktop (запущен); для сверки — Python 3 с pandas и pyyaml.

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

function Step($name) { Write-Host "== $name" -ForegroundColor Cyan }
function Check($what) { if ($LASTEXITCODE -ne 0) { throw "Ошибка на шаге: $what (код $LASTEXITCODE)" } }

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Не найден docker. Установите и запустите Docker Desktop."
}

Step "0. postgres:16 в docker compose"
docker compose up -d --wait db; Check "docker compose up"

$exec = @("compose", "exec", "-T", "-w", "/repo", "db", "psql", "-U", "postgres", "-d", "risk", "-X", "-q", "-v", "ON_ERROR_STOP=1")

Step "1. raw"
docker @exec -f /repo/sql/01_raw.sql; Check "01_raw.sql"

Step "2. reporting"
docker @exec -f /repo/sql/02_reporting.sql; Check "02_reporting.sql"

Step "3. метрики"
docker @exec -c "SELECT label, round(prev_value, 4) AS d_0109, round(value, 4) AS d_1001, round(delta_pp, 2) AS delta_pp, round(delta_pct, 2) AS delta_pct FROM reporting.v_metrics_change WHERE prev_value IS NOT NULL ORDER BY sort_order"
Check "метрики"

Step "4. данные дашборда"
# psql пишет JSON внутри контейнера, затем файл копируется как есть (без перекодировки консолью Windows).
$queries = [ordered]@{
  "metrics.json"     = "SELECT report_date, prev_date, sort_order, metric, label, unit, round(value, 8) AS value, round(prev_value, 8) AS prev_value, round(delta, 8) AS delta, round(delta_pp, 4) AS delta_pp, round(delta_pct, 4) AS delta_pct FROM reporting.v_metrics_change ORDER BY report_date, sort_order"
  "breakdown.json"   = "SELECT report_date, dimension, dim_value, loans, portfolio_kzt, par30_kzt, par90_kzt, npl_kzt, provisions_kzt, round(portfolio_share, 6) AS portfolio_share, round(par30, 6) AS par30, round(par90, 6) AS par90, round(npl, 6) AS npl FROM reporting.v_breakdown ORDER BY report_date, dimension, dim_value"
  "top_groups.json"  = "SELECT report_date, rank, group_id, loans, principal_kzt, npl_kzt, round(share, 6) AS share FROM reporting.v_top_groups WHERE rank <= 10 ORDER BY report_date, rank"
  "dpd_buckets.json" = "SELECT report_date, dpd_bucket, count(*) AS loans, sum(principal_kzt) AS principal_kzt, sum(provision_kzt) AS provisions_kzt FROM reporting.v_portfolio GROUP BY report_date, dpd_bucket ORDER BY 1, 2"
  "migration.json"   = "SELECT bucket_from, bucket_to, loans, principal_kzt_to FROM reporting.v_dpd_migration"
  "dq_checks.json"   = "SELECT check_name, description, value, severity FROM reporting.v_dq_checks"
}
New-Item -ItemType Directory -Force -Path "dashboard/data" | Out-Null
foreach ($f in $queries.Keys) {
    $sql = "SELECT coalesce(json_agg(t), '[]'::json) FROM ($($queries[$f])) t"
    docker @exec -At -o "/tmp/$f" -c $sql; Check "экспорт $f"
    docker compose cp "db:/tmp/$f" "dashboard/data/$f" | Out-Null; Check "копирование $f"
    Write-Host "  dashboard/data/$f"
}

Step "5. независимая сверка (pandas) и проверка YAML-модели"
$py = $null
foreach ($c in @("py", "python", "python3")) {
    if (Get-Command $c -ErrorAction SilentlyContinue) {
        try { & $c -c "import pandas, yaml" 2>$null } catch { continue }
        if ($LASTEXITCODE -eq 0) { $py = $c; break }
    }
}
if ($py) {
    $env:PSQL = "docker compose exec -T db psql -U postgres -d risk"
    & $py tests/reconcile.py;   Check "reconcile.py"
    & $py tests/check_model.py; Check "check_model.py"
} else {
    Write-Host "  пропущено: нужен Python 3 с pandas и pyyaml (pip install pandas pyyaml), затем запустите run.ps1 ещё раз" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Готово. Дашборд: python -m http.server -d dashboard 8000  ->  http://localhost:8000" -ForegroundColor Green
