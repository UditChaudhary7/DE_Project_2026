# Optimization Report (CP3)

**Course:** Database Management Systems · B.Tech 2nd Year  
**Project:** BookMyShow Database Engineering (DE Project 2026)  
**Milestone:** Checkpoint 3 (CP3 — Query Optimization & Performance Tuning)  
**Workload File:** `sql/06_optimized_queries.sql` (30 Queries: R01–R25 Read, W01–W05 Write)  
**Index Definition File:** `sql/05_indexes.sql` (12 Targeted Performance Indexes)  
**Test Harness Script:** `benchmarks/run_benchmark.sh`  
**Database Engine:** PostgreSQL 18.4 (macOS Sequoia, Apple Silicon ARM64, 16 GB Unified RAM)  
**Target Database:** `bms_db` (Schema: `bms`, Seed Data: 778,048 rows)  

---

## 1. Introduction

In Checkpoint 2 (Phase 3), a baseline performance analysis was conducted across the 30 core database queries of the BookMyShow ticketing platform using `queries/workload_30.sql`. The baseline database schema (`sql/01_schema.sql`) included primary keys, unique constraints, and an exclusion constraint (`no_overlapping_shows`), but lacked secondary indexes on critical foreign keys, filtering columns, and join paths.

The objective of Checkpoint 3 (CP3) is to systematically optimize the query workload without altering business logic or database consistency:
1. **Identify Performance Bottlenecks:** Diagnose sequential scan churn, nested loop explosions, correlated subqueries, non-sargable expressions, and memory buffer bottlenecks using PostgreSQL `EXPLAIN (ANALYZE, BUFFERS)`.
2. **Engineer a Targeted Indexing Strategy:** Design and implement 12 performance indexes in `sql/05_indexes.sql` covering B-tree, composite, partial, and covering (`INCLUDE`) architectures.
3. **Refactor Inefficient Queries:** Formulate optimized SQL statements in `sql/06_optimized_queries.sql` while guaranteeing strict semantic equivalence.
4. **Resolve Subtle Logic Defects:** Discover and fix the ANSI SQL three-valued logic `NULL` trap in query `R13`.
5. **Measure and Verify Results:** Benchmark the optimized workload using `benchmarks/run_benchmark.sh`, compare timings against the preserved baseline (`benchmarks/results/baseline/`), evaluate storage overhead, and assess write performance impact.

All benchmark figures reported in this document are derived directly from actual PostgreSQL engine execution measurements.

---

## 2. Baseline Performance

The baseline benchmark executed 3 runs for each of the 30 queries against database `bms_db` containing 778,048 records (300,389 booking seats, 160,034 shows, 150,094 bookings, 94,056 seats, 40,000 customers).

### Key Baseline Findings
- **Cumulative Workload Latency:** The sum of average execution times across all 30 queries was **3,865.473 ms**.
- **Extreme Latency Outliers:**
  - **`R19` (Distributor Show Sales):** Averaged **2,366.689 ms** (accounting for **61.2%** of the entire workload execution time).
  - **`R10` (Consecutive Shows Cleaning Gap):** Averaged **486.657 ms** due to an unconstrained self-join over shows.
  - **`R12` (Repeat Movie Bookings):** Averaged **154.993 ms**.
  - **`R18` (Regional Collections by Language/City):** Averaged **127.188 ms**.
  - **`R24` (Seat Class Pricing by City):** Averaged **102.348 ms**.
- **Buffer Cache Thrashing:** The baseline workload generated **526,011 shared buffer hits** per cycle (over **4.11 GB** of memory block reads), evicting working-set data from the 128 MB buffer cache.
- **Transactional Write Latencies:** Write operations with search filters took substantial time (e.g., `W02` took **19.147 ms**, `W04` took **13.687 ms**, `W05` took **9.432 ms**) because identifying candidate tuples required scanning entire 150k+ row tables.

---

## 3. Identified Bottlenecks

Detailed analysis of the baseline `EXPLAIN (ANALYZE, BUFFERS)` plans revealed six fundamental architectural bottlenecks:

### 3.1 Unindexed Foreign Keys
In PostgreSQL, foreign key constraints enforce referential integrity but do **not** automatically create supporting indexes. Because high-churn relationships lacked indexes:
- `bookings(customer_id)` was unindexed, causing `R05` to scan 150,094 rows just to locate 2 bookings for customer 1331.
- `bookings(show_id)` was unindexed, degrading joins in `R08`, `R12`, `R16`, `R18`, and `R19`.
- `shows(movie_id)` and `shows(screen_id)` were unindexed, forcing full scans of 160,034 shows for cinema schedules and distributor reports.

### 3.2 Correlated Subquery Scan Explosion (R19)
Query `R19` contained a scalar subquery within its `SELECT` projection list to calculate ticket sales per show:
```sql
SELECT s.show_id, s.starts_at,
       (SELECT COALESCE(sum(num_tickets), 0)
        FROM bookings b
        WHERE b.show_id = s.show_id AND b.status = 'CONFIRMED') AS tickets_sold
FROM shows s
WHERE s.movie_id = 2 AND s.starts_at >= '2026-06-01' AND s.starts_at < '2026-07-01'
ORDER BY tickets_sold DESC, s.starts_at;
```
For all 207 qualifying shows of movie 2, PostgreSQL executed `SubPlan 1` independently. Because `bookings.show_id` had no index, every subplan invocation performed a full sequential scan of 150,094 rows ($207 \times 150,094 \approx 31,069,458$ tuple evaluations), accumulating **455,158 buffer hits** and consuming **2,366.69 ms**.

### 3.3 Quadratic Self-Join on Shows (R10)
Query `R10` identified consecutive shows on the same screen with less than 30 minutes cleaning time. The baseline query joined `shows s1` and `shows s2` on screen and date, but lacked sargable boundary predicates on `starts_at`. The query planner resorted to a Gather Merge and parallel nested loop join, comparing hundreds of thousands of show combinations and consuming **486.66 ms**.

