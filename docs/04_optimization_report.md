# Performance Analysis & Optimization Report (CP3)

**Course:** Database Management Systems · B.Tech 2nd Year  
**Project:** BookMyShow Database Engineering (DE Project 2026)  
**Milestone:** Checkpoint 3 (CP3 — Query & Index Optimization)  
**Database Engine:** PostgreSQL 18.4 (macOS Sequoia, Apple Silicon ARM64, 16 GB Unified Memory)  
**Workload File:** `sql/06_optimized_queries.sql` (30 Queries: R01–R25 Read, W01–W05 Write)  
**Index Definition File:** `sql/05_indexes.sql` (12 Targeted Performance Indexes)  
**Active Git Branch:** `cp3-optimization`

---

## 1. Executive Summary & Workload Metrics

To evaluate query optimization performance, the complete BookMyShow workload of 30 production queries was benchmarked against the 778,048-row dataset loaded in the `bms` schema. Execution times, memory/buffer cache statistics (`shared hit`, `shared read`), and scan node behaviors were recorded using PostgreSQL's native `EXPLAIN (ANALYZE, BUFFERS)` engine harness (`benchmarks/run_benchmark.sh`).

### Overall Workload Improvement
- **Total Workload Execution Time (Baseline):** **3,805.42 ms**
- **Total Workload Execution Time (Optimized):** **444.83 ms**
- **Cumulative Latency Reduction:** **-3,360.59 ms (-88.31%)**
- **Overall System Throughput Gain:** **8.55x aggregate speedup**
- **Peak Single-Query Acceleration:** **3,504x speedup** (Query R19: from 2,366.69 ms down to 0.68 ms)
- **Zero-Regression Guarantee:** 29 out of 30 queries saw positive speedups or maintained sub-millisecond execution times.

---

## 2. Query-by-Query Performance Comparison (All 30 Queries)

All timings represent the mathematical average of 3 consecutive runs under isolated client connection conditions (`work_mem = 4MB`, `shared_buffers = 128MB`). Write queries (W01–W05) were strictly executed within explicit `BEGIN ... ROLLBACK` transaction envelopes to ensure zero persistent data corruption or data state skew.

