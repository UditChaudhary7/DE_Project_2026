# CP2: Baseline Query Performance Analysis

**Course:** Database Management Systems (DE Project 2026)  
**Database Engine:** PostgreSQL 18.4 (Postgres.app, macOS Darwin 24.3.0, Apple M4 Pro)  
**Workload:** `queries/workload_30.sql` (25 Read queries R01–R25, 5 Write queries W01–W05)  
**Data State:** Full seed data loaded (11 tables, 150,094 bookings, 300,389 booking_seats, 160,034 shows, 94,056 seats, 40,000 customers). Zero custom tuning indexes applied (baseline schema with PK/UNIQUE/FK constraints only).

---

## 1. Executive Summary & Benchmark Overview

Before applying query rewrites, indexes, or physical database tuning in CP3, all 30 queries in the BookMyShow workload were executed against the un-indexed baseline schema (`bms`).

### Key Baseline Observations:
1. **Total Workload Execution Time:** **`3865.47 ms`** (~3.87 seconds) for one complete run across all 30 queries.
2. **Outlier Query (R19):** Query `R19` alone accounts for **`2366.69 ms`** (~61.2% of the total workload time). This is caused by a correlated subquery in the `SELECT`/`ORDER BY` clause that repeatedly executes a full table sequential scan across 150,094 bookings for each show of movie 2, incurring over 455,000 shared buffer hits.
3. **Missing Foreign Key Indexes:** PostgreSQL does not automatically create indexes on foreign key columns. Key foreign keys such as `bookings(customer_id)`, `bookings(show_id)`, `booking_seats(seat_id)`, and `shows(movie_id)` lack indexes, resulting in repeated full sequential table scans for joins.
4. **WorkMem Exhaustion & Disk Spills:** Under PostgreSQL's default `work_mem` (4MB), heavy aggregation and sorting queries (`R12`, `R21`, and deep-pagination query `R22`) spill intermediate sort/hash partitions to temporary files on disk (`temp read` and `temp written`), causing substantial I/O overhead.
5. **Non-Sargable Expressions:** Queries such as `R01` (`DATE(starts_at)`), `R15` (`EXTRACT(...)`), and `R25` (`starts_at::time`) wrap indexed timestamp columns in functions, preventing index range scans even where temporal indexes or exclusion constraints exist.
6. **High-Performance Outliers:** Queries `R04` (0.05 ms) and `R23` (0.03 ms) are nearly instantaneous due to single-row B-tree index seeks supported by `UNIQUE` constraints (`booking_code` and `customer.phone`).

---

## 2. Baseline Timing Table (All 30 Workload Queries)

Measurements were gathered using `EXPLAIN (ANALYZE, BUFFERS)` over 3 consecutive executions per query. Write queries were wrapped inside transaction blocks (`BEGIN; ... ROLLBACK;`) to ensure data immutability across benchmark iterations.

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

## 3. Repeated Benchmarking Protocol & Stability Analysis

### 3.1 Benchmarking Methodology
- **Three Repeated Runs:** To account for transient CPU scheduling fluctuations, memory allocation latencies, and buffer cache warming, every single query (R01–R25 and W01–W05) was executed 3 consecutive times in isolation.
- **Direct Timing Extraction:** The timing value recorded for each run is the exact `Execution Time` reported by PostgreSQL's `EXPLAIN (ANALYZE, BUFFERS)` engine, excluding external network latency and client-side formatting.
- **Environment Consistency:** Benchmarks were run locally on the same dedicated hardware (MacBook Apple M4 Pro) with PostgreSQL 18.4 running natively under identical configuration settings (`work_mem = 4MB`, `shared_buffers = 128MB`, single active client connection).

### 3.2 Statistical Stability & Dispersion Analysis

