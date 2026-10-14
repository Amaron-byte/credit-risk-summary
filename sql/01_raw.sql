-- 01_raw.sql — загрузка CSV в схему raw «как есть».
-- Запуск из корня репозитория (пути \copy относительные):
--   psql -v ON_ERROR_STOP=1 -f sql/01_raw.sql
-- Идемпотентно: таблицы создаются один раз, каждый запуск делает TRUNCATE и перезаливку
-- в одной транзакции, поэтому повторный запуск не задваивает данные.
-- Все поля в raw — text: типизация, дедупликация и проверки живут в reporting,
-- чтобы кривая строка в CSV не роняла загрузку, а была видна в проверках качества.

CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE IF NOT EXISTS raw.portfolio (
    report_date           text,
    loan_id               text,
    borrower_id           text,
    group_id              text,
    sector                text,
    program               text,
    currency              text,
    issue_date            text,
    maturity_date         text,
    principal_outstanding text,
    days_past_due         text,
    restructured          text,
    written_off           text
);

CREATE TABLE IF NOT EXISTS raw.fx (
    date     text,
    currency text,
    rate_kzt text
);

BEGIN;
TRUNCATE raw.portfolio, raw.fx;
\copy raw.portfolio FROM 'data/portfolio.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.fx        FROM 'data/fx.csv'        WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
COMMIT;

SELECT 'raw.portfolio' AS table_name, count(*) AS rows FROM raw.portfolio
UNION ALL
SELECT 'raw.fx', count(*) FROM raw.fx;
