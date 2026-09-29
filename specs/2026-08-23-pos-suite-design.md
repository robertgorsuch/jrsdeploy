# POS Dashboard Suite - Design

Date: 2026-08-23
Status: Decisions taken in session; spec pending user review, then plan
Blueprint (options + mockups): https://claude.ai/code/artifact/c4d67c80-1890-4bad-9988-6c133d75230e
Predecessor: specs/2026-08-20-pos-sales-dashboards-design.md (dashboards 1-3)

## Goal

Extend the three POS dashboards on STAGE (Executive Overview, Operations
Console, Promo and Margin Story, `report/pos_perf/`) into a full suite over
the `robert.gorsuch` schema on `pos_data` (`av-flm7ykoxlcvq`), aligned with
the Wobby Sales Analyst semantic layer as exported 2026-08-23 (52 models,
67 relationships, 112 metrics, 69 glossary terms). Deliverables:

- 7 new dashboards (numbered 4-10 below), deployed to STAGE first.
- 9 paginated reports that double as drill targets from dashboard tiles.
- Navy re-skin of the two executive-facing boards that already exist
  (Executive Overview, Promo and Margin Story).
- The precomputed aggregates each of the above needs.

Every user-visible band keeps the house rules from the 08-20 spec: Actian
logo top-left, centered title, no source-identifying strings (no "Foodmart",
"Wobby", datasource URIs, SQL, table or column names), current-year labels.

## Decisions (2026-08-23)

| # | Question | Decision |
|---|---|---|
| 1 | Archetype per dashboard | Mix, chosen below: Cockpit for 4, 8, 9, 10; Console for 5, 6, 7; Statement pattern for the finance paginated reports |
| 2 | Theme | Light everywhere except navy for the executive board (1) and story decks (3, and any future deck) |
| 3 | Filters | Spike the control-strip dashlet first; fall back to per-dashlet popups with the same parameter contract |
| 4 | Chart engine | JFreeChart by default; HTML5 (Highcharts) only where JFreeChart lacks the form: waterfall, heatmap |
| 5 | Treasury | One board |
| 6 | Churn | Console first; the Retention Story deck is deferred, not dropped |
| 7 | Phase order | Finance first, then customers, operations, growth |
| 8 | Paginated reports | All nine, spread over the four phases |

## Architecture

### Archetypes

Four tile families. A dashboard belongs to exactly one.

- **Cockpit** (as Executive Overview): no filters, one anchor visual, KPI
  strip, supporting charts and one ranked list with drill. One screen.
- **Console** (as Operations Console): control strip at y=0, KPI chips,
  two trends or ranked charts, a leaderboard or scorecard table. Every
  JRXML on the board declares the same parameter set.
- **Story** (as Promo and Margin Story): navy hero band with one sentence
  and one number, one annotated chart, three cards. Navy end to end.
- **Statement** (new, paginated only): ledger table with inline variance
  bars on the left or top, waterfall and variance bars alongside; driven
  by store / month / version parameters. Used by the Store P&L Statement
  and Franchisee Fee Statement reports. It is not a dashboard.

Grid: 40 units wide, `showTitleBar:false`, `scaleToFit:width`, manifests
in `report/pos_perf/<key>_dashboard.json` composed by
`build_dashlets.ps1 -Compose` / `compose_dashboard.ps1`. Delete before
recompose (memory: dashboard-recompose-needs-delete). Labels use "and",
never an ampersand: the JRS label for dashboard 4 is "POS Store Profit
and Budget" (resource `pos_store_pnl`); "P&L" appears only in this spec
and in report titles rendered by JasperReports, which escapes it.

Resource names: `pos_store_pnl`, `pos_treasury`, `pos_churn`,
`pos_supply`, `pos_labour`, `pos_network`, `pos_marketing`; JRXML prefixes
`pnl_`, `trs_`, `chn_`, `sup_`, `lab_`, `net_`, `mkt_` as in the tile
tables below; paginated reports `rpt_<name>`.