### 3.4 Non-Sargable Function Filters
Several queries wrapped indexed or indexable columns inside functions:
- `DATE(s.starts_at) = '2026-07-02'` in `R01` and `DATE(s.starts_at) = '2026-06-28'` in `R07`.
- `EXTRACT(YEAR FROM s.starts_at) = 2026` in `R18`.
- `b.booked_at::date = ...` in `R20`.
Applying functions to columns invalidates standard B-tree range traversals, forcing PostgreSQL to evaluate the expression row-by-row across 160,034 shows and 150,094 bookings.

### 3.5 Deep Offset Pagination Overhead (R22)
Query `R22` queried page 4,001 of bookings: `ORDER BY booked_at DESC LIMIT 25 OFFSET 100000`. The engine had to scan the table, sort 150,094 rows, read 100,025 physical heap tuples from disk/RAM, and discard the first 100,000 tuples just to return 25 rows, taking **70.02 ms**.

### 3.6 SQL Three-Valued Logic NULL Trap (R13)
The baseline query for unredeemed offers used `NOT IN (SELECT offer_code FROM bookings)`. Because `bookings.offer_code` permits `NULL` values, the expression evaluated to `UNKNOWN` for every single offer, returning an empty result set (0 rows) and falsifying business metrics.

---

## 4. Indexing Strategy

To resolve these bottlenecks with minimal storage and write overhead, 12 targeted indexes were designed and implemented in `sql/05_indexes.sql`:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        INDEXING ARCHITECTURE                           │
├───────────────────┬──────────────────────────────────┬─────────────────┤
│ Table             │ Index Name                       │ Type            │
├───────────────────┼──────────────────────────────────┼─────────────────┤
│ bookings          │ idx_bookings_customer_id         │ B-tree (FK)     │
│ bookings          │ idx_bookings_show_id             │ B-tree (FK)     │
│ bookings          │ idx_bookings_status_booked_at    │ Composite       │
│ bookings          │ idx_bookings_offer_code          │ Partial         │
│ bookings          │ idx_bookings_booked_at_desc      │ Covering        │
│ shows             │ idx_shows_movie_id_starts_at     │ Composite       │
│ shows             │ idx_shows_screen_id_starts_at    │ Composite       │
│ booking_seats     │ idx_booking_seats_seat_id        │ B-tree (FK)     │
│ seats             │ idx_seats_screen_id_seat_class   │ Composite       │
│ screens           │ idx_screens_venue_id             │ B-tree (FK)     │
│ venues            │ idx_venues_city_id               │ B-tree (FK)     │
│ movie_reviews     │ idx_movie_reviews_movie_id_rating│ Composite       │
└───────────────────┴──────────────────────────────────┴─────────────────┘
```

### Detailed Index Justification

1. **`idx_bookings_customer_id` ON `bms.bookings(customer_id)`**
   - **Type:** B-tree (single column foreign key).
   - **Coverage:** Serves `R05` ("My bookings" lookup).
   - **Rationale:** Customer ID has high cardinality (40,000 customers across 150k bookings). A B-tree index narrows lookups from 150,094 rows to the exact 2–10 rows for that user.

2. **`idx_bookings_show_id` ON `bms.bookings(show_id)`**
   - **Type:** B-tree (single column foreign key).
   - **Coverage:** Serves `R08`, `R12`, `R16`, `R18`, `R19`, `W02`, `W04`.
   - **Rationale:** Powers relational joins from `shows` to `bookings`. Directly eliminates the inner sequential scan in `R19`.

3. **`idx_bookings_status_booked_at` ON `bms.bookings(status, booked_at)`**
   - **Type:** Composite B-tree.
   - **Coverage:** Serves `R09`, `R20`, `R21`, `W02`, `W03`, `W04`.
   - **Rationale:** Adheres to the **Equality First, Range Second** principle. `status` has low cardinality (`CONFIRMED`, `PENDING`, `CANCELLED`), allowing PostgreSQL to jump straight to the relevant status slice and perform an index range scan on `booked_at`.

4. **`idx_bookings_offer_code` ON `bms.bookings(offer_code) WHERE offer_code IS NOT NULL`**
   - **Type:** Partial B-tree index.
   - **Coverage:** Serves `R13` (`NOT EXISTS` antijoin).
   - **Rationale:** 90%+ of bookings do not use discount offers (`offer_code IS NULL`). A partial index indexes only the ~12,000 rows where an offer was actually applied, occupying only **176 kB** (a 99% space saving over an unconstrained index).

5. **`idx_bookings_booked_at_desc` ON `bms.bookings(booked_at DESC) INCLUDE (booking_id, customer_id, show_id, status, total_amount)`**
   - **Type:** Covering B-tree index with `INCLUDE`.
   - **Coverage:** Serves `R22` (deep offset console pagination).
   - **Rationale:** By embedding all projected columns in the index payload, PostgreSQL satisfies the query entirely through an **Index Only Scan**, reading sequential index pages and bypassing the 17 MB heap table entirely.

6. **`idx_shows_movie_id_starts_at` ON `bms.shows(movie_id, starts_at)`**
   - **Type:** Composite B-tree.
   - **Coverage:** Serves `R01`, `R02`, `R08`, `R18`, `R19`, `W05`.
   - **Rationale:** Enables instant filtering on movie ID followed by time range bounds for show schedules and distributor reports.

7. **`idx_shows_screen_id_starts_at` ON `bms.shows(screen_id, starts_at)`**
   - **Type:** Composite B-tree.
   - **Coverage:** Serves `R07`, `R10`, `R16`, `R17`, `R25`.
   - **Rationale:** Accelerates screen schedule lookups and enables the sargable self-join in `R10`.

8. **`idx_booking_seats_seat_id` ON `bms.booking_seats(seat_id)`**
   - **Type:** B-tree (foreign key).
   - **Coverage:** Serves `R11`, `R17`, `R24`, `W02`.
   - **Rationale:** Table `booking_seats` already had a unique index on `(show_id, seat_id)`, but zero index on `seat_id` alone. This index enables reverse lookups from seats to booking history.

9. **`idx_seats_screen_id_seat_class` ON `bms.seats(screen_id, seat_class)`**
   - **Type:** Composite B-tree.
   - **Coverage:** Serves `R03`, `R11`, `R24`.
   - **Rationale:** Filters seats by auditorium screen and seat category (e.g., Recliner vs Prime).

10. **`idx_screens_venue_id` ON `bms.screens(venue_id)`**
    - **Type:** B-tree (foreign key).
    - **Coverage:** Serves `R01`, `R02`, `R07`, `R16`, `R18`, `R24`.
    - **Rationale:** Bridges venue-to-screen joins.

11. **`idx_venues_city_id` ON `bms.venues(city_id)`**
    - **Type:** B-tree (foreign key).
    - **Coverage:** Serves `R01`, `R02`, `R18`.
    - **Rationale:** Allows rapid filtering of venues within a specific metropolitan city.

12. **`idx_movie_reviews_movie_id_rating` ON `bms.movie_reviews(movie_id, rating)`**
    - **Type:** Composite B-tree.
    - **Coverage:** Serves `R14` (average ratings for 2026 releases).
    - **Rationale:** Satisfies both the `GROUP BY movie_id` and `AVG(rating)` computation directly within the index tree.

---

## 5. Query Optimization Techniques

Query refactoring in `sql/06_optimized_queries.sql` adhered to strict rules: **preserve identical result rows, maintain ordering, and avoid non-standard database settings**.

### 5.1 Set-Based Transformation of Correlated Subqueries (R19)
The correlated scalar subquery in `R19` was converted into a relational `LEFT JOIN` combined with `GROUP BY`:
```sql
-- Optimized R19
SELECT s.show_id, s.starts_at,
       COALESCE(sum(b.num_tickets), 0) AS tickets_sold
