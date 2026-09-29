# Shrink anomaly report

Run 2026-08-26, model_version shrink-anomaly-v1. 45,136 store x category x month cells across 330 stores, 12 categories and 24 months.

## This is unsupervised, and that shapes what it can claim

There is no shrink-fraud label in this data, so this is not a fraud detector and must not be described as one. It measures how far each cell sits from comparable stores in the same category and month, and ranks the outliers for a human to look at. The output is a triage queue.

Everything is a RATE against sales in the same cell, because a large store shrinks more in absolute dollars simply by selling more, and the comparison is within category and month, so an inherently wasteful category or a bad month for everyone does not generate alarms.

Cells with under 250 of sales are dropped: a shrink rate computed on a tiny denominator is noise, and it is the fastest way to fill a review queue with nothing.

## Flags

2,464 of 45,136 cells flagged (5.46%).

| Source | Cells |
|---|---|
| none | 42,672 |
| robust_z | 1,561 |
| both | 704 |
| isolation_forest | 199 |

The two detectors agree on 704 cells. They are reported separately rather than blended, because where they disagree is informative: robust_z catches a cell whose overall rate is extreme, isolation forest catches odd shapes such as a normal total made up almost entirely of one reason code.

## Validation without labels

With no ground truth there is no precision to report. What can be tested is whether the flags are stable, whether they separate, and whether they concentrate value.

| Test | Result |
|---|---|
| Flagged store-categories that reflag in the second half | 0.380 |
| Same, expected by chance | 0.276 |
| Lift over chance | 1.38x |
| Flagged mean shrink rate | 0.0149 |
| Unflagged mean shrink rate | 0.0038 |
| Flagged mean shrink value | 134.91 |
| Unflagged mean shrink value | 37.67 |

Stability is the closest thing to evidence available here. Alerts driven by pure noise do not repeat, so a repeat rate well above chance means the detector is finding something persistent about those store-categories rather than reacting to month-to-month randomness.

## Size of the prize

The flagged cells are 5.46% of all cells but hold 17.1% of shrink dollars. Excess shrink in the flagged cells -- the amount above what a median peer would have lost -- totals 257,616 against 1,940,040 of shrink overall.

Excess is the honest way to size this. Total shrink in a flagged cell is not recoverable; the part above peer performance is the only piece a store could plausibly claw back, and even that assumes the cause is addressable.

## Output

shrink_anomaly_scores carries both scores, the peer median it was judged against, the dominant reason code and its share, the excess shrink value, and which detector fired. Sort by excess_shrink_value to work the queue by money rather than by strangeness.
