-- =====================================================================
-- BookMyShow DBMS Project — CP3: Performance Indexes
-- File   : sql/05_indexes.sql
-- Purpose: Targeted B-tree, composite, partial, and covering indexes
--          designed from baseline EXPLAIN (ANALYZE, BUFFERS) output.
--          Every index is commented with its purpose, affected columns,
--          relevant query IDs, and justification.
--
-- Run with:  psql -d bms_db -f sql/05_indexes.sql
-- Safe to re-run: all statements use IF NOT EXISTS.
-- =====================================================================

SET search_path TO bms;

-- =====================================================================
-- TABLE: bookings
-- Baseline problem: only PK and booking_code UNIQUE exist.
-- All FK columns (customer_id, show_id) have zero indexes, causing
-- repeated full seq scans across the 150 K-row bookings table.
-- =====================================================================

-- ---------------------------------------------------------------------
-- IDX-B1: bookings(customer_id)
-- Purpose : Look up all bookings for a specific customer.
-- Queries : R05 — "My bookings" for customer 1331 (11.6 ms baseline).
--           Baseline plan performed a full seq scan of 150 K rows just
--           to find the handful of rows for one customer.
-- Type    : B-tree (default) — equality lookup on a foreign key.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_bookings_customer_id
    ON bms.bookings (customer_id);

-- ---------------------------------------------------------------------
-- IDX-B2: bookings(show_id)
-- Purpose : Look up all bookings for a specific show (FK to shows).
-- Queries : R08 (24.3 ms), R12 (155 ms), R16 (40.2 ms),
--           R18 (127.2 ms), R19 (2366.7 ms — correlated subquery
--           ran a full seq scan of bookings 207 times), W02, W04.
-- Type    : B-tree — equality join/lookup on show_id.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_bookings_show_id
    ON bms.bookings (show_id);

-- ---------------------------------------------------------------------
-- IDX-B3: bookings(status, booked_at)
-- Purpose : Filter by booking status first (low cardinality prefix),
--           then restrict by timestamp range, satisfying ORDER BY
--           booked_at without a sort step.
-- Queries : R09 (9.9 ms — PENDING > 10 min), R20 (29.9 ms — daily
--           confirmed collections), R21 (94.5 ms — loyalty top-20),
--           R22 (70 ms — support console paginated),
--           W02 (min PENDING booking_id), W04 (delete expired PENDING).
-- Type    : Composite B-tree — status (equality) + booked_at (range).
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_bookings_status_booked_at
    ON bms.bookings (status, booked_at);

-- ---------------------------------------------------------------------
-- IDX-B4: bookings(offer_code) WHERE offer_code IS NOT NULL  [partial]
-- Purpose : Support the corrected R13 NOT EXISTS rewrite.
--           A partial index skips the ~95 % of bookings rows where
--           offer_code IS NULL (bookings with no offer applied),
--           making the NOT EXISTS subquery very cheap.
-- Queries : R13 (24.8 ms — offers never redeemed).
-- Type    : Partial B-tree — only indexes rows where offer was used.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_bookings_offer_code
    ON bms.bookings (offer_code)
    WHERE offer_code IS NOT NULL;

-- ---------------------------------------------------------------------
-- IDX-B5: bookings(booked_at DESC) INCLUDE(...)  [covering]
-- Purpose : Eliminate the full seq scan + 100 K row skip for the
--           high-offset pagination query R22.  The covering INCLUDE
--           columns allow an Index Only Scan; no heap fetch needed
--           for any column in the SELECT list.
-- Queries : R22 (70 ms — support console OFFSET 100000 LIMIT 25).
-- Type    : Covering B-tree (INCLUDE) — avoids heap access entirely.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_bookings_booked_at_desc
    ON bms.bookings (booked_at DESC)
    INCLUDE (booking_id, booking_code, customer_id, show_id, status);

-- =====================================================================
-- TABLE: shows
-- Baseline: only shows_pkey and the GiST exclusion constraint exist.
-- movie_id and screen_id FK columns have no plain B-tree indexes,
-- forcing seq scans on the 80 K-row shows table.
-- =====================================================================

-- ---------------------------------------------------------------------
-- IDX-S1: shows(movie_id, starts_at)
-- Purpose : Filter shows for a movie within a date/time range.
--           Composite order lets PostgreSQL use the index for both the
--           equality predicate on movie_id AND the range predicate on
--           starts_at in one index scan.
-- Queries : R01 (8.6 ms — home page, movie aggregation),
--           R02 (6.0 ms — showtimes for movie 2 in city 1),
--           R08 (24.3 ms — box-office weekend),
--           R18 (127.2 ms — regional collections, year range),
--           R19 (2366.7 ms — correlated subquery on shows for movie 2),
--           W05 (9.4 ms — price update for July weekend shows).
-- Type    : Composite B-tree — equality + range.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_shows_movie_id_starts_at
    ON bms.shows (movie_id, starts_at);

-- ---------------------------------------------------------------------
-- IDX-S2: shows(screen_id, starts_at)
-- Purpose : Self-join in R10 joins shows to itself on screen_id; both
--           sides currently do full seq scans.  This index makes the
--           inner side an index range scan filtered by screen_id and
--           starts_at, cutting the join fanout dramatically.
--           Also helps R07, R16, R17, R25 which filter shows by venue
--           or time and join through screen_id.
-- Queries : R07 (1.1 ms), R10 (486.7 ms — self-join),
--           R16 (40.2 ms), R17 (62.3 ms), R25 (40.6 ms).
-- Type    : Composite B-tree — equality + range.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_shows_screen_id_starts_at
    ON bms.shows (screen_id, starts_at);