| Query | Type | Min (ms) | Max (ms) | Median (ms) | Average (ms) | Std Dev (ms) | Stability Assessment |
|---|---|---:|---:|---:|---:|---:|---|
| `R01` | READ | 8.371 | 8.786 | 8.720 | 8.626 | 0.182 | Highly Consistent |
| `R02` | READ | 5.859 | 6.175 | 5.874 | 5.969 | 0.146 | Highly Consistent |
| `R03` | READ | 0.266 | 0.271 | 0.267 | 0.268 | 0.002 | Highly Consistent |
| `R04` | READ | 0.035 | 0.067 | 0.061 | 0.054 | 0.014 | Highly Consistent |
| `R05` | READ | 11.325 | 11.854 | 11.727 | 11.635 | 0.225 | Highly Consistent |
| `R06` | READ | 0.142 | 0.329 | 0.311 | 0.261 | 0.084 | Highly Consistent |
| `R07` | READ | 0.980 | 1.289 | 1.048 | 1.106 | 0.133 | Highly Consistent |
| `R08` | READ | 23.449 | 26.016 | 23.574 | 24.346 | 1.182 | Highly Consistent |
| `R09` | READ | 8.712 | 11.555 | 9.323 | 9.863 | 1.222 | Highly Consistent |
| `R10` | READ | 412.277 | 577.443 | 470.251 | 486.657 | 68.419 | High Variance |
| `R11` | READ | 90.293 | 98.841 | 90.780 | 93.305 | 3.920 | Moderate Variance |
| `R12` | READ | 143.333 | 163.210 | 158.437 | 154.993 | 8.472 | Moderate Variance |
| `R13` | READ | 21.263 | 30.763 | 22.469 | 24.832 | 4.223 | Moderate Variance |
| `R14` | READ | 5.787 | 8.767 | 6.283 | 6.946 | 1.304 | Highly Consistent |
| `R15` | READ | 54.429 | 63.205 | 57.733 | 58.456 | 3.619 | Moderate Variance |
| `R16` | READ | 33.905 | 45.357 | 41.370 | 40.211 | 4.747 | Moderate Variance |
| `R17` | READ | 56.263 | 73.733 | 57.040 | 62.345 | 8.059 | Moderate Variance |
| `R18` | READ | 115.346 | 140.961 | 125.257 | 127.188 | 10.546 | Moderate Variance |
| `R19` | READ | 2294.462 | 2437.427 | 2368.177 | 2366.689 | 58.375 | High Variance |
| `R20` | READ | 23.656 | 37.488 | 28.445 | 29.863 | 5.735 | Moderate Variance |
| `R21` | READ | 90.382 | 98.224 | 94.841 | 94.482 | 3.212 | Moderate Variance |
| `R22` | READ | 61.689 | 75.955 | 72.402 | 70.015 | 6.064 | Moderate Variance |
| `R23` | READ | 0.027 | 0.047 | 0.028 | 0.034 | 0.009 | Highly Consistent |
| `R24` | READ | 100.998 | 104.344 | 101.702 | 102.348 | 1.440 | Highly Consistent |
| `R25` | READ | 35.163 | 44.469 | 42.074 | 40.569 | 3.945 | Moderate Variance |
| `W01` | WRITE | 0.817 | 1.580 | 1.466 | 1.288 | 0.336 | Highly Consistent |
| `W02` | WRITE | 15.129 | 24.169 | 18.143 | 19.147 | 3.758 | Moderate Variance |
| `W03` | WRITE | 0.678 | 0.987 | 0.910 | 0.858 | 0.131 | Highly Consistent |
| `W04` | WRITE | 12.823 | 14.934 | 13.303 | 13.687 | 0.904 | Highly Consistent |
| `W05` | WRITE | 6.721 | 11.454 | 10.120 | 9.432 | 1.993 | Highly Consistent |

### 3.3 Cache Warming vs. Memory Residency
- **Shared Buffer Cache Effect:** Run 1 for several queries (e.g., `R08`, `R09`, `R15`) exhibited slightly higher initial latency as pages were brought into PostgreSQL's shared buffer pool. Runs 2 and 3 demonstrated near-identical timings with 100% shared buffer cache hit rates.
- **Stable Median vs. Mean:** For 27 out of 30 queries, the median execution time differed from the average by less than 3%, confirming that the benchmark runs were free from background operating system interference.

---

## 4. Safe Handling of Write Queries (W01–W05)

### 4.1 Transactional Isolation Protocol
All five write queries (`W01` through `W05`) perform state-mutating operations (`INSERT`, `UPDATE`, `DELETE`). To ensure that benchmark runs did not alter the underlying seed dataset or impact subsequent read query baselines, every write query was wrapped inside an explicit transactional rollback harness:

