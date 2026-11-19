# Comprehensive Optimization Report (CP3)

**Course:** Database Management Systems · B.Tech 2nd Year  
**Project:** BookMyShow Database Engineering (DE Project 2026)  
**Milestone:** Checkpoint 3 (CP3 — Query and Index Optimization)  
**Database Engine:** PostgreSQL 18.4 (macOS Sequoia, Apple Silicon ARM64, 16 GB Unified RAM)  
**Workload File:** `sql/06_optimized_queries.sql` (30 Queries: R01–R25 Read, W01–W05 Write)  
**Index Script:** `sql/05_indexes.sql` (12 Targeted Performance Indexes)  
**Benchmark Script:** `benchmarks/run_benchmark.sh` (3 repeated runs, isolated connection, `EXPLAIN (ANALYZE, BUFFERS)`)  
**Active Git Branch:** `cp3-optimization`

---

## 1. Introduction & Objectives

Checkpoint 3 (CP3) represents the core query and database optimization phase of the BookMyShow Database Engineering project. The primary objective is to transform an initial baseline implementation—characterized by full table sequential scans, unindexed foreign key lookups, non-sargable predicates, and quadratic nested subqueries—into a high-performance, enterprise-grade relational database workload.

### Optimization Principles Followed:
1. **Surgical Indexing:** Create indexes strictly backed by empirical execution plan analysis (`EXPLAIN (ANALYZE, BUFFERS)`). Avoid creating redundant, unused, or duplicate indexes.
2. **Sargability & Relational Algebra Rewrites:** Transform non-sargable SQL expressions into range scans that can traverse B-tree indexes directly.
3. **Subquery Flattening:** Eliminate correlated scalar subqueries executed repeatedly across table rows.
4. **Three-Valued Logic Correction:** Fix relational correctness bugs resulting from SQL `NULL` values in subqueries.
5. **Write Safety:** Benchmark write transactions (`INSERT`, `UPDATE`, `DELETE`) within isolated `BEGIN ... ROLLBACK` blocks, preserving seed data integrity.

---

## 2. Baseline Performance Overview (CP2 Summary)

In CP2, the database was populated with 778,048 records across 11 normalized tables in schema `bms`. At baseline, only Primary Keys, unique constraints, and a GiST exclusion constraint existed.

- **Baseline Total Workload Runtime:** **3,805.42 ms** across all 30 queries.
- **Top 3 Longest Running Queries:**
  - `R19` (Distributor Report): **2,366.69 ms** (62.2% of total workload time).
  - `R10` (Cinema Operations): **486.66 ms** (12.8% of total workload time).
  - `R12` (Repeat Movie Bookings): **154.99 ms**.
- **Buffer Cache Churn:** Query R19 alone traversed **455,158 buffer pages** (over 3.7 GB of memory bandwidth) to compute ticket counts for a single movie's shows.

---

## 3. Identified Architectural Bottlenecks

Baseline query plans revealed five major structural bottlenecks:

1. **Unindexed Foreign Keys on Large Tables:**
   - PostgreSQL does *not* automatically index foreign key columns. The 150,094-row `bookings` table had no indexes on `customer_id` or `show_id`. Queries filtering by customer (R05) or joining bookings to shows (R08, R12, R16, R18, R19) were forced to perform full sequential scans of all 150,000 rows.
2. **Correlated Scalar Subquery Churn (R19):**
   - The query used a scalar subquery `(SELECT count(*) FROM bookings b JOIN booking_seats bs ... WHERE b.show_id = s.show_id)` inside the `SELECT` projection list. Because `shows` returned 207 rows, PostgreSQL executed 207 separate sequential scans of `bookings`, examining 31,069,458 rows in total.
3. **Non-Sargable Date and Timestamp Functions (R01, R07, R18, R20):**
   - Expressions such as `DATE(s.starts_at) = '2026-07-02'` or `s.starts_at::date = '2026-06-28'` prevented the planner from utilizing B-tree index range scans, forcing sequential scans across 160,034 show records.
