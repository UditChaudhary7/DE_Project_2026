# Baseline Query Performance Analysis (CP2)

**Course:** Database Management Systems · B.Tech 2nd Year  
**Project:** BookMyShow Database Engineering (DE Project 2026)  
**Milestone:** Checkpoint 2 (CP2 — Baseline Performance Report)  
**Workload File:** `queries/workload_30.sql` (30 Queries: R01–R25 Read, W01–W05 Write)  

---

## 1. PostgreSQL Version and System Specifications

All baseline benchmarks were conducted in a local, dedicated test environment to guarantee measurement consistency and reproducibility:

| Component | Specification | Details / Settings |
|---|---|---|
| **Database Engine** | PostgreSQL 18.4 | Postgres.app official distribution |
| **Operating System** | macOS Sequoia (Darwin 24.3.0) | Local development workstation |
| **Hardware Architecture** | Apple Silicon ARM64 | Apple M4 processor |
| **Host System Memory** | 16 GB Unified Memory (RAM) | High-bandwidth unified memory |
| **Default Memory Configuration** | `work_mem = 4MB` | Default PostgreSQL per-operation sort/hash memory |
| **Buffer Cache** | `shared_buffers = 128MB` | Postgres default buffer cache setting |
| **Planner Costs** | `random_page_cost = 4.0`, `seq_page_cost = 1.0` | Default cost weights |
| **Active Connections** | 1 client (`psql`) | Benchmarks run in strict isolation (zero competing concurrency) |

---

## 2. Dataset Details and Table Record Counts

The database was loaded with the complete official seed dataset (`seed_data.zip`) into the `bms` schema using `sql/02_load_data.sql`. No tuning indexes were created beyond primary keys, unique constraints, and the exclusion constraint specified in the initial baseline schema (`sql/01_schema.sql`).

### Table Inventory and Storage Footprint

| Table Name | Record Count (Expected) | Record Count (Actual) | Table Size | Index Size | Total On-Disk Size | Key Constraints Present |
|---|---:|---:|---:|---:|---:|---|
| `booking_seats` | 300,389 | 300,389 | 15 MB | 16 MB | 32 MB | PK (`booking_id, seat_id`), UNIQUE (`show_id, seat_id`), FKs |
| `shows` | 160,034 | 160,034 | 11 MB | 16 MB | 27 MB | PK (`show_id`), GiST exclusion (`no_overlapping_shows`), FKs |
| `bookings` | 150,094 | 150,094 | 17 MB | 9,728 kB | 27 MB | PK (`booking_id`), UNIQUE (`booking_code`), FKs |
| `seats` | 94,056 | 94,056 | 4,992 kB | 4,976 kB | 10 MB | PK (`seat_id`), UNIQUE (`screen_id, row_label, seat_number`), FK |
| `customers` | 40,000 | 40,000 | 3,840 kB | 4,496 kB | 8,368 kB | PK (`customer_id`), UNIQUE (`email`, `phone`) |
| `movie_reviews` | 32,510 | 32,510 | 2,048 kB | 1,776 kB | 3,864 kB | PK (`review_id`), FKs |
| `screens` | 490 | 490 | 32 kB | 32 kB | 88 kB | PK (`screen_id`), FK |
| `movies` | 300 | 300 | 24 kB | 16 kB | 64 kB | PK (`movie_id`) |
| `venues` | 140 | 140 | 16 kB | 16 kB | 64 kB | PK (`venue_id`), FK |
| `cities` | 10 | 10 | 8 kB | 32 kB | 40 kB | PK (`city_id`), UNIQUE (`city_name`) |
| `offers` | 25 | 25 | 8 kB | 16 kB | 24 kB | PK (`offer_code`) |
| **Total Dataset** | **778,048** | **778,048** | **54 MB** | **53 MB** | **108 MB** | Fully verified with 0 integrity mismatches |

---

## 3. Benchmarking Methodology

To ensure that performance timings reflect real database engine behavior and meet strict scientific benchmark standards:

1. **Automated Test Harness:** All 30 queries defined in `queries/workload_30.sql` were executed via the test script `benchmarks/run_benchmark.sh` against database `bms_db`.
2. **Repeated Executions (3 Runs per Query):**
   - Each query was executed 3 times sequentially.
   - Execution times for Run 1, Run 2, and Run 3 were extracted directly from the PostgreSQL engine's `Execution Time` line in `EXPLAIN (ANALYZE, BUFFERS)`.
   - Average, median, minimum, and maximum execution times were computed.
3. **Transactional Isolation for Write Queries (W01–W05):**
   - Every write query was wrapped in an explicit transaction block:
     ```sql
     SET search_path TO bms;
     BEGIN;
     EXPLAIN (ANALYZE, BUFFERS) <WRITE_QUERY>;
     ROLLBACK;
     ```
   - This ensured that data modifications (`INSERT`, `UPDATE`, `DELETE`) were completely rolled back, guaranteeing identical dataset state across all benchmark runs.