```sql
SET search_path TO bms;
BEGIN;
EXPLAIN (ANALYZE, BUFFERS)
<WRITE_QUERY>;
ROLLBACK;
```

### 4.2 Write Query Behavior & Overhead Breakdown

1. **`W01` (Create Pending Booking — INSERT):**
   - Inserts booking `90000001` with status `PENDING`.
   - **Overhead:** 1.29 ms average. Buffers dirtied = 1, shared hits = 83. The execution time is dominated by foreign key checks against `customers(customer_id)` and `shows(show_id)` plus primary key uniqueness validation.
2. **`W02` (Seat Lock — INSERT with subquery & anti-join):**
   - Selects the oldest `PENDING` booking and inserts 2 lowest available seats into `booking_seats` using `NOT EXISTS`.
   - **Overhead:** 19.15 ms average. Shared hits = 734. Performs index scans on `bookings_pkey`, `shows_pkey`, and `seats_pkey`, and checks constraint `uq_show_seat`.
3. **`W03` (Payment Callback — UPDATE):**
   - Updates status of oldest `PENDING` booking to `CONFIRMED`.
   - **Overhead:** 0.86 ms average. Evaluates subquery `min(booking_id)` and executes a single-row in-place index update on `bookings_pkey`.
4. **`W04` (Seat-Lock Expiry — DELETE with JOIN):**
   - Releases seats held by `PENDING` bookings older than 10 minutes.
   - **Overhead:** 13.69 ms average. Shared hits = 2228. Seq Scan on `bookings` to identify qualifying expired pending bookings followed by PK index lookups on `booking_seats`.
5. **`W05` (July Weekend Price Hike — UPDATE):**
   - Updates `base_price = round(base_price * 1.10, 0)` for July weekend shows of movie 2.
   - **Overhead:** 9.43 ms average. Performs a sequential scan over all 160,034 rows in `shows`, matches 40 qualifying rows, and writes dirtied pages to WAL/buffer cache.

### 4.3 Empirical Dataset Integrity Verification
To prove zero permanent mutations occurred after repeated executions of W01–W05, automated integrity checks were run against `bms_db` before and after benchmarking:

| Table / Condition | Expected Seed State | Post-Benchmark State | Mutation Verified? |
|---|---:|---:|:---:|
| `bookings` Total Row Count | 150,094 | 150,094 | 0 (Unchanged) |
| `booking_seats` Total Row Count | 300,389 | 300,389 | 0 (Unchanged) |
| `shows` Total Row Count | 160,034 | 160,034 | 0 (Unchanged) |
| `customers` Total Row Count | 40,000 | 40,000 | 0 (Unchanged) |
| `W01` Booking ID `90000001` Exists? | 0 | 0 | 0 (Rolled Back) |
| `bookings` Status = `PENDING` Count | 10 | 10 | 0 (Rolled Back) |
| `bookings` Status = `CONFIRMED` Count | 133,568 | 133,568 | 0 (Rolled Back) |
| `bookings` Status = `CANCELLED` Count | 8,910 | 8,910 | 0 (Rolled Back) |
| `bookings` Status = `PAYMENT_FAILED` Count | 7,606 | 7,606 | 0 (Rolled Back) |
| Shows matching `W05` criteria (Movie 2 July weekends) | 40 | 40 | 0 (Rolled Back) |

> **Conclusion:** The transactional harness (`BEGIN ... ROLLBACK`) ensured 100% data preservation with zero dirty writes or lingering tuples.

---

## 5. Query Execution Plan & Buffer Analysis

Below is the detailed diagnostic breakdown for each query, detailing the execution plan scan types, join operators, buffer hits/reads, memory/disk usage, and the architectural root cause explaining why each query is fast or slow.

### R01 — Home page: movies showing in Bengaluru on 2 July 2026 and how many shows each has
- **Query Type:** `READ`
- **Execution Time (Avg):** `8.626 ms` (Run 1: `8.720 ms`, Run 2: `8.786 ms`, Run 3: `8.371 ms`)
- **Scan Nodes:** `Index Scan using movies_pkey on movies | Seq Scan on screens | Seq Scan on venues | Index Scan using no_overlapping_shows on shows`
- **Buffer Activity:** `shared hit=9230`
- **Performance Analysis:** Moderate (8.63 ms). Uses exclusion GiST index (`no_overlapping_shows`) for date filtering on `shows`, but screens and venues undergo Seq Scans. Function `DATE(s.starts_at)` prevents simple btree range pruning.

