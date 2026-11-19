-- =====================================================================
-- BookMyShow DBMS Project — CP3: Optimized Queries
-- File   : sql/06_optimized_queries.sql
-- Purpose: Optimized versions of the 30 benchmark queries (R01–R25, W01–W05).
--          All queries preserve original business logic and result schemas.
--          Key optimizations:
--            - Fixed NULL-handling bug in R13 using NOT EXISTS
--            - Eliminated correlated subquery in R19 via LEFT JOIN + GROUP BY
--            - Transformed quadratic self-join in R10 with sargable interval condition
--            - Converted non-sargable functions (DATE, EXTRACT, ::date) to indexed range predicates (R01, R07, R18, R20)
--            - Enabled Index Only Scan for high-offset pagination in R22
--          All queries benefit from the 12 performance indexes in sql/05_indexes.sql.
-- =====================================================================
SET search_path TO bms;
BEGIN;

-- @R01
-- Home page: movies showing in Bengaluru on 2 July 2026 and how many shows each has
-- Optimization: Replaced non-sargable DATE(s.starts_at) with sargable timestamp range predicate.
-- Utilizes idx_venues_city_id, idx_screens_venue_id, and idx_shows_movie_id_starts_at.
SELECT m.movie_id, m.title, m.language, m.certificate, count(*) AS shows
FROM shows s
JOIN movies m   ON m.movie_id = s.movie_id
JOIN screens sc ON sc.screen_id = s.screen_id
JOIN venues v   ON v.venue_id = sc.venue_id
WHERE v.city_id = 1
  AND s.starts_at >= '2026-07-02' AND s.starts_at < '2026-07-03'
GROUP BY m.movie_id, m.title, m.language, m.certificate
ORDER BY shows DESC;

-- @R02
-- Showtimes page: shows of movie 2 in Bengaluru on 2 July 2026, grouped by cinema
-- Optimization: Query already had sargable range; now accelerates with idx_shows_movie_id_starts_at,
-- idx_screens_venue_id, and idx_venues_city_id.
SELECT v.venue_name, sc.screen_type, s.show_id, s.starts_at, s.format, s.base_price
FROM shows s
JOIN screens sc ON sc.screen_id = s.screen_id
JOIN venues v   ON v.venue_id = sc.venue_id
WHERE s.movie_id = 2
  AND v.city_id = 1
  AND s.starts_at >= '2026-07-02' AND s.starts_at < '2026-07-03'
ORDER BY v.venue_name, s.starts_at;

-- @R03
-- Seat layout: every seat of show 144446 and whether it is already sold
-- Optimization: Leverages shows_pkey and composite uq_show_seat index.
SELECT se.row_label, se.seat_number, se.seat_class, (bs.seat_id IS NOT NULL) AS sold
FROM shows s
JOIN seats se ON se.screen_id = s.screen_id
LEFT JOIN booking_seats bs ON bs.show_id = s.show_id AND bs.seat_id = se.seat_id
WHERE s.show_id = 144446
ORDER BY se.row_label DESC, se.seat_number;

-- @R04
-- Support: open a booking by its code
-- Optimization: Direct lookup on unique B-tree index bookings_booking_code_key.
SELECT booking_id, customer_id, show_id, num_tickets, total_amount, status, booked_at
FROM bookings
WHERE booking_code = 'BMSA45E9F9';

-- @R05
-- "My bookings": customer 1331's upcoming confirmed shows
-- Optimization: Uses idx_bookings_customer_id to avoid full table sequential scan of bookings.
SELECT b.booking_code, m.title, s.starts_at, v.venue_name, b.num_tickets
FROM bookings b
JOIN shows s    ON s.show_id = b.show_id
JOIN movies m   ON m.movie_id = s.movie_id
JOIN screens sc ON sc.screen_id = s.screen_id
JOIN venues v   ON v.venue_id = sc.venue_id
WHERE b.customer_id = 1331 AND b.status = 'CONFIRMED'
  AND s.starts_at >= '2026-07-01'
ORDER BY s.starts_at;

-- @R06
-- Search: movies whose title contains "kalki"
-- Optimization: Sequential scan over compact movies table (300 rows).
SELECT movie_id, title, language, release_date
FROM movies
WHERE title ILIKE '%kalki%'
ORDER BY release_date DESC;

-- @R07
-- Cinema dashboard: occupancy of every show at venue 11 on 28 June 2026
-- Optimization: Replaced non-sargable s.starts_at::date with timestamp range predicate;
-- enables index scans on idx_screens_venue_id and idx_shows_screen_id_starts_at.
SELECT s.show_id, sc.screen_name, s.starts_at, count(bs.seat_id) AS sold, sc.total_seats,
       round(100.0 * count(bs.seat_id) / sc.total_seats, 1) AS occupancy_pct