4. **Buffer Statistics Capture:** Buffer operations (`shared hit`, `shared read`, `dirtied`, `temp read`, `temp written`) were logged to measure memory and disk I/O pressure.

---

## 4. Results for All 30 Queries

The table below documents the complete baseline timing results for all 30 queries across three runs, including the average execution time:

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Home page: movies showing in Bengaluru on 2 July 2026 and how many shows each has | READ | 8.720 | 8.786 | 8.371 | 8.626 |
| R02: Showtimes page: shows of movie 2 in Bengaluru on 2 July 2026, grouped by cinema | READ | 5.874 | 6.175 | 5.859 | 5.969 |
| R03: Seat layout: every seat of show 144446 and whether it is already sold | READ | 0.266 | 0.267 | 0.271 | 0.268 |
| R04: Support: open a booking by its code | READ | 0.061 | 0.067 | 0.035 | 0.054 |
| R05: 'My bookings': customer 1331's upcoming confirmed shows | READ | 11.727 | 11.325 | 11.854 | 11.635 |
| R06: Search: movies whose title contains 'kalki' | READ | 0.311 | 0.329 | 0.142 | 0.261 |
| R07: Cinema dashboard: occupancy of every show at venue 11 on 28 June 2026 | READ | 0.980 | 1.048 | 1.289 | 1.106 |
| R08: Box office: top 10 movies by collections over the weekend of 26–28 June 2026 | READ | 26.016 | 23.574 | 23.449 | 24.346 |
| R09: Seat-lock service: bookings still PENDING more than 10 minutes after they were made (checked at 23:59, 30 Jun 2026) | READ | 11.555 | 8.712 | 9.323 | 9.863 |
| R10: Cinema operations: consecutive shows on the same screen with less than 30 minutes for cleaning (June 2026) | READ | 412.277 | 470.251 | 577.443 | 486.657 |
| R11: Revenue mix: share of ticket revenue from recliner seats, per screen type | READ | 90.293 | 90.780 | 98.841 | 93.305 |
| R12: Fans: customers who booked the same movie more than once | READ | 143.333 | 158.437 | 163.210 | 154.993 |
| R13: Partnerships: offers that have never been redeemed | READ | 30.763 | 22.469 | 21.263 | 24.832 |
| R14: Movie pages: average user rating of 2026 releases with at least 20 reviews | READ | 6.283 | 5.787 | 8.767 | 6.946 |
| R15: Capacity planning: bookings by weekday and hour of booking | READ | 63.205 | 54.429 | 57.733 | 58.456 |
| R16: Cinema partners: cancellation rate per venue for June 2026 shows | READ | 45.357 | 41.370 | 33.905 | 40.211 |
| R17: Cinema operations: seats of screen 101 that were never sold for any June 2026 show | READ | 56.263 | 73.733 | 57.040 | 62.345 |
| R18: Regional insights: collections per language per city in 2026 | READ | 115.346 | 140.961 | 125.257 | 127.188 |
| R19: Distributor report: tickets sold for every June 2026 show of movie 2 | READ | 2437.427 | 2294.462 | 2368.177 | 2366.689 |
| R20: Finance: daily collections and running total for June 2026 | READ | 37.488 | 23.656 | 28.445 | 29.863 |
| R21: Loyalty: 20 customers with the most confirmed bookings in 2026 | READ | 98.224 | 90.382 | 94.841 | 94.482 |
| R22: Support console: all bookings, newest first, page 4,001 (25 per page) | READ | 61.689 | 72.402 | 75.955 | 70.015 |
| R23: Sign-in with mobile number | READ | 0.028 | 0.047 | 0.027 | 0.034 |
| R24: Pricing: average price paid per seat class in each city (2026) | READ | 100.998 | 101.702 | 104.344 | 102.348 |
| R25: Programming: average occupancy of late-night shows (starting 22:30 or later) in June 2026 | READ | 35.163 | 44.469 | 42.074 | 40.569 |
| W01: Checkout: create a PENDING booking for 2 tickets of show 144446 | WRITE | 1.466 | 1.580 | 0.817 | 1.288 |
| W02: Seat lock: the oldest PENDING booking adds 2 more seats (the unsold seats with the lowest ids in its show) | WRITE | 15.129 | 18.143 | 24.169 | 19.147 |
| W03: Payment callback: confirm the oldest PENDING booking | WRITE | 0.678 | 0.910 | 0.987 | 0.858 |
| W04: Seat-lock expiry: release seats held by PENDING bookings older than 10 minutes | WRITE | 14.934 | 12.823 | 13.303 | 13.687 |
| W05: Pricing: 10% higher prices for all July weekend shows of movie 2 | WRITE | 10.120 | 6.721 | 11.454 | 9.432 |
| **Total (sum of all 30)** | | **3841.974** | **3785.797** | **3968.645** | **3865.472** |