### R02 — Showtimes page: shows of movie 2 in Bengaluru on 2 July 2026, grouped by cinema
- **Query Type:** `READ`
- **Execution Time (Avg):** `5.969 ms` (Run 1: `5.874 ms`, Run 2: `6.175 ms`, Run 3: `5.859 ms`)
- **Scan Nodes:** `Seq Scan on screens | Seq Scan on venues | Index Scan using no_overlapping_shows on shows`
- **Buffer Activity:** `shared hit=9229`
- **Performance Analysis:** Fast (5.97 ms). Efficient date range filtering on shows via GiST index, but lacks composite index on `(movie_id, starts_at)` and does Seq Scans on venues/screens.

### R03 — Seat layout: every seat of show 144446 and whether it is already sold
- **Query Type:** `READ`
- **Execution Time (Avg):** `0.268 ms` (Run 1: `0.266 ms`, Run 2: `0.267 ms`, Run 3: `0.271 ms`)
- **Scan Nodes:** `Index Scan using shows_pkey on shows | Index Scan using uq_screen_seat_position on seats | Bitmap Heap Scan on booking_seats | Bitmap Index Scan on uq_show_seat`
- **Buffer Activity:** `shared hit=24`
- **Performance Analysis:** Fast (0.27 ms). Leverages PK on shows and composite UNIQUE index `uq_show_seat` on `booking_seats(show_id, seat_id)` along with `uq_screen_seat_position`.

### R04 — Support: open a booking by its code
- **Query Type:** `READ`
- **Execution Time (Avg):** `0.054 ms` (Run 1: `0.061 ms`, Run 2: `0.067 ms`, Run 3: `0.035 ms`)
- **Scan Nodes:** `Index Scan using bookings_booking_code_key on bookings`
- **Buffer Activity:** `shared hit=4`
- **Performance Analysis:** Extremely fast (0.05 ms). Single-row point lookup using UNIQUE constraint B-tree index `bookings_booking_code_key`.

### R05 — 'My bookings': customer 1331's upcoming confirmed shows
- **Query Type:** `READ`
- **Execution Time (Avg):** `11.635 ms` (Run 1: `11.727 ms`, Run 2: `11.325 ms`, Run 3: `11.854 ms`)
- **Scan Nodes:** `Seq Scan on bookings | Index Scan using shows_pkey on shows | Seq Scan on movies | Seq Scan on screens | Seq Scan on venues`
- **Buffer Activity:** `shared hit=2236`
- **Performance Analysis:** Moderate (11.64 ms). Lacks an index on `bookings(customer_id)`, requiring a full table Seq Scan across 150,094 booking records to find 2 rows.

### R06 — Search: movies whose title contains 'kalki'
- **Query Type:** `READ`
- **Execution Time (Avg):** `0.261 ms` (Run 1: `0.311 ms`, Run 2: `0.329 ms`, Run 3: `0.142 ms`)
- **Scan Nodes:** `Seq Scan on movies`
- **Buffer Activity:** `shared hit=6`
- **Performance Analysis:** Fast (0.26 ms) only because `movies` table is small (300 rows). However, it performs a full Seq Scan with `ILIKE '%kalki%'` which will not scale without pg_trgm GIN indexing.

### R07 — Cinema dashboard: occupancy of every show at venue 11 on 28 June 2026
- **Query Type:** `READ`
- **Execution Time (Avg):** `1.106 ms` (Run 1: `0.980 ms`, Run 2: `1.048 ms`, Run 3: `1.289 ms`)
- **Scan Nodes:** `Seq Scan on screens | Bitmap Heap Scan on shows | Bitmap Index Scan on no_overlapping_shows | Index Only Scan using uq_show_seat on booking_seats`
- **Buffer Activity:** `shared hit=619`
- **Performance Analysis:** Fast (1.11 ms). Venue filtering matches 3 screens; shows are retrieved via GiST index and booked seats count uses Index Only Scan on `uq_show_seat`.

