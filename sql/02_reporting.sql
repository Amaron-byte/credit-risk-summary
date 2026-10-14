-- 02_reporting.sql — очищенная витрина и метрики в схеме reporting.
-- Идемпотентно: только CREATE SCHEMA IF NOT EXISTS и CREATE OR REPLACE VIEW.
-- Порядок вьюх соответствует зависимостям; запускать целиком:
--   psql -v ON_ERROR_STOP=1 -f sql/02_reporting.sql
--
-- Бизнес-правила (см. README, раздел «Определения»):
--   портфель   = Σ principal_outstanding × курс на дату среза, без списанных кредитов
--   PAR30/90   = доля портфеля с days_past_due > 30 / > 90
--   NPL        = доля портфеля с days_past_due > 90 ИЛИ restructured = 1
--   провизии   = остаток × ставка: NPL 50%; 31–90 дней 10%; иначе (0–30 дней) 1%
--   концентрация = доля 10 крупнейших group_id в портфеле

CREATE SCHEMA IF NOT EXISTS reporting;

------------------------------------------------------------------------------
-- 1. Курсы: типизация; KZT = 1 добавляется явно.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_fx AS
SELECT DISTINCT
       f.date::date              AS rate_date,
       upper(trim(f.currency))   AS currency,
       f.rate_kzt::numeric(18,6) AS rate_kzt
FROM raw.fx f;

