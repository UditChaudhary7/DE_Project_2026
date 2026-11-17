CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE SCHEMA IF NOT EXISTS bms;
SET search_path TO bms;

DROP TABLE IF EXISTS movie_reviews CASCADE;
DROP TABLE IF EXISTS booking_seats CASCADE;
DROP TABLE IF EXISTS bookings CASCADE;
DROP TABLE IF EXISTS offers CASCADE;
DROP TABLE IF EXISTS customers CASCADE;
DROP TABLE IF EXISTS shows CASCADE;
DROP TABLE IF EXISTS movies CASCADE;
DROP TABLE IF EXISTS seats CASCADE;
DROP TABLE IF EXISTS screens CASCADE;
DROP TABLE IF EXISTS venues CASCADE;
DROP TABLE IF EXISTS cities CASCADE;

CREATE TABLE cities (
    city_id     INT             PRIMARY KEY,
    city_name   VARCHAR(100)    NOT NULL UNIQUE,
    state       VARCHAR(100)    NOT NULL
);

CREATE TABLE venues (
    venue_id    INT             PRIMARY KEY,
    venue_name  VARCHAR(150)    NOT NULL,
    city_id     INT             NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    chain       VARCHAR(50)     NOT NULL,
    address     TEXT            NOT NULL,

    CONSTRAINT chk_venue_chain
        CHECK (chain IN ('Cinepolis', 'INOX', 'Independent', 'Miraj', 'PVR'))
);

CREATE TABLE screens (
    screen_id   INT             PRIMARY KEY,
    venue_id    INT             NOT NULL REFERENCES venues(venue_id) ON DELETE CASCADE,
    screen_name VARCHAR(50)     NOT NULL,
    screen_type VARCHAR(20)     NOT NULL,
    total_seats INT             NOT NULL,

    CONSTRAINT chk_screen_type
        CHECK (screen_type IN ('4DX', 'GOLD', 'IMAX', 'STANDARD')),
    CONSTRAINT chk_screen_total_seats
        CHECK (total_seats > 0 AND total_seats <= 1000)
);

CREATE TABLE seats (
    seat_id     INT             PRIMARY KEY,
    screen_id   INT             NOT NULL REFERENCES screens(screen_id) ON DELETE CASCADE,
    row_label   VARCHAR(2)      NOT NULL,
    seat_number INT             NOT NULL,
    seat_class  VARCHAR(20)     NOT NULL,

    CONSTRAINT chk_seat_row_label
        CHECK (row_label ~ '^[A-P]$'),
    CONSTRAINT chk_seat_number
        CHECK (seat_number > 0 AND seat_number <= 100),
    CONSTRAINT chk_seat_class
        CHECK (seat_class IN ('CLASSIC', 'PRIME', 'RECLINER')),
    CONSTRAINT uq_screen_seat_position
        UNIQUE (screen_id, row_label, seat_number)
);

CREATE TABLE movies (
    movie_id        INT             PRIMARY KEY,
    title           VARCHAR(255)    NOT NULL,
    language        VARCHAR(50)     NOT NULL,
    certificate     VARCHAR(10)     NOT NULL,
    duration_min    INT             NOT NULL,
    release_date    DATE            NOT NULL,

    CONSTRAINT chk_movie_certificate
        CHECK (certificate IN ('A', 'U', 'UA')),
    CONSTRAINT chk_movie_duration
        CHECK (duration_min > 0 AND duration_min <= 400)
);

CREATE TABLE shows (
    show_id     INT             PRIMARY KEY,
    movie_id    INT             NOT NULL REFERENCES movies(movie_id) ON DELETE RESTRICT,
    screen_id   INT             NOT NULL REFERENCES screens(screen_id) ON DELETE RESTRICT,
    starts_at   TIMESTAMPTZ     NOT NULL,
    ends_at     TIMESTAMPTZ     NOT NULL,
    format      VARCHAR(20)     NOT NULL,
    base_price  NUMERIC(10, 2)  NOT NULL,

    CONSTRAINT chk_show_time_order
        CHECK (starts_at < ends_at),
    CONSTRAINT chk_show_format
        CHECK (format IN ('2D', '3D', '4DX', 'IMAX')),
    CONSTRAINT chk_show_base_price
        CHECK (base_price >= 0),

    CONSTRAINT no_overlapping_shows
        EXCLUDE USING gist (
            screen_id WITH =,
            tsrange(starts_at, ends_at) WITH &&
        )
);