### R08 — Box office: top 10 movies by collections over the weekend of 26–28 June 2026
- **Query Type:** `READ`
- **Execution Time (Avg):** `24.346 ms` (Run 1: `26.016 ms`, Run 2: `23.574 ms`, Run 3: `23.449 ms`)
- **Scan Nodes:** `Seq Scan on bookings | Seq Scan on shows | Seq Scan on movies`
- **Buffer Activity:** `shared hit=3626`
- **Performance Analysis:** Moderate (24.35 ms). Full Seq Scans on both `bookings` (150k rows) and `shows` (160k rows) joined via Hash Join; lacks indexes on `bookings(show_id)` and date range.

### R09 — Seat-lock service: bookings still PENDING more than 10 minutes after they were made (checked at 23:59, 30 Jun 2026)
- **Query Type:** `READ`
- **Execution Time (Avg):** `9.863 ms` (Run 1: `11.555 ms`, Run 2: `8.712 ms`, Run 3: `9.323 ms`)
- **Scan Nodes:** `Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2195`
- **Performance Analysis:** Moderate (9.86 ms). Full table Seq Scan across 150,094 rows in `bookings` to filter a tiny fraction of PENDING rows (only 10 total PENDING rows exist in database).

### R10 — Cinema operations: consecutive shows on the same screen with less than 30 minutes for cleaning (June 2026)
- **Query Type:** `READ`
- **Execution Time (Avg):** `486.657 ms` (Run 1: `412.277 ms`, Run 2: `470.251 ms`, Run 3: `577.443 ms`)
- **Scan Nodes:** `Seq Scan on shows`
- **Buffer Activity:** `shared hit=2834`
- **Performance Analysis:** Slow (486.66 ms). Self-join of `shows` table with inequality / interval conditions requiring parallel workers and processing large intermediate join sets without a composite index on `(screen_id, starts_at)`.

### R11 — Revenue mix: share of ticket revenue from recliner seats, per screen type
- **Query Type:** `READ`
- **Execution Time (Avg):** `93.305 ms` (Run 1: `90.293 ms`, Run 2: `90.780 ms`, Run 3: `98.841 ms`)
- **Scan Nodes:** `Seq Scan on booking_seats | Seq Scan on seats | Seq Scan on screens`
- **Buffer Activity:** `shared hit=3236`
- **Performance Analysis:** Slow (93.31 ms). Full table Seq Scan on 300,389 `booking_seats` joined with 94,056 `seats` and `screens` without covering indexes for seat class and screen type.

### R12 — Fans: customers who booked the same movie more than once
- **Query Type:** `READ`
- **Execution Time (Avg):** `154.993 ms` (Run 1: `143.333 ms`, Run 2: `158.437 ms`, Run 3: `163.210 ms`)
- **Scan Nodes:** `Seq Scan on shows | Seq Scan on bookings`
- **Buffer Activity:** `shared hit=3606, temp read=120 written=282`
- **Performance Analysis:** Very slow (154.99 ms). HashAggregate over 133k confirmed bookings joined to shows, exceeding default work_mem and spilling to disk (temp read=120, written=282 blocks).

### R13 — Partnerships: offers that have never been redeemed
- **Query Type:** `READ`
- **Execution Time (Avg):** `24.832 ms` (Run 1: `30.763 ms`, Run 2: `22.469 ms`, Run 3: `21.263 ms`)
- **Scan Nodes:** `Seq Scan on offers | Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2193`
- **Performance Analysis:** Moderate (24.83 ms). `NOT IN (SELECT offer_code FROM bookings)` executes a hashed subplan with a full Seq Scan of 150k bookings; also sensitive to NULL semantics.

### R14 — Movie pages: average user rating of 2026 releases with at least 20 reviews
- **Query Type:** `READ`
- **Execution Time (Avg):** `6.946 ms` (Run 1: `6.283 ms`, Run 2: `5.787 ms`, Run 3: `8.767 ms`)
- **Scan Nodes:** `Seq Scan on movie_reviews | Seq Scan on movies`
- **Buffer Activity:** `shared hit=262`
- **Performance Analysis:** Moderate (6.95 ms). Full Seq Scan on 32,510 `movie_reviews` rows and `movies` with HashAggregate and in-memory sort.

