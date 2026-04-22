-- =============================================================================
-- Library Management System - DDL Build Script
-- Course: BIS 3753 Database Management
-- Target: MySQL 8.0 (InnoDB, utf8mb4)
--
-- This script drops and recreates the `library_management` database and all
-- of its objects. It demonstrates normalization (3NF), primary and foreign
-- keys, bridge tables for many-to-many relationships, CHECK constraints,
-- stored generated columns, and supporting indexes.
--
-- Execution order (respecting FK dependencies):
--   1. Reference tables    : publisher, category, member_type
--   2. Bibliographic tables: author, book
--   3. Bridge tables       : book_author, book_category
--   4. People tables       : staff, member
--   5. Inventory tables    : book_copy
--   6. Transaction tables  : loan, reservation
--   7. Financial tables    : fine
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Database (re)creation
-- Using utf8mb4 so the database can store the full Unicode range (including
-- emoji and non-Latin scripts found in author and title metadata).
-- utf8mb4_0900_ai_ci is MySQL 8.0's default accent- and case-insensitive
-- collation, which is appropriate for library searches on titles / names.
-- -----------------------------------------------------------------------------
DROP DATABASE IF EXISTS library_management;
CREATE DATABASE library_management
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;
USE library_management;

-- =============================================================================
-- Reference tables
-- Small lookup tables that describe enumerated domains used by larger tables.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table: publisher
-- Stores distinct book publishers. publisher_name is UNIQUE so we do not
-- create duplicate publisher rows for the same company.
-- -----------------------------------------------------------------------------
CREATE TABLE publisher (
    publisher_id    INT             NOT NULL AUTO_INCREMENT,
    publisher_name  VARCHAR(150)    NOT NULL,
    city            VARCHAR(80)     NULL,
    country         VARCHAR(80)     NULL,
    website_url     VARCHAR(255)    NULL,
    contact_email   VARCHAR(150)    NULL,
    CONSTRAINT pk_publisher PRIMARY KEY (publisher_id),
    CONSTRAINT uq_publisher_name UNIQUE (publisher_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- -----------------------------------------------------------------------------
-- Table: category
-- Genre / subject lookup used via the book_category bridge table.
-- -----------------------------------------------------------------------------
CREATE TABLE category (
    category_id     INT             NOT NULL AUTO_INCREMENT,
    category_name   VARCHAR(100)    NOT NULL,
    description     VARCHAR(255)    NULL,
    CONSTRAINT pk_category PRIMARY KEY (category_id),
    CONSTRAINT uq_category_name UNIQUE (category_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- -----------------------------------------------------------------------------
-- Table: member_type
-- Defines borrowing policy tiers (e.g., Undergraduate, Graduate, Faculty,
-- Staff). A member's type drives loan count, loan period, and fine limits.
-- -----------------------------------------------------------------------------
CREATE TABLE member_type (
    member_type_id      INT             NOT NULL AUTO_INCREMENT,
    type_name           VARCHAR(50)     NOT NULL,
    max_active_loans    TINYINT         NOT NULL,
    loan_period_days    TINYINT         NOT NULL,
    fine_rate_per_day   DECIMAL(5,2)    NOT NULL,
    max_fine_balance    DECIMAL(7,2)    NOT NULL,
    can_reserve         BOOLEAN         NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_member_type PRIMARY KEY (member_type_id),
    CONSTRAINT uq_member_type_name UNIQUE (type_name),
    CONSTRAINT ck_member_type_max_loans     CHECK (max_active_loans >= 0),
    CONSTRAINT ck_member_type_period        CHECK (loan_period_days > 0),
    CONSTRAINT ck_member_type_fine_rate     CHECK (fine_rate_per_day >= 0),
    CONSTRAINT ck_member_type_fine_balance  CHECK (max_fine_balance >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- =============================================================================
-- Bibliographic tables
-- Describe the intellectual content (authors and titles) owned by the library.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table: author
-- A person who wrote one or more books. Books and authors are many-to-many
-- via the book_author bridge table.
-- -----------------------------------------------------------------------------
CREATE TABLE author (
    author_id   INT             NOT NULL AUTO_INCREMENT,
    first_name  VARCHAR(80)     NOT NULL,
    last_name   VARCHAR(80)     NOT NULL,
    birth_year  SMALLINT        NULL,
    death_year  SMALLINT        NULL,
    CONSTRAINT pk_author PRIMARY KEY (author_id),
    CONSTRAINT ck_author_birth_year
        CHECK (birth_year IS NULL OR birth_year >= 0),
    CONSTRAINT ck_author_death_after_birth
        CHECK (death_year IS NULL OR birth_year IS NULL OR death_year >= birth_year)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- -----------------------------------------------------------------------------
-- Table: book
-- Represents a bibliographic title (NOT a physical copy). Each physical
-- item on the shelf is a row in book_copy that references this table.
-- isbn13 is UNIQUE because ISBN-13 is the industry-standard unique title key.
-- -----------------------------------------------------------------------------
CREATE TABLE book (
    book_id             INT             NOT NULL AUTO_INCREMENT,
    isbn13              CHAR(13)        NOT NULL,
    title               VARCHAR(255)    NOT NULL,
    publisher_id        INT             NOT NULL,
    publication_year    SMALLINT        NULL,
    edition             VARCHAR(50)     NULL,
    language_code       CHAR(2)         NOT NULL DEFAULT 'EN',
    created_at          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_book PRIMARY KEY (book_id),
    CONSTRAINT uq_book_isbn13 UNIQUE (isbn13),
    CONSTRAINT fk_book_publisher
        FOREIGN KEY (publisher_id) REFERENCES publisher (publisher_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT ck_book_publication_year
        CHECK (publication_year IS NULL OR publication_year BETWEEN 1450 AND 2100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Index to speed up listing all books from a given publisher.
CREATE INDEX ix_book_publisher_id ON book (publisher_id);

-- =============================================================================
-- Bridge tables
-- Resolve many-to-many relationships between books and authors/categories.
-- Composite primary keys prevent duplicate associations.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table: book_author
-- Many-to-many bridge: a book may have multiple authors and an author may
-- write multiple books. author_order preserves byline sequence (1 = first
-- listed author) and is required to be positive.
-- -----------------------------------------------------------------------------
CREATE TABLE book_author (
    book_id         INT         NOT NULL,
    author_id       INT         NOT NULL,
    author_order    TINYINT     NOT NULL,
    CONSTRAINT pk_book_author PRIMARY KEY (book_id, author_id),
    CONSTRAINT fk_book_author_book
        FOREIGN KEY (book_id) REFERENCES book (book_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_book_author_author
        FOREIGN KEY (author_id) REFERENCES author (author_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT ck_book_author_order CHECK (author_order > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Secondary lookup direction (author -> their books). The composite PK
-- already supports book -> authors lookups.
CREATE INDEX ix_book_author_author_id ON book_author (author_id);

-- -----------------------------------------------------------------------------
-- Table: book_category
-- Many-to-many bridge between book and category. A book may be classified
-- under several subjects and vice versa.
-- -----------------------------------------------------------------------------
CREATE TABLE book_category (
    book_id     INT NOT NULL,
    category_id INT NOT NULL,
    CONSTRAINT pk_book_category PRIMARY KEY (book_id, category_id),
    CONSTRAINT fk_book_category_book
        FOREIGN KEY (book_id) REFERENCES book (book_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_book_category_category
        FOREIGN KEY (category_id) REFERENCES category (category_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Secondary lookup direction (category -> all books in it).
CREATE INDEX ix_book_category_category_id ON book_category (category_id);

-- =============================================================================
-- People tables
-- Library staff who process circulation and members who borrow material.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table: staff
-- Library employees who check out and return books. university_id and email
-- are each independently UNIQUE so neither can be duplicated across staff.
-- -----------------------------------------------------------------------------
CREATE TABLE staff (
    staff_id        INT                                     NOT NULL AUTO_INCREMENT,
    university_id   VARCHAR(20)                             NOT NULL,
    first_name      VARCHAR(80)                             NOT NULL,
    last_name       VARCHAR(80)                             NOT NULL,
    email           VARCHAR(150)                            NOT NULL,
    role            ENUM('LIBRARIAN','ASSISTANT','ADMIN')   NOT NULL,
    hire_date       DATE                                    NOT NULL,
    status          ENUM('ACTIVE','INACTIVE')               NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT pk_staff PRIMARY KEY (staff_id),
    CONSTRAINT uq_staff_university_id UNIQUE (university_id),
    CONSTRAINT uq_staff_email         UNIQUE (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- -----------------------------------------------------------------------------
-- Table: member
-- Library patrons. A member's borrowing rules are governed by member_type.
-- expiration_date enforces card validity windows.
-- -----------------------------------------------------------------------------
CREATE TABLE member (
    member_id           INT                                         NOT NULL AUTO_INCREMENT,
    university_id       VARCHAR(20)                                 NOT NULL,
    member_type_id      INT                                         NOT NULL,
    first_name          VARCHAR(80)                                 NOT NULL,
    last_name           VARCHAR(80)                                 NOT NULL,
    email               VARCHAR(150)                                NOT NULL,
    phone               VARCHAR(25)                                 NULL,
    status              ENUM('ACTIVE','SUSPENDED','EXPIRED')        NOT NULL DEFAULT 'ACTIVE',
    registration_date   DATE                                        NOT NULL,
    expiration_date     DATE                                        NOT NULL,
    CONSTRAINT pk_member PRIMARY KEY (member_id),
    CONSTRAINT uq_member_university_id UNIQUE (university_id),
    CONSTRAINT uq_member_email         UNIQUE (email),
    CONSTRAINT fk_member_member_type
        FOREIGN KEY (member_type_id) REFERENCES member_type (member_type_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT ck_member_expiration
        CHECK (expiration_date >= registration_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Speed up joins / filters by membership tier.
CREATE INDEX ix_member_member_type_id ON member (member_type_id);

-- =============================================================================
-- Inventory tables
-- Physical copies on the shelf. Circulation (loans) happens at the copy
-- level (by barcode), not at the title level.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table: book_copy
-- A single physical item. Each copy has its own barcode, shelf location, and
-- status. Loans reference book_copy_id because the library circulates
-- individual copies, not abstract titles.
-- -----------------------------------------------------------------------------
CREATE TABLE book_copy (
    book_copy_id        INT                                                         NOT NULL AUTO_INCREMENT,
    book_id             INT                                                         NOT NULL,
    barcode             VARCHAR(40)                                                 NOT NULL,
    acquisition_date    DATE                                                        NOT NULL,
    copy_status         ENUM('AVAILABLE','ON_LOAN','RESERVED','LOST','DAMAGED')     NOT NULL DEFAULT 'AVAILABLE',
    shelf_location      VARCHAR(50)                                                 NOT NULL,
    CONSTRAINT pk_book_copy PRIMARY KEY (book_copy_id),
    CONSTRAINT uq_book_copy_barcode UNIQUE (barcode),
    CONSTRAINT fk_book_copy_book
        FOREIGN KEY (book_id) REFERENCES book (book_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Needed for "list all copies of this title" lookups.
CREATE INDEX ix_book_copy_book_id ON book_copy (book_id);
-- Helpful for dashboards that group copies by status.
CREATE INDEX ix_book_copy_status  ON book_copy (copy_status);

-- =============================================================================
-- Transaction tables
-- Circulation history: loans (checkouts/returns) and reservations (holds).
-- Both are append-only transaction logs; parent deletes are RESTRICTed so
-- history is preserved.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table: loan
-- One row per checkout event. A loan is "active" while return_date IS NULL.
--
-- The active_copy_key generated column equals book_copy_id for active loans
-- and NULL otherwise. A UNIQUE index on that column guarantees that a given
-- physical copy cannot be on two active loans simultaneously, while still
-- permitting any number of historical (returned) loans for the same copy
-- because MySQL allows multiple NULLs in a UNIQUE index.
-- -----------------------------------------------------------------------------
CREATE TABLE loan (
    loan_id             INT                                             NOT NULL AUTO_INCREMENT,
    book_copy_id        INT                                             NOT NULL,
    member_id           INT                                             NOT NULL,
    checkout_staff_id   INT                                             NOT NULL,
    return_staff_id     INT                                             NULL,
    checkout_date       DATE                                            NOT NULL,
    due_date            DATE                                            NOT NULL,
    return_date         DATE                                            NULL,
    loan_status         ENUM('ACTIVE','OVERDUE','RETURNED','LOST')      NOT NULL DEFAULT 'ACTIVE',
    active_copy_key     INT
        GENERATED ALWAYS AS
            (CASE WHEN return_date IS NULL THEN book_copy_id ELSE NULL END) STORED,
    CONSTRAINT pk_loan PRIMARY KEY (loan_id),
    CONSTRAINT uq_loan_active_copy UNIQUE (active_copy_key),
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
    CONSTRAINT ck_loan_due_after_checkout
        CHECK (due_date >= checkout_date),
    CONSTRAINT ck_loan_return_after_checkout
        CHECK (return_date IS NULL OR return_date >= checkout_date),
    CONSTRAINT ck_loan_returned_has_date
        CHECK (loan_status <> 'RETURNED' OR return_date IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Circulation reporting indexes.
CREATE INDEX ix_loan_book_copy_id       ON loan (book_copy_id);
CREATE INDEX ix_loan_member_id          ON loan (member_id);
CREATE INDEX ix_loan_checkout_staff_id  ON loan (checkout_staff_id);
CREATE INDEX ix_loan_return_staff_id    ON loan (return_staff_id);
CREATE INDEX ix_loan_loan_status        ON loan (loan_status);
CREATE INDEX ix_loan_due_date           ON loan (due_date);

-- -----------------------------------------------------------------------------
-- Table: reservation
-- Title-level holds. A member reserves a book (by title), and when any copy
-- becomes available the reservation is fulfilled.
--
-- The active_reservation_key generated column equals "member_id-book_id"
-- while the reservation is ACTIVE and NULL otherwise. A UNIQUE index on it
-- prevents a member from holding two simultaneous active reservations for
-- the same title, while still allowing any number of historical
-- FULFILLED / CANCELLED / EXPIRED reservations.
-- -----------------------------------------------------------------------------
CREATE TABLE reservation (
    reservation_id          INT                                                 NOT NULL AUTO_INCREMENT,
    book_id                 INT                                                 NOT NULL,
    member_id               INT                                                 NOT NULL,
    reserve_date            DATE                                                NOT NULL,
    expiration_date         DATE                                                NOT NULL,
    fulfilled_date          DATE                                                NULL,
    reservation_status      ENUM('ACTIVE','FULFILLED','CANCELLED','EXPIRED')    NOT NULL DEFAULT 'ACTIVE',
    queue_position          INT                                                 NOT NULL,
    active_reservation_key  VARCHAR(60)
        GENERATED ALWAYS AS
            (CASE WHEN reservation_status = 'ACTIVE'
                  THEN CONCAT(member_id, '-', book_id)
                  ELSE NULL END) STORED,
    CONSTRAINT pk_reservation PRIMARY KEY (reservation_id),
    CONSTRAINT uq_reservation_active UNIQUE (active_reservation_key),
    CONSTRAINT fk_reservation_book
        FOREIGN KEY (book_id) REFERENCES book (book_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_reservation_member
        FOREIGN KEY (member_id) REFERENCES member (member_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT ck_reservation_expiration
        CHECK (expiration_date >= reserve_date),
    CONSTRAINT ck_reservation_fulfilled_after_reserve
        CHECK (fulfilled_date IS NULL OR fulfilled_date >= reserve_date),
    CONSTRAINT ck_reservation_queue_position
        CHECK (queue_position > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE INDEX ix_reservation_book_id             ON reservation (book_id);
CREATE INDEX ix_reservation_member_id           ON reservation (member_id);
CREATE INDEX ix_reservation_reservation_status  ON reservation (reservation_status);

-- =============================================================================
-- Financial tables
-- Fines assessed against specific loans (overdue or lost).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table: fine
-- A fine is associated 1:1 with a loan (loan_id is UNIQUE). The CHECK
-- constraints guarantee non-negative amounts and that paid never exceeds
-- assessed. fine_status is tracked independently to support partial
-- payments and administrative waivers.
-- -----------------------------------------------------------------------------
CREATE TABLE fine (
    fine_id             INT                                             NOT NULL AUTO_INCREMENT,
    loan_id             INT                                             NOT NULL,
    amount_assessed     DECIMAL(8,2)                                    NOT NULL,
    amount_paid         DECIMAL(8,2)                                    NOT NULL DEFAULT 0.00,
    fine_status         ENUM('PENDING','PARTIAL','PAID','WAIVED')       NOT NULL DEFAULT 'PENDING',
    assessed_date       DATE                                            NOT NULL,
    paid_date           DATE                                            NULL,
    waiver_reason       VARCHAR(255)                                    NULL,
    CONSTRAINT pk_fine PRIMARY KEY (fine_id),
    CONSTRAINT uq_fine_loan_id UNIQUE (loan_id),
    CONSTRAINT fk_fine_loan
        FOREIGN KEY (loan_id) REFERENCES loan (loan_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT ck_fine_amount_assessed
        CHECK (amount_assessed >= 0),
    CONSTRAINT ck_fine_amount_paid_nonneg
        CHECK (amount_paid >= 0),
    CONSTRAINT ck_fine_amount_paid_le_assessed
        CHECK (amount_paid <= amount_assessed),
    CONSTRAINT ck_fine_paid_after_assessed
        CHECK (paid_date IS NULL OR paid_date >= assessed_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE INDEX ix_fine_loan_id     ON fine (loan_id);
CREATE INDEX ix_fine_fine_status ON fine (fine_status);

-- =============================================================================
-- Verification queries
-- Uncomment and run these in MySQL Workbench after the script executes to
-- confirm that every object was created correctly.
-- =============================================================================
-- SHOW TABLES;
-- DESCRIBE publisher;
-- DESCRIBE category;
-- DESCRIBE member_type;
-- DESCRIBE author;
-- DESCRIBE book;
-- DESCRIBE book_author;
-- DESCRIBE book_category;
-- DESCRIBE staff;
-- DESCRIBE member;
-- DESCRIBE book_copy;
-- DESCRIBE loan;
-- DESCRIBE reservation;
-- DESCRIBE fine;
--
-- SHOW CREATE TABLE loan;
-- SHOW CREATE TABLE reservation;
-- SHOW CREATE TABLE fine;
--
-- -- Confirm foreign-key wiring:
-- SELECT table_name, column_name, referenced_table_name, referenced_column_name
-- FROM information_schema.key_column_usage
-- WHERE table_schema = 'library_management'
--   AND referenced_table_name IS NOT NULL
-- ORDER BY table_name, column_name;
--
-- -- Confirm CHECK constraints:
-- SELECT constraint_schema, table_name, constraint_name, check_clause
-- FROM information_schema.check_constraints
-- WHERE constraint_schema = 'library_management'
-- ORDER BY table_name, constraint_name;
-- =============================================================================
-- End of script
-- =============================================================================
