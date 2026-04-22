-- =============================================================================
-- Library Management System - MySQL 8.0 DDL Build Script
-- Course:   BIS 3753 Database Management
-- File:     library_management_schema.sql
-- Purpose:  Creates the `library_management` database schema.
--
-- Design highlights:
--   * InnoDB storage engine everywhere for FK + transaction support.
--   * utf8mb4 / utf8mb4_0900_ai_ci for full Unicode (incl. emoji) support.
--   * Tables created in strict FK-dependency order.
--   * Loans reference book_copy (physical inventory, barcode level).
--   * Reservations reference book (title level — queue for any copy).
--   * Generated columns + UNIQUE indexes enforce:
--       - one active loan per physical copy
--       - one active reservation per (member, book) pair
--     while still allowing historical rows via NULL-in-UNIQUE semantics.
--   * ON DELETE RESTRICT preserves transaction history; ON UPDATE CASCADE
--     lets surrogate keys be renumbered safely if ever required.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Database (re)creation
-- -----------------------------------------------------------------------------
DROP DATABASE IF EXISTS library_management;

CREATE DATABASE library_management
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;

USE library_management;


-- =============================================================================
-- 1. REFERENCE TABLES
-- Small lookup / policy tables that many other tables depend on.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- category — subject classifications a book can belong to (M:N via book_category)
-- -----------------------------------------------------------------------------
CREATE TABLE category (
    category_id   INT AUTO_INCREMENT PRIMARY KEY,
    category_name VARCHAR(100) NOT NULL UNIQUE,
    description   VARCHAR(255) NULL
) ENGINE=InnoDB;


-- -----------------------------------------------------------------------------
-- member_type — borrower policy tier (Student / Faculty / Staff / Alumni, etc.)
-- Drives loan limits, loan period, fine rate, and reservation rights.
-- -----------------------------------------------------------------------------
CREATE TABLE member_type (
    member_type_id     INT AUTO_INCREMENT PRIMARY KEY,
    type_name          VARCHAR(50)  NOT NULL UNIQUE,
    max_active_loans   TINYINT      NOT NULL,
    loan_period_days   TINYINT      NOT NULL,
    fine_rate_per_day  DECIMAL(5,2) NOT NULL,
    max_fine_balance   DECIMAL(7,2) NOT NULL,
    can_reserve        BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_member_type_max_loans   CHECK (max_active_loans  >= 0),
    CONSTRAINT chk_member_type_period      CHECK (loan_period_days  >  0),
    CONSTRAINT chk_member_type_fine_rate   CHECK (fine_rate_per_day >= 0),
    CONSTRAINT chk_member_type_fine_max    CHECK (max_fine_balance  >= 0)
) ENGINE=InnoDB;


-- =============================================================================
-- 2. BIBLIOGRAPHIC TABLES
-- Describe works/titles and the people/organizations behind them.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- publisher — organization that publishes a book (1:N -> book)
-- -----------------------------------------------------------------------------
CREATE TABLE publisher (
    publisher_id   INT AUTO_INCREMENT PRIMARY KEY,
    publisher_name VARCHAR(150) NOT NULL UNIQUE,
    city           VARCHAR(80)  NULL,
    country        VARCHAR(80)  NULL,
    website_url    VARCHAR(255) NULL,
    contact_email  VARCHAR(150) NULL
) ENGINE=InnoDB;


-- -----------------------------------------------------------------------------
-- author — individual contributor. M:N with book via bridge table book_author.
-- birth/death years are nullable because many records are incomplete.
-- -----------------------------------------------------------------------------
CREATE TABLE author (
    author_id  INT AUTO_INCREMENT PRIMARY KEY,
    first_name VARCHAR(80) NOT NULL,
    last_name  VARCHAR(80) NOT NULL,
    birth_year SMALLINT    NULL,
    death_year SMALLINT    NULL,
    CONSTRAINT chk_author_birth_year
        CHECK (birth_year IS NULL OR birth_year >= 0),
    CONSTRAINT chk_author_death_after_birth
        CHECK (death_year IS NULL OR birth_year IS NULL OR death_year >= birth_year)
) ENGINE=InnoDB;