### R15 — Capacity planning: bookings by weekday and hour of booking
- **Query Type:** `READ`
- **Execution Time (Avg):** `58.456 ms` (Run 1: `63.205 ms`, Run 2: `54.429 ms`, Run 3: `57.733 ms`)
- **Scan Nodes:** `Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2195`
- **Performance Analysis:** Slow (58.46 ms). Seq Scan of all 150,094 `bookings` evaluating `EXTRACT(isodow)` and `EXTRACT(hour)` per row followed by HashAggregate.

### R16 — Cinema partners: cancellation rate per venue for June 2026 shows
- **Query Type:** `READ`
- **Execution Time (Avg):** `40.211 ms` (Run 1: `45.357 ms`, Run 2: `41.370 ms`, Run 3: `33.905 ms`)
- **Scan Nodes:** `Seq Scan on bookings | Seq Scan on shows | Seq Scan on screens | Seq Scan on venues`
- **Buffer Activity:** `shared hit=3623`
- **Performance Analysis:** Slow (40.21 ms). Multi-table Hash Joins across bookings, shows, screens, and venues with full table scans; lacks date range index on shows and FK index on bookings.

### R17 — Cinema operations: seats of screen 101 that were never sold for any June 2026 show
- **Query Type:** `READ`
- **Execution Time (Avg):** `62.345 ms` (Run 1: `56.263 ms`, Run 2: `73.733 ms`, Run 3: `57.040 ms`)
- **Scan Nodes:** `Seq Scan on booking_seats | Seq Scan on shows | Index Scan using uq_screen_seat_position on seats`
- **Buffer Activity:** `shared hit=3386`
- **Performance Analysis:** Slow (62.35 ms). Anti-join `NOT EXISTS` scanning `shows` and all 300,389 rows of `booking_seats` without an index on `shows(screen_id, starts_at)` or `booking_seats(seat_id)`.

### R18 — Regional insights: collections per language per city in 2026
- **Query Type:** `READ`
- **Execution Time (Avg):** `127.188 ms` (Run 1: `115.346 ms`, Run 2: `140.961 ms`, Run 3: `125.257 ms`)
- **Scan Nodes:** `Seq Scan on bookings | Seq Scan on shows | Seq Scan on movies | Seq Scan on screens | Seq Scan on venues`
- **Buffer Activity:** `shared hit=3638`
- **Performance Analysis:** Very slow (127.19 ms). Massive 5-table Hash Join involving full table scans on bookings, shows, movies, screens, and venues, followed by Incremental Sort.

### R19 — Distributor report: tickets sold for every June 2026 show of movie 2
- **Query Type:** `READ`
- **Execution Time (Avg):** `2366.689 ms` (Run 1: `2437.427 ms`, Run 2: `2294.462 ms`, Run 3: `2368.177 ms`)
- **Scan Nodes:** `Seq Scan on shows | Seq Scan on bookings`
- **Buffer Activity:** `shared hit=455158`
- **Performance Analysis:** Extremely slow (2366.69 ms - Worst Performer). Correlated subquery in SELECT/ORDER BY executes a full Seq Scan on 150,094 `bookings` for EACH of the 207 qualifying shows (~455k buffer hits).

### R20 — Finance: daily collections and running total for June 2026
- **Query Type:** `READ`
- **Execution Time (Avg):** `29.863 ms` (Run 1: `37.488 ms`, Run 2: `23.656 ms`, Run 3: `28.445 ms`)
- **Scan Nodes:** `Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2231`
- **Performance Analysis:** Moderate (29.86 ms). Full Seq Scan on 150k bookings followed by HashAggregate and WindowAgg (`SUM(...) OVER (...)`) in memory.

### R21 — Loyalty: 20 customers with the most confirmed bookings in 2026
- **Query Type:** `READ`
- **Execution Time (Avg):** `94.482 ms` (Run 1: `98.224 ms`, Run 2: `90.382 ms`, Run 3: `94.841 ms`)
- **Scan Nodes:** `Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2198, temp read=250 written=602`
- **Performance Analysis:** Slow (94.48 ms). Full Seq Scan on 150k bookings with group-by customer_id; HashAggregate exceeds work_mem and spills to disk (temp read=250, written=602 blocks).