---

## 5. Statistical Variance and Dispersion Analysis

To evaluate timing stability and cache impact across the three repeated runs:

| Query | Type | Min (ms) | Max (ms) | Median (ms) | Average (ms) | Std Dev (ms) | Stability Classification |
|---|---|---:|---:|---:|---:|---:|---|
| `R01` | READ | 8.371 | 8.786 | 8.720 | 8.626 | 0.182 | Highly Stable |
| `R02` | READ | 5.859 | 6.175 | 5.874 | 5.969 | 0.146 | Highly Stable |
| `R03` | READ | 0.266 | 0.271 | 0.267 | 0.268 | 0.002 | Highly Stable |
| `R04` | READ | 0.035 | 0.067 | 0.061 | 0.054 | 0.014 | Highly Stable |
| `R05` | READ | 11.325 | 11.854 | 11.727 | 11.635 | 0.225 | Highly Stable |
| `R06` | READ | 0.142 | 0.329 | 0.311 | 0.261 | 0.084 | Highly Stable |
| `R07` | READ | 0.980 | 1.289 | 1.048 | 1.106 | 0.133 | Highly Stable |
| `R08` | READ | 23.449 | 26.016 | 23.574 | 24.346 | 1.182 | Highly Stable |
| `R09` | READ | 8.712 | 11.555 | 9.323 | 9.863 | 1.222 | Highly Stable |
| `R10` | READ | 412.277 | 577.443 | 470.251 | 486.657 | 68.419 | High Variance |
| `R11` | READ | 90.293 | 98.841 | 90.780 | 93.305 | 3.920 | Moderate Variance |
| `R12` | READ | 143.333 | 163.210 | 158.437 | 154.993 | 8.472 | Moderate Variance |
| `R13` | READ | 21.263 | 30.763 | 22.469 | 24.832 | 4.223 | Moderate Variance |
| `R14` | READ | 5.787 | 8.767 | 6.283 | 6.946 | 1.304 | Highly Stable |
| `R15` | READ | 54.429 | 63.205 | 57.733 | 58.456 | 3.619 | Moderate Variance |
| `R16` | READ | 33.905 | 45.357 | 41.370 | 40.211 | 4.747 | Moderate Variance |
| `R17` | READ | 56.263 | 73.733 | 57.040 | 62.345 | 8.059 | Moderate Variance |
| `R18` | READ | 115.346 | 140.961 | 125.257 | 127.188 | 10.546 | Moderate Variance |
| `R19` | READ | 2294.462 | 2437.427 | 2368.177 | 2366.689 | 58.375 | High Variance |
| `R20` | READ | 23.656 | 37.488 | 28.445 | 29.863 | 5.735 | Moderate Variance |
| `R21` | READ | 90.382 | 98.224 | 94.841 | 94.482 | 3.212 | Moderate Variance |
| `R22` | READ | 61.689 | 75.955 | 72.402 | 70.015 | 6.064 | Moderate Variance |
| `R23` | READ | 0.027 | 0.047 | 0.028 | 0.034 | 0.009 | Highly Stable |
| `R24` | READ | 100.998 | 104.344 | 101.702 | 102.348 | 1.440 | Highly Stable |
| `R25` | READ | 35.163 | 44.469 | 42.074 | 40.569 | 3.945 | Moderate Variance |
| `W01` | WRITE | 0.817 | 1.580 | 1.466 | 1.288 | 0.336 | Highly Stable |
| `W02` | WRITE | 15.129 | 24.169 | 18.143 | 19.147 | 3.758 | Moderate Variance |
| `W03` | WRITE | 0.678 | 0.987 | 0.910 | 0.858 | 0.131 | Highly Stable |
| `W04` | WRITE | 12.823 | 14.934 | 13.303 | 13.687 | 0.904 | Highly Stable |
| `W05` | WRITE | 6.721 | 11.454 | 10.120 | 9.432 | 1.993 | Highly Stable |

---

## 6. Relevant Execution Plans and Buffer Statistics

Below is the execution plan profile for every query in the workload, detailing the scan operators, join types, shared buffer activity, and root-cause explanations:

### `R01` (READ): Home page: movies showing in Bengaluru on 2 July 2026 and how many shows each has
- **Execution Time (Avg):** `8.626 ms` (Run 1: `8.720 ms`, Run 2: `8.786 ms`, Run 3: `8.371 ms`)
- **Scan Nodes in Plan:** `Index Scan using movies_pkey on movies | Seq Scan on screens | Seq Scan on venues | Index Scan using no_overlapping_shows on shows`
- **Buffer Activity:** `shared hit=9230`
- **Plan Diagnostic:** Moderate (8.63 ms). Uses exclusion GiST index (`no_overlapping_shows`) for date filtering on `shows`, but screens and venues undergo Seq Scans. Function `DATE(s.starts_at)` prevents simple btree range pruning.