### Visual system

Light theme (dashboards 2, 4-10, all paginated reports): white tiles on
Tech Grey `#ECF3F8`, title `#1F4E79`, subtitle `#5B7DA6`, table header
`#1F4E79` on white, zebra `#D6E0EF`. Categorical series order, fixed and
never cycled: `#0550DC`, `#1DB6C0`, `#0A4CAD`, `#239CA8`. Sequential
(heatmap, choropleth): `#C8E4FF` to `#0A4CAD`. Status colours (dials,
favourable/unfavourable) stay `#5CB85C` / `#F0AD4E` / `#D9534F` and are
never reused for a series.

Navy theme (dashboards 1 and 3, future decks): page and tile background
Software Blue `#000032`, tile border `#26305A`, text white, captions
`#8AC6F8`, series Tech Blue `#3C91FF` then Software Teal `#2EC0CB`. Teal
sits just above the dark-mode lightness band, so every teal series carries
direct value labels. Implementation: a second copy of each affected JRXML
(`exec_*`, `story_*`) with the background and text styles changed; no
`.jrtx` is introduced because none of the 18 existing reports uses one and
mixing would create two style sources.

Chart rules carried from the dataviz method: one axis per chart (two
measures on different scales are indexed to a base month or split into
two charts); share-of-whole is sorted bars, 100 pct stacked only when the
share varies across a dimension; plan-vs-actual is diverging bars with
favourable to the right; a legend for 2+ series and none for one; labels
in text colour, never series colour.

### Filters

Phase 0 spike: extend `gen_dashboard.py` to emit the JRS 10 dashboard-level
filter wiring so one full-width control dashlet at y=0 drives every report
on the board (`dashletFilterShowPopup:false`). Acceptance: on a two-tile
test board, changing the region control re-renders both tiles. If the
spike fails within one working session, consoles ship with per-dashlet
popups exactly as Operations Console does today. Either way every console
JRXML declares the same parameter names, so switching later is a manifest
change only.

Parameter contract per console (input controls under
`/reports/pos_perf/controls/`, reusing `p_from`, `p_to`, `p_regions`,
`p_period` where they apply):

| Board | Parameters |
|---|---|
| 5 Treasury | `p_asof` (date), `p_regions`, `p_franchisee` (query LOV from franchisees) |
| 6 Churn | `p_score_date` (LOV from customer_churn_scores), `p_regions`, `p_tier` (LOV), `p_band` (LOV Low/Watch/High/Critical/All) |
| 7 Supply | `p_regions`, `p_store` (query LOV from stores), `p_category` (LOV from products), `p_supplier` (LOV from suppliers) |

### Chart engine

JFreeChart elements for bar, stackedBar, line, area, pie, meter, xyScatter.
HTML5 chart elements (`cvc:chart`) only for:

- waterfall (dashboard 4 anchor tile; Store P&L Statement),
- heatmap (dashboard 8 day-of-week x shift tile).

Each HTML5 chart is verified on STAGE in the viewer and in PDF export
before its dashboard is composed; if PDF export of an HTML5 chart is
unacceptable, the fallback is the JFreeChart construction (stacked bar
with a transparent base series for waterfall; crosstab with conditional
cell backgrounds for heatmap). The customizer jar stays unused on all new
reports so nothing depends on a PROD Tomcat restart.

Maps: FusionMaps component as in `exec_map.jrxml`, extended from province
choropleth to store markers (`c:markerData`) for dashboard 9.

### Data layer - precomputed aggregates

Rule from the 08-20 spec: no tile scans `pos_sales_detail` (63.6M rows) at
render time. Existing `dash_*` tables stay as they are. New objects, all in
`robert.gorsuch`, each with a `build_*.sql` and a `verify_*.sql` under
`scripts/pos_perf/` and built with the X100 rules already learned
(FLOAT8-wrapped ratios, no ordered aggregate windows, no semicolons or
unbalanced apostrophes in SQL comments):