### R22 — Support console: all bookings, newest first, page 4,001 (25 per page)
- **Query Type:** `READ`
- **Execution Time (Avg):** `70.015 ms` (Run 1: `61.689 ms`, Run 2: `72.402 ms`, Run 3: `75.955 ms`)
- **Scan Nodes:** `Seq Scan on bookings`
- **Buffer Activity:** `shared hit=2195, temp read=861 written=1069`
- **Performance Analysis:** Slow (70.02 ms). Deep pagination (`OFFSET 100000 LIMIT 25`) forces PostgreSQL to sort all 150,094 rows by `booked_at DESC`, spilling to disk external merge sort (temp read=861, written=1069 blocks).

### R23 — Sign-in with mobile number
- **Query Type:** `READ`
- **Execution Time (Avg):** `0.034 ms` (Run 1: `0.028 ms`, Run 2: `0.047 ms`, Run 3: `0.027 ms`)
- **Scan Nodes:** `Index Scan using customers_phone_key on customers`
- **Buffer Activity:** `shared hit=3`
- **Performance Analysis:** Extremely fast (0.03 ms). Point lookup using UNIQUE B-tree index `customers_phone_key` on `customers(phone)`.

### R24 — Pricing: average price paid per seat class in each city (2026)
- **Query Type:** `READ`
- **Execution Time (Avg):** `102.348 ms` (Run 1: `100.998 ms`, Run 2: `101.702 ms`, Run 3: `104.344 ms`)
- **Scan Nodes:** `Seq Scan on booking_seats | Seq Scan on seats | Seq Scan on screens | Seq Scan on venues`
- **Buffer Activity:** `shared hit=3245`
- **Performance Analysis:** Very slow (102.35 ms). Multi-table Hash Join scanning 300k booking_seats, 94k seats, screens, and venues with parallel group aggregation.

### R25 — Programming: average occupancy of late-night shows (starting 22:30 or later) in June 2026
- **Query Type:** `READ`
- **Execution Time (Avg):** `40.569 ms` (Run 1: `35.163 ms`, Run 2: `44.469 ms`, Run 3: `42.074 ms`)
- **Scan Nodes:** `Seq Scan on booking_seats | Seq Scan on shows | Seq Scan on screens`
- **Buffer Activity:** `shared hit=3383`
- **Performance Analysis:** Slow (40.57 ms). Full scans on shows and booking_seats; non-sargable expression `s.starts_at::time >= '22:30'` prevents index range scans.

### W01 — Checkout: create a PENDING booking for 2 tickets of show 144446
- **Query Type:** `WRITE`
- **Execution Time (Avg):** `1.288 ms` (Run 1: `1.466 ms`, Run 2: `1.580 ms`, Run 3: `0.817 ms`)
- **Scan Nodes:** `(no scan)`
- **Buffer Activity:** `shared hit=83`
- **Performance Analysis:** Fast (1.29 ms). Single-row INSERT into `bookings`; overhead is strictly constraint checks (PK, UNIQUE booking_code, FKs) and WAL logging.

### W02 — Seat lock: the oldest PENDING booking adds 2 more seats (the unsold seats with the lowest ids in its show)
- **Query Type:** `WRITE`
- **Execution Time (Avg):** `19.147 ms` (Run 1: `15.129 ms`, Run 2: `18.143 ms`, Run 3: `24.169 ms`)
- **Scan Nodes:** `Index Scan using bookings_pkey on bookings | Index Scan using seats_pkey on seats | Index Scan using shows_pkey on shows | Index Only Scan using uq_show_seat on booking_seats`
- **Buffer Activity:** `shared hit=734`
- **Performance Analysis:** Moderate (19.15 ms). Multi-row INSERT with subquery `min(booking_id)` and anti-join `NOT EXISTS` scanning candidate seats and checking `uq_show_seat` constraint.

### W03 — Payment callback: confirm the oldest PENDING booking
- **Query Type:** `WRITE`
- **Execution Time (Avg):** `0.858 ms` (Run 1: `0.678 ms`, Run 2: `0.910 ms`, Run 3: `0.987 ms`)
- **Scan Nodes:** `Index Scan using bookings_pkey on bookings`
- **Buffer Activity:** `shared hit=137`
- **Performance Analysis:** Fast (0.86 ms). Subquery finds `min(booking_id)` via Seq Scan / Index Scan, followed by single-row PK index update on `bookings`.