### `R02` (READ): Showtimes page: shows of movie 2 in Bengaluru on 2 July 2026, grouped by cinema
- **Execution Time (Avg):** `5.969 ms` (Run 1: `5.874 ms`, Run 2: `6.175 ms`, Run 3: `5.859 ms`)
- **Scan Nodes in Plan:** `Seq Scan on screens | Seq Scan on venues | Index Scan using no_overlapping_shows on shows`
- **Buffer Activity:** `shared hit=9229`
- **Plan Diagnostic:** Fast (5.97 ms). Efficient date range filtering on shows via GiST index, but lacks composite index on `(movie_id, starts_at)` and does Seq Scans on venues/screens.

### `R03` (READ): Seat layout: every seat of show 144446 and whether it is already sold
- **Execution Time (Avg):** `0.268 ms` (Run 1: `0.266 ms`, Run 2: `0.267 ms`, Run 3: `0.271 ms`)
- **Scan Nodes in Plan:** `Index Scan using shows_pkey on shows | Index Scan using uq_screen_seat_position on seats | Bitmap Heap Scan on booking_seats | Bitmap Index Scan on uq_show_seat`
- **Buffer Activity:** `shared hit=24`
- **Plan Diagnostic:** Fast (0.27 ms). Leverages PK on shows and composite UNIQUE index `uq_show_seat` on `booking_seats(show_id, seat_id)` along with `uq_screen_seat_position`.

### `R04` (READ): Support: open a booking by its code
- **Execution Time (Avg):** `0.054 ms` (Run 1: `0.061 ms`, Run 2: `0.067 ms`, Run 3: `0.035 ms`)
- **Scan Nodes in Plan:** `Index Scan using bookings_booking_code_key on bookings`
- **Buffer Activity:** `shared hit=4`
- **Plan Diagnostic:** Extremely fast (0.05 ms). Single-row point lookup using UNIQUE constraint B-tree index `bookings_booking_code_key`.

### `R05` (READ): 'My bookings': customer 1331's upcoming confirmed shows
- **Execution Time (Avg):** `11.635 ms` (Run 1: `11.727 ms`, Run 2: `11.325 ms`, Run 3: `11.854 ms`)
- **Scan Nodes in Plan:** `Seq Scan on bookings | Index Scan using shows_pkey on shows | Seq Scan on movies | Seq Scan on screens | Seq Scan on venues`
- **Buffer Activity:** `shared hit=2236`
- **Plan Diagnostic:** Moderate (11.64 ms). Lacks an index on `bookings(customer_id)`, requiring a full table Seq Scan across 150,094 booking records to find 2 rows.

### `R06` (READ): Search: movies whose title contains 'kalki'
- **Execution Time (Avg):** `0.261 ms` (Run 1: `0.311 ms`, Run 2: `0.329 ms`, Run 3: `0.142 ms`)
- **Scan Nodes in Plan:** `Seq Scan on movies`
- **Buffer Activity:** `shared hit=6`
- **Plan Diagnostic:** Fast (0.26 ms) only because `movies` table is small (300 rows). However, it performs a full Seq Scan with `ILIKE '%kalki%'` which will not scale without pg_trgm GIN indexing.

### `R07` (READ): Cinema dashboard: occupancy of every show at venue 11 on 28 June 2026
- **Execution Time (Avg):** `1.106 ms` (Run 1: `0.980 ms`, Run 2: `1.048 ms`, Run 3: `1.289 ms`)
- **Scan Nodes in Plan:** `Seq Scan on screens | Bitmap Heap Scan on shows | Bitmap Index Scan on no_overlapping_shows | Index Only Scan using uq_show_seat on booking_seats`
- **Buffer Activity:** `shared hit=619`
- **Plan Diagnostic:** Fast (1.11 ms). Venue filtering matches 3 screens; shows are retrieved via GiST index and booked seats count uses Index Only Scan on `uq_show_seat`.

### `R08` (READ): Box office: top 10 movies by collections over the weekend of 26–28 June 2026
- **Execution Time (Avg):** `24.346 ms` (Run 1: `26.016 ms`, Run 2: `23.574 ms`, Run 3: `23.449 ms`)
- **Scan Nodes in Plan:** `Seq Scan on bookings | Seq Scan on shows | Seq Scan on movies`
- **Buffer Activity:** `shared hit=3626`
- **Plan Diagnostic:** Moderate (24.35 ms). Full Seq Scans on both `bookings` (150k rows) and `shows` (160k rows) joined via Hash Join; lacks indexes on `bookings(show_id)` and date range.