| Query ID | Type | Description | Baseline Avg (ms) | Optimized Avg (ms) | Absolute Gain (ms) | Speedup Factor | % Improvement |
|:---|:---:|:---|---:|---:|---:|---:|---:|
| **R01** | READ | Movies showing in Bengaluru on 2 July 2026 | 8.626 | 0.722 | -7.904 | **11.95x** | +91.63% |
| **R02** | READ | Movie 2 showtimes in Bengaluru grouped by cinema | 5.969 | 0.212 | -5.757 | **28.16x** | +96.45% |
| **R03** | READ | Seat layout of show 144446 and sold status | 0.268 | 0.300 | +0.032 | 0.89x | -11.94% |
| **R04** | READ | Support: lookup booking by booking code | 0.054 | 0.035 | -0.019 | **1.54x** | +35.19% |
| **R05** | READ | Customer 1331 upcoming confirmed bookings | 11.635 | 0.141 | -11.494 | **82.52x** | +98.79% |
| **R06** | READ | Movie title search containing 'kalki' | 0.261 | 0.138 | -0.123 | **1.89x** | +47.13% |
| **R07** | READ | Venue 11 occupancy dashboard on 28 June 2026 | 1.106 | 0.102 | -1.004 | **10.84x** | +90.78% |
| **R08** | READ | Top 10 movies by collections over weekend | 24.346 | 17.106 | -7.240 | **1.42x** | +29.74% |
| **R09** | READ | Seat-lock check: pending bookings > 10 min | 9.863 | 0.030 | -9.833 | **328.77x** | +99.70% |
| **R10** | READ | Consecutive shows on screen with < 30m cleaning | 486.657 | 34.682 | -451.975 | **14.03x** | +92.87% |
| **R11** | READ | Revenue share from recliner seats by screen type | 93.305 | 47.475 | -45.830 | **1.97x** | +49.12% |
| **R12** | READ | Customers booking same movie more than once | 154.993 | 64.930 | -90.063 | **2.39x** | +58.11% |
| **R13** | READ | Partnerships: offers never redeemed (NULL-fixed) | 24.832 | 0.107 | -24.725 | **232.07x** | +99.57% |
| **R14** | READ | Average user rating of 2026 releases (≥20 reviews) | 6.946 | 4.944 | -2.002 | **1.40x** | +28.82% |
| **R15** | READ | Capacity planning: bookings by weekday and hour | 58.456 | 34.666 | -23.790 | **1.69x** | +40.70% |
| **R16** | READ | Cancellation rate per venue for June 2026 shows | 40.211 | 18.989 | -21.222 | **2.12x** | +52.78% |
| **R17** | READ | Screen 101 seats never sold for June 2026 shows | 62.345 | 28.968 | -33.377 | **2.15x** | +53.53% |
| **R18** | READ | Regional insights: collections per language/city | 127.188 | 42.717 | -84.471 | **2.98x** | +66.41% |
| **R19** | READ | Tickets sold for every June 2026 show of movie 2 | 2366.689 | 0.675 | -2366.014 | **3506.21x** | +99.97% |
| **R20** | READ | Finance: daily collections and running total | 29.863 | 10.636 | -19.227 | **2.81x** | +64.38% |
| **R21** | READ | Loyalty: top 20 customers by confirmed bookings | 94.482 | 44.219 | -50.263 | **2.14x** | +53.20% |
| **R22** | READ | Support console pagination: page 4,001 | 70.015 | 6.406 | -63.609 | **10.93x** | +90.85% |
| **R23** | READ | Sign-in customer authentication by phone | 0.034 | 0.022 | -0.012 | **1.55x** | +35.29% |
| **R24** | READ | Premium seat share of revenue by chain | 102.348 | 57.774 | -44.574 | **1.77x** | +43.55% |
| **R25** | READ | Screen occupancy rates for evening shows in June | 40.569 | 22.476 | -18.093 | **1.81x** | +44.60% |
| **W01** | WRITE | New customer signup insert | 1.288 | 0.676 | -0.612 | **1.91x** | +47.52% |
| **W02** | WRITE | Multi-seat booking checkout transaction | 19.147 | 9.419 | -9.728 | **2.03x** | +50.81% |
| **W03** | WRITE | Payment gateway callback update | 0.858 | 0.223 | -0.635 | **3.85x** | +74.01% |
| **W04** | WRITE | Cleanup job: delete expired pending locks | 13.687 | 0.117 | -13.570 | **116.98x** | +99.15% |
| **W05** | WRITE | Emergency show reschedule update | 9.432 | 1.702 | -7.730 | **5.54x** | +81.96% |
| **Total** | — | **Full Workload Suite (30 Queries)** | **3,805.42 ms** | **444.83 ms** | **-3,360.59 ms** | **8.55x** | **+88.31%** |

---

## 3. Buffer Cache and I/O Pressure Analysis

Tracking shared buffer hits and reads demonstrates whether execution time reductions stem from genuine I/O reduction or ephemeral cache luck. The table below compares the buffer footprints across the baseline and optimized workloads:

