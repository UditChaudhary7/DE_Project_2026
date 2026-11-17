SET search_path TO bms;

\copy cities        FROM 'seed_data/cities.csv'        WITH (FORMAT csv, HEADER true, NULL '')
\copy venues        FROM 'seed_data/venues.csv'        WITH (FORMAT csv, HEADER true, NULL '')
\copy screens       FROM 'seed_data/screens.csv'       WITH (FORMAT csv, HEADER true, NULL '')
\copy seats         FROM 'seed_data/seats.csv'         WITH (FORMAT csv, HEADER true, NULL '')
\copy movies        FROM 'seed_data/movies.csv'        WITH (FORMAT csv, HEADER true, NULL '')
\copy shows         FROM 'seed_data/shows.csv'         WITH (FORMAT csv, HEADER true, NULL '')
\copy customers     FROM 'seed_data/customers.csv'     WITH (FORMAT csv, HEADER true, NULL '')
\copy offers        FROM 'seed_data/offers.csv'        WITH (FORMAT csv, HEADER true, NULL '')
\copy bookings      FROM 'seed_data/bookings.csv'      WITH (FORMAT csv, HEADER true, NULL '')
\copy booking_seats FROM 'seed_data/booking_seats.csv' WITH (FORMAT csv, HEADER true, NULL '')
\copy movie_reviews FROM 'seed_data/movie_reviews.csv' WITH (FORMAT csv, HEADER true, NULL '')

ANALYZE;

SELECT 'cities' AS table_name, count(*) AS actual_rows, 10 AS expected_rows FROM cities UNION ALL
SELECT 'venues', count(*), 140 FROM venues UNION ALL
SELECT 'screens', count(*), 490 FROM screens UNION ALL
SELECT 'seats', count(*), 94056 FROM seats UNION ALL
SELECT 'movies', count(*), 300 FROM movies UNION ALL
SELECT 'shows', count(*), 160034 FROM shows UNION ALL
SELECT 'customers', count(*), 40000 FROM customers UNION ALL
SELECT 'offers', count(*), 25 FROM offers UNION ALL
SELECT 'bookings', count(*), 150094 FROM bookings UNION ALL
SELECT 'booking_seats', count(*), 300389 FROM booking_seats UNION ALL
SELECT 'movie_reviews', count(*), 32510 FROM movie_reviews;

SELECT count(*) AS invalid_screen_seats
FROM booking_seats bs
JOIN shows s ON s.show_id = bs.show_id
JOIN seats se ON se.seat_id = bs.seat_id
WHERE se.screen_id <> s.screen_id;

SELECT count(*) AS ticket_count_mismatches
FROM bookings b
JOIN (
    SELECT booking_id, count(*) AS seat_count
    FROM booking_seats
    GROUP BY booking_id
) bs ON bs.booking_id = b.booking_id
WHERE b.status IN ('CONFIRMED', 'PENDING')
  AND b.num_tickets <> bs.seat_count;

SELECT count(*) AS overlapping_shows
FROM shows s1
JOIN shows s2
  ON s1.screen_id = s2.screen_id
 AND s1.show_id < s2.show_id
 AND tsrange(s1.starts_at, s1.ends_at) && tsrange(s2.starts_at, s2.ends_at);

SELECT count(*) AS formula_mismatches
FROM bookings
WHERE total_amount <> (ticket_amount + convenience_fee + fnb_amount - discount);

SELECT count(*) AS orphan_seats_in_inactive_bookings
FROM booking_seats bs
JOIN bookings b ON b.booking_id = bs.booking_id
WHERE b.status IN ('CANCELLED', 'PAYMENT_FAILED');