### `R09` (READ): Seat-lock service: bookings still PENDING more than 10 minutes after they were made (checked at 23:59, 30 Jun 2026)
- **Execution Time (Avg):** `9.863 ms` (Run 1: `11.555 ms`, Run 2: `8.712 ms`, Run 3: `9.323 ms`)
- **Scan Nodes in Plan:** `Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2195`
- **Plan Diagnostic:** Moderate (9.86 ms). Full table Seq Scan across 150,094 rows in `bookings` to filter a tiny fraction of PENDING rows (only 10 total PENDING rows exist in database).

### `R10` (READ): Cinema operations: consecutive shows on the same screen with less than 30 minutes for cleaning (June 2026)
- **Execution Time (Avg):** `486.657 ms` (Run 1: `412.277 ms`, Run 2: `470.251 ms`, Run 3: `577.443 ms`)
- **Scan Nodes in Plan:** `Seq Scan on shows`
- **Buffer Activity:** `shared hit=2834`
- **Plan Diagnostic:** Slow (486.66 ms). Self-join of `shows` table with inequality / interval conditions requiring parallel workers and processing large intermediate join sets without a composite index on `(screen_id, starts_at)`.

### `R11` (READ): Revenue mix: share of ticket revenue from recliner seats, per screen type
- **Execution Time (Avg):** `93.305 ms` (Run 1: `90.293 ms`, Run 2: `90.780 ms`, Run 3: `98.841 ms`)
- **Scan Nodes in Plan:** `Seq Scan on booking_seats | Seq Scan on seats | Seq Scan on screens`
- **Buffer Activity:** `shared hit=3236`
- **Plan Diagnostic:** Slow (93.31 ms). Full table Seq Scan on 300,389 `booking_seats` joined with 94,056 `seats` and `screens` without covering indexes for seat class and screen type.

### `R12` (READ): Fans: customers who booked the same movie more than once
- **Execution Time (Avg):** `154.993 ms` (Run 1: `143.333 ms`, Run 2: `158.437 ms`, Run 3: `163.210 ms`)
- **Scan Nodes in Plan:** `Seq Scan on shows | Seq Scan on bookings`
- **Buffer Activity:** `shared hit=3606, temp read=120 written=282`
- **Plan Diagnostic:** Very slow (154.99 ms). HashAggregate over 133k confirmed bookings joined to shows, exceeding default work_mem and spilling to disk (temp read=120, written=282 blocks).

### `R13` (READ): Partnerships: offers that have never been redeemed
- **Execution Time (Avg):** `24.832 ms` (Run 1: `30.763 ms`, Run 2: `22.469 ms`, Run 3: `21.263 ms`)
- **Scan Nodes in Plan:** `Seq Scan on offers | Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2193`
- **Plan Diagnostic:** Moderate (24.83 ms). `NOT IN (SELECT offer_code FROM bookings)` executes a hashed subplan with a full Seq Scan of 150k bookings; also sensitive to NULL semantics.

### `R14` (READ): Movie pages: average user rating of 2026 releases with at least 20 reviews
- **Execution Time (Avg):** `6.946 ms` (Run 1: `6.283 ms`, Run 2: `5.787 ms`, Run 3: `8.767 ms`)
- **Scan Nodes in Plan:** `Seq Scan on movie_reviews | Seq Scan on movies`
- **Buffer Activity:** `shared hit=262`
- **Plan Diagnostic:** Moderate (6.95 ms). Full Seq Scan on 32,510 `movie_reviews` rows and `movies` with HashAggregate and in-memory sort.

### `R15` (READ): Capacity planning: bookings by weekday and hour of booking
- **Execution Time (Avg):** `58.456 ms` (Run 1: `63.205 ms`, Run 2: `54.429 ms`, Run 3: `57.733 ms`)
- **Scan Nodes in Plan:** `Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2195`
- **Plan Diagnostic:** Slow (58.46 ms). Seq Scan of all 150,094 `bookings` evaluating `EXTRACT(isodow)` and `EXTRACT(hour)` per row followed by HashAggregate.

### `R16` (READ): Cinema partners: cancellation rate per venue for June 2026 shows
- **Execution Time (Avg):** `40.211 ms` (Run 1: `45.357 ms`, Run 2: `41.370 ms`, Run 3: `33.905 ms`)
- **Scan Nodes in Plan:** `Seq Scan on bookings | Seq Scan on shows | Seq Scan on screens | Seq Scan on venues`
- **Buffer Activity:** `shared hit=3623`
- **Plan Diagnostic:** Slow (40.21 ms). Multi-table Hash Joins across bookings, shows, screens, and venues with full table scans; lacks date range index on shows and FK index on bookings.