FROM shows s
LEFT JOIN bookings b ON b.show_id = s.show_id AND b.status = 'CONFIRMED'
WHERE s.movie_id = 2
  AND s.starts_at >= '2026-06-01' AND s.starts_at < '2026-07-01'
GROUP BY s.show_id, s.starts_at
ORDER BY tickets_sold DESC, s.starts_at;
```
This allowed the optimizer to execute a single set-based join plan utilizing `idx_shows_movie_id_starts_at` and `idx_bookings_show_id`, collapsing runtime from **2,366.69 ms to 0.68 ms**.

### 5.2 Sargable Timestamp Range Conversions (R01, R07, R18, R20)
Function wrappers on temporal columns were rewritten into open/closed range intervals:
- **R01:** `DATE(s.starts_at) = '2026-07-02'` $\longrightarrow$ `s.starts_at >= '2026-07-02' AND s.starts_at < '2026-07-03'`.
- **R07:** `DATE(s.starts_at) = '2026-06-28'` $\longrightarrow$ `s.starts_at >= '2026-06-28' AND s.starts_at < '2026-06-29'`.
- **R18:** `EXTRACT(YEAR FROM s.starts_at) = 2026` $\longrightarrow$ `s.starts_at >= '2026-01-01' AND s.starts_at < '2027-01-01'`.
- **R20:** `b.booked_at::date` filtering $\longrightarrow$ explicit month timestamp boundary.
Converting these predicates to sargable expressions enabled the query planner to replace full table scans with high-speed B-tree index range traversals.

### 5.3 Bounded Window Interval Transformation (R10)
In `R10`, consecutive shows were originally evaluated using:
```sql
s2.starts_at >= s1.ends_at AND s2.starts_at - s1.ends_at < interval '30 minutes'
```
Subtracting timestamps produced an interval expression that prevented index usage on `s2.starts_at`. The condition was refactored into an indexed boundary predicate:
```sql
s2.starts_at >= s1.ends_at AND s2.starts_at < s1.ends_at + interval '30 minutes'
```
Supported by `idx_shows_screen_id_starts_at`, PostgreSQL probed `s2` using a direct Index Scan for every show of `s1`, reducing runtime from **486.66 ms to 35.04 ms**.

---

## 6. NULL-Related Correctness Issue and Solution (R13)

### The SQL Three-Valued Logic Defect
In SQL relational theory, boolean logic is ternary: `TRUE`, `FALSE`, and `UNKNOWN` (represented by `NULL`). The baseline query for unredeemed promotional offers was formulated as:
```sql
-- Original R13 (Buggy)
SELECT offer_code, discount_pct, max_discount, description
FROM offers
WHERE offer_code NOT IN (SELECT offer_code FROM bookings);
```

When PostgreSQL evaluates `val NOT IN (c1, c2, ..., NULL)`, the standard dictates expanding the set comparison into a conjunction of inequalities:
$$ (val \ne c_1) \text{ AND } (val \ne c_2) \text{ AND } \dots \text{ AND } (val \ne \text{NULL}) $$
Under SQL standards:
1. Any equality or inequality comparison with `NULL` yields `UNKNOWN` (e.g., `'SUMMER50' \ne \text{NULL} \implies \text{UNKNOWN}`).
2. In boolean conjunctions, `TRUE AND UNKNOWN` yields `UNKNOWN`.
3. In SQL `WHERE` clauses, a row is returned if and only if the filter evaluates strictly to `TRUE`. Rows evaluating to `UNKNOWN` or `FALSE` are discarded.

Because the `bookings` table contains bookings where no offer was applied (`offer_code IS NULL`), the subquery returned a set containing `NULL`. Consequently, `offer_code NOT IN (...)` evaluated to `UNKNOWN` for **every single offer in the database**. The query returned **0 rows**, misleading the partnerships team into believing that every single offer was actively redeemed.

### The Engineering Solution
The query was rewritten using `NOT EXISTS`, which evaluates two-valued existential truth:
```sql
-- Optimized R13 (Correct & Fast)
SELECT o.offer_code, o.discount_pct, o.max_discount, o.description
FROM offers o
WHERE NOT EXISTS (
    SELECT 1 FROM bookings b WHERE b.offer_code = o.offer_code
);
```

#### Results Verification
1. **Correctness:** The query now returns the **7 genuine unredeemed offers**:
   - `SUMMER50` (50% off)
   - `MONSOON20` (20% off)
   - `STUDENT15` (15% off)
   - `SENIOR25` (25% off)
   - `EARLYBIRD` (10% off)
   - `NIGHTOWL` (15% off)
   - `FESTIVE30` (30% off)
2. **Performance:** Combined with the partial index `idx_bookings_offer_code`, the engine executes a `Nested Loop Anti Join` using an **Index Only Scan**, dropping execution time from **24.83 ms to 0.11 ms** (**221.7× speedup**).

---

## 7. Before/After Comparison for All 30 Queries

The table below presents the complete performance comparison across all 30 benchmark queries, measured under 3 sequential runs using `benchmarks/run_benchmark.sh`:

| Query ID | Description | Type | Baseline Avg (ms) | Optimized Avg (ms) | Baseline Scan Path | Optimized Scan Path | Result Status |
|:---|:---|:---:|---:|---:|:---|:---|:---:|
| **R01** | Movies showing in BLR on 2 July | READ | 8.626 | 0.669 | Seq Scan (shows, screens, venues) | Index Scan (`idx_shows_screen_id_starts_at`) | Verified |
| **R02** | Movie 2 showtimes in BLR on 2 July | READ | 5.969 | 0.162 | Seq Scan (shows, screens) | Bitmap Index Scan (`idx_shows_movie_id_starts_at`) | Verified |
| **R03** | Seat layout & availability for show 144446 | READ | 0.268 | 0.262 | Seq Scan (seats) + Index Scan (booking_seats)| Index Scan (`idx_seats_screen_id_seat_class`) | Verified |
| **R04** | Support: lookup booking by code | READ | 0.054 | 0.034 | Index Scan (`bookings_booking_code_key`) | Index Scan (`bookings_booking_code_key`) | Verified |
| **R05** | Customer 1331 upcoming confirmed bookings| READ | 11.635 | 0.112 | Seq Scan on bookings (150k rows) | Bitmap Index Scan (`idx_bookings_customer_id`) | Verified |
| **R06** | Search: movies with 'kalki' in title | READ | 0.261 | 0.132 | Seq Scan on movies (300 rows) | Seq Scan on movies (in-memory cached pages) | Verified |
| **R07** | Venue 11 occupancy on 28 June 2026 | READ | 1.106 | 0.116 | Seq Scan (screens, shows) | Index Scan (`idx_screens_venue_id`, `idx_shows`) | Verified |
| **R08** | Top 10 movies by collections (26–28 June) | READ | 24.346 | 18.048 | Seq Scan (shows, bookings) | Bitmap Index Scan (`idx_shows_movie_id_starts_at`)| Verified |
| **R09** | Pending bookings older than 10 minutes | READ | 9.863 | 0.034 | Parallel Seq Scan on bookings (150k rows)| Index Scan (`idx_bookings_status_booked_at`) | Verified |
| **R10** | Cleaning gap < 30 min between shows | READ | 486.657 | 35.035 | Gather Merge + Parallel Nested Loop on shows | Index Scan (`idx_shows_screen_id_starts_at`) | Verified |
| **R11** | Revenue share from recliner seats | READ | 93.305 | 51.117 | Parallel Seq Scan (booking_seats, seats) | Hash Join via `idx_seats_screen_id_seat_class` | Verified |
| **R12** | Fans: booked same movie $\ge 2$ times | READ | 154.993 | 74.302 | Hash Join + Parallel Seq Scan (bookings) | Accelerated join via `idx_bookings_show_id` | Verified |
| **R13** | Partnerships: offers never redeemed | READ | 24.832 | 0.112 | Seq Scan (bookings 150k rows) [Wrong: 0 rows]| Anti Join via `idx_bookings_offer_code` [7 rows] | **Fixed Bug** |
| **R14** | Avg rating for 2026 releases ($\ge 20$ reviews)| READ | 6.946 | 4.997 | HashAggregate over reviews | Index Scan (`idx_movie_reviews_movie_id_rating`) | Verified |
| **R15** | Capacity planning by weekday and hour | READ | 58.456 | 34.973 | Parallel Seq Scan on bookings | Parallel Seq Scan with optimized aggregation | Verified |
| **R16** | Venue cancellation rates for June 2026 | READ | 40.211 | 19.269 | Multi-table Seq Scan | Joins using `idx_bookings_show_id`, `idx_screens` | Verified |
| **R17** | Unsold seats on screen 101 in June 2026 | READ | 62.345 | 29.070 | Seq Scan on shows and booking_seats | Bitmap Scan (`idx_shows`), Index (`booking_seats`)| Verified |
| **R18** | Collections per language & city (2026) | READ | 127.188 | 48.666 | Multi-table Seq Scan across shows & bookings | Sargable range on `shows` + `idx_venues_city_id` | Verified |
| **R19** | Distributor per-show sales for movie 2 | READ | 2,366.689 | 0.684 | Correlated SubPlan Seq Scan (207 iterations) | Hash/Nested Left Join (`idx_shows`, `idx_bookings`)| Verified |
| **R20** | Daily collections & running total (June) | READ | 29.863 | 10.588 | Seq Scan on bookings | Bitmap Index Scan (`idx_bookings_status_booked_at`)| Verified |
| **R21** | Top 20 loyalty customers in 2026 | READ | 94.482 | 44.903 | Parallel Seq Scan on bookings | Parallel HashAggregate over confirmed bookings | Verified |
| **R22** | Deep pagination: page 4,001 (offset 100k) | READ | 70.015 | 8.885 | Seq Scan + Sort on bookings (100k heap read) | Index Only Scan (`idx_bookings_booked_at_desc`) | Verified |
| **R23** | Customer sign-in with mobile number | READ | 0.034 | 0.024 | Index Scan (`customers_phone_key`) | Index Scan (`customers_phone_key`) | Verified |
| **R24** | Average price paid per seat class per city | READ | 102.348 | 70.126 | Multi-table Hash Join on 300k rows | Accelerated joins via foreign key indexes | Verified |
| **R25** | Late-night show occupancy in June 2026 | READ | 40.569 | 22.599 | Seq Scan on shows and booking_seats | Bitmap Index Scan (`idx_shows_screen_id_starts_at`)| Verified |
| **W01** | Create pending booking (insert 1 row) | WRITE | 1.288 | 0.925 | Direct heap insert + constraint triggers | Direct insert maintaining 5 B-tree indexes | Verified |
| **W02** | Lock 2 seats for oldest pending booking | WRITE | 19.147 | 10.884 | Seq Scan to find min booking + seat join | Index Scan (`idx_bookings_status`), `booking_seats`| Verified |
| **W03** | Confirm oldest pending booking | WRITE | 0.858 | 0.274 | Seq Scan to find min booking + PK update | Index Scan (`idx_bookings_status_booked_at`) + PK | Verified |
| **W04** | Expire stale seat locks (> 10 min) | WRITE | 13.687 | 0.102 | Seq Scan on bookings + join delete | Index Scan (`idx_bookings_status_booked_at`) + PK | Verified |
| **W05** | Weekend pricing surge update for movie 2 | WRITE | 9.432 | 1.828 | Seq Scan on shows (160k rows) | Bitmap Index Scan (`idx_shows_movie_id_starts_at`)| Verified |
| **TOTAL**| **Entire Workload (30 Queries)** | **ALL** | **3,865.473** | **488.932** | — | — | **30/30 OK** |

---

## 8. Percentage Improvement

The percentage improvement for each query is computed as:
$$ \text{Improvement \%} = \frac{\text{Baseline Time} - \text{Optimized Time}}{\text{Baseline Time}} \times 100 $$

```
Workload Latency Reduction:
Baseline  [██████████████████████████████████████████████████] 3,865.47 ms
Optimized [██████] 488.93 ms  (-87.35%)
```

### Improvement Distribution by Speedup Tier

| Speedup Tier | Factor Range | Query Count | Notable Queries | Primary Optimization Mechanism |
|:---|:---:|:---:|:---|:---|
| **Hyper Acceleration** | $> 1,000×$ | 1 | `R19` (3,460.1×) | Correlated subquery converted to set-based `LEFT JOIN ... GROUP BY` |
| **Order-of-Magnitude** | $100× – 999×$ | 4 | `R09` (290.1×), `R13` (221.7×), `W04` (134.2×), `R05` (103.9×) | Elimination of 150k sequential scans via composite & foreign key B-trees |
| **High Optimization** | $10× – 99×$ | 4 | `R02` (36.8×), `R10` (13.9×), `R01` (12.9×), `R07` (9.5×) | Sargable date range boundaries replacing functions on timestamps |
| **Substantial Gain** | $2× – 9×$ | 11 | `R22` (7.9×), `W05` (5.2×), `W03` (3.1×), `R20` (2.8×), `R18` (2.6×), `R17` (2.1×), `R16` (2.1×), `R21` (2.1×), `R12` (2.1×), `R06` (2.0×), `R11` (1.8×) | Covering indexes (Index Only Scan), foreign key joins, index range filtering |
| **Moderate / Baseline Optimal** | $1× – 1.9×$ | 10 | `R25` (1.8×), `W02` (1.8×), `R15` (1.7×), `R04` (1.6×), `R24` (1.5×), `R23` (1.4×), `R14` (1.4×), `W01` (1.4×), `R08` (1.3×), `R03` (1.0×) | Already sub-millisecond, or whole-table aggregations bounded by memory I/O |

### Cumulative Workload Summary
- **Baseline Cumulative Runtime:** **3,865.473 ms**
- **Optimized Cumulative Runtime:** **488.932 ms**
- **Net Workload Latency Saved:** **3,376.541 ms**
- **Overall Workload Improvement:** **87.35% (7.91× overall throughput speedup)**

---

## 9. Execution-Plan Analysis (Top 5 Improvements)

Below are the verbatim `EXPLAIN (ANALYZE, BUFFERS)` execution plans comparing baseline and optimized runs for the 5 most dramatically improved queries.

### 9.1 Query R19 — Distributor Report for Movie 2 (3,460.07× Speedup)

#### Baseline Execution Plan
```text
Sort  (cost=577274.66..577274.98 rows=129 width=24) (actual time=2437.357..2437.384 rows=207.00 loops=1)
  Sort Key: ((SubPlan 1)) DESC, s.starts_at
  Sort Method: quicksort  Memory: 34kB
  Buffers: shared hit=455158
  ->  Gather  (cost=1000.00..577270.13 rows=129 width=24) (actual time=17.717..2436.935 rows=207.00 loops=1)
        Workers Planned: 1
        Workers Launched: 1
        Buffers: shared hit=455152
        ->  Parallel Seq Scan on shows s  (cost=0.00..3055.41 rows=76 width=16) (actual time=3.502..4.320 rows=103.50 loops=2)
              Filter: ((starts_at >= '2026-06-01 00:00:00+05:30') AND (starts_at < '2026-07-01 00:00:00+05:30') AND (movie_id = 2))
              Rows Removed by Filter: 79914
              Buffers: shared hit=1408
        SubPlan 1
          ->  Aggregate  (cost=4443.41..4443.43 rows=1 width=8) (actual time=11.743..11.743 rows=1.00 loops=207)
                Buffers: shared hit=453744
                ->  Seq Scan on bookings b  (cost=0.00..4443.41 rows=2 width=4) (actual time=7.628..11.734 rows=0.95 loops=207)
                      Filter: ((show_id = s.show_id) AND ((status)::text = 'CONFIRMED'::text))
                      Rows Removed by Filter: 150093
                      Buffers: shared hit=453744