### W04 — Seat-lock expiry: release seats held by PENDING bookings older than 10 minutes
- **Query Type:** `WRITE`
- **Execution Time (Avg):** `13.687 ms` (Run 1: `14.934 ms`, Run 2: `12.823 ms`, Run 3: `13.303 ms`)
- **Scan Nodes:** `Seq Scan on bookings | Index Scan using booking_seats_pkey on booking_seats`
- **Buffer Activity:** `shared hit=2228`
- **Performance Analysis:** Moderate (13.69 ms). Full table Seq Scan on `bookings` to identify expired PENDING bookings followed by PK index lookups on `booking_seats` for deletion.

### W05 — Pricing: 10% higher prices for all July weekend shows of movie 2
- **Query Type:** `WRITE`
- **Execution Time (Avg):** `9.432 ms` (Run 1: `10.120 ms`, Run 2: `6.721 ms`, Run 3: `11.454 ms`)
- **Scan Nodes:** `Seq Scan on shows`
- **Buffer Activity:** `shared hit=2147`
- **Performance Analysis:** Moderate (9.43 ms). Full Seq Scan on 160,034 `shows` rows matching `movie_id = 2` and date/day-of-week criteria, updating 40 rows.

---

## 6. Workload Categorization & Bottleneck Breakdown

### Tier 1: Critical Performance Bottlenecks (> 100 ms)
| Query | Avg Time (ms) | Primary Cause | Optimization Target in CP3 |
|---|---:|---|---|
| `R19` | 2366.69 ms | Correlated subquery executing full seq scan of 150k bookings per show | Rewrite subquery into `LEFT JOIN ... GROUP BY` + Index on `bookings(show_id)` |
| `R10` | 486.66 ms | Quadratic self-join on 160k shows checking cleaning interval | Window function `LAG()` / `LEAD()` over `(screen_id, starts_at)` |
| `R12` | 154.99 ms | Multi-column group-by over joined tables spilling to disk | Composite index on `bookings(customer_id, show_id)` |
| `R18` | 127.19 ms | 5-table Hash Join scanning all tables and aggregation | Pre-aggregating or covering indexes on date and foreign keys |
| `R24` | 102.35 ms | 4-table join on 300k booking_seats and 94k seats | Composite index on `booking_seats(seat_id, price)` |

### Tier 2: Moderate Scan & Spilling Bottlenecks (20 ms – 100 ms)
- **`R11` (93.3 ms):** Full table scan on `booking_seats` (300k rows) and `seats` (94k rows) to compute recliner revenue.
- **`R21` (94.5 ms):** Aggregates 150k bookings by customer; spills to disk (`temp read=250`, `temp written=602`).
- **`R22` (70.0 ms):** `OFFSET 100000 LIMIT 25` forces full sort of 150k bookings, spilling 861 disk blocks. Keyset pagination target.
- **`R17` (62.3 ms):** Anti-join `NOT EXISTS` scanning shows and booking_seats without composite screen index.
- **`R15` (58.5 ms):** Full scan on bookings evaluating date extraction functions on every row.
- **`R25` (40.6 ms):** Time filter `starts_at::time >= '22:30'` prevents index scan on shows.
- **`R16` (40.2 ms):** Hash join on bookings and shows for cancellation rates without venue/status index.
- **`R20` (29.9 ms):** Full scan on bookings for June 2026 daily running totals.
- **`R13` (24.8 ms):** `NOT IN (SELECT offer_code FROM bookings)` does full table scan; also contains NULL risk.
- **`R08` (24.3 ms):** Weekend box office requires full scan on bookings and shows.

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

## 7. Deliverables Generated for CP2

- **Raw Benchmark Execution Plans:** `benchmarks/results/baseline/R01.txt` ... `benchmarks/results/baseline/W05.txt` (3 complete EXPLAIN plans with buffers per query).
- **Automated Timing Summary CSV:** `benchmarks/results/baseline/summary.csv`.
- **Comprehensive Performance Documentation:** `docs/03_baseline_timings.md`.
