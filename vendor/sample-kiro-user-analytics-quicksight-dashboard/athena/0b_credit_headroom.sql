-- PATCH P8 (kiro-enterprise-monitoring): credit headroom per user per month.
--
-- Kiro allocates plan credits per CALENDAR MONTH and resets them on the 1st,
-- and the report carries each user's monthly limit (Usage_Limit). One row per
-- (user, calendar month):
--   remaining_credits           = usage_limit - credits_used_mtd, floored at 0
--   pct_used                    = credits_used_mtd / usage_limit (above 1 in overage)
--   projected_month_end_credits = credits_used_mtd * days_in_month / days_elapsed
--                                 (linear burn from the 1st of the month)
--
-- Sources:
--   * Credits, overage and tier come from base_user_activity, which reads the
--     report_facts dedup view (latest export wins per date, user and client).
--     A user has one row per client per day; the month total SUMs all of them.
--   * usage_limit is not in report_facts (P8 leaves that view byte-identical),
--     so it is read from report_facts_raw: per user and month, the value on
--     the latest dated row, ordered like the report_facts dedup (export_ts,
--     processed_ts, part_id). Rows without a value are skipped. Parts
--     normalized before P8 have no usage_limit (NULL), so one export
--     normalized after P8 is enough to fill the month.
--   * days_elapsed counts from the 1st of the month to as_of_date, the latest
--     activity_date in the DATA (not the wall clock: the export lags about a
--     day), capped at the last day of the month. A finished month therefore
--     projects to its actual total.
--
-- Status. The two thresholds are the constants in `params` below, nowhere else:
--   UNKNOWN_LIMIT  usage_limit is NULL or <= 0. Not scored and never counted as
--                  at risk; remaining_credits and pct_used are NULL, not 100%.
--   EXHAUSTED      credits_used_mtd >= usage_limit
--   AT_RISK        pct_used >= at_risk_pct, or the projection reaches
--                  usage_limit by the end of the month
--   WATCH          pct_used >= watch_pct
--   OK             everything else
--
-- is_latest_month is 'Yes' on the month of the latest activity_date. The
-- dashboard shows only that month; earlier months stay here as history.
CREATE OR REPLACE VIEW ${database}.credit_headroom AS
WITH params AS (
    SELECT 0.75 AS watch_pct, 0.90 AS at_risk_pct
),
bound AS (
    SELECT MAX(activity_date) AS max_date FROM ${database}.base_user_activity
),
usage_mtd AS (
    SELECT
        b.user_id,
        date_trunc('month', b.activity_date)          AS month,
        SUM(b.credits_used)                           AS credits_used_mtd,
        SUM(b.overage_credits_used)                   AS overage_credits_used,
        max_by(b.subscription_tier, b.activity_date)  AS user_tier,
        max_by(b.overage_enabled, b.activity_date)    AS overage_enabled,
        max_by(b.overage_cap, b.activity_date)        AS overage_cap
    FROM ${database}.base_user_activity b
    GROUP BY b.user_id, date_trunc('month', b.activity_date)
),
limit_rows AS (
    SELECT
        userid                                              AS user_id,
        TRY(CAST(date AS date))                             AS activity_date,
        TRY(CAST(NULLIF(trim(usage_limit), '') AS double))  AS usage_limit,
        COALESCE(export_ts, '')                             AS export_ts,
        COALESCE(processed_ts, '')                          AS processed_ts,
        COALESCE(part_id, '')                               AS part_id
    FROM ${database}.report_facts_raw
),
limits AS (
    SELECT
        user_id,
        date_trunc('month', activity_date)                  AS month,
        max_by(usage_limit,
               (activity_date, export_ts, processed_ts, part_id)) AS usage_limit
    FROM limit_rows
    WHERE activity_date IS NOT NULL
      AND usage_limit IS NOT NULL
    GROUP BY user_id, date_trunc('month', activity_date)
),
spans AS (
    SELECT
        u.*,
        date_add('day', -1, date_add('month', 1, u.month))  AS month_end
    FROM usage_mtd u
),
m AS (
    SELECT
        s.month,
        s.user_id,
        s.user_tier,
        l.usage_limit,
        s.credits_used_mtd,
        s.overage_enabled,
        s.overage_cap,
        s.overage_credits_used,
        LEAST(w.max_date, s.month_end)                                AS as_of_date,
        date_diff('day', s.month, LEAST(w.max_date, s.month_end)) + 1 AS days_elapsed,
        day_of_month(s.month_end)                                     AS days_in_month,
        CASE WHEN s.month = date_trunc('month', w.max_date)
             THEN 'Yes' ELSE 'No' END                                 AS is_latest_month
    FROM spans s
    CROSS JOIN bound w
    LEFT JOIN limits l
      ON l.user_id = s.user_id
     AND l.month = s.month
),
scored AS (
    SELECT
        m.*,
        CASE WHEN m.usage_limit > 0 AND m.credits_used_mtd < m.usage_limit
             THEN m.usage_limit - m.credits_used_mtd
             WHEN m.usage_limit > 0
             THEN 0.0
        END                                                  AS remaining_credits,
        CASE WHEN m.usage_limit > 0
             THEN m.credits_used_mtd / m.usage_limit
        END                                                  AS pct_used,
        -- Multiply first: 5000 * 30 / 15 is exactly 10000, while
        -- 5000 / 15 * 30 lands a hair under it and misses the >= below.
        m.credits_used_mtd * m.days_in_month
            / NULLIF(m.days_elapsed, 0)                      AS projected_month_end_credits
    FROM m
),
rated AS (
    SELECT
        s.*,
        CASE
            WHEN s.pct_used IS NULL                             THEN 'UNKNOWN_LIMIT'
            WHEN s.credits_used_mtd >= s.usage_limit            THEN 'EXHAUSTED'
            WHEN s.pct_used >= p.at_risk_pct
              OR s.projected_month_end_credits >= s.usage_limit THEN 'AT_RISK'
            WHEN s.pct_used >= p.watch_pct                      THEN 'WATCH'
            ELSE 'OK'
        END                                                  AS status
    FROM scored s
    CROSS JOIN params p
)
SELECT
    r.month,
    r.user_id,
    COALESCE(d.user_label, r.user_id)  AS user_label,
    d.idc_username,
    d.idc_email,
    r.user_tier,
    r.usage_limit,
    r.credits_used_mtd,
    r.remaining_credits,
    r.pct_used,
    r.overage_enabled,
    r.overage_cap,
    r.overage_credits_used,
    r.as_of_date,
    r.days_elapsed,
    r.days_in_month,
    r.projected_month_end_credits,
    r.status,
    r.is_latest_month
FROM rated r
LEFT JOIN ${database}.user_dim d ON d.user_id = r.user_id;
