-- =============================================================================
-- Library Management System - Analytical SQL Query Script
-- Course:   BIS 3753 Database Management
-- File:     library_management_analytical_queries.sql
-- Purpose:  Read-only analytical queries that demonstrate real-world library
--           reporting against the `library_management` schema.
--
-- Execution order:
--   1. library_management_schema.sql       (creates the schema)
--   2. library_management_seed_data.sql    (loads seed data)
--   3. library_management_analytical_queries.sql   (this file)
--
-- SAFETY NOTE:
--   This script is 100% read-only. It performs NO INSERT, UPDATE, DELETE,
--   ALTER, or DROP operations. It may be re-run any number of times with
--   no side effects on the underlying schema or data.
--
-- SQL techniques demonstrated across the full query set:
--   * INNER JOIN, LEFT JOIN
--   * Correlated subqueries with EXISTS / NOT EXISTS
--   * WHERE, GROUP BY, HAVING, ORDER BY
--   * Aggregate functions: COUNT, SUM, AVG, MAX, MIN
--   * Date functions: DATEDIFF, DATE_FORMAT, YEAR
--   * Conditional aggregation (CASE inside SUM)
--   * String aggregation with GROUP_CONCAT
--   * Data-quality / operational-risk flagging
-- =============================================================================

USE library_management;


-- =============================================================================
-- Query 1
-- Business question:
--   Which active loans are currently overdue, and how many days overdue are
--   they?
-- SQL techniques:
--   INNER JOIN (4 tables), WHERE, DATEDIFF, ORDER BY.
-- Why it matters:
--   This is the core "overdue report" that circulation staff run every morning
--   to trigger reminder notices, escalate to collections, and prioritize
--   follow-up phone calls. Days overdue drives the fine accrual.
-- =============================================================================
SELECT
    l.loan_id                                    AS loan_id,
    m.university_id                              AS member_university_id,
    CONCAT(m.first_name, ' ', m.last_name)       AS member_name,
    m.email                                      AS member_email,
    b.title                                      AS book_title,
    b.isbn13                                     AS isbn13,
    bc.barcode                                   AS copy_barcode,
    l.checkout_date                              AS checkout_date,
    l.due_date                                   AS due_date,
    DATEDIFF(CURRENT_DATE, l.due_date)           AS days_overdue
FROM       loan      AS l
INNER JOIN member    AS m  ON m.member_id     = l.member_id
INNER JOIN book_copy AS bc ON bc.book_copy_id = l.book_copy_id
INNER JOIN book      AS b  ON b.book_id       = bc.book_id
WHERE l.return_date IS NULL
  AND l.due_date    <  CURRENT_DATE
ORDER BY days_overdue DESC,
         member_name  ASC;


-- =============================================================================
-- Query 2
-- Business question:
--   Which categories have the highest circulation volume?
-- SQL techniques:
--   INNER JOIN (5 tables), GROUP BY, COUNT, ORDER BY.
-- Why it matters:
--   Collection development teams use circulation-by-category to decide where
--   to invest the acquisitions budget. Categories with high loan counts
--   warrant more copies; dormant categories may be candidates for weeding.
--   This query is shaped for an R Studio bar chart (category vs. total_loans).
-- =============================================================================
SELECT
    c.category_name          AS category_name,
    COUNT(l.loan_id)         AS total_loans,
    COUNT(DISTINCT l.member_id) AS distinct_borrowers,
    COUNT(DISTINCT b.book_id)   AS distinct_titles_loaned
FROM       category      AS c
INNER JOIN book_category AS bc ON bc.category_id = c.category_id
INNER JOIN book          AS b  ON b.book_id      = bc.book_id
INNER JOIN book_copy     AS cp ON cp.book_id     = b.book_id
INNER JOIN loan          AS l  ON l.book_copy_id = cp.book_copy_id
GROUP BY c.category_id, c.category_name
ORDER BY total_loans DESC,
         category_name ASC;


-- =============================================================================
-- Query 3
-- Business question:
--   Which members have unpaid fine balances above their borrowing policy
--   threshold?
-- SQL techniques:
--   INNER JOIN, WHERE (filter on fine_status), GROUP BY, HAVING,
--   SUM (conditional balance calculation).
-- Why it matters:
--   Members whose unpaid balance exceeds `member_type.max_fine_balance` must
--   be automatically blocked from new checkouts per library policy. This
--   report feeds the nightly "patron block" batch and the front-desk alert.
-- =============================================================================
SELECT
    m.member_id                                          AS member_id,
    m.university_id                                      AS member_university_id,
    CONCAT(m.first_name, ' ', m.last_name)               AS member_name,
    mt.type_name                                         AS member_type,
    mt.max_fine_balance                                  AS policy_max_balance,
    SUM(f.amount_assessed - f.amount_paid)               AS unpaid_balance,
    SUM(f.amount_assessed - f.amount_paid)
        - mt.max_fine_balance                            AS amount_over_limit,
    COUNT(f.fine_id)                                     AS unpaid_fine_count