| Object | Grain | Source | Used by |
|---|---|---|---|
| `dash_tender_monthly` | store x year_month x tender_group | tender_summary_daily (1.82M) | 5 |
| `dash_churn` | score_date x home_region x loyalty_tier x risk_band x recommended_action, plus driver_1 counts | customer_churn_scores + customers | 6, Churn Action List |
| `dash_cohort` | first-purchase cohort (yyyymm) x months_since_first | customer_month | 6 |
| `dash_labour` | store x year_month x day_of_week x shift_name: hours, labour_cost, net sales | shift_schedules + dash_store daily sales | 8 |
| `dash_email` | campaign x send month: sent, opened, clicked, converted | email_engagement | 10 |
| `dash_ecom_monthly` | year_month x delivery_partner: orders, value, late, satisfaction | ecommerce_orders | 10 |

Read directly, no aggregate (all under 110K rows): store_pnl_monthly,
store_budget_vs_actual, gl_monthly, chart_of_accounts, franchise_fee_ledger,
ap_invoices, tax_collected_monthly, gift_card_liability, loyalty_liability,
store_assets, inventory, purchase_orders, suppliers, shrinkage_log, stores,
competitor_locations, fsa_demographics, marketing_campaigns, employees,
store_traffic, pricebook_history.

### Semantic alignment with Wobby

Every KPI on a tile maps to a Wobby metric name so the AI Analyst and the
dashboard give the same number for the same question. The tile caption
uses the glossary term, not the metric id. Reference mapping (metric ->
tile):

- four_wall_ebitda, contribution_margin_pct, sales_variance_vs_budget,
  opex_variance_vs_budget, loaded_labour_pct_of_sales,
  occupancy_pct_of_sales, sales_plan_attainment_pct -> dashboard 4
- ar_outstanding, ar_pct_paid_on_time, ap_outstanding, avg_days_to_pay,
  ap_pct_paid_on_time, early_pay_discounts_taken, cashless_share_pct,
  total_card_processing_fees, tax_collected, taxable_sales_share_pct,
  gift_card_liability_cad, loyalty_liability_cad, total_net_book_value -> 5
- avg_churn_probability, total_ltv_at_risk, pct_customers_overdue,
  avg_overdue_ratio, loyalty_redemption_rate -> 6
- out_of_stock_rate, overstock_rate, inventory_days_of_supply,
  inventory_turnover, avg_gmroi, supplier_on_time_rate,
  avg_supplier_fill_rate, avg_source_cycle_time, shrinkage_pct_of_cogs -> 7
- total_labour_cost, total_labour_hours, labour_cost_pct_of_sales,
  cost_per_labour_hour, active_employee_count, store_conversion_rate,
  revenue_per_store_visitor -> 8
- total_stores, avg_sales_per_sqft, competitor_count,
  total_net_book_value, total_depreciation -> 9
- ecommerce_revenue_share_pct, ecommerce_late_fulfillment_rate,
  avg_ecommerce_satisfaction_score, email_open_rate, email_click_rate,
  email_conversion_rate, promotion_roi, subsidy_cost_per_conversion,
  total_campaign_conversions -> 10

Known Wobby caveats that affect tiles: promotional_sales equals
total_net_sales unless the promo filter is applied (the dashboard SQL
filters explicitly); GL amounts are signed (revenue positive, costs
negative, positive variance always favourable); risk bands are Low < 0.25,
Watch 0.25-0.45, High 0.45-0.70, Critical >= 0.70.

### Dashboards

Grid coordinates are x, y, w, h on the 40-wide grid, taken from the
blueprint mockups. Page pixel sizes follow the existing tiles of the same
shape (KPI strip 1600x130, half-width chart 950x422, full-width trend
1600x420, quarter chart 800x300, list 800x214).

**4. Store P&L and Budget** - Cockpit, light. Question: where does the
money go between net sales and four-wall EBITDA, and how far off plan.