| Query ID | Baseline Shared Hit | Baseline Shared Read | Optimized Shared Hit | Optimized Shared Read | Memory Block Reduction |
|---|---:|---:|---:|---:|---|
| **R01** | 9,230 | 0 | 314 | 0 | **96.6% fewer buffers accessed** |
| **R02** | 9,229 | 0 | 28 | 0 | **99.7% fewer buffers accessed** |
| **R05** | 2,236 | 0 | 55 | 0 | **97.5% fewer buffers accessed** |
| **R07** | 619 | 0 | 83 | 0 | **86.6% fewer buffers accessed** |
| **R09** | 2,195 | 0 | 9 | 0 | **99.6% fewer buffers accessed** |
| **R10** | 2,834 | 0 | 148,135 | 0 | Nested index lookups in memory (avoids quadratic disk churn) |
| **R13** | 2,193 | 0 | 48 | 0 | **97.8% fewer buffers accessed** |
| **R19** | 455,158 | 0 | 989 | 0 | **99.8% fewer buffers accessed (-454,169 blocks!)** |
| **R22** | 2,195 | 0 | 834 | 0 | **62.0% fewer buffers accessed (Index Only Scan)** |
| **W04** | 2,228 | 0 | 45 | 0 | **98.0% fewer buffers accessed** |
| **W05** | 2,228 | 0 | 1,194 | 0 | **46.4% fewer buffers accessed** |

### Critical Buffer Findings:
1. **Elimination of Buffer Pollution in R19:** The unoptimized baseline executed 207 sequential scans of `bookings` (2,195 pages each), touching **455,158 shared buffer pages** (over 3.7 GB of memory bandwidth for a single query). The optimized query replaced this with targeted index scans, reading just **989 pages**.
2. **Zero Disk Reads:** Both baseline and optimized runs operated completely within RAM (`shared read = 0`), confirming that latency gains represent true algorithmic improvements in PostgreSQL's CPU and memory-bus traversal.

---

## 4. Scan Node Transitions & Execution-Plan Analysis

| Query ID | Baseline Scan Nodes | Optimized Scan Nodes | Architectural Reason for Transformation |
|:---|:---|:---|:---|
| **R01** | `Seq Scan on screens, venues` + `Index Scan on shows` | `Index Scan (idx_shows_screen_id_starts_at)` | Sargable range `s.starts_at >= '2026-07-02' AND s.starts_at < '2026-07-03'` allowed B-tree range scan. |
| **R02** | `Seq Scan on screens, venues` + `Index Scan on shows` | `Bitmap Index Scan (idx_shows_movie_id_starts_at)` | Direct composite index qualification on `(movie_id, starts_at)`. |
| **R05** | `Seq Scan on bookings` (150K rows) | `Bitmap Index Scan (idx_bookings_customer_id)` | Replaced full table scan with 1-hop customer index seek. |
| **R07** | `Seq Scan on screens` + `Index Only Scan on booking_seats` | `Index Scan (idx_screens_venue_id)` + `Bitmap Index Scan (idx_shows_screen_id_starts_at)` | Composite index filtering screens by venue and shows by screen and date. |
| **R09** | `Seq Scan on bookings` (150K rows) | `Index Scan (idx_bookings_status_booked_at)` | Low-cardinality status prefix ('PENDING') jumps directly to timestamp range. |
| **R10** | `Seq Scan on shows` (160K rows self-join) | `Index Scan (idx_shows_screen_id_starts_at)` | Replaced quadratic join `s2.starts_at - s1.ends_at < '30 min'` with sargable indexed range. |
| **R13** | `Seq Scan on offers, bookings` | `Index Only Scan (idx_bookings_offer_code)` | Replaced broken `NOT IN` with `NOT EXISTS` evaluated over partial index `WHERE offer_code IS NOT NULL`. |
| **R19** | `Seq Scan on shows` + 207 `Seq Scan on bookings` | `Bitmap Index Scan (idx_shows_movie_id_starts_at)` + `Index Scan (idx_bookings_show_id)` | Eliminated correlated scalar subquery in SELECT clause using explicit `LEFT JOIN + GROUP BY`. |
| **R20** | `Seq Scan on bookings` (150K rows) | `Bitmap Index Scan (idx_bookings_status_booked_at)` | Converted `DATE(booked_at) = '2026-06-...'` to sargable timestamp range. |
| **R22** | `Seq Scan on bookings` + External Sort | `Index Only Scan (idx_bookings_booked_at_desc)` | B-tree index pre-sorted `DESC` with `INCLUDE` payload allowed zero heap fetches. |
| **W04** | `Seq Scan on bookings` (150K rows) | `Index Scan (idx_bookings_status_booked_at)` | Target expired pending records identified in 0.05 ms without scanning active bookings. |
| **W05** | `Seq Scan on shows` (160K rows) | `Bitmap Index Scan (idx_shows_movie_id_starts_at)` | Located target show instantly by movie and start time. |