Planning Time: 0.427 ms | Execution Time: 2437.427 ms
```

#### Optimized Execution Plan
```text
Sort  (cost=1936.21..1936.54 rows=133 width=24) (actual time=0.732..0.736 rows=207.00 loops=1)
  Sort Key: (COALESCE(sum(b.num_tickets), '0'::bigint)) DESC, s.starts_at
  Sort Method: quicksort  Memory: 34kB
  Buffers: shared hit=938 read=52
  ->  GroupAggregate  (cost=1929.19..1931.52 rows=133 width=24) (actual time=0.664..0.695 rows=207.00 loops=1)
        Group Key: s.show_id
        Buffers: shared hit=932 read=52
        ->  Sort  (cost=1929.19..1929.52 rows=133 width=20) (actual time=0.661..0.666 rows=281.00 loops=1)
              Sort Key: s.show_id
              Sort Method: quicksort  Memory: 35kB
              Buffers: shared hit=932 read=52
              ->  Nested Loop Left Join  (cost=6.54..1924.50 rows=133 width=20) (actual time=0.049..0.642 rows=281.00 loops=1)
                    Buffers: shared hit=929 read=52
                    ->  Bitmap Heap Scan on shows s  (cost=6.12..404.66 rows=133 width=16) (actual time=0.024..0.133 rows=207.00 loops=1)
                          Recheck Cond: ((movie_id = 2) AND (starts_at >= '2026-06-01 00:00:00+05:30') AND (starts_at < '2026-07-01 00:00:00+05:30'))
                          Heap Blocks: exact=129
                          Buffers: shared hit=133
                          ->  Bitmap Index Scan on idx_shows_movie_id_starts_at  (cost=0.00..6.08 rows=133 width=0) (actual time=0.013..0.013 rows=207.00 loops=1)
                    ->  Index Scan using idx_bookings_show_id on bookings b  (cost=0.42..11.41 rows=2 width=8) (actual time=0.002..0.002 rows=0.95 loops=207)
                          Index Cond: (show_id = s.show_id)
                          Filter: ((status)::text = 'CONFIRMED'::text)
                          Index Searches: 207
                          Buffers: shared hit=796 read=52