FROM       member      AS m
INNER JOIN member_type AS mt ON mt.member_type_id = m.member_type_id
INNER JOIN loan        AS l  ON l.member_id       = m.member_id
INNER JOIN fine        AS f  ON f.loan_id         = l.loan_id
WHERE f.fine_status IN ('PENDING', 'PARTIAL')
GROUP BY m.member_id,
         m.university_id,
         m.first_name,
         m.last_name,
         mt.type_name,
         mt.max_fine_balance
HAVING SUM(f.amount_assessed - f.amount_paid) > mt.max_fine_balance
ORDER BY amount_over_limit DESC;


-- =============================================================================
-- Query 4
-- Business question:
--   Which books have active reservations but no currently available copies?
-- SQL techniques:
--   EXISTS (active reservations), NOT EXISTS (no available copies),
--   INNER JOIN, GROUP BY, COUNT.
-- Why it matters:
--   These are the titles where the hold queue is stalled because there is
--   physically nothing on the shelf. Acquisitions/ILL staff use this list to
--   expedite purchases or borrow a copy from a partner library.
-- =============================================================================
SELECT
    b.book_id                              AS book_id,
    b.isbn13                               AS isbn13,
    b.title                                AS book_title,
    COUNT(r.reservation_id)                AS active_reservations,
    MIN(r.reserve_date)                    AS oldest_reservation_date
FROM       book        AS b
INNER JOIN reservation AS r ON r.book_id = b.book_id
WHERE r.reservation_status = 'ACTIVE'
  AND EXISTS (
        SELECT 1
        FROM reservation AS r2
        WHERE r2.book_id            = b.book_id
          AND r2.reservation_status = 'ACTIVE'
  )
  AND NOT EXISTS (
        SELECT 1
        FROM book_copy AS bc
        WHERE bc.book_id     = b.book_id
          AND bc.copy_status = 'AVAILABLE'
  )
GROUP BY b.book_id, b.isbn13, b.title
ORDER BY active_reservations DESC,
         oldest_reservation_date ASC;


-- =============================================================================
-- Query 5
-- Business question:
--   Which staff members processed the most checkouts by month?
-- SQL techniques:
--   INNER JOIN, DATE_FORMAT, GROUP BY, ORDER BY, COUNT.
-- Why it matters:
--   Circulation managers use this to measure staff workload, plan coverage,
--   and identify training needs during peak periods (start of semester,
--   finals week). Shaped for an R Studio time-series / grouped-bar chart
--   (x = checkout_month, fill = staff_name, y = checkouts_processed).
-- =============================================================================
SELECT
    DATE_FORMAT(l.checkout_date, '%Y-%m')             AS checkout_month,
    s.staff_id                                        AS staff_id,
    CONCAT(s.first_name, ' ', s.last_name)            AS staff_name,
    s.role                                            AS staff_role,
    COUNT(l.loan_id)                                  AS checkouts_processed
FROM       staff AS s
INNER JOIN loan  AS l ON l.checkout_staff_id = s.staff_id
GROUP BY DATE_FORMAT(l.checkout_date, '%Y-%m'),
         s.staff_id,
         s.first_name,
         s.last_name,
         s.role
ORDER BY checkout_month      ASC,
         checkouts_processed DESC,
         staff_name          ASC;


-- =============================================================================
-- Query 6
-- Business question:
--   Which books have never been loaned?
-- SQL techniques:
--   LEFT JOIN (book -> book_copy -> loan), WHERE ... IS NULL.
-- Why it matters:
--   Highlights underused inventory. Titles with no circulation history may
--   be candidates for promotion (displays, reading lists), relocation to a
--   more prominent shelf, or weeding after a defined grace period.
-- =============================================================================
SELECT
    b.book_id                    AS book_id,
    b.isbn13                     AS isbn13,
    b.title                      AS book_title,
    p.publisher_name             AS publisher_name,
    b.publication_year           AS publication_year,
    COUNT(bc.book_copy_id)       AS copies_on_shelf
FROM      book      AS b
INNER JOIN publisher AS p  ON p.publisher_id  = b.publisher_id
LEFT JOIN book_copy AS bc ON bc.book_id      = b.book_id
LEFT JOIN loan      AS l  ON l.book_copy_id  = bc.book_copy_id
WHERE l.loan_id IS NULL
GROUP BY b.book_id, b.isbn13, b.title, p.publisher_name, b.publication_year
ORDER BY b.publication_year DESC,
         b.title ASC;