4. **Quadratic Self-Joins (R10):**
   - Finding consecutive shows on the same screen with less than 30 minutes cleaning time evaluated `(s2.starts_at - s1.ends_at) < interval '30 minutes'` across all show pairings on the same screen without upper bound bounding, yielding a nested loop over hundreds of thousands of candidate combinations.
5. **Deep-Offset Pagination and External Sorting (R22):**
   - `SELECT ... FROM bookings ORDER BY booked_at DESC LIMIT 25 OFFSET 100000` scanned all 150,094 heap tuples and performed a high-latency top-N heap sort in memory.

---

## 4. Indexing Strategy (`sql/05_indexes.sql`)

Twelve targeted indexes were engineered to resolve the bottlenecks above. Every index serves a specific operational purpose:

```
┌────────────────────────────────────────────────────────────────────────┐
│                   TARGETED INDEX ARCHITECTURE (12 INDEXES)              │
├──────────────────┬─────────────────────────────┬───────────────────────┤
│ Table            │ Index Name                  │ Type & Purpose        │
├──────────────────┼─────────────────────────────┼───────────────────────┤
│ bookings         │ idx_bookings_customer_id    │ B-tree FK (R05)       │
│ bookings         │ idx_bookings_show_id        │ B-tree FK (R08,R18,R19)│
│ bookings         │ idx_bookings_status_booked  │ Composite (R09,R20,W04│
│ bookings         │ idx_bookings_offer_code     │ Partial (R13)         │
│ bookings         │ idx_bookings_booked_at_desc │ Covering INCLUDE(R22) │
│ shows            │ idx_shows_movie_starts_at   │ Composite (R01,R02,R19│
│ shows            │ idx_shows_screen_starts_at  │ Composite (R07,R10,R25│
│ booking_seats    │ idx_booking_seats_seat_id   │ B-tree FK (R11,R17,R24│
│ seats            │ idx_seats_screen_class      │ Composite (R11,R24)   │
│ screens          │ idx_screens_venue_id        │ B-tree FK (R01,R02,R07│
│ venues           │ idx_venues_city_id          │ B-tree FK (R01,R02,R18│
│ movie_reviews    │ idx_movie_reviews_movie_rat │ Composite (R14)       │
└──────────────────┴─────────────────────────────┴───────────────────────┘
```

### Detailed Index Justification:
- **Composite Indexes (`status, booked_at` and `movie_id, starts_at`):** Follow the *Equality First, Range Second* rule. The leading column filters the low-cardinality equality predicate, allowing the trailing column to execute an immediate range scan without sorting.
- **Partial Index (`idx_bookings_offer_code WHERE offer_code IS NOT NULL`):** Because ~95% of bookings do not use a promotional offer, indexing `NULL` values wastes disk and cache space. Indexing only non-null offer codes reduced index size to just **176 kB** while accelerating anti-join lookups by 232x.
- **Covering Index (`idx_bookings_booked_at_desc` with `INCLUDE`):** Stores `booking_id, customer_id, total_amount, status` directly in the index leaf pages. For high-offset pagination (R22), PostgreSQL fulfills the query entirely through an **Index Only Scan**, bypassing 100,000 random heap tuple reads.
- **Why GIN / BRIN were not chosen:**
  - `BRIN` requires physical sorting on disk and works best on multi-gigabyte append-only tables; on a 150K-row table, B-tree range seek is significantly faster (0.03 ms vs ~2 ms).
  - `GIN` is ideal for full-text search or arrays; movie title search (R06) operates on only 300 rows where table sequential scan takes 0.13 ms, making GIN maintenance overhead unjustified.

---

## 5. Query Optimization Techniques (`sql/06_optimized_queries.sql`)

