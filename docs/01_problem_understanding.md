# Phase 1: Problem Understanding & Business Requirements Analysis

**Project:** BookMyShow Movie & Event Ticketing Database (DBMS Project 2026)  
**Team Number:** T0012  
**Target Database:** PostgreSQL 15+  

---

## 1. Project Overview & Context

BookMyShow operates India's leading entertainment ticketing platform, facilitating high-concurrency ticket reservations for cinemas across multiple tier-1 and tier-2 cities. Cinema ticketing is fundamentally a **seat-by-seat inventory reservation system**:
- A **Venue** (cinema chain auditorium complex such as PVR or INOX) operates multiple **Screens**.
- Each screen has a distinct physical **Seat Layout** divided into seat categories (e.g., Classic, Prime, Recliner).
- A **Show** represents a specific movie screening scheduled in an auditorium at a designated time interval.
- **Seat Exclusivity Constraint:** A physical seat can be sold at most once for a given show. During the checkout process, seats are held under temporary locks while payment processing completes.

The current system manages historical and active data covering April through early July 2026 (spanning over 300,000 bookings and 160,000 shows across 10 cities).

---

## 2. Core Business Problem & Objectives

### The Problem
The legacy database schema was rapidly provisioned without documented normalization, declarative relational integrity constraints, or index design. The database currently relies solely on raw data exports. Consequently, high traffic surges (such as Friday movie premiere releases) cause severe query latency, connection saturation, and potential concurrency hazards.

### Objectives
1. **Schema Reconstruction & Integrity:** Re-engineer a 3NF/BCNF compliant relational schema in PostgreSQL (under schema `bms`), enforcing strict primary, foreign key, unique, check, and exclusion constraints to ensure zero double-booking and complete data consistency.
2. **Performance Benchmarking:** Empirically baseline the execution times and query execution plans of the 30 critical enterprise queries (`workload_30.sql`) using `EXPLAIN (ANALYZE, BUFFERS)`.
3. **Query & Index Optimization:** Apply targeted composite B-tree indexes, covering indexes (`INCLUDE`), partial indexes, trigram GIN indexes, and query rewrites to drastically reduce execution latency without altering query results or compromising write throughput.
4. **Scalability Assurance:** Validate that optimized queries maintain acceptable service-level agreements (SLAs) under an impending **20× dataset expansion** (~6 million booking seats, 3.2 million shows).

---

## 3. Stakeholder Analysis

| Stakeholder | Role & Core Needs | Key Concerns |
|---|---|---|
| **Customers / Movie-Goers** | Search showtimes, view dynamic seat availability, lock seats, and complete checkouts seamlessly. | High latency on search/booking pages; loss of locked seats during payment; checkout timeouts. |
| **Cinema / Venue Owners & Managers** | Track auditorium occupancy, verify turnover/cleaning gaps between shows, audit unsold seats. | Inability to access timely operational dashboards; scheduling conflicts and audit delays. |
| **Film Distributors** | Monitor weekend box-office collections, track per-show ticket counts, verify revenue shares. | Delayed revenue reconciliations; slow aggregations across multi-city release weekends. |
| **Programming & Scheduling Team** | Schedule screenings, allocate screens to high-demand films, optimize late-night slots. | Show overlapping errors on the same screen; inadequate capacity utilization insights. |
| **Payments & Seat-Lock Engine** | Maintain temporary reservation queues, release expired locks (10 min timeout), confirm bookings. | Lagging cleanup workers causing phantom seat blockages; lock contention during peak traffic. |
| **Brand Partnerships Team** | Track partner promotional campaigns, manage voucher/offer redemptions. | Faulty queries returning empty redemption reports, distorting commercial partner settlements. |
| **Finance & Business Insights** | Run aggregate financial reports (revenue mix, tax/fees, cancellations, regional collections). | Heavy analytical queries timing out, locking operational tables, and failing under scale. |
| **Customer Support Team** | Rapidly retrieve booking histories, lookup transactions by booking code or customer phone. | High wait times resolving customer complaints due to unindexed lookups. |

---

## 4. Business Problems (P1 – P8) & Workload Mapping

### P1: Slow Catalog Discovery during Peak Release Windows
- **Reported Issue:** "Now showing, showtimes and search pages are slow on Friday mornings."
- **Stakeholders Affected:** Customers (Movie-Goers), Cinema Chains.
- **Related Queries:** `R01` (Movies showing in city on date), `R02` (Showtimes for movie in city by cinema), `R06` (Title substring search).
- **Business Need:** Instant catalog discovery and fuzzy text search during peak ticket release periods without full-table scans.
- **Technical Bottleneck:** Unindexed sequential scans on `shows` and `movies` joined across `screens` and `venues`, plus lack of trigram indexing on movie titles.