### `R17` (READ): Cinema operations: seats of screen 101 that were never sold for any June 2026 show
- **Execution Time (Avg):** `62.345 ms` (Run 1: `56.263 ms`, Run 2: `73.733 ms`, Run 3: `57.040 ms`)
- **Scan Nodes in Plan:** `Seq Scan on booking_seats | Seq Scan on shows | Index Scan using uq_screen_seat_position on seats`
- **Buffer Activity:** `shared hit=3386`
- **Plan Diagnostic:** Slow (62.35 ms). Anti-join `NOT EXISTS` scanning `shows` and all 300,389 rows of `booking_seats` without an index on `shows(screen_id, starts_at)` or `booking_seats(seat_id)`.

### `R18` (READ): Regional insights: collections per language per city in 2026
- **Execution Time (Avg):** `127.188 ms` (Run 1: `115.346 ms`, Run 2: `140.961 ms`, Run 3: `125.257 ms`)
- **Scan Nodes in Plan:** `Seq Scan on bookings | Seq Scan on shows | Seq Scan on movies | Seq Scan on screens | Seq Scan on venues`
- **Buffer Activity:** `shared hit=3638`
- **Plan Diagnostic:** Very slow (127.19 ms). Massive 5-table Hash Join involving full table scans on bookings, shows, movies, screens, and venues, followed by Incremental Sort.

### `R19` (READ): Distributor report: tickets sold for every June 2026 show of movie 2
- **Execution Time (Avg):** `2366.689 ms` (Run 1: `2437.427 ms`, Run 2: `2294.462 ms`, Run 3: `2368.177 ms`)
- **Scan Nodes in Plan:** `Seq Scan on shows | Seq Scan on bookings`
- **Buffer Activity:** `shared hit=455158`
- **Plan Diagnostic:** Extremely slow (2366.69 ms - Worst Performer). Correlated subquery in SELECT/ORDER BY executes a full Seq Scan on 150,094 `bookings` for EACH of the 207 qualifying shows (~455k buffer hits).

### `R20` (READ): Finance: daily collections and running total for June 2026
- **Execution Time (Avg):** `29.863 ms` (Run 1: `37.488 ms`, Run 2: `23.656 ms`, Run 3: `28.445 ms`)
- **Scan Nodes in Plan:** `Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2231`
- **Plan Diagnostic:** Moderate (29.86 ms). Full Seq Scan on 150k bookings followed by HashAggregate and WindowAgg (`SUM(...) OVER (...)`) in memory.

### `R21` (READ): Loyalty: 20 customers with the most confirmed bookings in 2026
- **Execution Time (Avg):** `94.482 ms` (Run 1: `98.224 ms`, Run 2: `90.382 ms`, Run 3: `94.841 ms`)
- **Scan Nodes in Plan:** `Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2198, temp read=250 written=602`
- **Plan Diagnostic:** Slow (94.48 ms). Full Seq Scan on 150k bookings with group-by customer_id; HashAggregate exceeds work_mem and spills to disk (temp read=250, written=602 blocks).

### `R22` (READ): Support console: all bookings, newest first, page 4,001 (25 per page)
- **Execution Time (Avg):** `70.015 ms` (Run 1: `61.689 ms`, Run 2: `72.402 ms`, Run 3: `75.955 ms`)
- **Scan Nodes in Plan:** `Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2195, temp read=861 written=1069`
- **Plan Diagnostic:** Slow (70.02 ms). Deep pagination (`OFFSET 100000 LIMIT 25`) forces PostgreSQL to sort all 150,094 rows by `booked_at DESC`, spilling to disk external merge sort (temp read=861, written=1069 blocks).

### `R23` (READ): Sign-in with mobile number
- **Execution Time (Avg):** `0.034 ms` (Run 1: `0.028 ms`, Run 2: `0.047 ms`, Run 3: `0.027 ms`)
- **Scan Nodes in Plan:** `Index Scan using customers_phone_key on customers`
- **Buffer Activity:** `shared hit=3`
- **Plan Diagnostic:** Extremely fast (0.03 ms). Point lookup using UNIQUE B-tree index `customers_phone_key` on `customers(phone)`.

### `R24` (READ): Pricing: average price paid per seat class in each city (2026)
- **Execution Time (Avg):** `102.348 ms` (Run 1: `100.998 ms`, Run 2: `101.702 ms`, Run 3: `104.344 ms`)
- **Scan Nodes in Plan:** `Seq Scan on booking_seats | Seq Scan on seats | Seq Scan on screens | Seq Scan on venues`
- **Buffer Activity:** `shared hit=3245`
- **Plan Diagnostic:** Very slow (102.35 ms). Multi-table Hash Join scanning 300k booking_seats, 94k seats, screens, and venues with parallel group aggregation.

### `R25` (READ): Programming: average occupancy of late-night shows (starting 22:30 or later) in June 2026
- **Execution Time (Avg):** `40.569 ms` (Run 1: `35.163 ms`, Run 2: `44.469 ms`, Run 3: `42.074 ms`)
- **Scan Nodes in Plan:** `Seq Scan on booking_seats | Seq Scan on shows | Seq Scan on screens`
- **Buffer Activity:** `shared hit=3383`
- **Plan Diagnostic:** Slow (40.57 ms). Full scans on shows and booking_seats; non-sargable expression `s.starts_at::time >= '22:30'` prevents index range scans.