-- =============================================================================
-- Query 7
-- Business question:
--   What is the average loan duration by member type for returned loans?
-- SQL techniques:
--   INNER JOIN, WHERE (non-null return_date), AVG, DATEDIFF, GROUP BY,
--   ORDER BY, MIN, MAX.
-- Why it matters:
--   Compares real borrowing behavior to the configured `loan_period_days`
--   per tier. If faculty on average keep books longer than their loan
--   period, policy adjustment or renewal workflow improvements may be
--   warranted.
-- =============================================================================
SELECT
    mt.type_name                                         AS member_type,
    mt.loan_period_days                                  AS policy_loan_period_days,
    COUNT(l.loan_id)                                     AS returned_loans,
    ROUND(AVG(DATEDIFF(l.return_date, l.checkout_date)), 2)
                                                         AS avg_loan_days,
    MIN(DATEDIFF(l.return_date, l.checkout_date))        AS shortest_loan_days,
    MAX(DATEDIFF(l.return_date, l.checkout_date))        AS longest_loan_days
FROM       member_type AS mt
INNER JOIN member      AS m  ON m.member_type_id = mt.member_type_id
INNER JOIN loan        AS l  ON l.member_id      = m.member_id
WHERE l.return_date IS NOT NULL
GROUP BY mt.member_type_id, mt.type_name, mt.loan_period_days
ORDER BY avg_loan_days DESC;


-- =============================================================================
-- Query 8
-- Business question:
--   Which members currently have the most active loans, and how close are
--   they to their checkout limit?
-- SQL techniques:
--   INNER JOIN, WHERE (return_date IS NULL), GROUP BY, COUNT, ORDER BY,
--   arithmetic on aggregate vs. policy column.
-- Why it matters:
--   Front-desk staff use this to spot members approaching their
--   `max_active_loans` ceiling and to coach power-users on returns. It also
--   surfaces potential policy violations if `remaining_capacity` goes
--   negative.
-- =============================================================================
SELECT
    m.member_id                                           AS member_id,
    m.university_id                                       AS member_university_id,
    CONCAT(m.first_name, ' ', m.last_name)                AS member_name,
    mt.type_name                                          AS member_type,
    mt.max_active_loans                                   AS max_active_loans,
    COUNT(l.loan_id)                                      AS active_loan_count,
    mt.max_active_loans - COUNT(l.loan_id)                AS remaining_capacity
FROM       member      AS m
INNER JOIN member_type AS mt ON mt.member_type_id = m.member_type_id
INNER JOIN loan        AS l  ON l.member_id       = m.member_id
WHERE l.return_date IS NULL
GROUP BY m.member_id,
         m.university_id,
         m.first_name,
         m.last_name,
         mt.type_name,
         mt.max_active_loans
ORDER BY active_loan_count DESC,
         member_name ASC;


-- =============================================================================
-- Query 9  (OPTIONAL - Fine collection summary by status)
-- Business question:
--   What is the current state of the fine book: how much has been assessed,
--   collected, waived, and written off, broken down by fine_status?
-- SQL techniques:
--   GROUP BY, SUM, COUNT, AVG, ORDER BY.
-- Why it matters:
--   The business office uses this monthly snapshot for revenue reporting
--   and bad-debt reserves. It is also the simplest "executive dashboard"
--   slice of library financial health.
-- =============================================================================
SELECT
    f.fine_status                        AS fine_status,
    COUNT(f.fine_id)                     AS fine_count,
    SUM(f.amount_assessed)               AS total_assessed,
    SUM(f.amount_paid)                   AS total_collected,
    SUM(f.amount_assessed - f.amount_paid) AS total_outstanding,
    ROUND(AVG(f.amount_assessed), 2)     AS avg_fine_amount
FROM fine AS f
GROUP BY f.fine_status
ORDER BY total_outstanding DESC;


-- =============================================================================
-- Query 10  (OPTIONAL - Books with multiple authors, one row per title)
-- Business question:
--   For catalog display, what is the full author list for every multi-author
--   book in the collection?
-- SQL techniques:
--   INNER JOIN, GROUP BY, GROUP_CONCAT (ordered), HAVING, COUNT.
-- Why it matters:
--   The OPAC (public catalog) needs a single "by:" line per title. Using
--   GROUP_CONCAT with ORDER BY author_order preserves cite order (primary
--   author first) without shipping multiple rows to the UI layer.
-- =============================================================================
SELECT
    b.book_id                                                     AS book_id,
    b.isbn13                                                      AS isbn13,
    b.title                                                       AS book_title,
    COUNT(ba.author_id)                                           AS author_count,
    GROUP_CONCAT(
        CONCAT(a.first_name, ' ', a.last_name)
        ORDER BY ba.author_order ASC
        SEPARATOR '; '
    )                                                             AS author_list
FROM       book        AS b
INNER JOIN book_author AS ba ON ba.book_id   = b.book_id
INNER JOIN author      AS a  ON a.author_id  = ba.author_id
GROUP BY b.book_id, b.isbn13, b.title
HAVING COUNT(ba.author_id) > 1
ORDER BY author_count DESC,
         b.title ASC;