Planning Time: 0.665 ms | Execution Time: 0.764 ms (avg 0.684 ms)
```
**Key Changes:**
- Buffer touches dropped from **455,158 hits to 990 total page accesses** (-99.78%).
- Replaced 207 individual sequential table scans with a single index join loop using `idx_bookings_show_id`.

---

### 9.2 Query R09 — Stale Pending Bookings (290.09× Speedup)

#### Baseline Execution Plan
```text
Sort  (cost=4737.64..4737.66 rows=5 width=20) (actual time=10.375..11.530 rows=6.00 loops=1)
  Sort Key: booked_at
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=2195
  ->  Gather  (cost=1000.00..4737.59 rows=5 width=20) (actual time=9.291..11.508 rows=6.00 loops=1)
        Workers Planned: 1
        Workers Launched: 1
        Buffers: shared hit=2192
        ->  Parallel Seq Scan on bookings  (cost=0.00..3737.09 rows=3 width=20) (actual time=4.592..8.270 rows=3.00 loops=2)
              Filter: (((status)::text = 'PENDING'::text) AND (booked_at < ('2026-06-30 23:59:00+05:30' - '00:10:00')))
              Rows Removed by Filter: 75044
Planning Time: 0.959 ms | Execution Time: 11.555 ms
```

#### Optimized Execution Plan
```text
Index Scan using idx_bookings_status_booked_at on bookings  (cost=0.42..31.89 rows=10 width=20) (actual time=0.020..0.032 rows=6.00 loops=1)
  Index Cond: (((status)::text = 'PENDING'::text) AND (booked_at < ('2026-06-30 23:59:00+05:30'::timestamp with time zone - '00:10:00'::interval)))
  Index Searches: 1
  Buffers: shared hit=6 read=3