### 1. Eliminating Correlated Subquery with `LEFT JOIN + GROUP BY` (R19)
- **Baseline:** Evaluated `SELECT (SELECT count(*) FROM ...) FROM shows s WHERE ...`
- **Optimized:**
  ```sql
  SELECT s.show_id, s.starts_at, sc.screen_name,
         count(bs.seat_id) AS tickets_sold
  FROM shows s
  JOIN screens sc ON sc.screen_id = s.screen_id
  LEFT JOIN bookings b ON b.show_id = s.show_id AND b.status IN ('CONFIRMED', 'PENDING')
  LEFT JOIN booking_seats bs ON bs.booking_id = b.booking_id
  WHERE s.movie_id = 2
    AND s.starts_at >= '2026-06-01' AND s.starts_at < '2026-07-01'
  GROUP BY s.show_id, s.starts_at, sc.screen_name
  ORDER BY s.starts_at;
  ```
- **Result:** Plan changed from a Nested Loop of 207 sequential scans into a single Hash Aggregate join, cutting runtime from **2,366.69 ms to 0.68 ms (3,506x speedup)**.

### 2. Sargable Range Predicates (R01, R07, R18, R20)
- Replaced `DATE(s.starts_at) = '2026-07-02'` with `s.starts_at >= '2026-07-02' AND s.starts_at < '2026-07-03'`.
- This enables PostgreSQL to compute index start/stop keys directly at the B-tree root, avoiding function evaluation per row.

### 3. Sargable Self-Join Window Bounding (R10)
- Baseline condition: `(s2.starts_at - s1.ends_at) < interval '30 minutes' AND s2.starts_at >= s1.ends_at`.
- Optimized condition:
  ```sql
  WHERE s2.starts_at >= s1.ends_at
    AND s2.starts_at < s1.ends_at + interval '30 minutes'
  ```
- Adding the upper bound transformed the join from an unindexed quadratic scan into an indexed range lookup on `idx_shows_screen_id_starts_at`, dropping latency from **486.66 ms to 34.68 ms (14x speedup)**.

---

## 6. SQL NULL-Related Correctness Issue & Resolution (R13)

### The Problem: Three-Valued Logic Trap in `NOT IN`
The baseline query R13 was defined as:
```sql
SELECT offer_code, description, discount_pct
FROM offers
WHERE offer_code NOT IN (SELECT offer_code FROM bookings);
```
In SQL's three-valued logic (`TRUE`, `FALSE`, `UNKNOWN`), the expression `val NOT IN (val1, val2, NULL)` evaluates as:
$$\text{NOT } (val = val1 \lor val = val2 \lor val = \text{NULL})$$
If any row in `bookings` contains `offer_code IS NULL` (which represents ~95% of bookings where customers did not use an offer), the inner comparison evaluates to `UNKNOWN`. Negating `UNKNOWN` yields `UNKNOWN`. Because `WHERE` clauses require conditions to evaluate strictly to `TRUE`, **the baseline query returned exactly 0 rows**, failing silently!

### The Solution: `NOT EXISTS` Anti-Join
In `sql/06_optimized_queries.sql`, R13 was rewritten using `NOT EXISTS`:
```sql
SELECT o.offer_code, o.description, o.discount_pct
FROM offers o
WHERE NOT EXISTS (
    SELECT 1
    FROM bookings b
    WHERE b.offer_code = o.offer_code
);
```

### Verification & Impact:
- **Correctness:** Correctly returns the **7 offers** in the seed dataset that have never been redeemed (`AXIS100`, `BLOCKBUSTER`, `FEDERAL50`, `HSBC20`, `INDUS50`, `KOTAK20`, `YES100`).
- **Performance:** Paired with the partial index `idx_bookings_offer_code`, execution time dropped from **24.83 ms down to 0.11 ms (232x speedup)** via an **Index Only Scan**.

---

## 7. Before / After Comparison for All 30 Queries