------------------------------------------------------------------------------
-- 2. Все кредиты на все даты: типизация, дедупликация, курс, флаги.
--    Здесь же остаются списанные — чтобы их можно было посчитать и проверить.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_loan_clean AS
WITH typed AS (
    SELECT report_date::date                      AS report_date,
           trim(loan_id)                          AS loan_id,
           trim(borrower_id)                      AS borrower_id,
           trim(group_id)                         AS group_id,
           trim(sector)                           AS sector,
           trim(program)                          AS program,
           upper(trim(currency))                  AS currency,
           issue_date::date                       AS issue_date,
           maturity_date::date                    AS maturity_date,
           principal_outstanding::numeric(20,2)   AS principal_outstanding,
           days_past_due::int                     AS days_past_due,
           restructured::int                      AS restructured,
           written_off::int                       AS written_off
    FROM raw.portfolio
),
dedup AS (
    -- В выгрузке 30 полных дублей строк на каждую дату. Дубли идентичны
    -- (проверка в v_dq_checks), поэтому оставляем одну строку на (дата, кредит).
    SELECT DISTINCT ON (report_date, loan_id) *
    FROM typed
    ORDER BY report_date, loan_id, principal_outstanding DESC
),
flagged AS (
    SELECT d.*,
           -- Списание необратимо: кредит, списанный на любом из прошлых срезов,
           -- в портфель не возвращается, даже если в следующей выгрузке флаг = 0.
           max(d.written_off) OVER (PARTITION BY d.loan_id ORDER BY d.report_date
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                           AS written_off_ever
    FROM dedup d
)
SELECT f.*,
       CASE WHEN f.currency = 'KZT' THEN 1::numeric ELSE fx.rate_kzt END AS fx_rate,
       fx.rate_date                                                      AS fx_rate_date,
       round(f.principal_outstanding
             * CASE WHEN f.currency = 'KZT' THEN 1::numeric ELSE fx.rate_kzt END, 2)
                                                                         AS principal_kzt,
       (f.written_off_ever = 0)                                          AS in_portfolio
FROM flagged f
LEFT JOIN LATERAL (
    -- курс на дату среза; если на дату курса нет — последний известный до неё
    SELECT v.rate_kzt, v.rate_date
    FROM reporting.v_fx v
    WHERE v.currency = f.currency AND v.rate_date <= f.report_date
    ORDER BY v.rate_date DESC
    LIMIT 1
) fx ON f.currency <> 'KZT';

------------------------------------------------------------------------------
-- 3. Витрина портфеля (источник семантической модели): только кредиты в портфеле.
--    Суммы по категориям риска вынесены в отдельные колонки, чтобы любая доля
--    считалась как sum(колонка) / sum(principal_kzt) в любом разрезе.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_portfolio AS
WITH base AS (
    SELECT c.*,
           (c.days_past_due > 30)                          AS is_par30,
           (c.days_past_due > 90)                          AS is_par90,
           (c.days_past_due > 90 OR c.restructured = 1)    AS is_npl
    FROM reporting.v_loan_clean c
    WHERE c.in_portfolio
),
rated AS (
    SELECT b.*,
           CASE WHEN b.is_npl                       THEN 0.50
                WHEN b.days_past_due BETWEEN 31 AND 90 THEN 0.10
                ELSE 0.01 END::numeric(4,2)          AS provision_rate,
           CASE WHEN b.days_past_due = 0             THEN '0'
                WHEN b.days_past_due <= 30           THEN '1–30'
                WHEN b.days_past_due <= 90           THEN '31–90'
                ELSE '90+' END                       AS dpd_bucket,
           CASE WHEN b.is_npl                        THEN 'NPL (50%)'
                WHEN b.days_past_due BETWEEN 31 AND 90 THEN '31–90 дней (10%)'
                ELSE 'до 30 дней (1%)' END           AS provision_category
    FROM base b
)
SELECT report_date, loan_id, borrower_id, group_id, sector, program, currency,
       issue_date, maturity_date, principal_outstanding, fx_rate, principal_kzt,
       days_past_due, dpd_bucket, restructured,
       is_par30, is_par90, is_npl,
       CASE WHEN is_par30 THEN principal_kzt ELSE 0 END          AS par30_kzt,
       CASE WHEN is_par90 THEN principal_kzt ELSE 0 END          AS par90_kzt,
       CASE WHEN is_npl   THEN principal_kzt ELSE 0 END          AS npl_kzt,
       provision_category, provision_rate,
       round(principal_kzt * provision_rate, 2)                  AS provision_kzt,
       (maturity_date < report_date)                             AS is_past_maturity
FROM rated;

------------------------------------------------------------------------------
-- 4. Крупнейшие группы связанных заёмщиков (ранг внутри даты).
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_top_groups AS
WITH g AS (
    SELECT report_date, group_id,
           sum(principal_kzt)  AS principal_kzt,
           count(*)            AS loans,
           sum(npl_kzt)        AS npl_kzt
    FROM reporting.v_portfolio
    GROUP BY report_date, group_id
)
SELECT g.report_date,
       row_number() OVER (PARTITION BY g.report_date
                          ORDER BY g.principal_kzt DESC, g.group_id) AS rank,
       g.group_id, g.loans, g.principal_kzt, g.npl_kzt,
       g.principal_kzt / sum(g.principal_kzt) OVER (PARTITION BY g.report_date) AS share
FROM g;

------------------------------------------------------------------------------
-- 5. Метрики на каждую дату среза.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_metrics AS
WITH p AS (
    SELECT report_date,
           count(*)               AS loans,
           count(DISTINCT borrower_id) AS borrowers,
           count(DISTINCT group_id)    AS groups,
           sum(principal_kzt)     AS portfolio_kzt,
           sum(par30_kzt)         AS par30_kzt,
           sum(par90_kzt)         AS par90_kzt,
           sum(npl_kzt)           AS npl_kzt,
           sum(provision_kzt)     AS provisions_kzt
    FROM reporting.v_portfolio
    GROUP BY report_date
),
t AS (
    SELECT report_date, sum(principal_kzt) AS top10_kzt
    FROM reporting.v_top_groups
    WHERE rank <= 10
    GROUP BY report_date
)
SELECT p.report_date,
       p.loans, p.borrowers, p.groups,
       p.portfolio_kzt,
       p.par30_kzt, p.par30_kzt / p.portfolio_kzt         AS par30,
       p.par90_kzt, p.par90_kzt / p.portfolio_kzt         AS par90,
       p.npl_kzt,   p.npl_kzt   / p.portfolio_kzt         AS npl,
       p.provisions_kzt,
       p.provisions_kzt / p.portfolio_kzt                 AS provisions_to_portfolio,
       p.provisions_kzt / nullif(p.npl_kzt, 0)            AS provisions_to_npl,
       t.top10_kzt,
       t.top10_kzt / p.portfolio_kzt                      AS top10_concentration
FROM p
JOIN t USING (report_date);

------------------------------------------------------------------------------
-- 6. Метрики в длинном формате с изменением к предыдущему срезу (01.09).
--    Для долей delta_pp — изменение в процентных пунктах; для сумм и штук delta_pct — в %.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_metrics_change AS
WITH long AS (
    SELECT m.report_date, x.sort_order, x.metric, x.label, x.unit, x.value
    FROM reporting.v_metrics m
    CROSS JOIN LATERAL (VALUES
        (1, 'portfolio_kzt',       'Портфель, ₸',              'kzt',   m.portfolio_kzt),
        (2, 'par30',               'PAR30',                    'share', m.par30),
        (3, 'par90',               'PAR90',                    'share', m.par90),
        (4, 'npl',                 'NPL',                      'share', m.npl),
        (5, 'provisions_kzt',      'Провизии, ₸',              'kzt',   m.provisions_kzt),
        (6, 'provisions_to_npl',   'Покрытие NPL провизиями',  'share', m.provisions_to_npl),
        (7, 'top10_concentration', 'Концентрация топ-10 групп','share', m.top10_concentration),
        (8, 'loans',               'Кредитов, шт.',            'count', m.loans::numeric)
    ) AS x(sort_order, metric, label, unit, value)
),
w AS (
    SELECT l.*,
           lag(l.value)       OVER (PARTITION BY l.metric ORDER BY l.report_date) AS prev_value,
           lag(l.report_date) OVER (PARTITION BY l.metric ORDER BY l.report_date) AS prev_date
    FROM long l
)
SELECT report_date, prev_date, sort_order, metric, label, unit,
       value, prev_value,
       value - prev_value                                                     AS delta,
       CASE WHEN unit = 'share' THEN (value - prev_value) * 100 END           AS delta_pp,
       CASE WHEN unit <> 'share' THEN (value / nullif(prev_value, 0) - 1) * 100 END AS delta_pct
FROM w;

------------------------------------------------------------------------------
-- 7. Разрезы по отрасли и программе (одна вьюха, удобно для фасетов в Vega-Lite).
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_breakdown AS
WITH b AS (
    SELECT report_date, 'sector'::text AS dimension, sector AS dim_value,
           principal_kzt, par30_kzt, par90_kzt, npl_kzt, provision_kzt
    FROM reporting.v_portfolio
    UNION ALL
    SELECT report_date, 'program', program,
           principal_kzt, par30_kzt, par90_kzt, npl_kzt, provision_kzt
    FROM reporting.v_portfolio
),
a AS (
    SELECT report_date, dimension, dim_value,
           count(*)            AS loans,
           sum(principal_kzt)  AS portfolio_kzt,
           sum(par30_kzt)      AS par30_kzt,
           sum(par90_kzt)      AS par90_kzt,
           sum(npl_kzt)        AS npl_kzt,
           sum(provision_kzt)  AS provisions_kzt
    FROM b
    GROUP BY report_date, dimension, dim_value
)
SELECT a.*,
       a.portfolio_kzt / sum(a.portfolio_kzt) OVER (PARTITION BY a.report_date, a.dimension) AS portfolio_share,
       a.par30_kzt / a.portfolio_kzt AS par30,
       a.par90_kzt / a.portfolio_kzt AS par90,
       a.npl_kzt   / a.portfolio_kzt AS npl
FROM a;

------------------------------------------------------------------------------
-- 8. Миграция кредитов между корзинами просрочки 01.09 → 01.10.
--    'списан' — кредит выбыл из портфеля (списан на одном из срезов).
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_dpd_migration AS
WITH s AS (
    SELECT c.report_date, c.loan_id, c.principal_kzt,
           CASE WHEN NOT c.in_portfolio THEN 'списан'
                WHEN c.days_past_due = 0   THEN '0'
                WHEN c.days_past_due <= 30 THEN '1–30'
                WHEN c.days_past_due <= 90 THEN '31–90'
                ELSE '90+' END AS bucket
    FROM reporting.v_loan_clean c
),
d AS (SELECT min(report_date) AS d0, max(report_date) AS d1 FROM s)
SELECT a.bucket                AS bucket_from,
       b.bucket                AS bucket_to,
       count(*)                AS loans,
       sum(b.principal_kzt)    AS principal_kzt_to
FROM d
JOIN s a ON a.report_date = d.d0
JOIN s b ON b.report_date = d.d1 AND b.loan_id = a.loan_id
GROUP BY a.bucket, b.bucket;

------------------------------------------------------------------------------
-- 9. Проверки качества данных: что нашли и как обработали.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_dq_checks AS
WITH typed AS (
    SELECT p.report_date::date AS report_date, p.loan_id, p::text AS row_text
    FROM raw.portfolio p
),
c AS (
    SELECT 'raw_rows' AS check_name, 'Строк в raw.portfolio' AS description,
           count(*)::numeric AS value, 'info' AS severity
    FROM raw.portfolio
    UNION ALL
    SELECT 'exact_duplicate_rows', 'Полные дубли строк (удалены в v_loan_clean)',
           (count(*) - count(DISTINCT row_text))::numeric, 'fixed'
    FROM typed
    UNION ALL
    SELECT 'conflicting_duplicates', 'Дубли (дата, кредит) с разными значениями — должно быть 0',
           (SELECT count(*) FROM (
                SELECT report_date, loan_id FROM typed
                GROUP BY report_date, loan_id
                HAVING count(DISTINCT row_text) > 1) z)::numeric,
           'error'
    UNION ALL
    SELECT 'missing_fx', 'Строк в валюте без курса — должно быть 0',
           count(*)::numeric, 'error'
    FROM reporting.v_loan_clean WHERE fx_rate IS NULL
    UNION ALL
    SELECT 'fx_not_on_report_date', 'Строк, где курс взят не на дату среза',
           count(*)::numeric, 'warn'
    FROM reporting.v_loan_clean WHERE currency <> 'KZT' AND fx_rate_date <> report_date
    UNION ALL
    SELECT 'written_off_flag_rows', 'Строк с written_off = 1 в выгрузке',
           count(*)::numeric, 'info'
    FROM reporting.v_loan_clean WHERE written_off = 1
    UNION ALL
    SELECT 'written_off_reappeared', 'Кредиты, списанные ранее, но с written_off = 0 на следующем срезе (исключены)',
           count(*)::numeric, 'fixed'
    FROM reporting.v_loan_clean WHERE written_off = 0 AND written_off_ever = 1
    UNION ALL
    SELECT 'written_off_reappeared_kzt', 'Остаток таких «воскресших» кредитов, ₸',
           coalesce(sum(principal_kzt), 0), 'fixed'
    FROM reporting.v_loan_clean WHERE written_off = 0 AND written_off_ever = 1
    UNION ALL
    SELECT 'negative_or_zero_principal', 'Остаток ≤ 0 — должно быть 0',
           count(*)::numeric, 'error'
    FROM reporting.v_loan_clean WHERE principal_outstanding <= 0
    UNION ALL
    SELECT 'negative_dpd', 'Отрицательная просрочка — должно быть 0',
           count(*)::numeric, 'error'
    FROM reporting.v_loan_clean WHERE days_past_due < 0
    UNION ALL
    SELECT 'past_maturity_in_portfolio', 'Кредиты в портфеле с истёкшим сроком погашения',
           count(*)::numeric, 'warn'
    FROM reporting.v_portfolio WHERE is_past_maturity
    UNION ALL
    SELECT 'dpd_exactly_30_or_90', 'Кредиты ровно на границе 30/90 дней (не входят в PAR30/PAR90)',
           count(*)::numeric, 'info'
    FROM reporting.v_portfolio WHERE days_past_due IN (30, 90)
)
SELECT * FROM c;