-- =============================================================================
-- Query 11  (DATA-QUALITY / OPERATIONAL-RISK CHECK)
-- Business question:
--   Are there any physical copies marked `copy_status = 'AVAILABLE'` that
--   are simultaneously tied to an open loan (return_date IS NULL)?
-- SQL techniques:
--   INNER JOIN, WHERE, EXISTS-style integrity check via join.
-- Why it matters:
--   This is a true data-integrity contradiction: a copy cannot be on the
--   shelf AND checked out. Rows returned here indicate that either the
--   return workflow failed to update `copy_status` or a manual status edit
--   desynchronized inventory from circulation. These must be reconciled
--   daily; patrons looking up "AVAILABLE" copies that are actually
--   checked out produce angry support tickets.
-- =============================================================================
SELECT
    bc.book_copy_id                              AS book_copy_id,
    bc.barcode                                   AS barcode,
    bc.copy_status                               AS recorded_copy_status,
    b.title                                      AS book_title,
    l.loan_id                                    AS open_loan_id,
    l.checkout_date                              AS checkout_date,
    l.due_date                                   AS due_date,
    CONCAT(m.first_name, ' ', m.last_name)       AS borrower_name,
    'AVAILABLE status with open loan'            AS integrity_issue
FROM       book_copy AS bc
INNER JOIN loan      AS l  ON l.book_copy_id = bc.book_copy_id
INNER JOIN book      AS b  ON b.book_id      = bc.book_id
INNER JOIN member    AS m  ON m.member_id    = l.member_id
WHERE bc.copy_status = 'AVAILABLE'
  AND l.return_date IS NULL
ORDER BY l.checkout_date ASC;


-- =============================================================================
-- Query 12  (OPTIONAL - Expired members who still have active loans)
-- Business question:
--   Which members whose accounts have EXPIRED still have material checked
--   out that has not been returned?
-- SQL techniques:
--   INNER JOIN, WHERE, DATEDIFF, ORDER BY.
-- Why it matters:
--   Patrons whose borrowing privileges have lapsed should have no open
--   loans. These rows represent collection risk (the member may be off
--   campus and no longer reachable) and policy violations that the
--   circulation manager must resolve individually.
-- =============================================================================
SELECT
    m.member_id                                    AS member_id,
    m.university_id                                AS member_university_id,
    CONCAT(m.first_name, ' ', m.last_name)         AS member_name,
    m.email                                        AS member_email,
    m.status                                       AS member_status,
    m.expiration_date                              AS account_expiration_date,
    DATEDIFF(CURRENT_DATE, m.expiration_date)      AS days_since_expiration,
    COUNT(l.loan_id)                               AS active_loan_count
FROM       member AS m
INNER JOIN loan   AS l ON l.member_id = m.member_id
WHERE m.status        = 'EXPIRED'
  AND l.return_date IS NULL
GROUP BY m.member_id,
         m.university_id,
         m.first_name,
         m.last_name,
         m.email,
         m.status,
         m.expiration_date
ORDER BY days_since_expiration DESC,
         active_loan_count     DESC;


-- =============================================================================
-- Query 13  (OPTIONAL - Yearly acquisition vs. circulation trend)
-- Business question:
--   By publication year, how many titles do we own versus how many of them
--   have ever been loaned?
-- SQL techniques:
--   LEFT JOIN, YEAR(), GROUP BY, COUNT (DISTINCT + conditional),
--   ORDER BY.
-- Why it matters:
--   Helps detect "acquisition drift" -- years where we bought heavily but
--   circulation is weak. Also shaped for an R Studio line / area chart
--   (x = publication_year, y = titles vs. loaned_titles).
-- =============================================================================
SELECT
    b.publication_year                                          AS publication_year,
    COUNT(DISTINCT b.book_id)                                   AS titles_in_catalog,
    COUNT(DISTINCT CASE WHEN l.loan_id IS NOT NULL
                        THEN b.book_id END)                     AS titles_ever_loaned,
    COUNT(l.loan_id)                                            AS total_loans
FROM      book      AS b
LEFT JOIN book_copy AS bc ON bc.book_id     = b.book_id
LEFT JOIN loan      AS l  ON l.book_copy_id = bc.book_copy_id
WHERE b.publication_year IS NOT NULL
GROUP BY b.publication_year
ORDER BY b.publication_year ASC;


-- =============================================================================
-- Diagnostic example (commented out - left as an intentional SELECT * case)
-- Uncomment in MySQL Workbench to inspect a single loan row end-to-end:
--
-- SELECT * FROM loan WHERE return_date IS NULL LIMIT 5;
--
-- =============================================================================
-- End of library_management_analytical_queries.sql
-- =============================================================================
