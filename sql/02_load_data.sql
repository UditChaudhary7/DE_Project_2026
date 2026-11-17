SET search_path TO bms;

\copy cities        FROM 'seed_data/cities.csv'        WITH (FORMAT csv, HEADER true)
\copy venues        FROM 'seed_data/venues.csv'        WITH (FORMAT csv, HEADER true)
\copy screens       FROM 'seed_data/screens.csv'       WITH (FORMAT csv, HEADER true)
\copy seats         FROM 'seed_data/seats.csv'         WITH (FORMAT csv, HEADER true)
\copy movies        FROM 'seed_data/movies.csv'        WITH (FORMAT csv, HEADER true)
\copy shows         FROM 'seed_data/shows.csv'         WITH (FORMAT csv, HEADER true)
\copy customers     FROM 'seed_data/customers.csv'     WITH (FORMAT csv, HEADER true)
\copy offers        FROM 'seed_data/offers.csv'        WITH (FORMAT csv, HEADER true)
\copy bookings      FROM 'seed_data/bookings.csv'      WITH (FORMAT csv, HEADER true)
\copy booking_seats FROM 'seed_data/booking_seats.csv' WITH (FORMAT csv, HEADER true)
\copy movie_reviews FROM 'seed_data/movie_reviews.csv' WITH (FORMAT csv, HEADER true)

ANALYZE;

SELECT 'cities' t, count(*) FROM cities UNION ALL
SELECT 'venues', count(*) FROM venues UNION ALL
SELECT 'screens', count(*) FROM screens UNION ALL
SELECT 'seats', count(*) FROM seats UNION ALL
SELECT 'movies', count(*) FROM movies UNION ALL
SELECT 'shows', count(*) FROM shows UNION ALL
SELECT 'customers', count(*) FROM customers UNION ALL
SELECT 'offers', count(*) FROM offers UNION ALL
SELECT 'bookings', count(*) FROM bookings UNION ALL
SELECT 'booking_seats', count(*) FROM booking_seats UNION ALL
SELECT 'movie_reviews', count(*) FROM movie_reviews;