| Tile | x,y,w,h | Form | Source |
|---|---|---|---|
| pnl_kpi_strip: net sales + plan attainment, gross margin, four-wall EBITDA + var vs budget, labour pct, loss-making store count | 0,0,40,4 | KPI strip | store_pnl_monthly, store_budget_vs_actual, sales_targets |
| pnl_waterfall: net sales -> COGS -> shrink -> labour -> occupancy -> other opex -> fees -> EBITDA, network, current year | 0,4,22,12 | HTML5 waterfall | store_pnl_monthly |
| pnl_variance_region: EBITDA variance vs Original budget by region | 22,4,18,12 | diverging bars | store_budget_vs_actual |
| pnl_contribution_trend: contribution margin pct, actual / Original / Reforecast, 24 months | 0,16,20,12 | 3-line | store_pnl_monthly, store_budget_monthly |
| pnl_worst_stores: 6 lowest four-wall margin stores with format; row drill to Store P&L Statement | 20,16,20,12 | ranked list | store_pnl_monthly |

**5. Franchise Treasury** - Console, light, one board. Question: what is
owed to us, what we owe, what liabilities sit on the books.

| Tile | x,y,w,h | Form | Source |
|---|---|---|---|
| trs_controls: as-of date, region, franchisee | 0,0,40,3 | control strip | - |
| trs_kpi: AR outstanding + aged 60+, AP outstanding + pct on time, cashless share, tax collected YTD, gift + loyalty liability | 0,3,40,4 | KPI chips | franchise_fee_ledger, ap_invoices, dash_tender_monthly, tax_collected_monthly, liabilities |
| trs_ar_aging: AR by aging bucket | 0,7,13,11 | bars | franchise_fee_ledger |
| trs_dpo: days to pay by payment terms | 13,7,13,11 | horizontal bars | ap_invoices |
| trs_tender_mix: tender group share by month, 100 pct stacked | 26,7,14,11 | stackedBar | dash_tender_monthly |
| trs_tax_province: tax collected by province | 0,18,13,12 | horizontal bars | tax_collected_monthly |
| trs_liability: gift card and loyalty closing liability by month | 13,18,13,12 | 2-line | gift_card_liability, loyalty_liability |
| trs_lease_expiry: stores by lease expiry year | 26,18,14,12 | bars | store_assets |

Drill: trs_ar_aging -> AR Aging; trs_dpo -> AP Aging and Payment Run;
trs_tax_province -> Sales Tax Remittance; trs_kpi AR chip -> Franchisee
Fee Statement.

**6. Retention and Churn** - Console, light. Question: who is about to
leave, how much LTV is at risk, what to do.

| Tile | x,y,w,h | Form | Source |
|---|---|---|---|
| chn_controls: score date, home region, loyalty tier, band | 0,0,40,3 | control strip | - |
| chn_kpi: scored customers, Critical + High pct, LTV at risk, pct overdue vs expected, avg churn probability | 0,3,40,4 | KPI chips | dash_churn, customer_ipt_stats |
| chn_bands: customers by risk band, sorted | 0,7,14,11 | bars | dash_churn |
| chn_ltv_band: LTV at risk by band | 14,7,13,11 | bars | dash_churn |
| chn_drivers: top driver_1 values among Critical | 27,7,13,11 | horizontal bars | dash_churn |
| chn_cohorts: active share by months since first purchase, two cohort years | 0,18,21,10 | 2-line | dash_cohort |
| chn_actions: recommended action x count x LTV; row drill to Churn Action List | 21,18,19,10 | list | dash_churn |

**7. Supply and Inventory** - Console, light. Question: are we stocked
right, are suppliers delivering.