CREATE TABLE customers (
    customer_id INT             PRIMARY KEY,
    full_name   VARCHAR(150)    NOT NULL,
    email       VARCHAR(255)    NOT NULL UNIQUE,
    phone       VARCHAR(15)     NOT NULL UNIQUE,
    city_id     INT             NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    created_at  TIMESTAMPTZ     NOT NULL,

    CONSTRAINT chk_customer_phone
        CHECK (phone ~ '^[0-9]{10}$')
);

CREATE TABLE offers (
    offer_code      VARCHAR(50)     PRIMARY KEY,
    description     VARCHAR(255)    NOT NULL,
    discount_pct    INT             NOT NULL,
    max_discount    NUMERIC(10, 2)  NOT NULL,
    valid_from      DATE            NOT NULL,
    valid_to        DATE            NOT NULL,

    CONSTRAINT chk_offer_discount_pct
        CHECK (discount_pct > 0 AND discount_pct <= 100),
    CONSTRAINT chk_offer_max_discount
        CHECK (max_discount >= 0),
    CONSTRAINT chk_offer_valid_dates
        CHECK (valid_from <= valid_to)
);

CREATE TABLE bookings (
    booking_id      INT             PRIMARY KEY,
    booking_code    VARCHAR(20)     NOT NULL UNIQUE,
    customer_id     INT             NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    show_id         INT             NOT NULL REFERENCES shows(show_id) ON DELETE RESTRICT,
    booked_at       TIMESTAMPTZ     NOT NULL,
    num_tickets     INT             NOT NULL,
    ticket_amount   NUMERIC(10, 2)  NOT NULL,
    convenience_fee NUMERIC(10, 2)  NOT NULL,
    fnb_amount      NUMERIC(10, 2)  NOT NULL,
    offer_code      VARCHAR(50)     REFERENCES offers(offer_code) ON DELETE SET NULL,
    discount        NUMERIC(10, 2)  NOT NULL,
    total_amount    NUMERIC(10, 2)  NOT NULL,
    payment_method  VARCHAR(30)     NOT NULL,
    status          VARCHAR(30)     NOT NULL,

    CONSTRAINT chk_booking_code_format
        CHECK (booking_code ~ '^BMS[0-9A-F]{7}$'),
    CONSTRAINT chk_booking_num_tickets
        CHECK (num_tickets > 0),
    CONSTRAINT chk_booking_ticket_amount
        CHECK (ticket_amount >= 0),
    CONSTRAINT chk_booking_convenience_fee
        CHECK (convenience_fee >= 0),
    CONSTRAINT chk_booking_fnb_amount
        CHECK (fnb_amount >= 0),
    CONSTRAINT chk_booking_discount
        CHECK (discount >= 0),
    CONSTRAINT chk_booking_total_amount_positive
        CHECK (total_amount >= 0),
    CONSTRAINT chk_booking_payment_method
        CHECK (payment_method IN ('CARD', 'GIFT_CARD', 'NETBANKING', 'UPI', 'WALLET')),
    CONSTRAINT chk_booking_status
        CHECK (status IN ('CANCELLED', 'CONFIRMED', 'PAYMENT_FAILED', 'PENDING')),

    CONSTRAINT chk_booking_total_amount_formula
        CHECK (total_amount = ticket_amount + convenience_fee + fnb_amount - discount)
);

CREATE TABLE booking_seats (
    booking_id  INT             NOT NULL REFERENCES bookings(booking_id) ON DELETE CASCADE,
    show_id     INT             NOT NULL REFERENCES shows(show_id) ON DELETE RESTRICT,
    seat_id     INT             NOT NULL REFERENCES seats(seat_id) ON DELETE RESTRICT,
    price       NUMERIC(10, 2)  NOT NULL,

    PRIMARY KEY (booking_id, seat_id),

    CONSTRAINT chk_booking_seats_price
        CHECK (price >= 0),

    CONSTRAINT uq_show_seat
        UNIQUE (show_id, seat_id)
);

CREATE TABLE movie_reviews (
    review_id   INT             PRIMARY KEY,
    movie_id    INT             NOT NULL REFERENCES movies(movie_id) ON DELETE CASCADE,
    customer_id INT             NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    rating      INT             NOT NULL,
    review_text TEXT,
    created_at  TIMESTAMPTZ     NOT NULL,

    CONSTRAINT chk_review_rating
        CHECK (rating >= 1 AND rating <= 10),
    CONSTRAINT uq_movie_customer_review
        UNIQUE (movie_id, customer_id)
);