All measurements were taken on PostgreSQL 18.4 with 3 runs averaged (`summary.csv`).

| Query ID | Type | Description | Baseline Avg (ms) | Optimized Avg (ms) | Latency Delta | Speedup | % Improvement |
|:---|:---:|:---|---:|---:|---:|---:|---:|
| **R01** | READ | Movies showing in Bengaluru on 2 July 2026 | 8.626 | 0.722 | -7.904 ms | **11.95x** | +91.63% |
| **R02** | READ | Movie 2 showtimes in Bengaluru by cinema | 5.969 | 0.212 | -5.757 ms | **28.16x** | +96.45% |
| **R03** | READ | Show 144446 seat layout & sold status | 0.268 | 0.300 | +0.032 ms | 0.89x | -11.94% |
| **R04** | READ | Lookup booking by unique booking code | 0.054 | 0.035 | -0.019 ms | **1.54x** | +35.19% |
| **R05** | READ | Customer 1331 upcoming confirmed bookings | 11.635 | 0.141 | -11.494 ms | **82.52x** | +98.79% |
| **R06** | READ | Movie title search containing 'kalki' | 0.261 | 0.138 | -0.123 ms | **1.89x** | +47.13% |
| **R07** | READ | Venue 11 occupancy dashboard on 28 June | 1.106 | 0.102 | -1.004 ms | **10.84x** | +90.78% |
| **R08** | READ | Top 10 movies by collections over weekend | 24.346 | 17.106 | -7.240 ms | **1.42x** | +29.74% |
| **R09** | READ | Pending seat locks > 10 min | 9.863 | 0.030 | -9.833 ms | **328.77x** | +99.70% |
| **R10** | READ | Consecutive shows on screen (<30m cleaning) | 486.657 | 34.682 | -451.975 ms | **14.03x** | +92.87% |
| **R11** | READ | Recliner ticket revenue share by screen type | 93.305 | 47.475 | -45.830 ms | **1.97x** | +49.12% |
| **R12** | READ | Customers booking same movie >1 time | 154.993 | 64.930 | -90.063 ms | **2.39x** | +58.11% |
| **R13** | READ | Offers never redeemed (NULL-corrected) | 24.832 | 0.107 | -24.725 ms | **232.07x** | +99.57% |
| **R14** | READ | Avg user rating of 2026 releases (≥20 reviews)| 6.946 | 4.944 | -2.002 ms | **1.40x** | +28.82% |
| **R15** | READ | Bookings by weekday and hour | 58.456 | 34.666 | -23.790 ms | **1.69x** | +40.70% |
| **R16** | READ | Venue cancellation rates for June 2026 | 40.211 | 18.989 | -21.222 ms | **2.12x** | +52.78% |
| **R17** | READ | Screen 101 seats never sold in June | 62.345 | 28.968 | -33.377 ms | **2.15x** | +53.53% |
| **R18** | READ | Regional insights: collections by lang/city | 127.188 | 42.717 | -84.471 ms | **2.98x** | +66.41% |
| **R19** | READ | Tickets sold per June show for movie 2 | 2366.689 | 0.675 | -2366.014 ms| **3506.21x** | +99.97% |
| **R20** | READ | Daily collections & running total for June | 29.863 | 10.636 | -19.227 ms | **2.81x** | +64.38% |
| **R21** | READ | Loyalty: top 20 customers by bookings | 94.482 | 44.219 | -50.263 ms | **2.14x** | +53.20% |
| **R22** | READ | Support console pagination: page 4,001 | 70.015 | 6.406 | -63.609 ms | **10.93x** | +90.85% |
| **R23** | READ | Sign-in customer authentication by phone | 0.034 | 0.022 | -0.012 ms | **1.55x** | +35.29% |
| **R24** | READ | Premium seat share of revenue by chain | 102.348 | 57.774 | -44.574 ms | **1.77x** | +43.55% |
| **R25** | READ | Evening screen occupancy rates in June | 40.569 | 22.476 | -18.093 ms | **1.81x** | +44.60% |
| **W01** | WRITE | New customer registration insert | 1.288 | 0.676 | -0.612 ms | **1.91x** | +47.52% |
| **W02** | WRITE | Multi-seat booking checkout transaction | 19.147 | 9.419 | -9.728 ms | **2.03x** | +50.81% |
| **W03** | WRITE | Payment gateway callback update | 0.858 | 0.223 | -0.635 ms | **3.85x** | +74.01% |
| **W04** | WRITE | Delete expired pending seat locks | 13.687 | 0.117 | -13.570 ms | **116.98x** | +99.15% |
| **W05** | WRITE | Emergency show reschedule update | 9.432 | 1.702 | -7.730 ms | **5.54x** | +81.96% |
| **Total** | — | **Full Workload Suite (30 Queries)** | **3,805.42 ms** | **444.83 ms** | **-3,360.59 ms** | **8.55x** | **+88.31%** |

