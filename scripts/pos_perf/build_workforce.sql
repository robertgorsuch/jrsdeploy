-- build_workforce.sql -- DROP-and-rebuild of employees and shift_schedules.
-- employees: one row per staff slot per store -- stores.staff_count (4 to 12)
-- drives the roster, so headcount reconciles to the stores dimension.
-- employee_id = storenumber * 100 + slot. Slot 0 is the Store Manager,
-- slot 1 Assistant Manager, slot 2 Keyholder, the rest Sales Associates.
-- Identity and wages are hash-deterministic fiction. Hire dates are picked
-- from date_dim by Julian day number -- managers hire at store open, others
-- at a deterministic offset inside the store operating window. About 1 in 8
-- staff are Terminated with a termination date after hire.
-- shift_schedules: one row per store per calendar day per shift (Opening and
-- Closing) across the full 731-day window -- 482,460 rows. The assigned
-- employee is a hash pick from that store roster.
-- NOTE: sql.ps1 run-file splitter has no comment awareness -- never put a
-- semicolon or an unbalanced apostrophe in a comment in this file.

DROP TABLE IF EXISTS wf_seed_first;

CREATE TABLE wf_seed_first AS
SELECT 0 AS id, 'Liam' AS name UNION ALL SELECT 1, 'Olivia' UNION ALL SELECT 2, 'Noah'
UNION ALL SELECT 3, 'Emma' UNION ALL SELECT 4, 'Jackson' UNION ALL SELECT 5, 'Ava'
UNION ALL SELECT 6, 'Lucas' UNION ALL SELECT 7, 'Sophia' UNION ALL SELECT 8, 'Ethan'
UNION ALL SELECT 9, 'Charlotte' UNION ALL SELECT 10, 'Benjamin' UNION ALL SELECT 11, 'Amelia'
UNION ALL SELECT 12, 'William' UNION ALL SELECT 13, 'Mia' UNION ALL SELECT 14, 'James'
UNION ALL SELECT 15, 'Harper' UNION ALL SELECT 16, 'Alexander' UNION ALL SELECT 17, 'Evelyn'
UNION ALL SELECT 18, 'Michael' UNION ALL SELECT 19, 'Abigail' UNION ALL SELECT 20, 'Daniel'
UNION ALL SELECT 21, 'Emily' UNION ALL SELECT 22, 'Matthew' UNION ALL SELECT 23, 'Ella'
UNION ALL SELECT 24, 'Samuel' UNION ALL SELECT 25, 'Grace' UNION ALL SELECT 26, 'David'
UNION ALL SELECT 27, 'Chloe' UNION ALL SELECT 28, 'Joseph' UNION ALL SELECT 29, 'Camila'
UNION ALL SELECT 30, 'Carter' UNION ALL SELECT 31, 'Aria' UNION ALL SELECT 32, 'Owen'
UNION ALL SELECT 33, 'Scarlett' UNION ALL SELECT 34, 'Wyatt' UNION ALL SELECT 35, 'Lily'
UNION ALL SELECT 36, 'John' UNION ALL SELECT 37, 'Hannah' UNION ALL SELECT 38, 'Jack'
UNION ALL SELECT 39, 'Nora' UNION ALL SELECT 40, 'Luke' UNION ALL SELECT 41, 'Zoey'
UNION ALL SELECT 42, 'Ryan' UNION ALL SELECT 43, 'Mila' UNION ALL SELECT 44, 'Nathan'
UNION ALL SELECT 45, 'Aubrey' UNION ALL SELECT 46, 'Isaac' UNION ALL SELECT 47, 'Violet'
UNION ALL SELECT 48, 'Gabriel' UNION ALL SELECT 49, 'Stella' UNION ALL SELECT 50, 'Anthony'
UNION ALL SELECT 51, 'Claire' UNION ALL SELECT 52, 'Dylan' UNION ALL SELECT 53, 'Lucy'
UNION ALL SELECT 54, 'Leo' UNION ALL SELECT 55, 'Audrey' UNION ALL SELECT 56, 'Marcus'
UNION ALL SELECT 57, 'Sadie' UNION ALL SELECT 58, 'Simon' UNION ALL SELECT 59, 'Naomi';