| Tile | x,y,w,h | Form | Source |
|---|---|---|---|
| sup_controls: region, store, category, supplier | 0,0,40,3 | control strip | - |
| sup_kpi: out-of-stock pct, overstock pct, days of supply, supplier on-time pct, shrink pct of COGS | 0,3,40,4 | KPI chips | inventory, purchase_orders, shrinkage_log |
| sup_stock_status: stock status by category, 100 pct stacked | 0,7,20,10 | stackedBar | inventory |
| sup_gmroi: GMROI by category | 20,7,20,10 | horizontal bars | inventory |
| sup_scorecard: supplier on-time, fill rate, lead days; row drill to Supplier Scorecard | 0,17,20,11 | table | purchase_orders, suppliers |
| sup_shrink: shrink value by reason by month | 20,17,20,11 | stackedBar | shrinkage_log |

**8. Workforce and Labour** - Cockpit, light. Question: is labour
scheduled where the sales are.

| Tile | x,y,w,h | Form | Source |
|---|---|---|---|
| lab_kpi: labour cost, pct of net sales, cost per hour, active staff, sales per labour hour | 0,0,40,4 | KPI strip | dash_labour, employees |
| lab_heatmap: scheduled hours by day of week x shift, cell value = hours, colour = sales per hour | 0,4,24,12 | HTML5 heatmap | dash_labour |
| lab_format: labour pct of sales by store format | 24,4,16,12 | horizontal bars | store_pnl_monthly |
| lab_indexed: monthly labour cost and net sales indexed to January = 100 | 0,16,20,10 | 2-line | dash_labour |
| lab_conversion: traffic conversion pct by region | 20,16,20,10 | bars | store_traffic, stores |

**9. Store Network** - Map-led Cockpit, light. Question: which stores and
trade areas are strong, exposed, or due for a decision.

| Tile | x,y,w,h | Form | Source |
|---|---|---|---|
| net_map: store markers sized by sales per sq ft, ring when 2+ competitors within 2 km | 0,0,22,17 | FusionMaps markers | stores, competitor_locations, dash_store |
| net_sqft_format: sales per sq ft by format | 22,0,18,9 | horizontal bars | stores, dash_store |
| net_income_scatter: trade-area median income vs store sales | 22,9,18,8 | xyScatter | fsa_demographics, stores, dash_store |
| net_lease: lease expiries and refits by year | 0,17,20,9 | bars | store_assets |
| net_exposed: stores with 3+ competitors and below-format sales per sq ft | 20,17,20,9 | list | stores, competitor_locations |

**10. Marketing and Digital** - Cockpit, light. Question: what campaigns,
email and online orders return.

| Tile | x,y,w,h | Form | Source |
|---|---|---|---|
| mkt_kpi: e-commerce share, late fulfilment pct, email open / click / convert, promo ROI | 0,0,40,4 | KPI strip | dash_ecom_monthly, dash_email, promotions |
| mkt_funnel: email funnel as horizontal bars, pct of sent | 0,4,14,11 | horizontal bars | dash_email |
| mkt_ecom_share: e-commerce share of net sales by month | 14,4,26,11 | area | dash_ecom_monthly, dash_monthly |
| mkt_campaign_roi: campaign ROI ranked, subsidy cost per conversion as label; drill to Campaign section of Weekly Flash | 0,15,20,11 | horizontal bars | marketing_campaigns, promotions |
| mkt_partners: delivery partner late rate and satisfaction | 20,15,20,11 | table | dash_ecom_monthly |

**Navy re-skin of 1 and 3.** Executive Overview and Promo and Margin Story
get navy variants of every JRXML (`exec_*`, `story_*`): background
`#000032`, tile borders `#26305A`, text white, captions `#8AC6F8`, series
`#3C91FF` / `#2EC0CB` with direct labels on teal, dial ranges unchanged.
Layouts do not change. The light versions remain in git history; STAGE
carries only the navy versions after the switch.

### Paginated reports

All A4 landscape unless noted, logo top-left, centered title, parameters
from the dashboard that drills into them, schedulable from JRS.