### P2: High Latency in Seat Layout Rendering & Concurrency Invariant
- **Reported Issue:** "The seat layout screen and seat locking are too slow, and two people must never get the same seat."
- **Stakeholders Affected:** Customers, Booking Engine.
- **Related Queries:** `R03` (Fetch show seat layout & availability), `W01` (Create pending booking), `W02` (Lock seats for pending booking).
- **Business Need:** Sub-5ms retrieval of auditorium seat availability and atomic, collision-free seat allocation.
- **Technical Bottleneck:** Sequential scanning over 300,000+ booking seats to verify reservation state; risk of double allocation without strict exclusion/unique constraints on `(show_id, seat_id)`.

### P3: Lagging Payment Confirmations & Asynchronous Lock Expiry
- **Reported Issue:** "Payments: the pending-payment queue, confirmations and seat-lock expiry jobs lag."
- **Stakeholders Affected:** Payments Service, Seat-Lock Daemon, Customers.
- **Related Queries:** `R09` (Identify bookings pending > 10 minutes), `W03` (Confirm pending booking upon payment callback), `W04` (Release expired seat locks).
- **Business Need:** Rapid queue polling and reconciliation so that uncompleted checkouts immediately return inventory to the pool.
- **Technical Bottleneck:** Unindexed temporal filters on `booked_at` filtered by `status = 'PENDING'`.

### P4: Sluggish Customer Profile, Booking Lookup & Support Console
- **Reported Issue:** "Customers and support wait too long for My bookings, booking lookup and sign-in."
- **Stakeholders Affected:** Customer Support Agents, Customers.
- **Related Queries:** `R04` (Lookup booking by unique alphanumeric code), `R05` (Customer upcoming confirmed bookings), `R22` (High-offset pagination for support logs), `R23` (Sign-in authentication via phone number).
- **Business Need:** Instant customer authentication and single-record retrieval by code or phone number.
- **Technical Bottleneck:** Missing unique indexes on `booking_code` and `customer.phone`; costly `OFFSET` scan on non-indexed booking order.

### P5: Cinema Operations, Capacity Audit & Turnaround Deficiencies
- **Reported Issue:** "Cinema managers need occupancy, cleaning-gap checks and never-sold seats per screen."
- **Stakeholders Affected:** Cinema Operations Managers, Programming Team.
- **Related Queries:** `R07` (Daily show occupancy per venue), `R10` (Consecutive shows with cleaning gap < 30 min), `R17` (Seats never sold for any show in a month), `R25` (Occupancy of late-night shows).
- **Business Need:** Real-time visibility into screen utilization, scheduling compliance, and cleaning turnaround intervals.
- **Technical Bottleneck:** Complex window functions (`LAG`), subqueries, and large join aggregations across unindexed temporal ranges.

### P6: Empty Partner Offer Redemption Reporting
- **Reported Issue:** "Partnerships' 'offers never redeemed' report is always empty."
- **Stakeholders Affected:** Partnerships Team, Commercial Marketing.
- **Related Queries:** `R13` (Offers never redeemed).
- **Business Need:** Accurate detection of unredeemed promotional discounts to assess partner performance and billing.
- **Technical Bottleneck:** SQL logical defect: using `NOT IN (SELECT offer_code FROM bookings)` where `offer_code` contains `NULL` values, causing standard SQL three-valued logic to evaluate to NULL/empty. Requires rewrite to `NOT EXISTS` or `IS NOT NULL` filter.

### P7: Distributor Release-Weekend Box-Office Reporting & Dynamic Pricing
- **Reported Issue:** "Distributors want box-office and per-show ticket counts during release weekends."
- **Stakeholders Affected:** Film Distributors, Cinema Finance.
- **Related Queries:** `R08` (Top 10 movies by weekend box office), `R19` (Tickets sold per show for a movie), `W05` (Dynamic price surge for weekend shows).
- **Business Need:** Rapid weekend revenue calculation and batch execution of dynamic surge pricing.
- **Technical Bottleneck:** Aggregations over hundreds of thousands of booking seats without pre-computed or indexed date-range rollups.

