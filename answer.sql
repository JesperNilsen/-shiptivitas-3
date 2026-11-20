-- Shiptivity analytics: did the Kanban board (released 2018-06-02) move daily active users?
--
-- Run every query:   sqlite3 shiptivity.db < answer.sql
-- Charts and ideas:  .venv/bin/python analysis.py   (runs these same queries by name)
--
-- Conventions used throughout
-- * Timestamps are Unix seconds. A "day" is a UTC calendar day: date(ts, 'unixepoch').
-- * Launch comparisons use 'YYYY-MM-DD' text on both sides. (Comparing an integer timestamp
--   with strftime() output is a trap: strftime returns TEXT, and SQLite sorts every integer
--   before every TEXT value unless a column's INTEGER affinity converts it first.)
-- * Days with no logins count as 0 users. Averages run over a full calendar, not only over
--   days that had activity; skipping empty days would overstate the "before" average.
-- * In card_change_history, a row with oldStatus IS NULL records a card being created in the
--   backlog. It is not a status change, so status-change counts exclude it.

.headers on
.mode column

-- TYPE YOUR SQL QUERY BELOW

-- PART 1: Create a SQL query that maps out the daily average users before and after the feature change

-- name: dau_before_after
-- Average daily active users (distinct users who logged in on a day) before vs after launch.
WITH RECURSIVE
  bounds AS (
    SELECT date(MIN(login_timestamp), 'unixepoch') AS first_day,
           date(MAX(login_timestamp), 'unixepoch') AS last_day
    FROM login_history
  ),
  calendar(day) AS (
    SELECT first_day FROM bounds
    UNION ALL
    SELECT date(day, '+1 day') FROM calendar, bounds WHERE day < bounds.last_day
  ),
  daily AS (
    SELECT date(login_timestamp, 'unixepoch') AS day,
           COUNT(DISTINCT user_id) AS active_users
    FROM login_history
    GROUP BY day
  )
SELECT CASE WHEN calendar.day < '2018-06-02' THEN 'before launch' ELSE 'after launch' END AS period,
       MIN(calendar.day) AS first_day,
       MAX(calendar.day) AS last_day,
       COUNT(*) AS days,
       ROUND(AVG(COALESCE(daily.active_users, 0)), 2) AS avg_daily_active_users
FROM calendar
LEFT JOIN daily USING (day)
GROUP BY period
ORDER BY first_day;

-- name: dau_daily
-- Daily active users for every calendar day (0 when nobody logged in). Feeds the line chart.
WITH RECURSIVE
  bounds AS (
    SELECT date(MIN(login_timestamp), 'unixepoch') AS first_day,
           date(MAX(login_timestamp), 'unixepoch') AS last_day
    FROM login_history
  ),
  calendar(day) AS (
    SELECT first_day FROM bounds
    UNION ALL
    SELECT date(day, '+1 day') FROM calendar, bounds WHERE day < bounds.last_day
  ),
  daily AS (
    SELECT date(login_timestamp, 'unixepoch') AS day,
           COUNT(DISTINCT user_id) AS active_users
    FROM login_history
    GROUP BY day
  )
SELECT calendar.day,
       COALESCE(daily.active_users, 0) AS active_users,
       CASE WHEN calendar.day < '2018-06-02' THEN 'before' ELSE 'after' END AS period
FROM calendar
LEFT JOIN daily USING (day)
ORDER BY calendar.day;


-- PART 2: Create a SQL query that indicates the number of status changes by card

-- name: status_changes_by_card
-- Status changes per card. LEFT JOIN from card so cards that never moved still appear, with 0.
SELECT card.id AS card_id,
       card.name,
       card.status AS current_status,
       COUNT(h.cardID) AS status_changes
FROM card
LEFT JOIN card_change_history AS h
       ON h.cardID = card.id
      AND h.oldStatus IS NOT NULL      -- skip the row that records the card's creation
      AND h.oldStatus <> h.newStatus   -- a priority-only reorder is not a status change
GROUP BY card.id
ORDER BY status_changes DESC, card.id;

-- name: cards_by_change_count
-- How many cards had 0, 1, 2, ... status changes. Feeds the "by card" bar chart.
SELECT status_changes,
       COUNT(*) AS cards
FROM (
  SELECT card.id, COUNT(h.cardID) AS status_changes
  FROM card
  LEFT JOIN card_change_history AS h
         ON h.cardID = card.id
        AND h.oldStatus IS NOT NULL
        AND h.oldStatus <> h.newStatus
  GROUP BY card.id
)
GROUP BY status_changes
ORDER BY status_changes;

-- name: status_changes_daily
-- Status changes per day since launch (0 on days with none), the "daily" view of the same data.
WITH RECURSIVE
  calendar(day) AS (
    SELECT '2018-06-02'
    UNION ALL
    SELECT date(day, '+1 day') FROM calendar
    WHERE day < (SELECT date(MAX(timestamp), 'unixepoch') FROM card_change_history)
  ),
  daily AS (
    SELECT date(timestamp, 'unixepoch') AS day, COUNT(*) AS status_changes
    FROM card_change_history
    WHERE oldStatus IS NOT NULL AND oldStatus <> newStatus
    GROUP BY day
  )
SELECT calendar.day,
       COALESCE(daily.status_changes, 0) AS status_changes
FROM calendar
LEFT JOIN daily USING (day)
ORDER BY calendar.day;


-- PART 3: Supporting queries behind the three ideas (ideas.md)

-- name: monthly_engagement
-- Per month: average daily users, monthly users, and stickiness (avg DAU / MAU).
-- Stickiness answers "on a typical day, what share of this month's users showed up?"
WITH RECURSIVE
  bounds AS (
    SELECT date(MIN(login_timestamp), 'unixepoch') AS first_day,
           date(MAX(login_timestamp), 'unixepoch') AS last_day
    FROM login_history
  ),
  calendar(day) AS (
    SELECT first_day FROM bounds
    UNION ALL
    SELECT date(day, '+1 day') FROM calendar, bounds WHERE day < bounds.last_day
  ),
  daily AS (
    SELECT date(login_timestamp, 'unixepoch') AS day,
           COUNT(DISTINCT user_id) AS active_users,
           COUNT(*) AS logins
    FROM login_history
    GROUP BY day
  ),
  monthly AS (
    SELECT strftime('%Y-%m', login_timestamp, 'unixepoch') AS month,
           COUNT(DISTINCT user_id) AS monthly_active_users
    FROM login_history
    GROUP BY month
  )
SELECT strftime('%Y-%m', calendar.day) AS month,
       COUNT(*) AS days,
       ROUND(AVG(COALESCE(daily.active_users, 0)), 2) AS avg_daily_active_users,
       monthly.monthly_active_users,
       ROUND(100.0 * AVG(COALESCE(daily.active_users, 0)) / monthly.monthly_active_users, 1)
         AS stickiness_pct,
       SUM(COALESCE(daily.logins, 0)) AS logins
FROM calendar
LEFT JOIN daily USING (day)
JOIN monthly ON monthly.month = strftime('%Y-%m', calendar.day)
GROUP BY month
ORDER BY month;

-- name: user_cohorts
-- Did DAU rise because existing users came more often, or because new users arrived?
-- A user "joins" on their first login. Activity is normalised by tenure (days since joining,
-- up to the last day of data), because a user who joined in August has had less time to log in.
WITH per_user AS (
  SELECT user_id,
         date(MIN(login_timestamp), 'unixepoch') AS first_day,
         COUNT(DISTINCT date(login_timestamp, 'unixepoch')) AS active_days
  FROM login_history
  GROUP BY user_id
),
tenure AS (
  SELECT *,
         julianday((SELECT date(MAX(login_timestamp), 'unixepoch') FROM login_history))
           - julianday(first_day) + 1 AS tenure_days
  FROM per_user
)
SELECT CASE WHEN first_day < '2018-06-02' THEN 'joined before launch' ELSE 'joined after launch' END
         AS cohort,
       COUNT(*) AS users,
       ROUND(AVG(tenure_days)) AS avg_tenure_days,
       ROUND(AVG(7.0 * active_days / tenure_days), 2) AS active_days_per_week
FROM tenure
GROUP BY cohort
ORDER BY cohort DESC;

-- name: signups_by_month
-- New users per month (month of first login). Shows whether growth continued after launch.
SELECT strftime('%Y-%m', first_day) AS month,
       COUNT(*) AS new_users,
       SUM(COUNT(*)) OVER (ORDER BY strftime('%Y-%m', first_day)) AS total_users
FROM (
  SELECT user_id, date(MIN(login_timestamp), 'unixepoch') AS first_day
  FROM login_history
  GROUP BY user_id
)
GROUP BY month
ORDER BY month;

-- name: status_transitions
-- Which moves people make. Backward moves are the "move cards backwards" user story.
SELECT oldStatus AS from_status,
       newStatus AS to_status,
       COUNT(*) AS moves
FROM card_change_history
WHERE oldStatus IS NOT NULL AND oldStatus <> newStatus
GROUP BY oldStatus, newStatus
ORDER BY moves DESC;

-- name: card_cycle_time
-- Average days a card spends between first entering in-progress and its last move to complete.
WITH per_card AS (
  SELECT cardID,
         MIN(CASE WHEN newStatus = 'in-progress' THEN timestamp END) AS started,
         MAX(CASE WHEN newStatus = 'complete' THEN timestamp END) AS completed
  FROM card_change_history
  GROUP BY cardID
)
SELECT COUNT(*) AS completed_cards,
       ROUND(AVG((completed - started) / 86400.0), 1) AS avg_days_in_progress,
       ROUND(MIN((completed - started) / 86400.0), 1) AS min_days,
       ROUND(MAX((completed - started) / 86400.0), 1) AS max_days
FROM per_card
WHERE started IS NOT NULL AND completed IS NOT NULL;

-- name: card_flow_by_month
-- Cards created vs status changes per month. Separates "more moves because there are more cards
-- on the board" from "each card moves more often".
WITH monthly AS (
  SELECT strftime('%Y-%m', timestamp, 'unixepoch') AS month,
         SUM(oldStatus IS NULL) AS cards_created,
         SUM(oldStatus IS NOT NULL AND oldStatus <> newStatus) AS status_changes
  FROM card_change_history
  GROUP BY month
)
SELECT month,
       cards_created,
       SUM(cards_created) OVER (ORDER BY month) AS cards_on_board,
       status_changes,
       ROUND(1.0 * status_changes / SUM(cards_created) OVER (ORDER BY month), 2)
         AS changes_per_card_on_board
FROM monthly
ORDER BY month;

-- name: card_wait_times
-- How long cards sit untouched: creation to first status change, and the age of cards that
-- have never moved (measured to the last day of data).
WITH created AS (
  SELECT cardID, timestamp AS created_at
  FROM card_change_history
  WHERE oldStatus IS NULL
),
first_move AS (
  SELECT cardID, MIN(timestamp) AS moved_at
  FROM card_change_history
  WHERE oldStatus IS NOT NULL AND oldStatus <> newStatus
  GROUP BY cardID
),
data_end AS (
  SELECT MAX(timestamp) AS ts FROM card_change_history
)
SELECT
  (SELECT COUNT(*) FROM first_move) AS cards_moved,
  (SELECT ROUND(AVG((moved_at - created_at) / 86400.0), 1)
     FROM created JOIN first_move USING (cardID)) AS avg_days_to_first_move,
  (SELECT COUNT(*) FROM created WHERE cardID NOT IN (SELECT cardID FROM first_move))
    AS cards_never_moved,
  (SELECT ROUND(AVG(((SELECT ts FROM data_end) - created_at) / 86400.0), 1)
     FROM created WHERE cardID NOT IN (SELECT cardID FROM first_move))
    AS avg_age_days_never_moved;

-- name: logins_vs_moves_after_launch
-- After launch, how often does a login come with a card move? (Board activity vs visits.)
SELECT
  (SELECT COUNT(*) FROM login_history
    WHERE date(login_timestamp, 'unixepoch') >= '2018-06-02') AS logins,
  (SELECT COUNT(*) FROM card_change_history
    WHERE oldStatus IS NOT NULL AND oldStatus <> newStatus) AS status_changes,
  (SELECT COUNT(DISTINCT date(timestamp, 'unixepoch')) FROM card_change_history
    WHERE oldStatus IS NOT NULL AND oldStatus <> newStatus) AS days_with_a_status_change,
  (SELECT julianday(date(MAX(login_timestamp), 'unixepoch')) - julianday('2018-06-02') + 1
     FROM login_history) AS days_since_launch;