Planning Time: 0.428 ms | Execution Time: 0.042 ms (avg 0.034 ms)
```
**Key Changes:**
- Eradicated the 150,094-row parallel scan.
- B-tree composite index directly positioned the reader at `status = 'PENDING'`, reading only 9 buffer pages.

---

### 9.3 Query R13 — Unredeemed Offers (221.71× Speedup + Correctness Fix)

#### Baseline Execution Plan (Erroneous Result)
```text
Seq Scan on offers o  (cost=4068.18..4069.49 rows=12 width=31) (actual time=30.688..30.689 rows=0.00 loops=1)
  Filter: (NOT (ANY ((offer_code)::text = ((hashed SubPlan 1).col1)::text)))
  Rows Removed by Filter: 25
  Buffers: shared hit=2193
  SubPlan 1
    ->  Seq Scan on bookings b  (cost=0.00..3692.94 rows=150094 width=10) (actual time=0.032..16.076 rows=150094.00 loops=1)
          Buffers: shared hit=2192
Planning Time: 0.427 ms | Execution Time: 30.763 ms
```

#### Optimized Execution Plan (Correct 7 Rows Returned)
```text
Nested Loop Anti Join  (cost=0.29..9.69 rows=7 width=31) (actual time=0.065..0.126 rows=7.00 loops=1)
  Buffers: shared hit=32 read=20
  ->  Seq Scan on offers o  (cost=0.00..1.25 rows=25 width=31) (actual time=0.004..0.005 rows=25.00 loops=1)
        Buffers: shared hit=1
  ->  Index Only Scan using idx_bookings_offer_code on bookings b  (cost=0.29..25.58 rows=1217 width=10) (actual time=0.005..0.005 rows=0.72 loops=25)
        Index Cond: (offer_code = (o.offer_code)::text)
        Index Searches: 25
        Buffers: shared hit=31 read=20
Planning Time: 0.534 ms | Execution Time: 0.148 ms (avg 0.112 ms)
```
**Key Changes:**
- Solved the three-valued logic trap, recovering the missing 7 records.
- Converted full table hash join into an Anti Join utilizing a tiny 176 kB partial index.

---

### 9.4 Query W04 — Stale Seat Lock Deletion (134.19× Speedup)

#### Baseline Execution Plan
```text
Delete on booking_seats bs  (cost=0.42..4878.67 rows=0 width=0) (actual time=14.826..14.826 rows=0.00 loops=1)
  Buffers: shared hit=2228
  ->  Nested Loop  (cost=0.42..4878.67 rows=10 width=12) (actual time=4.272..14.761 rows=12.00 loops=1)
        Buffers: shared hit=2216
        ->  Seq Scan on bookings b  (cost=0.00..4818.65 rows=5 width=10) (actual time=4.244..14.667 rows=6.00 loops=1)
              Filter: (((status)::text = 'PENDING'::text) AND (booked_at < ('2026-06-30 23:59:00+05:30' - '00:10:00')))
              Rows Removed by Filter: 150088
              Buffers: shared hit=2192
        ->  Index Scan using booking_seats_pkey on booking_seats bs  (cost=0.42..11.88 rows=2 width=10) (actual time=0.010..0.013 rows=2.00 loops=6)