DROP TABLE IF EXISTS wf_seed_last;

CREATE TABLE wf_seed_last AS
SELECT 0 AS id, 'Smith' AS name UNION ALL SELECT 1, 'Brown' UNION ALL SELECT 2, 'Tremblay'
UNION ALL SELECT 3, 'Martin' UNION ALL SELECT 4, 'Roy' UNION ALL SELECT 5, 'Wilson'
UNION ALL SELECT 6, 'MacDonald' UNION ALL SELECT 7, 'Gagnon' UNION ALL SELECT 8, 'Johnson'
UNION ALL SELECT 9, 'Taylor' UNION ALL SELECT 10, 'Campbell' UNION ALL SELECT 11, 'Anderson'
UNION ALL SELECT 12, 'Leblanc' UNION ALL SELECT 13, 'Cote' UNION ALL SELECT 14, 'Williams'
UNION ALL SELECT 15, 'Miller' UNION ALL SELECT 16, 'Thompson' UNION ALL SELECT 17, 'Gauthier'
UNION ALL SELECT 18, 'White' UNION ALL SELECT 19, 'Morin' UNION ALL SELECT 20, 'Lavoie'
UNION ALL SELECT 21, 'Fortin' UNION ALL SELECT 22, 'Clark' UNION ALL SELECT 23, 'Gagne'
UNION ALL SELECT 24, 'Ouellet' UNION ALL SELECT 25, 'Pelletier' UNION ALL SELECT 26, 'Moore'
UNION ALL SELECT 27, 'Belanger' UNION ALL SELECT 28, 'Levesque' UNION ALL SELECT 29, 'Walker'
UNION ALL SELECT 30, 'Bergeron' UNION ALL SELECT 31, 'Young' UNION ALL SELECT 32, 'Leclerc'
UNION ALL SELECT 33, 'Robinson' UNION ALL SELECT 34, 'Simard' UNION ALL SELECT 35, 'Wright'
UNION ALL SELECT 36, 'Boucher' UNION ALL SELECT 37, 'Mitchell' UNION ALL SELECT 38, 'Caron'
UNION ALL SELECT 39, 'Stewart' UNION ALL SELECT 40, 'Beaulieu' UNION ALL SELECT 41, 'Scott'
UNION ALL SELECT 42, 'Cloutier' UNION ALL SELECT 43, 'Reid' UNION ALL SELECT 44, 'Dube'
UNION ALL SELECT 45, 'King' UNION ALL SELECT 46, 'Poirier' UNION ALL SELECT 47, 'Fraser'
UNION ALL SELECT 48, 'Nadeau' UNION ALL SELECT 49, 'Ross' UNION ALL SELECT 50, 'Girard'
UNION ALL SELECT 51, 'Murray' UNION ALL SELECT 52, 'Lapointe' UNION ALL SELECT 53, 'Kelly'
UNION ALL SELECT 54, 'Grant' UNION ALL SELECT 55, 'Fournier' UNION ALL SELECT 56, 'Bennett'
UNION ALL SELECT 57, 'Marchand' UNION ALL SELECT 58, 'Watson' UNION ALL SELECT 59, 'Chan';

DROP TABLE IF EXISTS wf_slots;

CREATE TABLE wf_slots AS
SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11;

DROP TABLE IF EXISTS employees;

