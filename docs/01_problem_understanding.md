# Problem Understanding (Phase 1)

| # | What the business needs | Stakeholder | Type |
|---|---|---|---|
| P1 | The "now showing", showtimes and search pages must load quickly even on busy Friday mornings. | Movie-goer (customer app) | Customer-facing / real-time |
| P2 | Showing the seat layout and locking a seat must be fast, and the same seat must never be sold twice for one show. | Movie-goer, booking engine | Customer-facing / real-time |
| P3 | The pending-payment queue, payment confirmations and the job that releases expired seat locks must keep up. | Payments / seat-lock service | Customer-facing / real-time (write-heavy) |
| P4 | "My bookings", booking lookup by code and sign-in must answer immediately. | Movie-goer, support team | Customer-facing / real-time |
| P5 | Occupancy per show, gaps between shows for cleaning and seats that were never sold per screen. | Cinema / venue manager | Interactive operations tool |
| P6 | The report of offers nobody has used returns nothing, so it cannot be trusted. | Partnerships team | Reporting / analytics (correctness problem) |
| P7 | Box-office totals and tickets per show during release weekends. | Distributors | Reporting / analytics |
| P8 | Revenue mix, regional collections, ratings, loyalty, booking patterns and cancellations time out, and volume will grow 20 times. | Finance, insights team | Reporting / analytics |

## Performance targets this implies
- P1–P4 touch single customers or single shows, so they need millisecond answers and indexed lookups.
- P5 and P7 run on small slices of data but are used interactively, so they should answer in a fraction of a second.
- P6 and P8 read large parts of the data; seconds are acceptable, but they must scale with 20 times more data.

## Assumptions
- The seed data (about 300,000 booking seats, April to early July 2026) is representative of production.
- Query results must stay identical after optimization, except where a query is proven to return a wrong answer.
- Only PostgreSQL features may be used, with default server settings.
- A booking in status CANCELLED or PAYMENT_FAILED holds no seats; PENDING and CONFIRMED bookings do.
- Times are in India Standard Time (+05:30).