-- -----------------------------------------------------------------------------
-- book — bibliographic title (one logical work; physical copies live in book_copy)
-- ISBN-13 is the natural key, enforced UNIQUE.
-- -----------------------------------------------------------------------------
CREATE TABLE book (
    book_id          INT AUTO_INCREMENT PRIMARY KEY,
    isbn13           CHAR(13)     NOT NULL UNIQUE,
    title            VARCHAR(255) NOT NULL,
    publisher_id     INT          NOT NULL,
    publication_year SMALLINT     NULL,
    edition          VARCHAR(50)  NULL,
    language_code    CHAR(2)      NOT NULL DEFAULT 'EN',
    created_at       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_book_publisher
        FOREIGN KEY (publisher_id) REFERENCES publisher (publisher_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_book_publication_year
        CHECK (publication_year IS NULL OR publication_year BETWEEN 1450 AND 2100)
) ENGINE=InnoDB;


-- =============================================================================
-- 3. BRIDGE TABLES
-- Resolve many-to-many relationships between books and authors/categories.
-- Composite PKs prevent duplicate associations; secondary indexes support
-- efficient lookups from the "other" side of the relationship.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- book_author — M:N between book and author, with author_order for citation order
-- -----------------------------------------------------------------------------
CREATE TABLE book_author (
    book_id      INT     NOT NULL,
    author_id    INT     NOT NULL,
    author_order TINYINT NOT NULL,
    PRIMARY KEY (book_id, author_id),
    CONSTRAINT fk_book_author_book
        FOREIGN KEY (book_id) REFERENCES book (book_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_book_author_author
        FOREIGN KEY (author_id) REFERENCES author (author_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_book_author_order CHECK (author_order > 0),
    INDEX idx_book_author_author (author_id)
) ENGINE=InnoDB;


-- -----------------------------------------------------------------------------
-- book_category — M:N between book and category
-- -----------------------------------------------------------------------------
CREATE TABLE book_category (
    book_id     INT NOT NULL,
    category_id INT NOT NULL,
    PRIMARY KEY (book_id, category_id),
    CONSTRAINT fk_book_category_book
        FOREIGN KEY (book_id) REFERENCES book (book_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_book_category_category
        FOREIGN KEY (category_id) REFERENCES category (category_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    INDEX idx_book_category_category (category_id)
) ENGINE=InnoDB;


-- =============================================================================
-- 4. PEOPLE TABLES
-- Library staff (operators) and members (borrowers).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- staff — library employees who process checkouts/returns
-- -----------------------------------------------------------------------------
CREATE TABLE staff (
    staff_id      INT AUTO_INCREMENT PRIMARY KEY,
    university_id VARCHAR(20)  NOT NULL UNIQUE,
    first_name    VARCHAR(80)  NOT NULL,
    last_name     VARCHAR(80)  NOT NULL,
    email         VARCHAR(150) NOT NULL UNIQUE,
    role          ENUM('LIBRARIAN', 'ASSISTANT', 'ADMIN') NOT NULL,
    hire_date     DATE NOT NULL,
    status        ENUM('ACTIVE', 'INACTIVE') NOT NULL DEFAULT 'ACTIVE'
) ENGINE=InnoDB;


-- -----------------------------------------------------------------------------
-- member — library patrons. FK to member_type drives borrowing privileges.
-- -----------------------------------------------------------------------------
CREATE TABLE member (
    member_id         INT AUTO_INCREMENT PRIMARY KEY,
    university_id     VARCHAR(20)  NOT NULL UNIQUE,
    member_type_id    INT          NOT NULL,
    first_name        VARCHAR(80)  NOT NULL,
    last_name         VARCHAR(80)  NOT NULL,
    email             VARCHAR(150) NOT NULL UNIQUE,
    phone             VARCHAR(25)  NULL,
    status            ENUM('ACTIVE', 'SUSPENDED', 'EXPIRED') NOT NULL DEFAULT 'ACTIVE',
    registration_date DATE NOT NULL,
    expiration_date   DATE NOT NULL,
    CONSTRAINT fk_member_member_type
        FOREIGN KEY (member_type_id) REFERENCES member_type (member_type_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_member_expiration
        CHECK (expiration_date >= registration_date)
) ENGINE=InnoDB;


-- =============================================================================
-- 5. INVENTORY TABLES
-- Physical, loanable copies of books. Each barcode == one row.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- book_copy — a physical, barcoded copy of a title. Loans reference this table.
-- -----------------------------------------------------------------------------
CREATE TABLE book_copy (
    book_copy_id     INT AUTO_INCREMENT PRIMARY KEY,
    book_id          INT NOT NULL,
    barcode          VARCHAR(40) NOT NULL UNIQUE,
    acquisition_date DATE NOT NULL,
    copy_status      ENUM('AVAILABLE', 'ON_LOAN', 'RESERVED', 'LOST', 'DAMAGED')
                     NOT NULL DEFAULT 'AVAILABLE',
    shelf_location   VARCHAR(50) NOT NULL,
    CONSTRAINT fk_book_copy_book
        FOREIGN KEY (book_id) REFERENCES book (book_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
) ENGINE=InnoDB;


-- =============================================================================
-- 6. TRANSACTION TABLES
-- Circulation events: loans (physical-copy level) and reservations (title level).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- loan — checkout/return transaction for a specific physical copy.
--
-- active_copy_key is a STORED generated column that equals book_copy_id while
-- the loan is open (return_date IS NULL) and NULL once returned. A UNIQUE index
-- on it therefore prevents two simultaneously-open loans for the same copy,
-- while still permitting unlimited historical returned rows (MySQL allows
-- multiple NULLs in a UNIQUE index).
-- -----------------------------------------------------------------------------
CREATE TABLE loan (
    loan_id           INT AUTO_INCREMENT PRIMARY KEY,
    book_copy_id      INT  NOT NULL,
    member_id         INT  NOT NULL,
    checkout_staff_id INT  NOT NULL,
    return_staff_id   INT  NULL,
    checkout_date     DATE NOT NULL,
    due_date          DATE NOT NULL,
    return_date       DATE NULL,
    loan_status       ENUM('ACTIVE', 'OVERDUE', 'RETURNED', 'LOST')
                      NOT NULL DEFAULT 'ACTIVE',
    active_copy_key   INT AS
        (CASE WHEN return_date IS NULL THEN book_copy_id ELSE NULL END) STORED,

    CONSTRAINT fk_loan_book_copy
        FOREIGN KEY (book_copy_id) REFERENCES book_copy (book_copy_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_loan_member
        FOREIGN KEY (member_id) REFERENCES member (member_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_loan_checkout_staff
        FOREIGN KEY (checkout_staff_id) REFERENCES staff (staff_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_loan_return_staff
        FOREIGN KEY (return_staff_id) REFERENCES staff (staff_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,

    CONSTRAINT chk_loan_due_after_checkout
        CHECK (due_date >= checkout_date),
    CONSTRAINT chk_loan_return_after_checkout
        CHECK (return_date IS NULL OR return_date >= checkout_date),
    CONSTRAINT chk_loan_returned_has_date
        CHECK (loan_status <> 'RETURNED' OR return_date IS NOT NULL),

    UNIQUE KEY uq_loan_active_copy (active_copy_key),
    INDEX idx_loan_book_copy      (book_copy_id),
    INDEX idx_loan_member         (member_id),
    INDEX idx_loan_checkout_staff (checkout_staff_id),
    INDEX idx_loan_return_staff   (return_staff_id),
    INDEX idx_loan_status         (loan_status),
    INDEX idx_loan_due_date       (due_date)
) ENGINE=InnoDB;


-- -----------------------------------------------------------------------------
-- reservation — title-level hold placed by a member.
--
-- A reservation is against a BOOK (title), not a specific copy, because any
-- returning copy of the title should be able to satisfy the next hold.
--
-- active_reservation_key is a STORED generated column equal to "<member_id>-<book_id>"
-- only while reservation_status = 'ACTIVE'; otherwise NULL. A UNIQUE index on
-- it prevents a member from having two simultaneous active holds on the same
-- title, while keeping fulfilled/cancelled/expired history unconstrained.
-- -----------------------------------------------------------------------------
CREATE TABLE reservation (
    reservation_id     INT AUTO_INCREMENT PRIMARY KEY,
    book_id            INT  NOT NULL,
    member_id          INT  NOT NULL,
    reserve_date       DATE NOT NULL,
    expiration_date    DATE NOT NULL,
    fulfilled_date     DATE NULL,
    reservation_status ENUM('ACTIVE', 'FULFILLED', 'CANCELLED', 'EXPIRED')
                       NOT NULL DEFAULT 'ACTIVE',
    queue_position     INT  NOT NULL,
    active_reservation_key VARCHAR(60) AS
        (CASE WHEN reservation_status = 'ACTIVE'
              THEN CONCAT(member_id, '-', book_id)
              ELSE NULL END) STORED,

    CONSTRAINT fk_reservation_book
        FOREIGN KEY (book_id) REFERENCES book (book_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_reservation_member
        FOREIGN KEY (member_id) REFERENCES member (member_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,

    CONSTRAINT chk_reservation_expiration
        CHECK (expiration_date >= reserve_date),
    CONSTRAINT chk_reservation_fulfilled_date
        CHECK (fulfilled_date IS NULL OR fulfilled_date >= reserve_date),
    CONSTRAINT chk_reservation_queue_position
        CHECK (queue_position > 0),

    UNIQUE KEY uq_reservation_active (active_reservation_key),
    INDEX idx_reservation_book   (book_id),
    INDEX idx_reservation_member (member_id),
    INDEX idx_reservation_status (reservation_status)
) ENGINE=InnoDB;


-- =============================================================================
-- 7. FINANCIAL TABLES
-- Fines assessed against loans for overdue/lost items.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- fine — 1:1 with loan (UNIQUE on loan_id). A single loan can produce at most
-- one fine record; payment is tracked via amount_paid + fine_status.
-- -----------------------------------------------------------------------------
CREATE TABLE fine (
    fine_id         INT AUTO_INCREMENT PRIMARY KEY,
    loan_id         INT          NOT NULL UNIQUE,
    amount_assessed DECIMAL(8,2) NOT NULL,
    amount_paid     DECIMAL(8,2) NOT NULL DEFAULT 0.00,
    fine_status     ENUM('PENDING', 'PARTIAL', 'PAID', 'WAIVED')
                    NOT NULL DEFAULT 'PENDING',
    assessed_date   DATE NOT NULL,
    paid_date       DATE NULL,
    waiver_reason   VARCHAR(255) NULL,

    CONSTRAINT fk_fine_loan
        FOREIGN KEY (loan_id) REFERENCES loan (loan_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,

    CONSTRAINT chk_fine_assessed_nonneg CHECK (amount_assessed >= 0),
    CONSTRAINT chk_fine_paid_nonneg     CHECK (amount_paid     >= 0),
    CONSTRAINT chk_fine_paid_le_assessed CHECK (amount_paid   <= amount_assessed),
    CONSTRAINT chk_fine_paid_date
        CHECK (paid_date IS NULL OR paid_date >= assessed_date),

    INDEX idx_fine_loan   (loan_id),
    INDEX idx_fine_status (fine_status)
) ENGINE=InnoDB;


-- =============================================================================
-- Verification queries
-- Run the statements below manually in MySQL Workbench after build to confirm
-- that the schema was created correctly.
-- =============================================================================
-- SHOW TABLES;
-- DESCRIBE loan;
-- DESCRIBE reservation;
-- SHOW CREATE TABLE loan;
-- SHOW CREATE TABLE reservation;
-- SHOW CREATE TABLE fine;
-- SELECT TABLE_NAME, ENGINE, TABLE_COLLATION
--   FROM information_schema.TABLES
--  WHERE TABLE_SCHEMA = 'library_management';
-- SELECT CONSTRAINT_NAME, TABLE_NAME, CONSTRAINT_TYPE
--   FROM information_schema.TABLE_CONSTRAINTS
--  WHERE TABLE_SCHEMA = 'library_management'
--  ORDER BY TABLE_NAME, CONSTRAINT_TYPE;
-- =============================================================================
-- End of library_management_schema.sql
-- =============================================================================