CREATE TABLE employees AS
WITH base AS (
  SELECT st.storenumber, st.storename, st.province, sl.n AS slot, st.staff_count,
         st.open_date,
         DAY(st.open_date) + (153 * (MONTH(st.open_date) + 12 * ((14 - MONTH(st.open_date)) / 12) - 3) + 2) / 5
           + 365 * (YEAR(st.open_date) + 4800 - (14 - MONTH(st.open_date)) / 12)
           + (YEAR(st.open_date) + 4800 - (14 - MONTH(st.open_date)) / 12) / 4
           - (YEAR(st.open_date) + 4800 - (14 - MONTH(st.open_date)) / 12) / 100
           + (YEAR(st.open_date) + 4800 - (14 - MONTH(st.open_date)) / 12) / 400 - 32045 AS open_jdn
  FROM stores st
  JOIN wf_slots sl ON sl.n < st.staff_count
), calc AS (
  SELECT b.*,
         b.storenumber * 100 + b.slot AS employee_id,
         VARCHAR(b.storenumber) + '|' + VARCHAR(b.slot) AS hk,
         2459215 - b.open_jdn AS span
  FROM base b
), pick AS (
  SELECT c.*,
         c.open_jdn +
           CASE WHEN c.slot <= 1 THEN 0
                WHEN c.span < 1 THEN 0
                ELSE ABS(MOD(HASH(c.hk + 'hd'), c.span + 1)) END AS hire_jdn,
         CASE WHEN ABS(MOD(HASH(c.hk + 'st'), 8)) = 0 AND c.slot >= 2 THEN 'Terminated'
              ELSE 'Active' END AS employment_status
  FROM calc c
), pick2 AS (
  SELECT p.*,
         CASE WHEN p.hire_jdn + 30 + ABS(MOD(HASH(p.hk + 'tm'), 400)) > 2459215
              THEN 2459215
              ELSE p.hire_jdn + 30 + ABS(MOD(HASH(p.hk + 'tm'), 400)) END AS term_jdn
  FROM pick p
)
SELECT p.employee_id, p.storenumber, p.storename, p.province,
       sf.name AS first_name, sl2.name AS last_name,
       sf.name + ' ' + sl2.name AS full_name,
       CASE p.slot WHEN 0 THEN 'Store Manager' WHEN 1 THEN 'Assistant Manager'
            WHEN 2 THEN 'Keyholder' ELSE 'Sales Associate' END AS role,
       CASE p.slot
            WHEN 0 THEN DECIMAL(28.0 + ABS(MOD(HASH(p.hk + 'wg'), 13)) / 2.0, 6, 2)
            WHEN 1 THEN DECIMAL(24.0 + ABS(MOD(HASH(p.hk + 'wg'), 7)) / 2.0, 6, 2)
            WHEN 2 THEN DECIMAL(19.0 + ABS(MOD(HASH(p.hk + 'wg'), 7)) / 2.0, 6, 2)
            ELSE DECIMAL(15.5 + ABS(MOD(HASH(p.hk + 'wg'), 31)) / 10.0, 6, 2) END AS hourly_wage,
       hd.calendar_date AS hire_date,
       p.employment_status,
       CASE WHEN p.employment_status = 'Terminated' THEN td.calendar_date END AS termination_date,
       LOWERCASE(sf.name) + '.' + LOWERCASE(sl2.name) + VARCHAR(p.employee_id) + '@retailco.example' AS email
FROM pick2 p
JOIN wf_seed_first sf  ON sf.id  = ABS(MOD(HASH(p.hk + 'fn'), 60))
JOIN wf_seed_last  sl2 ON sl2.id = ABS(MOD(HASH(p.hk + 'ln'), 60))
JOIN date_dim hd ON hd.jdn = p.hire_jdn
JOIN date_dim td ON td.jdn = p.term_jdn;

DROP TABLE IF EXISTS shift_schedules;

CREATE TABLE shift_schedules AS
WITH sh AS (
  SELECT 0 AS shift_no UNION ALL SELECT 1
), grid AS (
  SELECT st.storenumber, st.staff_count, d.calendar_date, d.jdn, d.is_holiday, d.is_weekend,
         sh.shift_no,
         VARCHAR(st.storenumber) + '|' + VARCHAR(d.jdn) + '|' + VARCHAR(sh.shift_no) AS hk
  FROM stores st, date_dim d, sh
)
SELECT 'SH-' + VARCHAR(storenumber) + '-' + VARCHAR(jdn) + '-' + VARCHAR(shift_no) AS shift_id,
       storenumber, calendar_date,
       CASE shift_no WHEN 0 THEN 'Opening' ELSE 'Closing' END AS shift_name,
       storenumber * 100 + ABS(MOD(HASH(hk + 'emp'), staff_count)) AS employee_id,
       DECIMAL(6.0 + ABS(MOD(HASH(hk + 'hrs'), 5)) / 2.0, 4, 1) AS scheduled_hours,
       is_holiday, is_weekend
FROM grid;

DROP TABLE IF EXISTS wf_seed_first;

DROP TABLE IF EXISTS wf_seed_last;

DROP TABLE IF EXISTS wf_slots;
