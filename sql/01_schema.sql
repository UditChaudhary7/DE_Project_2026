CREATE EXTENSION IF NOT EXISTS btree_gist;

DROP SCHEMA IF EXISTS bms CASCADE;
CREATE SCHEMA bms;
SET search_path TO bms;

CREATE TABLE cities (
    city_id    integer PRIMARY KEY,
    city_name  text    NOT NULL UNIQUE,
    state      text    NOT NULL
);

CREATE TABLE venues (
    venue_id    integer PRIMARY KEY,
    venue_name  text    NOT NULL,
    city_id     integer NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    chain       text    NOT NULL,
    address     text    NOT NULL
);

CREATE TABLE screens (
    screen_id    integer PRIMARY KEY,
    venue_id     integer NOT NULL REFERENCES venues(venue_id) ON DELETE CASCADE,
    screen_name  text    NOT NULL,
    screen_type  text    NOT NULL,
    total_seats  integer NOT NULL CHECK (total_seats > 0),
    UNIQUE (venue_id, screen_name)
);

CREATE TABLE seats (
    seat_id      integer PRIMARY KEY,
    screen_id    integer NOT NULL REFERENCES screens(screen_id) ON DELETE CASCADE,
    row_label    text    NOT NULL CHECK (row_label ~ '^[A-Z]{1,2}$'),
    seat_number  integer NOT NULL CHECK (seat_number > 0),
    seat_class   text    NOT NULL CHECK (seat_class IN ('CLASSIC','PRIME','RECLINER')),
    UNIQUE (screen_id, row_label, seat_number)
);

CREATE TABLE movies (
    movie_id      integer PRIMARY KEY,
    title         text    NOT NULL,
    language      text    NOT NULL,
    certificate   text    NOT NULL,
    duration_min  integer NOT NULL CHECK (duration_min > 0),
    release_date  date    NOT NULL
);

CREATE TABLE shows (
    show_id     integer       PRIMARY KEY,
    movie_id    integer       NOT NULL REFERENCES movies(movie_id)   ON DELETE RESTRICT,
    screen_id   integer       NOT NULL REFERENCES screens(screen_id) ON DELETE RESTRICT,
    starts_at   timestamptz   NOT NULL,
    ends_at     timestamptz   NOT NULL,
    format      text          NOT NULL,
    base_price  numeric(8,2)  NOT NULL CHECK (base_price > 0),
    CHECK (ends_at > starts_at),
    CONSTRAINT shows_no_overlap
        EXCLUDE USING gist (screen_id WITH =, tstzrange(starts_at, ends_at) WITH &&)
);

CREATE TABLE customers (
    customer_id  integer     PRIMARY KEY,
    full_name    text        NOT NULL,
    email        text        NOT NULL UNIQUE,
    phone        text        NOT NULL UNIQUE CHECK (phone ~ '^[0-9]{10}$'),
    city_id      integer     NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    created_at   timestamptz NOT NULL
);

CREATE TABLE offers (
    offer_code    text          PRIMARY KEY,
    description   text          NOT NULL,
    discount_pct  numeric(5,2)  NOT NULL CHECK (discount_pct > 0 AND discount_pct <= 100),
    max_discount  numeric(10,2) NOT NULL CHECK (max_discount >= 0),
    valid_from    date          NOT NULL,
    valid_to      date          NOT NULL,
    CHECK (valid_to >= valid_from)
);

CREATE TABLE bookings (
    booking_id       integer       PRIMARY KEY,
    booking_code     text          NOT NULL UNIQUE CHECK (booking_code ~ '^BMS[0-9A-F]{7}$'),
    customer_id      integer       NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    show_id          integer       NOT NULL REFERENCES shows(show_id)         ON DELETE RESTRICT,
    booked_at        timestamptz   NOT NULL,
    num_tickets      integer       NOT NULL CHECK (num_tickets > 0),
    ticket_amount    numeric(10,2) NOT NULL CHECK (ticket_amount   >= 0),
    convenience_fee  numeric(10,2) NOT NULL CHECK (convenience_fee >= 0),
    fnb_amount       numeric(10,2) NOT NULL CHECK (fnb_amount      >= 0),
    offer_code       text          REFERENCES offers(offer_code) ON DELETE SET NULL,
    discount         numeric(10,2) NOT NULL CHECK (discount        >= 0),
    total_amount     numeric(10,2) NOT NULL,
    payment_method   text          NOT NULL,
    status           text          NOT NULL CHECK (status IN ('CANCELLED','CONFIRMED','PAYMENT_FAILED','PENDING')),
    CONSTRAINT bookings_total_rule
        CHECK (total_amount = ticket_amount + convenience_fee + fnb_amount - discount),
    UNIQUE (booking_id, show_id)
);

CREATE TABLE booking_seats (
    booking_id  integer       NOT NULL,
    show_id     integer       NOT NULL REFERENCES shows(show_id) ON DELETE RESTRICT,
    seat_id     integer       NOT NULL REFERENCES seats(seat_id) ON DELETE RESTRICT,
    price       numeric(8,2)  NOT NULL CHECK (price >= 0),
    PRIMARY KEY (show_id, seat_id),
    FOREIGN KEY (booking_id, show_id) REFERENCES bookings(booking_id, show_id) ON DELETE CASCADE
);

CREATE TABLE movie_reviews (
    review_id    integer     PRIMARY KEY,
    movie_id     integer     NOT NULL REFERENCES movies(movie_id)       ON DELETE CASCADE,
    customer_id  integer     NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    rating       integer     NOT NULL CHECK (rating BETWEEN 1 AND 10),
    review_text  text,
    created_at   timestamptz NOT NULL
);

ALTER TABLE venues   ADD CONSTRAINT venues_chain_chk  CHECK (chain IN ('Cinepolis','Independent','INOX','Miraj','PVR'));
ALTER TABLE screens  ADD CONSTRAINT screens_type_chk  CHECK (screen_type IN ('4DX','GOLD','IMAX','STANDARD'));
ALTER TABLE shows    ADD CONSTRAINT shows_format_chk  CHECK (format IN ('2D','3D','4DX','IMAX'));
ALTER TABLE movies   ADD CONSTRAINT movies_cert_chk   CHECK (certificate IN ('A','U','UA'));
ALTER TABLE bookings ADD CONSTRAINT bookings_pay_chk  CHECK (payment_method IN ('CARD','GIFT_CARD','NETBANKING','UPI','WALLET'));
ALTER TABLE bookings ADD CONSTRAINT bookings_offer_discount_rule CHECK ((offer_code IS NULL) = (discount = 0));