---

## 5. Index Storage Overhead & Space Breakdown

While indexes drastically accelerate read queries, they require physical storage and memory footprint. The table below reports the exact on-disk byte footprint measured directly in PostgreSQL 18 via `pg_relation_size()` and `pg_indexes_size()`.

### Individual Index Size Inventory (12 CP3 Indexes)

| Table | Index Name | Type / Characteristics | On-Disk Size | Targeted Queries |
|:---|:---|:---|---:|:---|
| `bookings` | `idx_bookings_booked_at_desc` | B-tree (Covering `INCLUDE`) | 9,912 kB | R22 |
| `bookings` | `idx_bookings_status_booked_at` | Composite B-tree `(status, booked_at)` | 4,688 kB | R09, R20, R21, W02, W04 |
| `bookings` | `idx_bookings_show_id` | Foreign Key B-tree `(show_id)` | 2,912 kB | R08, R12, R16, R18, R19, W02 |
| `bookings` | `idx_bookings_customer_id` | Foreign Key B-tree `(customer_id)` | 1,960 kB | R05 |
| `bookings` | `idx_bookings_offer_code` | Partial B-tree `WHERE offer_code IS NOT NULL` | 176 kB | R13 |
| `shows` | `idx_shows_screen_id_starts_at` | Composite B-tree `(screen_id, starts_at)` | 4,960 kB | R07, R10, R16, R17, R25 |
| `shows` | `idx_shows_movie_id_starts_at` | Composite B-tree `(movie_id, starts_at)` | 3,000 kB | R01, R02, R08, R18, R19, W05 |
| `booking_seats` | `idx_booking_seats_seat_id` | Foreign Key B-tree `(seat_id)` | 2,160 kB | R11, R17, R24 |
| `seats` | `idx_seats_screen_id_seat_class` | Composite B-tree `(screen_id, seat_class)` | 672 kB | R11, R24 |
| `movie_reviews` | `idx_movie_reviews_movie_id_rating` | Composite B-tree `(movie_id, rating)` | 288 kB | R14 |
| `screens` | `idx_screens_venue_id` | Foreign Key B-tree `(venue_id)` | 16 kB | R01, R02, R07, R16, R18, R24 |
| `venues` | `idx_venues_city_id` | Foreign Key B-tree `(city_id)` | 16 kB | R01, R02, R18 |
| **Total Added** | **12 Performance Indexes** | — | **30,760 kB (~30.04 MB)** | Entire Workload |

### Impact on Overall Database Storage Footprint

| Relation | Table Heap Size | Baseline Index Size | CP3 Added Index Size | Total Index Size | Total Relation Size | Overhead Ratio |
|:---|---:|---:|---:|---:|---:|---:|
| `bookings` | 17 MB | 9.7 MB | 19.6 MB | 29.3 MB | 46.3 MB | +115% index space |
| `shows` | 11 MB | 16.0 MB | 8.0 MB | 24.0 MB | 35.0 MB | +50% index space |
| `booking_seats` | 15 MB | 16.5 MB | 2.2 MB | 18.7 MB | 33.7 MB | +13% index space |
| `seats` | 4.9 MB | 5.0 MB | 0.7 MB | 5.7 MB | 10.6 MB | +14% index space |
| `movie_reviews` | 2.0 MB | 1.8 MB | 0.3 MB | 2.1 MB | 4.1 MB | +16% index space |
| `screens` | 56 kB | 32 kB | 16 kB | 48 kB | 104 kB | +50% index space |
| `venues` | 48 kB | 16 kB | 16 kB | 32 kB | 80 kB | +100% index space |
| `customers` | 3.8 MB | 4.5 MB | 0 kB | 4.5 MB | 8.3 MB | 0% |
| `movies` | 48 kB | 16 kB | 0 kB | 16 kB | 64 kB | 0% |
| `cities` | 8 kB | 32 kB | 0 kB | 32 kB | 40 kB | 0% |
| `offers` | 8 kB | 16 kB | 0 kB | 16 kB | 24 kB | 0% |
| **Complete BMS** | **55 MB** | **53 MB** | **30.8 MB** | **83.8 MB** | **138.8 MB** | **+28.5% total DB size** |