Execution Time: 14.887 ms
```

#### Optimized Execution Plan
```text
Delete on booking_seats bs  (cost=0.84..151.94 rows=0 width=0) (actual time=0.056..0.056 rows=0.00 loops=1)
  Buffers: shared hit=51
  ->  Nested Loop  (cost=0.84..151.94 rows=20 width=12) (actual time=0.014..0.045 rows=12.00 loops=1)
        Buffers: shared hit=33
        ->  Index Scan using idx_bookings_status_booked_at on bookings b  (cost=0.42..31.89 rows=10 width=10) (actual time=0.009..0.018 rows=6.00 loops=1)
              Index Cond: (((status)::text = 'PENDING'::text) AND (booked_at < ('2026-06-30 23:59:00+05:30' - '00:10:00')))
              Buffers: shared hit=9
        ->  Index Scan using booking_seats_pkey on booking_seats bs  (cost=0.42..11.88 rows=2 width=10) (actual time=0.003..0.004 rows=2.00 loops=6)
              Index Cond: (booking_id = b.booking_id)
              Buffers: shared hit=24
Planning Time: 0.592 ms | Execution Time: 0.109 ms (avg 0.102 ms)
```
**Key Changes:**
- Filter on expired bookings transitioned from scanning 2,192 pages down to 9 pages.
- Total delete execution dropped from 14.9 ms to 0.10 ms.

---

### 9.5 Query R05 — Customer Console "My Bookings" (103.88× Speedup)

#### Baseline Execution Plan
```text
Sort  (cost=4507.11..4507.11 rows=1 width=65) (actual time=11.652..11.654 rows=2.00 loops=1)
  Sort Key: s.starts_at
  Buffers: shared hit=2236
  ->  Nested Loop ...
        ->  Seq Scan on bookings b  (cost=0.00..4443.41 rows=4 width=19) (actual time=1.634..11.479 rows=7.00 loops=1)
              Filter: ((customer_id = 1331) AND ((status)::text = 'CONFIRMED'::text))
              Rows Removed by Filter: 150087
              Buffers: shared hit=2192
Planning Time: 1.641 ms | Execution Time: 11.727 ms
```

#### Optimized Execution Plan
```text
Sort  (cost=54.30..54.31 rows=1 width=65) (actual time=0.086..0.086 rows=2.00 loops=1)
  Sort Key: s.starts_at
  Buffers: shared hit=52 read=2
  ->  Nested Loop ...
        ->  Bitmap Heap Scan on bookings b  (cost=4.33..19.87 rows=4 width=19) (actual time=0.015..0.029 rows=7.00 loops=1)
              Buffers: shared hit=7 read=2
              ->  Bitmap Index Scan on idx_bookings_customer_id  (cost=0.00..4.33 rows=4 width=0) (actual time=0.009..0.009 rows=7.00 loops=1)
                    Index Cond: (customer_id = 1331)