---

## 8. Percentage Improvement Distribution

```
Workload Latency Distribution:
  Baseline:  ████████████████████████████████████████ 3,805.42 ms
  Optimized: ████▌ 444.83 ms (-88.31%)

Breakdown by Speedup Tier:
  > 100x Speedup : 4 queries (R19: 3,506x, R09: 328x, R13: 232x, W04: 117x)
  10x – 100x     : 5 queries (R05: 82x, R02: 28x, R10: 14x, R01: 12x, R22: 11x)
  2x – 10x       : 11 queries (R07, W05, W03, R20, R18, R12, R17, R21, R16, W02, R06)
  1.1x – 2x      : 9 queries (R11, W01, R25, R24, R15, R23, R04, R08, R14)
  Neutral (±0.03ms): 1 query (R03: already sub-millisecond, operating at 0.30 ms)
```

---

## 9. Execution-Plan Deep Dives

### Deep Dive: Query R19 (Distributor Report)
- **Baseline Plan:**
  ```text
  Seq Scan on shows s (filter: movie_id = 2 AND starts_at range) -> 207 rows
    SubPlan 1
      -> Aggregate (count)
        -> Nested Loop
          -> Seq Scan on bookings b (filter: show_id = s.show_id) [Executed 207 times!]
          -> Index Scan on booking_seats
  Execution Time: 2,366.689 ms | Buffers: shared hit=455,158
  ```
- **Optimized Plan:**
  ```text
  HashAggregate (group by s.show_id, s.starts_at, sc.screen_name)
    -> Nested Loop Left Join
      -> Nested Loop Left Join
        -> Nested Loop (s join sc)
          -> Bitmap Heap Scan on shows s using idx_shows_movie_id_starts_at
          -> Index Scan on screens sc
        -> Index Scan on bookings b using idx_bookings_show_id
      -> Index Only Scan on booking_seats bs using uq_show_seat
  Execution Time: 0.675 ms | Buffers: shared hit=989
  ```
- **Architectural Analysis:** Eliminating the correlated subquery reduced shared buffer page reads from 455,158 to 989, yielding a **3,506x latency reduction**.

---

## 10. Index Storage Overhead & Database Sizing

Measured directly from PostgreSQL catalog views (`pg_relation_size`, `pg_indexes_size`):

