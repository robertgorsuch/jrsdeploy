# Price elasticity report

Run 2026-08-26, model_version price-elasticity-v1. PLU x month pricebook panel: 16,056 rows, 938 PLUs, 24 months.

## What this estimate is

Observational, not causal. Prices were not randomly assigned, and a retailer promotes what it expects to sell, so price and expected demand move together. The design removes the two largest confounders it can -- within-PLU first differences, so permanent product quality cannot masquerade as price sensitivity, and month demeaning, so chain-wide shocks like the March 2020 pantry-loading spike are not read as a price response. What survives is a ranked hypothesis about which products are price-sensitive. Settle it with a price test before repricing anything.

14,463 consecutive-month differences, 10,814 used for fitting (through 202006) and 3,649 held out. 700 of 938 PLUs had the 6 differences needed to fit individually; the rest inherit their category elasticity and are labelled as such.

## Out-of-time validation

Elasticities fitted on months through 202006 were used to predict demand changes in the held-out months (n = 3,413).

| Measure | Value |
|---|---|
| Correlation, predicted vs actual demand change | 0.2503 |
| R2 against a no-price-response null | 0.0023 |
| Correlation using raw unshrunk betas | 0.1463 |
| Calibration slope (actual on predicted) | 0.5046 |

The null is the honest comparator: a model that says price changes do nothing. Shrunk elasticities are compared against unshrunk ones so the value of the shrinkage is visible rather than assumed.

## Distribution

| Statistic | Value |
|---|---|
| Median elasticity | -2.000 |
| 10th percentile | -4.903 |
| 90th percentile | -0.189 |
| Share elastic (below -1) | 68.4% |
| Share with a positive sign (theory violation) | 6.7% |

A positive elasticity says demand rose when price rose. That is a sign error, not a discovery: it means the remaining confounding beats the signal for those products. The share is reported rather than hidden, and those PLUs should not be repriced on this evidence.

## Category elasticity, by sales

| Category | PLUs | Median elasticity | Annual sales |
|---|---|---|---|
| Uncategorised | 624 | -1.554 | 331,134,420 |
| Butcher | 30 | -4.534 | 164,455,774 |
| Appetizers | 32 | -4.381 | 78,686,004 |
| Prepared meals | 24 | -3.103 | 64,065,670 |
| Single serve | 31 | -2.585 | 45,608,534 |
| Desserts | 25 | -1.366 | 40,524,394 |
| Seafood | 8 | -2.706 | 10,837,432 |
| Sides | 5 | -1.467 | 7,696,412 |
| Pantry essentials | 11 | -5.138 | 6,022,586 |
| Bakery | 1 | -1.024 | 2,398,330 |
| Kitchen essentials | 8 | -2.604 | 1,625,440 |

## Output

plu_price_elasticity carries the raw and shrunk elasticity, its standard error and shrink weight, the category fallback, a demand band, and a pricing_signal in plain words. optimal_price is only populated where the elasticity is below -1, because the textbook formula p* = c*e/(1+e) is undefined otherwise -- an inelastic product has no unconstrained optimum, which in practice means there is room to test a rise, not that price should go up without limit.