### P8: Analytical Timeouts across Multi-Dimensional BI Reports
- **Reported Issue:** "Finance and insight reports (revenue mix, regional collections, ratings, loyalty, booking patterns, cancellations) time out, and volume will grow 20×."
- **Stakeholders Affected:** Corporate Finance, Business Intelligence, Executive Leadership.
- **Related Queries:** `R11` (Recliner revenue share), `R12` (Repeat viewers/fans), `R14` (Average ratings of new releases), `R15` (Booking patterns by day/hour), `R16` (Cancellation rate per venue), `R18` (Regional collections by language and city), `R20` (Daily running collections), `R21` (Top loyalty customers), `R24` (Average price paid per seat class per city).
- **Business Need:** Scalable decision-support metrics without degrading online transactional processing (OLTP).
- **Technical Bottleneck:** Heavy multi-table joins, nested grouping sets, and window aggregations spanning entire tables without partitioning or covering index support.

---

## 5. Workload Classification & Latency Targets

To prevent transactional degradation and establish clear optimization targets, all database interactions are categorized into three distinct operational profiles:

```
┌────────────────────────────────────────────────────────────────────────────┐
│                    BookMyShow Workload Classification                      │
├─────────────────────────────────────┬──────────────────────────────────────┤
│ 1. Real-Time Transactional (OLTP)   │ Sub-5 ms SLA                         │
│    R02, R03, R04, R05, R06, R09,    │ Critical path: seat selection, auth, │
│    R23, W01, W02, W03               │ locking, single-record lookups.      │
├─────────────────────────────────────┼──────────────────────────────────────┤
│ 2. Interactive Operational Tools    │ Sub-250 ms SLA                       │
│    R01, R07, R13, R17, R22,         │ Cinema dashboards, catalog overview, │
│    W04, W05                         │ batch lock expiries, surge updates.  │
├─────────────────────────────────────┼──────────────────────────────────────┤
│ 3. Analytical & BI Reporting (OLAP) │ Sub-5,000 ms SLA                     │
│    R08, R10, R11, R12, R14, R15,    │ Multi-join aggregations, box office, │
│    R16, R18, R19, R20, R21, R24,    │ loyalty rankings, trend analysis     │
│    R25                              │ (evaluated on 20× large dataset).    │
└─────────────────────────────────────┴──────────────────────────────────────┘
```

### Detailed Breakdown

1. **Customer-Facing Real-Time Transactional Path (OLTP)**
   - **Characteristics:** High concurrency, single-record or indexed slice operations, strict SLA (< 5 ms).
   - **Queries:** `R02`, `R03`, `R04`, `R05`, `R06`, `R09`, `R23`, `W01`, `W02`, `W03`.
   - **Performance Imperative:** Must utilize Index Scans and Index Only Scans. Cannot tolerate table locks or sequential scans.

2. **Interactive Cinema Operations & Console Workflows**
   - **Characteristics:** Moderate concurrency, filtered by specific venue/auditorium/status, interactive UI SLA (< 250 ms).
   - **Queries:** `R01`, `R07`, `R13`, `R17`, `R22`, `W04`, `W05`.
   - **Performance Imperative:** Requires composite index filtering on `(venue_id, date)` and keyset pagination to replace costly `OFFSET` sweeps.

3. **Analytical & Reporting Operations (OLAP)**
   - **Characteristics:** Periodic, read-intensive, large scans across historical partitions, SLA (< 5,000 ms on 20× data).
   - **Queries:** `R08`, `R10`, `R11`, `R12`, `R14`, `R15`, `R16`, `R18`, `R19`, `R20`, `R21`, `R24`, `R25`.
   - **Performance Imperative:** Requires covering indexes, parallel sequential scan optimization, partition pruning on date ranges, and avoiding correlated subqueries.

---

## 6. Architectural & Business Assumptions

1. **Schema Namespace:** All entities and constraints must reside within the dedicated PostgreSQL schema `bms` with default `search_path TO bms`.
2. **Double-Booking Invariant:** A physical seat cannot have two active bookings for the same show. This requires a compound uniqueness constraint on `(show_id, seat_id)` in `booking_seats`.
3. **Show Non-Overlap Invariant:** No single screen can host two overlapping shows simultaneously. In PostgreSQL, this requires an exclusion constraint using the `btree_gist` extension on `screen_id WITH =, tsrange(starts_at, ends_at) WITH &&`.
4. **Lock Expiry Window:** Pending bookings are held for a maximum of 10 minutes. If unconfirmed after 10 minutes, seats must be released (`W04`).
5. **Soft vs. Hard Deletions:** Cancellations (`status = 'CANCELLED'`) preserve the booking header row for financial and analytical tracking (`R16`), but release all associated seat inventory.
6. **Query Invariance:** All optimizations (Phase 4) must strictly preserve output schemas, column naming, and row semantics identical to `workload_30.sql`.