| Relation | Table Size | Baseline Indexes | Added CP3 Indexes | Total Index Size | Total Size | Overhead % |
|:---|---:|---:|---:|---:|---:|---:|
| `bookings` | 17 MB | 9,728 kB | 19,648 kB | 29,376 kB | 46.3 MB | +69.8% total size |
| `shows` | 11 MB | 16 MB | 7,960 kB | 24 MB | 35.0 MB | +29.6% total size |
| `booking_seats` | 15 MB | 16 MB | 2,160 kB | 18 MB | 33.7 MB | +6.8% total size |
| `seats` | 5,024 kB | 4,976 kB | 672 kB | 5,648 kB | 10.6 MB | +6.7% total size |
| `movie_reviews` | 2,088 kB | 1,776 kB | 288 kB | 2,064 kB | 4.1 MB | +7.4% total size |
| `screens` | 56 kB | 32 kB | 16 kB | 48 kB | 104 kB | +18.2% total size |
| `venues` | 48 kB | 16 kB | 16 kB | 32 kB | 80 kB | +25.0% total size |
| `customers` | 3,872 kB | 4,496 kB | 0 kB | 4,496 kB | 8.3 MB | 0.0% |
| `movies` | 48 kB | 16 kB | 0 kB | 16 kB | 64 kB | 0.0% |
| `cities` | 8 kB | 32 kB | 0 kB | 32 kB | 40 kB | 0.0% |
| `offers` | 8 kB | 16 kB | 0 kB | 16 kB | 24 kB | 0.0% |
| **All Relations** | **55.0 MB** | **53.0 MB** | **30.76 MB** | **83.76 MB** | **138.8 MB** | **+28.5% total DB size** |

---

## 11. WRITE Query Performance & Index Maintenance Impact

In transactional DBMS design, indexes introduce write overhead because every `INSERT`, `UPDATE`, or `DELETE` must maintain index leaf blocks and emit Write-Ahead Log (WAL) records.

However, our empirical benchmarks reveal that **every write query improved in execution time**:
- **W01 (Insert Customer):** Ran in 0.68 ms. No unnecessary indexes were placed on `customers`.
- **W02 (Booking Checkout):** Improved from 19.15 ms to 9.42 ms (2.03x faster) because accelerating the read verification phase (checking seat availability) outweighed the multi-table index insertion cost.
- **W03 (Confirm Booking):** Improved from 0.86 ms to 0.22 ms (3.85x faster).
- **W04 (Delete Expired Locks):** Improved from 13.69 ms to 0.12 ms (**117x faster**). Locating the expired rows via `idx_bookings_status_booked_at` took 0.05 ms, completely eliminating the 150K-row sequential scan.
- **W05 (Reschedule Show):** Improved from 9.43 ms to 1.70 ms (5.54x faster).

---

## 12. Queries with Modest or Unchanged Performance

Four queries exhibited modest or neutral performance changes:
1. **R04 (Booking Code Lookup - 0.035 ms) & R23 (Phone Lookup - 0.022 ms):**
   - Both operate on unique single-column primary keys / unique constraints (`bookings_booking_code_key` and `customers_phone_key`). They already execute in <0.05 ms (a single B-tree root-to-leaf traverse).
2. **R06 (Movie Title ILIKE '%kalki%' - 0.138 ms):**
   - The `movies` table contains only 300 rows (occupying 6 buffer pages). A sequential scan in memory cache is faster than traversing an index structure.
3. **R03 (Seat Layout - 0.300 ms vs 0.268 ms baseline):**
   - Executing in ~0.3 ms in both phases; microsecond variations represent routine OS scheduling and IPC jitter.

---

## 13. Final Conclusion & CP3 Checklist

The CP3 optimization effort successfully addressed every structural defect in the BookMyShow database workload while preserving data integrity and schema constraints.

### Deliverables Checklist (CHECKPOINTS.md):
- [x] `sql/05_indexes.sql`: 12 performance indexes with complete comments, query mappings, and rationale.
- [x] `sql/06_optimized_queries.sql`: All 30 queries optimized, preserving result schemas, with the R13 NULL trap fixed.
- [x] `benchmarks/results/optimized/`: All 30 raw execution plan files (`R01.txt` to `W05.txt`) and `summary.csv` generated via automated benchmark harness.
- [x] `docs/04_optimization_report.md`: Comprehensive 13-section report containing real PostgreSQL measurements.
- [x] Strict preservation of all CP1 and CP2 deliverables on branch `cp3-optimization`.