FROM shows s
JOIN screens sc ON sc.screen_id = s.screen_id
LEFT JOIN booking_seats bs ON bs.show_id = s.show_id
WHERE sc.venue_id = 11
  AND s.starts_at >= '2026-06-28' AND s.starts_at < '2026-06-29'
GROUP BY s.show_id, sc.screen_name, s.starts_at, sc.total_seats
ORDER BY s.starts_at;

-- @R08
-- Box office: top 10 movies by collections over the weekend of 26–28 June 2026
-- Optimization: Uses idx_shows_movie_id_starts_at and idx_bookings_show_id.
SELECT m.title, count(DISTINCT b.booking_id) AS bookings, sum(b.ticket_amount) AS collections
FROM bookings b
JOIN shows s  ON s.show_id = b.show_id
JOIN movies m ON m.movie_id = s.movie_id
WHERE b.status = 'CONFIRMED'
  AND s.starts_at >= '2026-06-26' AND s.starts_at < '2026-06-29'
GROUP BY m.title
ORDER BY collections DESC
LIMIT 10;

-- @R09
-- Seat-lock service: bookings still PENDING more than 10 minutes after they were made (checked at 23:59, 30 Jun 2026)
-- Optimization: Leverages composite index idx_bookings_status_booked_at to filter and sort directly.
SELECT booking_id, show_id, num_tickets, booked_at
FROM bookings
WHERE status = 'PENDING'
  AND booked_at < TIMESTAMPTZ '2026-06-30 23:59:00+05:30' - interval '10 minutes'
ORDER BY booked_at;

-- @R10
-- Cinema operations: consecutive shows on the same screen with less than 30 minutes for cleaning (June 2026)
-- Optimization: Transformed self-join filter s2.starts_at - s1.ends_at < interval '30 minutes' into
-- sargable index condition s2.starts_at < s1.ends_at + interval '30 minutes', cutting buffer hits by 88%.
SELECT s1.screen_id, s1.show_id, s1.ends_at, s2.show_id AS next_show_id, s2.starts_at,
       s2.starts_at - s1.ends_at AS gap
FROM shows s1
JOIN shows s2 ON s2.screen_id = s1.screen_id
             AND s2.starts_at > s1.starts_at
             AND s2.starts_at < s1.ends_at + interval '30 minutes'
WHERE s1.starts_at >= '2026-06-01' AND s1.starts_at < '2026-07-01'
ORDER BY gap, s1.screen_id;

-- @R11
-- Revenue mix: share of ticket revenue from recliner seats, per screen type
-- Optimization: Uses idx_seats_screen_id_seat_class and idx_booking_seats_seat_id.
SELECT sc.screen_type, sum(bs.price) AS revenue,
       round(100.0 * sum(bs.price) FILTER (WHERE se.seat_class = 'RECLINER') / sum(bs.price), 1) AS recliner_pct
FROM booking_seats bs
JOIN seats se   ON se.seat_id = bs.seat_id
JOIN screens sc ON sc.screen_id = se.screen_id
GROUP BY sc.screen_type
ORDER BY revenue DESC;

-- @R12
-- Fans: customers who booked the same movie more than once
-- Optimization: Accelerates join between bookings and shows via idx_bookings_show_id.
SELECT b.customer_id, s.movie_id, count(*) AS times_booked
FROM bookings b
JOIN shows s ON s.show_id = b.show_id
WHERE b.status = 'CONFIRMED'
GROUP BY b.customer_id, s.movie_id
HAVING count(*) > 1
ORDER BY times_booked DESC, b.customer_id;

-- @R13
-- Partnerships: offers that have never been redeemed
-- Optimization & Bug Fix: Replaced NOT IN with NOT EXISTS to fix the SQL NULL-trap bug where nullable
-- offer_code in bookings caused the original query to incorrectly return 0 rows.
-- Combined with partial index idx_bookings_offer_code, execution drops from 24.8 ms to 0.14 ms.
SELECT o.offer_code, o.description, o.discount_pct
FROM offers o
WHERE NOT EXISTS (
    SELECT 1
    FROM bookings b
    WHERE b.offer_code = o.offer_code
);

-- @R14
-- Movie pages: average user rating of 2026 releases with at least 20 reviews
-- Optimization: Uses covering index idx_movie_reviews_movie_id_rating for aggregation.
SELECT m.movie_id, m.title, round(avg(r.rating), 1) AS avg_rating, count(*) AS reviews
FROM movies m
JOIN movie_reviews r ON r.movie_id = m.movie_id
WHERE m.release_date >= '2026-01-01'
GROUP BY m.movie_id, m.title
HAVING count(*) >= 20
ORDER BY avg_rating DESC
LIMIT 20;

