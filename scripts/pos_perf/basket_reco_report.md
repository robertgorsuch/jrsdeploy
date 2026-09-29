# Market-basket recommender report

Run 2026-08-26, model_version basket-reco-v1. 915 items, 230,248 co-occurring pairs.

Split is out of time: co-occurrence is built only from baskets before 2020-11-01, and all 300,000 evaluated baskets fall after it.

## Leave-one-out accuracy against the popularity baseline

One item is hidden from each held-out basket, the rest are used to rank candidates, and we record where the hidden item landed. Items already visible in the basket are excluded from the ranking.

| Scorer | hit@1 | hit@5 | hit@10 | MRR |
|---|---|---|---|---|
| popularity | 0.0216 | 0.0691 | 0.1578 | 0.0628 |
| cosine | 0.0776 | 0.2164 | 0.3048 | 0.1538 |
| lift | 0.0418 | 0.1313 | 0.1996 | 0.0951 |

Best scorer: **cosine**, which beats the popularity baseline (2.45x on MRR).

Popularity is the baseline that matters. Most grocery baskets contain staples, so recommending the chain bestsellers to everyone is already a decent strategy. A co-occurrence model only earns its place by beating it.

## What the recommendations look like

66.4% of the stored recommendations sit in the same category as their anchor product. A very high share would mean the model has learned little beyond the category tree and a category rule would do the same job for free; a very low share on a grocery assortment would be equally suspicious.

## Output

plu_recommendations holds the top 10 companions per PLU with both scores, the raw pair basket count and its support, so a caller can apply its own confidence floor. Pairs seen in fewer than 30 baskets are excluded from lift, which is unstable on thin support.

The table is the serving artefact -- a lookup joined in SQL or read by a dashboard. There is no fitted estimator to register, because the model IS the pair table.