Planning Time: 1.119 ms | Execution Time: 0.121 ms (avg 0.112 ms)
```
**Key Changes:**
- Fast customer dashboard rendering: dropped from 11.6 ms to 0.11 ms, comfortably meeting the $< 5 \text{ ms}$ real-time SLA.

---

## 10. Index Storage Overhead

The disk storage footprint of each index and table was measured directly via PostgreSQL administrative sizing functions (`pg_relation_size` and `pg_table_size`):

| Table Name | Table Size | Index Name | Index Size | % of Table |
|:---|---:|:---|---:|---:|
| `bookings` | 17 MB (17,989 kB) | `idx_bookings_customer_id` | 1,960 kB | 10.9% |
| `bookings` | 17 MB (17,989 kB) | `idx_bookings_show_id` | 2,912 kB | 16.2% |
| `bookings` | 17 MB (17,989 kB) | `idx_bookings_status_booked_at` | 4,688 kB | 26.1% |
| `bookings` | 17 MB (17,989 kB) | `idx_bookings_offer_code` *(partial)* | 176 kB | **1.0%** |
| `bookings` | 17 MB (17,989 kB) | `idx_bookings_booked_at_desc` *(covering)*| 9,912 kB | 55.1% |
| `shows` | 11 MB (11,567 kB) | `idx_shows_movie_id_starts_at` | 3,000 kB | 25.9% |
| `shows` | 11 MB (11,567 kB) | `idx_shows_screen_id_starts_at` | 4,960 kB | 42.9% |
| `booking_seats` | 15 MB (16,154 kB) | `idx_booking_seats_seat_id` | 2,160 kB | 13.4% |
| `seats` | 5,024 kB | `idx_seats_screen_id_seat_class` | 672 kB | 13.4% |
| `screens` | 56 kB | `idx_screens_venue_id` | 16 kB | 28.6% |
| `venues` | 48 kB | `idx_venues_city_id` | 16 kB | 33.3% |
| `movie_reviews`| 2,088 kB | `idx_movie_reviews_movie_id_rating` | 288 kB | 13.8% |
| **Totals** | **54 MB (Raw Tables)** | **All 12 Performance Indexes** | **30,760 kB (~30.0 MB)** | **27.8% DB Footprint** |

### Storage Trade-off Evaluation
- **Baseline Storage:** ~54 MB raw heap data + ~53 MB primary/unique/exclusion constraints = **107 MB**.
- **New Index Footprint:** **30.0 MB** across 12 targeted indexes.
- **Combined Database Storage:** **137 MB** (an increase of only **27.8%**).
- **Engineering Verdict:** A modest 30 MB storage overhead delivers an **87.35% reduction in total workload latency** and cuts **340,122 page reads per cycle** from memory traffic. This is an exceptional return on disk footprint.

---

## 11. WRITE Query Performance Impact

A critical trade-off in database indexing is write amplification: every inserted, updated, or deleted tuple must maintain all corresponding B-tree leaf structures.

To evaluate this trade-off under real conditions, all write queries (`W01`–`W05`) were executed inside transactional rollback blocks (`BEGIN; EXPLAIN (ANALYZE, BUFFERS) ...; ROLLBACK;`).

| Query ID | Operation | Baseline Avg | Optimized Avg | Delta | Speedup | Write Overhead Assessment |
|:---|:---|---:|---:|---:|:---:|:---|
| **W01** | `INSERT INTO bookings` (1 row) | 1.288 ms | **0.925 ms** | -0.363 ms | **1.39× faster** | Buffer hits rose from 85 to 178 pages to update 5 B-tree indexes, but execution remained well below 1 ms. |
| **W02** | Add 2 seats to oldest PENDING | 19.147 ms | **10.884 ms** | -8.263 ms | **1.76× faster** | Fast candidate identification using `idx_bookings_status_booked_at` and `idx_booking_seats_seat_id` outweighed maintenance. |
| **W03** | Confirm oldest PENDING booking | 0.858 ms | **0.274 ms** | -0.584 ms | **3.13× faster** | Subquery locating `min(booking_id)` dropped from full table scan to B-tree probe. |
| **W04** | Expire stale seat locks | 13.687 ms | **0.102 ms** | -13.585 ms | **134.19× faster** | Finding candidate rows via index dropped search latency by 99%. |
| **W05** | Surge pricing for movie 2 | 9.432 ms | **1.828 ms** | -7.604 ms | **5.16× faster** | Filter on shows targeted only July weekend rows via `idx_shows_movie_id_starts_at`. |

### Key Findings
1. **Zero Net Degradation:** No write query exhibited performance degradation. In fact, **all five write queries executed faster**.
2. **Search Dominates Modification:** In practical transactional applications, DML operations rarely modify random tuples across an entire table; they locate specific rows (`WHERE status = 'PENDING'`, `WHERE movie_id = 2`). The index acceleration on the search phase substantially outweighs the microsecond cost of inserting index keys into memory-resident B-tree pages.
3. **Acceptability:** In high-concurrency ticketing engines, keeping write transactions under 1–2 ms prevents lock contention on booking rows.

---

## 12. Queries That Did Not Improve (or Had Modest Gains) and Reasons

While the workload improved by 87.35%, several queries saw modest gains (2%–52%) and remained between 30 ms and 75 ms. In database systems, recognizing queries that are inherently bounded by physical limits is crucial:

### 12.1 Queries Already Operating at Engine Limits
- **`R03` (Seat Layout for Show 144446 — 0.268 ms $\to$ 0.262 ms, 2.2%):**  
  Already executed in 0.26 ms in baseline using `shows_pkey` and unique constraint `uq_show_seat`. The remaining latency consists of query parsing, execution planning, and client transmission.
- **`R04` (Booking Lookup by Code — 0.054 ms $\to$ 0.034 ms, 37%):**  
  Accesses a single row through unique index `bookings_booking_code_key`.
- **`R23` (Customer Sign-In by Phone — 0.034 ms $\to$ 0.024 ms, 29%):**  
  Single-row probe through unique index `customers_phone_key`.

### 12.2 Small-Table Sequential Scans Outperforming Indexes
- **`R06` (Search Movies Containing 'kalki' — 0.261 ms $\to$ 0.132 ms, 49%):**  
  The `movies` table contains only 300 rows and occupies **48 kB (6 pages)**. A sequential scan reads all 6 pages into memory in 0.13 ms. Creating a trigram GIN index (`pg_trgm`) would introduce index page traversal overhead that exceeds the cost of a sequential scan over 6 memory blocks.

### 12.3 High-Volume Analytical Aggregations (Full Dataset Scans)
- **`R11` (Recliner Ticket Revenue Share — 93.31 ms $\to$ 51.12 ms):**  
  Calculates aggregate revenue by screen type across the entire `booking_seats` table (**300,389 rows**) joined with `seats` (**94,056 rows**) and `screens` (**490 rows**). Because the query must examine almost every booked seat in the database, a sequential scan with parallel Hash Joins is mathematically optimal. An index scan would incur random disk/page lookups, slowing the query down.
- **`R12` (Repeat Movie Bookings — 154.99 ms $\to$ 74.30 ms):**  
  Detecting customers who booked the same movie $\ge 2$ times requires aggregating all 150,094 bookings and 160,034 shows. Repeat customer status is an emergent property that can only be determined *after* grouping all rows.
- **`R15` (Capacity Planning by Weekday/Hour — 58.46 ms $\to$ 34.97 ms):**  
  Groups all 150,094 bookings into a $7 \times 24$ temporal matrix. Because there is no `WHERE` clause, 100% of the table's rows must be processed.
- **`R21` (Top 20 Loyalty Customers in 2026 — 94.48 ms $\to$ 44.90 ms):**  
  Ranks customers by confirmed bookings across the entire year, processing all 135,000 confirmed records.
- **`R24` (Seat Class Pricing by City — 102.35 ms $\to$ 70.13 ms):**  
  Multi-way join aggregating all 300,389 booked seats across all screens, venues, and cities.

**Conclusion for Unspeedable Queries:**  
Queries scanning 80%–100% of a table cannot be accelerated further by B-tree indexes alone. Achieving sub-5 ms performance for these reports requires architectural techniques reserved for Phase 5 / CP4:
1. **Declarative Partitioning:** Splitting `shows`, `bookings`, and `booking_seats` by date range or city to enable partition pruning.
2. **Materialized Views / Summary Tables:** Periodically aggregating financial and loyalty stats asynchronously.

---

## 13. Final Conclusion

The Checkpoint 3 (CP3) optimization cycle achieved outstanding performance gains while maintaining complete data integrity and business correctness:

1. **Dramatic Throughput Increase:** Total workload runtime decreased from **3,865.47 ms to 488.93 ms**, representing an **87.35% overall reduction (7.91× speedup)**.
2. **Elimination of Catastrophic Latencies:** The worst-performing baseline query (`R19`) was accelerated from **2,366.69 ms to 0.68 ms (3,460× speedup)**, and the quadratic cleaning gap query (`R10`) dropped from **486.66 ms to 35.04 ms (14× speedup)**.
3. **Cache & Memory Efficiency:** Memory buffer touches fell by **64.66%**, saving **340,122 page hits per cycle** and freeing buffer memory for concurrent user sessions.
4. **Minimal Storage Footprint:** 12 targeted indexes were created totaling **30.0 MB** (adding only 27.8% to the raw data size).
5. **Safe and Fast Writes:** All write operations maintained or improved their latency, with search-and-modify writes (`W02`, `W04`, `W05`) running up to **134× faster**.
6. **Data Integrity & Logic Resolution:** Uncovered and fixed the subtle ANSI SQL three-valued logic bug in `R13` (`NOT IN` $\to$ `NOT EXISTS`), restoring accurate reporting for promotional partnerships.
7. **Production Readiness:** All 30 queries comfortably satisfy Phase 4 and Phase 5 SLA targets, establishing a verified foundation for scalability testing on the 20× large dataset (Checkpoint 4).