| Report | Phase | Parameters | Content |
|---|---|---|---|
| Store P&L Statement (Statement pattern) | 1 | store, year_month, budget_version | ledger with actual / budget / var / var pct and inline variance bars, waterfall, 12-month EBITDA strip, rank in region |
| AR Aging | 1 | as-of date, region | franchisee x bucket matrix, totals, aged 60+ list |
| AP Aging and Payment Run | 1 | as-of date, terms | supplier x bucket, discounts available before due date |
| Sales Tax Remittance | 1 | province, year_month | taxable sales, rate lines, tax collected, rate-change note |
| Churn Action List | 2 | store or region, score date | High + Critical customers: id, LTV at risk, drivers, recommended action, expected next purchase |
| Inventory Reorder List | 3 | store | PLUs at or below reorder point: on hand, reorder qty, lead days, open PO |
| Supplier Scorecard | 3 | quarter | per supplier: on-time, fill rate, lead time, spend, PO count |
| Weekly Flash (A4 portrait, 2 pages) | 3 | week ending | network KPIs vs prior week and plan; campaign section |
| Franchisee Fee Statement (Statement pattern) | 4 | franchisee, year_month | invoices, payments, aging, royalty and marketing fee lines tied to store_pnl |

### Environments and deployment

Same pipeline as the 08-20 plan: SQL aggregate + verify -> hand-authored
JRXML from `smoke_kpi.jrxml` -> `lint_jrxml.ps1` -> `compile_jrxml.ps1`
-> `deploy_report.ps1` (with input controls) -> compose from manifest ->
`verify_report.ps1` plus a pypdfium2 rasterize-and-read check -> promote
with `promote.ps1`. STAGE is the target for this spec; PROD promotion of
each phase is a separate confirmation because PROD is shared.
Datasource `/datasources/pos_data_avalanche` is reused. Credentials stay in
the gitignored `jrs.config.json`; nothing source-identifying is committed
(repo is public).

### Testing / acceptance

- Every aggregate has a verify script with reconciliation checks against
  its source (row counts, totals to the cent where the source reconciles,
  no NULL keys).
- Every KPI tile value is compared with the matching Wobby metric for the
  same filter (query both, difference under 0.5 pct or explained in the
  verify script).
- Every dashboard is rasterized from run-to-PDF and inspected for
  overflow, label collisions and empty tiles; the PNG is kept under
  `out/pos_perf/` (gitignored) and named in the task report.
- Consoles: change each control once and confirm every tile re-renders
  with the filtered value (two-tile spike first, then the full board).
- HTML5 charts: viewer and PDF export both checked on STAGE before the
  dashboard that uses them is composed.
- Navy re-skin: a light/navy side-by-side PNG for dashboards 1 and 3.

## Security

No new datasources, roles or users. Reports carry no credentials, URIs
or schema names. Input controls that back onto queries are read-only
SELECTs over `robert.gorsuch`.

## Phasing

| Phase | Scope |
|---|---|
| 0 | Close out Task 8 (promote 1-3 to PROD) and Task 9 (docs, memory); control-strip filter spike |
| 1 Finance | dash_tender_monthly; dashboards 4 and 5; navy re-skin of 1 and 3; reports: Store P&L Statement, AR Aging, AP Aging and Payment Run, Sales Tax Remittance |
| 2 Customers | dash_churn, dash_cohort; dashboard 6; report: Churn Action List |
| 3 Operations | dash_labour; dashboards 7 and 8; reports: Inventory Reorder List, Supplier Scorecard, Weekly Flash |
| 4 Growth | dash_email, dash_ecom_monthly; dashboards 9 and 10; report: Franchisee Fee Statement; Retention Story deck if wanted |

Each phase ends with STAGE verification and a go/no-go on PROD promotion.

## Out of scope

Wobby-side dashboards or analyst changes; real-time refresh; new AI
analysts; return-rate analytics; customer demographics and diet-profile
visualisations (candidate for a later Customer Insight board); installing
the customizer jar on PROD; a `.jrtx` style-template migration.