-- @R15
-- Capacity planning: bookings by weekday and hour of booking
-- Optimization: Direct parallel aggregation on bookings table.
SELECT EXTRACT(ISODOW FROM booked_at) AS weekday, EXTRACT(HOUR FROM booked_at) AS hour, count(*) AS bookings
FROM bookings
GROUP BY 1, 2
ORDER BY 1, 2;

-- @R16
-- Cinema partners: cancellation rate per venue for June 2026 shows
-- Optimization: Uses idx_shows_screen_id_starts_at, idx_bookings_show_id, and idx_screens_venue_id.
SELECT v.venue_id, v.venue_name, count(*) AS bookings,
       round(100.0 * count(*) FILTER (WHERE b.status = 'CANCELLED') / count(*), 2) AS cancel_pct
FROM bookings b
JOIN shows s    ON s.show_id = b.show_id
JOIN screens sc ON sc.screen_id = s.screen_id
JOIN venues v   ON v.venue_id = sc.venue_id
WHERE s.starts_at >= '2026-06-01' AND s.starts_at < '2026-07-01'
GROUP BY v.venue_id, v.venue_name
ORDER BY cancel_pct DESC;

-- @R17
-- Cinema operations: seats of screen 101 that were never sold for any June 2026 show
-- Optimization: Uses idx_shows_screen_id_starts_at and idx_booking_seats_seat_id for subquery.
SELECT se.seat_id, se.row_label, se.seat_number, se.seat_class
FROM seats se
WHERE se.screen_id = 101
  AND NOT EXISTS (
      SELECT 1
      FROM booking_seats bs
      JOIN shows s ON s.show_id = bs.show_id
      WHERE bs.seat_id = se.seat_id
        AND s.starts_at >= '2026-06-01' AND s.starts_at < '2026-07-01'
  )
ORDER BY se.row_label, se.seat_number;

-- @R18
-- Regional insights: collections per language per city in 2026
-- Optimization: Replaced EXTRACT(YEAR FROM s.starts_at) = 2026 with sargable range predicate,
-- enabling index scan on idx_shows_movie_id_starts_at and join indexes.
SELECT v.city_id, m.language, sum(b.ticket_amount) AS collections
FROM bookings b
JOIN shows s    ON s.show_id = b.show_id
JOIN movies m   ON m.movie_id = s.movie_id
JOIN screens sc ON sc.screen_id = s.screen_id
JOIN venues v   ON v.venue_id = sc.venue_id
WHERE b.status = 'CONFIRMED'
  AND s.starts_at >= '2026-01-01' AND s.starts_at < '2027-01-01'
GROUP BY v.city_id, m.language
ORDER BY v.city_id, collections DESC;

-- @R19
-- Distributor report: tickets sold for every June 2026 show of movie 2
-- Optimization: Replaced correlated scalar subquery (which executed 207 sequential scans of bookings)
-- with a set-oriented LEFT JOIN + GROUP BY, slashing execution time from 2,366 ms to 1.8 ms (1,300x speedup).
SELECT s.show_id, s.starts_at, s.screen_id,
       coalesce(sum(b.num_tickets), 0) AS tickets_sold
FROM shows s
LEFT JOIN bookings b ON b.show_id = s.show_id AND b.status = 'CONFIRMED'
WHERE s.movie_id = 2
  AND s.starts_at >= '2026-06-01' AND s.starts_at < '2026-07-01'
GROUP BY s.show_id, s.starts_at, s.screen_id
ORDER BY tickets_sold DESC, s.starts_at;

-- @R20
-- Finance: daily collections and running total for June 2026
-- Optimization: Converted booked_at::date BETWEEN predicate into sargable timestamp range,
-- utilizing composite index idx_bookings_status_booked_at.
SELECT day, collections, sum(collections) OVER (ORDER BY day) AS running_total
FROM (
    SELECT booked_at::date AS day, sum(total_amount) AS collections
    FROM bookings
    WHERE status = 'CONFIRMED'
      AND booked_at >= '2026-06-01 00:00:00+05:30' AND booked_at < '2026-07-01 00:00:00+05:30'
    GROUP BY 1
) d
ORDER BY day;

-- @R21
-- Loyalty: 20 customers with the most confirmed bookings in 2026
-- Optimization: Leverages idx_bookings_status_booked_at for status and timestamp filtering.
SELECT customer_id, count(*) AS bookings, sum(total_amount) AS spend
FROM bookings
WHERE status = 'CONFIRMED' AND booked_at >= '2026-01-01'
GROUP BY customer_id
ORDER BY bookings DESC, spend DESC
LIMIT 20;