### `W01` (WRITE): Checkout: create a PENDING booking for 2 tickets of show 144446
- **Execution Time (Avg):** `1.288 ms` (Run 1: `1.466 ms`, Run 2: `1.580 ms`, Run 3: `0.817 ms`)
- **Scan Nodes in Plan:** `(no scan)`
- **Buffer Activity:** `shared hit=83`
- **Plan Diagnostic:** Fast (1.29 ms). Single-row INSERT into `bookings`; overhead is strictly constraint checks (PK, UNIQUE booking_code, FKs) and WAL logging.

### `W02` (WRITE): Seat lock: the oldest PENDING booking adds 2 more seats (the unsold seats with the lowest ids in its show)
- **Execution Time (Avg):** `19.147 ms` (Run 1: `15.129 ms`, Run 2: `18.143 ms`, Run 3: `24.169 ms`)
- **Scan Nodes in Plan:** `Index Scan using bookings_pkey on bookings | Index Scan using seats_pkey on seats | Index Scan using shows_pkey on shows | Index Only Scan using uq_show_seat on booking_seats`
- **Buffer Activity:** `shared hit=734`
- **Plan Diagnostic:** Moderate (19.15 ms). Multi-row INSERT with subquery `min(booking_id)` and anti-join `NOT EXISTS` scanning candidate seats and checking `uq_show_seat` constraint.

### `W03` (WRITE): Payment callback: confirm the oldest PENDING booking
- **Execution Time (Avg):** `0.858 ms` (Run 1: `0.678 ms`, Run 2: `0.910 ms`, Run 3: `0.987 ms`)
- **Scan Nodes in Plan:** `Index Scan using bookings_pkey on bookings`
- **Buffer Activity:** `shared hit=137`
- **Plan Diagnostic:** Fast (0.86 ms). Subquery finds `min(booking_id)` via Seq Scan / Index Scan, followed by single-row PK index update on `bookings`.

### `W04` (WRITE): Seat-lock expiry: release seats held by PENDING bookings older than 10 minutes
- **Execution Time (Avg):** `13.687 ms` (Run 1: `14.934 ms`, Run 2: `12.823 ms`, Run 3: `13.303 ms`)
- **Scan Nodes in Plan:** `Seq Scan on bookings | Index Scan using booking_seats_pkey on booking_seats`
- **Buffer Activity:** `shared hit=2228`
- **Plan Diagnostic:** Moderate (13.69 ms). Full table Seq Scan on `bookings` to identify expired PENDING bookings followed by PK index lookups on `booking_seats` for deletion.

### `W05` (WRITE): Pricing: 10% higher prices for all July weekend shows of movie 2
- **Execution Time (Avg):** `9.432 ms` (Run 1: `10.120 ms`, Run 2: `6.721 ms`, Run 3: `11.454 ms`)
- **Scan Nodes in Plan:** `Seq Scan on shows`
- **Buffer Activity:** `shared hit=2147`
- **Plan Diagnostic:** Moderate (9.43 ms). Full Seq Scan on 160,034 `shows` rows matching `movie_id = 2` and date/day-of-week criteria, updating 40 rows.

---

## 7. Identification of Slow Queries and Performance Bottlenecks

Based on the baseline metrics, queries are categorized into three distinct performance tiers:

### Tier 1: Severe Bottlenecks (> 100 ms)
| Query | Avg Time (ms) | Primary Structural Bottleneck | Optimization Target for CP3 |
|---|---:|---|---|
| **`R19`** | **2366.69 ms** | Correlated subquery in SELECT/ORDER BY. Executes full seq scan on 150k bookings for each show (~455k buffer hits). | Rewrite into `LEFT JOIN ... GROUP BY` + Index on `bookings(show_id)` |
| **`R10`** | **486.66 ms** | Quadratic self-join on 160k shows checking cleaning gap interval. | Rewrite using `LAG()` window function over `(screen_id, starts_at)` |
| **`R12`** | **154.99 ms** | Heavy HashAggregate over joined tables exceeding `work_mem`; spills to disk (`temp read=120`, `written=282`). | Composite index on `bookings(customer_id, show_id)` |
| **`R18`** | **127.19 ms** | 5-table Hash Join scanning all tables and aggregating by city and language. | Covering indexes on join keys and date filter |
| **`R24`** | **102.35 ms** | 4-table join on 300k `booking_seats` and 94k `seats` with parallel aggregation. | Composite index on `booking_seats(seat_id, price)` |