-- =====================================================================
-- TABLE: booking_seats
-- Baseline: only the PK (booking_id, seat_id) and the UNIQUE
--           (show_id, seat_id) exist.  seat_id as a standalone FK
--           has no index, causing seq scans when joining to seats.
-- =====================================================================

-- ---------------------------------------------------------------------
-- IDX-BS1: booking_seats(seat_id)
-- Purpose : Join booking_seats → seats on seat_id.  The existing
--           PK starts with booking_id; PostgreSQL cannot use it for a
--           pure seat_id lookup.  This new index enables Index Scan or
--           Bitmap Index Scan when joining to seats.
-- Queries : R11 (93.3 ms — recliner revenue mix),
--           R17 (62.3 ms — unsold seats NOT EXISTS),
--           R24 (102.3 ms — avg price by seat class per city).
-- Type    : B-tree — equality join on FK column.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_booking_seats_seat_id
    ON bms.booking_seats (seat_id);

-- =====================================================================
-- TABLE: seats
-- Baseline: PK (seat_id) and UNIQUE (screen_id, row_label, seat_number).
-- The unique index starts with screen_id; it CAN be used for
-- screen_id equality lookups, so no additional screen_id index is
-- needed.  However seat_class is never indexed.
-- =====================================================================

-- ---------------------------------------------------------------------
-- IDX-SE1: seats(screen_id, seat_class)
-- Purpose : Filter seats by screen_id and seat_class together so that
--           queries joining seats and filtering on seat_class can use
--           an index scan instead of a seq scan + filter.
-- Queries : R11 (FILTER WHERE seat_class = 'RECLINER'),
--           R24 (GROUP BY seat_class per city — seq scan on 350 K rows).
-- Type    : Composite B-tree — screen_id equality + seat_class equality.
-- Note    : uq_screen_seat_position already covers (screen_id, row_label,
--           seat_number); this index complements it with seat_class.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_seats_screen_id_seat_class
    ON bms.seats (screen_id, seat_class);

-- =====================================================================
-- TABLE: screens
-- Baseline: only screens_pkey exists.  venue_id FK has no index,
-- forcing seq scans whenever screens is joined to venues on venue_id.
-- =====================================================================

-- ---------------------------------------------------------------------
-- IDX-SC1: screens(venue_id)
-- Purpose : Join screens → venues on venue_id; also used when
--           filtering screens by venue_id directly (R07).
-- Queries : R01 (8.6 ms), R02 (6.0 ms), R07 (1.1 ms),
--           R16 (40.2 ms), R18 (127.2 ms), R24 (102.3 ms).
-- Type    : B-tree — FK equality lookup.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_screens_venue_id
    ON bms.screens (venue_id);

-- =====================================================================
-- TABLE: venues
-- Baseline: only venues_pkey exists.  city_id FK has no index.
-- =====================================================================

-- ---------------------------------------------------------------------
-- IDX-V1: venues(city_id)
-- Purpose : Filter venues by city (R01, R02 — Bengaluru shows page).
--           Without this, PostgreSQL must seq scan all venues to find
--           those in city_id = 1.
-- Queries : R01 (8.6 ms), R02 (6.0 ms), R18 (127.2 ms).
-- Type    : B-tree — FK equality lookup.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_venues_city_id
    ON bms.venues (city_id);

-- =====================================================================
-- TABLE: movie_reviews
-- Baseline: only PK and UNIQUE(movie_id, customer_id) exist.
-- The UNIQUE index starts with movie_id, so R14 may already benefit.
-- Adding an explicit plain index on movie_id + rating to allow a
-- covering scan for the avg(rating) aggregation.
-- =====================================================================

-- ---------------------------------------------------------------------
-- IDX-MR1: movie_reviews(movie_id, rating)
-- Purpose : GROUP BY movie_id with avg(rating); a covering index on
--           (movie_id, rating) means no heap fetch is needed for
--           the aggregation — the planner can use an Index Only Scan.
-- Queries : R14 (6.9 ms — avg rating of 2026 releases ≥ 20 reviews).
-- Type    : Composite B-tree — covering scan for aggregation.
-- Note    : uq_movie_customer_review already covers (movie_id, customer_id)
--           but does NOT include rating, so the aggregate still needs
--           a heap fetch.  This index avoids that.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_movie_reviews_movie_id_rating
    ON bms.movie_reviews (movie_id, rating);

-- =====================================================================
-- Post-index maintenance: update table statistics so the planner
-- immediately has accurate row estimates for all affected tables.
-- =====================================================================
ANALYZE bms.bookings;
ANALYZE bms.shows;
ANALYZE bms.booking_seats;
ANALYZE bms.seats;
ANALYZE bms.screens;
ANALYZE bms.venues;
ANALYZE bms.movie_reviews;

-- =====================================================================
-- Summary of indexes created (12 total):
--
--   bookings      : idx_bookings_customer_id
--                   idx_bookings_show_id
--                   idx_bookings_status_booked_at
--                   idx_bookings_offer_code          (partial)
--                   idx_bookings_booked_at_desc      (covering INCLUDE)
--
--   shows         : idx_shows_movie_id_starts_at
--                   idx_shows_screen_id_starts_at
--
--   booking_seats : idx_booking_seats_seat_id
--
--   seats         : idx_seats_screen_id_seat_class
--
--   screens       : idx_screens_venue_id
--
--   venues        : idx_venues_city_id
--
--   movie_reviews : idx_movie_reviews_movie_id_rating
-- =====================================================================
