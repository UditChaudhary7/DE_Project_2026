SET search_path TO bms;
\echo '1. booked seat on a screen different from the show screen (expect 0)'
SELECT count(*) FROM booking_seats bs
JOIN shows s ON s.show_id = bs.show_id
JOIN seats se ON se.seat_id = bs.seat_id
WHERE se.screen_id <> s.screen_id;
\echo '2. num_tickets vs seat rows, per status'
SELECT b.status, count(*) AS bookings,
       count(*) FILTER (WHERE b.num_tickets = coalesce(x.n,0)) AS tickets_match_seat_rows,
       count(*) FILTER (WHERE coalesce(x.n,0) = 0) AS no_seat_rows
FROM bookings b
LEFT JOIN (SELECT booking_id, count(*) n FROM booking_seats GROUP BY 1) x USING (booking_id)
GROUP BY b.status ORDER BY 1;
\echo '3. overlapping shows on one screen (expect 0)'
SELECT count(*) FROM shows a JOIN shows b
  ON a.screen_id = b.screen_id AND a.show_id < b.show_id
 AND tstzrange(a.starts_at,a.ends_at) && tstzrange(b.starts_at,b.ends_at);
\echo '4. ticket_amount vs sum of seat prices (mismatches)'
SELECT count(*) FROM bookings b
JOIN (SELECT booking_id, sum(price) s FROM booking_seats GROUP BY 1) x USING (booking_id)
WHERE b.ticket_amount <> x.s;
\echo '5. screens.total_seats vs count of seats (mismatches)'
SELECT count(*) FROM screens sc
JOIN (SELECT screen_id, count(*) n FROM seats GROUP BY 1) x USING (screen_id)
WHERE sc.total_seats <> x.n;
\echo '6. shows.ends_at - starts_at vs movie duration'
SELECT count(*) FILTER (WHERE s.ends_at - s.starts_at = m.duration_min * interval '1 minute') AS equal_to_duration,
       count(*) FILTER (WHERE s.ends_at - s.starts_at <> m.duration_min * interval '1 minute') AS different
FROM shows s JOIN movies m USING (movie_id);
\echo '7. when is offer_code empty?'
SELECT (offer_code IS NULL) AS no_offer, count(*) AS bookings,
       count(*) FILTER (WHERE discount > 0) AS with_discount
FROM bookings GROUP BY 1;
\echo '8. rows with no review text'
SELECT count(*) FILTER (WHERE review_text IS NULL) AS no_text, count(*) AS total FROM movie_reviews;