### Tier 2: Moderate Bottlenecks (20 ms – 100 ms)
- **`R11` (93.3 ms):** Full sequential scan on 300,389 `booking_seats` and 94,056 `seats` to compute recliner revenue mix.
- **`R21` (94.5 ms):** Aggregates 150,094 bookings by customer; spills to disk (`temp read=250`, `temp written=602`).
- **`R22` (70.0 ms):** Deep pagination (`OFFSET 100000 LIMIT 25`) forces PostgreSQL to sort 150,094 rows by `booked_at DESC`, spilling 861 disk blocks (`external merge sort`). Target for keyset pagination.
- **`R17` (62.3 ms):** Anti-join `NOT EXISTS` scanning shows and booking_seats without composite screen index.
- **`R15` (58.5 ms):** Full scan on bookings evaluating per-row date extraction functions (`EXTRACT(isodow)` and `EXTRACT(hour)`).
- **`R25` (40.6 ms):** Non-sargable time expression `starts_at::time >= '22:30'` prevents index scans on shows.
- **`R16` (40.2 ms):** Hash join on bookings and shows for cancellation rates without venue/status index.
- **`R20` (29.9 ms):** Full scan on bookings for June 2026 daily running totals.
- **`R13` (24.8 ms):** `NOT IN (SELECT offer_code FROM bookings)` performs full table scan and has NULL semantics issue.
- **`R08` (24.3 ms):** Weekend box office requires full table scans on bookings and shows.

### Tier 3: Sub-20 ms Queries
- **`W02` (19.1 ms):** Multi-table lookup (`min(booking_id)` and unsold seats filter).
- **`W04` (13.7 ms):** Deletes expired seats; seq scan on bookings to identify pending status.
- **`R05` (11.6 ms):** Seq scan on bookings to find upcoming shows for customer 1331.
- **`R09` (9.9 ms):** Seq scan on bookings to find 10 pending bookings.
- **`W05` (9.4 ms):** Seq scan on shows to update prices for weekend July shows of movie 2.
- **`R01` (8.6 ms) & `R02` (6.0 ms):** Filter shows via GiST index, but screens and venues are seq-scanned.
- **`R14` (6.9 ms):** Seq scan on reviews (32k rows).
- **`W01` (1.3 ms):** Direct row insert into bookings.
- **`R07` (1.1 ms):** Screen and show lookup for venue 11.
- **`W03` (0.86 ms):** PK update on oldest pending booking.
- **`R03` (0.27 ms):** Seat layout lookup using PK and `uq_show_seat`.
- **`R06` (0.26 ms):** Small table scan on 300 movies.
- **`R04` (0.05 ms) & `R23` (0.03 ms):** Direct B-tree point lookups on UNIQUE columns.

---

## 8. Initial Observations About Database Performance

1. **The Missing Foreign Key Index Dilemma:**
   - Relational foreign keys define referential integrity but **do not automatically create indexes in PostgreSQL**.
   - Because foreign keys like `bookings.show_id`, `bookings.customer_id`, and `booking_seats.seat_id` lack indexes, joins frequently degenerate into expensive Hash Joins requiring full sequential scans.
2. **Correlated Subquery Pathology (The R19 Effect):**
   - Correlated subqueries in `SELECT` or `ORDER BY` execute once per outer row.
   - In `R19`, scanning 150,094 rows 207 times resulted in **455,158 buffer page accesses** and **2,366 ms** of latency. Converting this pattern to a declarative `LEFT JOIN ... GROUP BY` will yield immense speedups.
3. **Memory Limits & Disk Spills:**
   - With the default `work_mem = 4MB`, aggregation and sorting for larger result sets (`R12`, `R21`, `R22`) cannot fit in memory.
   - PostgreSQL is forced to perform external disk merge sorts and on-disk hash tables, increasing buffer and I/O pressure.
4. **Non-Sargable Expressions:**
   - Expressions like `DATE(s.starts_at) = '2026-07-02'` (`R01`), `s.starts_at::time >= '22:30'` (`R25`), and `EXTRACT(...)` (`R15`, `W05`) prevent PostgreSQL from utilizing standard B-tree index seeks. Converting these to sargable range predicates (e.g. `starts_at >= '2026-07-02' AND starts_at < '2026-07-03'`) will unlock index range scans.
5. **Write Overhead is Well-Bounded:**
   - Write queries (`W01`–`W05`) executed cleanly in **0.86 ms to 19.15 ms**, demonstrating that constraint validation overhead (PK/FK/CHECK) is minimal on clean single-row or small batch operations.
   - In CP3, we must ensure that any new indexes added to accelerate read queries do not disproportionately degrade write query performance.

---

## 9. Deliverables Inventory for CP2

- **Performance Report:** `docs/03_baseline_timings.md`
- **Automated Timing Summary:** `benchmarks/results/baseline/summary.csv`
- **Raw Benchmark Execution Plans (3 runs each):** `benchmarks/results/baseline/R01.txt` ... `benchmarks/results/baseline/W05.txt`