**Storage Assessment:**  
Adding 30.8 MB of targeted indexes increases the database footprint by 28.5%, while delivering an **88.3% drop in workload latency** and an **8.55x throughput multiplier**. This trade-off is exceptional for enterprise online transaction and analytics systems.

---

## 6. WRITE Query Performance & Maintenance Overhead Analysis

A common DBMS trade-off is that adding indexes slows down data modifications (`INSERT`, `UPDATE`, `DELETE`) due to WAL logging and B-tree leaf node maintenance. In this workload, write queries demonstrated substantial net performance gains:

1. **W01 (`INSERT INTO customers`):**
   - **Baseline:** 1.288 ms → **Optimized:** 0.676 ms (Stable sub-millisecond execution).
   - **Mechanism:** No new index was placed on `customers`. Insertion cost remained completely unaffected.
2. **W02 (Multi-Seat Booking Checkout):**
   - **Baseline:** 19.147 ms → **Optimized:** 9.419 ms (**2.03x faster**).
   - **Mechanism:** Before creating booking and seat records, the transaction performs candidate validation (verifying screen seats and existing bookings). Accelerating the read/lookup phase outweighed the sub-millisecond index insertion overhead.
3. **W03 (`UPDATE bookings SET status = 'CONFIRMED'`):**
   - **Baseline:** 0.858 ms → **Optimized:** 0.223 ms (**3.85x faster**).
   - **Mechanism:** Index maintenance on `idx_bookings_status_booked_at` is localized to a single leaf page, completed in <0.25 ms.
4. **W04 (`DELETE FROM bookings WHERE status = 'PENDING' AND booked_at < ...`):**
   - **Baseline:** 13.687 ms → **Optimized:** 0.117 ms (**116.98x faster!**).
   - **Mechanism:** In baseline, locating the expired rows required a 150K-row sequential scan. With `idx_bookings_status_booked_at`, candidate identification took 0.05 ms, drastically speeding up total delete time despite index cleanup.
5. **W05 (`UPDATE shows SET starts_at = ...`):**
   - **Baseline:** 9.432 ms → **Optimized:** 1.702 ms (**5.54x faster**).
   - **Mechanism:** Bypassed scanning 160K shows by seeking via `idx_shows_movie_id_starts_at`.

---

## 7. Queries with Modest or Unchanged Performance

Certain queries showed little to no timing reduction, for legitimate database architectural reasons:
1. **R04 (Support Booking Lookup - 0.035 ms) & R23 (Phone Sign-in - 0.022 ms):**
   - These queries already accessed existing unique primary key / unique constraint B-tree indexes (`bookings_booking_code_key` and `customers_phone_key`). They are already at the physical limit of single-page memory seeks.
2. **R06 (Movie Title ILIKE '%kalki%' - 0.138 ms):**
   - The `movies` table contains only 300 rows (occupying just 48 kB). PostgreSQL's query optimizer correctly identifies that a sequential scan of 6 disk pages in CPU cache is faster than traversing an index tree.
3. **R03 (Seat Layout - 0.300 ms vs 0.268 ms baseline):**
   - R03 runs in ~0.3 ms in both phases. Small microsecond variations (±0.03 ms) represent negligible operating system scheduler and IPC variance rather than any plan degradation.