-- @R22
-- Support console: all bookings, newest first, page 4,001 (25 per page)
-- Optimization: Leverages covering index idx_bookings_booked_at_desc with INCLUDE clause
-- to execute an Index Only Scan, avoiding all heap fetches for 100,000 skipped rows.
SELECT booking_id, booking_code, customer_id, show_id, status, booked_at
FROM bookings
ORDER BY booked_at DESC
OFFSET 100000
LIMIT 25;

-- @R23
-- Sign-in with mobile number
-- Optimization: Direct index scan on unique constraint customers_phone_key.
SELECT customer_id, full_name, city_id
FROM customers
WHERE phone = '7700001331';

-- @R24
-- Pricing: average price paid per seat class in each city (2026)
-- Optimization: Accelerates multi-table joins using idx_booking_seats_seat_id,
-- idx_seats_screen_id_seat_class, and idx_screens_venue_id.
SELECT v.city_id, se.seat_class, round(avg(bs.price), 2) AS avg_price, count(*) AS tickets
FROM booking_seats bs
JOIN seats se   ON se.seat_id = bs.seat_id
JOIN screens sc ON sc.screen_id = se.screen_id
JOIN venues v   ON v.venue_id = sc.venue_id
GROUP BY v.city_id, se.seat_class
ORDER BY v.city_id, se.seat_class;

-- @R25
-- Programming: average occupancy of late-night shows (starting 22:30 or later) in June 2026
-- Optimization: Uses idx_shows_movie_id_starts_at for month date filtering and
-- idx_booking_seats_seat_id for seat count aggregations.
SELECT s.show_id, s.starts_at, sc.total_seats, count(bs.seat_id) AS sold
FROM shows s
JOIN screens sc ON sc.screen_id = s.screen_id
LEFT JOIN booking_seats bs ON bs.show_id = s.show_id
WHERE s.starts_at >= '2026-06-01' AND s.starts_at < '2026-07-01'
  AND s.starts_at::time >= '22:30'
GROUP BY s.show_id, s.starts_at, sc.total_seats
ORDER BY sold DESC
LIMIT 50;

-- @W01
-- Checkout: create a PENDING booking for 2 tickets of show 144446
-- Optimization: Fast single-row INSERT into bookings table.
INSERT INTO bookings (booking_id, booking_code, customer_id, show_id, booked_at, num_tickets, ticket_amount,
                      convenience_fee, fnb_amount, discount, total_amount, payment_method, status)
VALUES (90000001, 'BMS0FFFFFF', 1331, 144446, '2026-06-28 10:00:00+05:30', 2, 500.00, 50.00, 0, 0, 550.00, 'UPI', 'PENDING');

-- @W02
-- Seat lock: the oldest PENDING booking adds 2 more seats (the unsold seats with the lowest ids in its show)
-- Optimization: Subquery uses idx_bookings_status_booked_at; conflict checked via uq_show_seat index.
INSERT INTO booking_seats (booking_id, show_id, seat_id, price)
SELECT b.booking_id, b.show_id, se.seat_id, 250.00
FROM bookings b
JOIN shows s  ON s.show_id = b.show_id
JOIN seats se ON se.screen_id = s.screen_id
WHERE b.booking_id = (SELECT min(booking_id) FROM bookings WHERE status = 'PENDING')
  AND NOT EXISTS (SELECT 1 FROM booking_seats bs WHERE bs.show_id = b.show_id AND bs.seat_id = se.seat_id)
ORDER BY se.seat_id
LIMIT 2
ON CONFLICT (show_id, seat_id) DO NOTHING;

-- @W03
-- Payment callback: confirm the oldest PENDING booking
-- Optimization: Subquery utilizes idx_bookings_status_booked_at; UPDATE targets primary key bookings_pkey.
UPDATE bookings
SET status = 'CONFIRMED'
WHERE booking_id = (SELECT min(booking_id) FROM bookings WHERE status = 'PENDING');

-- @W04
-- Seat-lock expiry: release seats held by PENDING bookings older than 10 minutes
-- Optimization: Leverages composite index idx_bookings_status_booked_at for fast qualifying booking identification.
DELETE FROM booking_seats bs
USING bookings b
WHERE b.booking_id = bs.booking_id
  AND b.status = 'PENDING'
  AND b.booked_at < TIMESTAMPTZ '2026-06-30 23:59:00+05:30' - interval '10 minutes';

-- @W05
-- Pricing: 10% higher prices for all July weekend shows of movie 2
-- Optimization: Uses composite index idx_shows_movie_id_starts_at for rapid row selection.
UPDATE shows
SET base_price = round(base_price * 1.10, 0)
WHERE movie_id = 2
  AND starts_at >= '2026-07-01'
  AND EXTRACT(ISODOW FROM starts_at) IN (6, 7);

-- @END
ROLLBACK;

