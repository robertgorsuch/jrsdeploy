"""register_prompts.py -- MLflow Prompt Registry entry for the POS
model family.

WHY THIS PROMPT, AND WHY IT LOOKS LIKE THIS
  Seven models now write seven tables into pos_data. Every one of them has a
  specific way of being misread, and they are not obvious ones:

    store_plu_forecast.predicted_units is a MEDIAN that covers demand in only
      45 percent of weeks. Anyone who treats it as "how much to order" causes
      stockouts. suggested_order is the q0.85 figure and the only orderable one.
    plu_price_elasticity magnitudes overstate the real response by about 2x,
      and the estimates are observational. Quoting a revenue outcome from them
      is a fabrication with a number attached.
    shrink_anomaly_scores has no fraud label. It is a triage queue. Language
      that implies theft is both unsupported and a way to get someone accused.
    supplier_reliability_forecast FAILED validation at AUC 0.5002. Its columns
      are in the table for provenance, not for use.
    every forward row is a forecast, not a measurement, and the weather behind
      it is a climatological average rather than a forecast feed.

  A general-purpose summariser handed these tables will produce fluent,
  confident, wrong advice -- and the wrongness is invisible, because the numbers
  are real. The prompt is therefore mostly guardrails. That is the point: the
  value is not in asking for a summary, it is in encoding what each model is
  not allowed to be used for, in the one place that travels with the model.

  Registering it in MLflow rather than pasting it into an application keeps it
  versioned and aliased next to the models whose caveats it encodes, so when a
  model changes the prompt that constrains it is visible in the same registry.

Usage
  python scripts/pos_perf/register_prompts.py             # print, register nothing
  python scripts/pos_perf/register_prompts.py --register  # register a new version
"""

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pos_ml_common import OWNER, TEAM, admiral_token, cfg  # noqa: E402

PROMPT_NAME = "pos-store-weekly-brief"

TEMPLATE = """You are a retail operations analyst writing the Monday briefing for the manager of \
one store in a 330-store Canadian grocery franchise. You write for someone with twenty minutes \
and a shop floor to run.

All rows below are already filtered to store {{store_number}}, week beginning {{week_start}}.

DEMAND (store_day_forecast)
{{demand_rows}}

REPLENISHMENT (store_plu_forecast)
{{replenishment_rows}}

SHRINK (shrink_anomaly_scores)
{{shrink_rows}}

PRICING (plu_price_elasticity, for lines this store sells)
{{pricing_rows}}

BASKET AFFINITY (plu_recommendations)
{{basket_rows}}

HOW EACH INPUT MAY AND MAY NOT BE USED

Demand. predicted is a 14-day-ahead forecast of daily sales in CAD, made before the week began. \
Rows with a null actual are forecasts, never measurements, and must be worded that way. Typical \
error is about 21 percent, so give ranges and never quote a forecast to the dollar. The weather \
behind forward rows is a day-of-year climatological average, not a forecast, so never attribute a \
change in the number to expected weather.

Replenishment. suggested_order is the order quantity and is already rounded up to a whole case. \
predicted_units is a median: it covers actual demand in only about 45 percent of weeks, so it is \
never an order quantity and never "what you will need". If a PLU does not appear, it was not \
being sold at the end of the period and must not be ordered. Do not invent quantities for lines \
that are absent.

Shrink. This is an unsupervised outlier queue built by comparing this store against peers in the \
same category and month. There is no fraud label anywhere in the data. Write "worth checking" and \
nothing stronger. Never state or imply theft, dishonesty, negligence, or any named or implied \
individual. Rank by excess_shrink_value, which is the amount above what a median peer lost, \
because that is the only part that could plausibly be recovered.

Pricing. These elasticities are observational, not causal, and they overstate the true response \
by roughly a factor of two. Use them ONLY to rank candidates for a price test. Never state an \
expected revenue or margin outcome as a fact. Where identified is "category", say the figure is \
inherited from the category rather than measured for that product. Ignore any positive \
elasticity: it is a sign error, not a discovery that raising price raises demand.

Supplier lead times. If lead time comes up, use expected_lead_days only. The predicted_lead_days \
and p_on_time columns come from a model that failed validation at AUC 0.5002 and must not be \
quoted.

Period. This data ends 2020-12-31. Everything here is historical.

OUTPUT

Write at most 400 words, in these five sections, in this order:

1. Week ahead -- the sales shape for the week and the one or two days that differ from normal.
2. Order now -- at most six lines, each as PLU, product, suggested_order, and the one-line reason.
3. Worth checking -- at most three shrink cells, each with its excess value and peer comparison.
4. Price test candidates -- at most three, framed as a test to run, never as a decision taken.
5. Cross-sell -- at most two pairings with a concrete placement or bundle suggestion.

Every item carries a number and a next action. If a section has nothing material, write "Nothing \
this week." and move on rather than padding it.

If the inputs are empty, internally inconsistent, or insufficient to support a section, say so \
plainly in that section and stop. Do not infer values that are not in the rows above, and do not \
carry a number from one section into another it does not belong to."""

TAGS = {
    "owner": OWNER,
    "team": TEAM,
    "domain": "retail-operations",
    "audience": "single-store manager",
    "consumes": ("store_day_forecast, store_plu_forecast, shrink_anomaly_scores, "
                 "plu_price_elasticity, plu_recommendations"),
    "related_models": ("store-day-demand, plu-weekly-demand, shrink-anomaly, "
                       "price-elasticity (table only), basket-reco (table only)"),
    "guardrails": ("median vs order quantity, elasticity is observational and overstated ~2x, "
                   "shrink is triage not accusation, supplier model failed validation"),
    "excluded_model": "supplier-lead-time -- AUC 0.5002, columns must not be quoted",
    "data_caveat": "source data ends 2020-12-31 -- all output is historical",
    "lifecycle": "active",
    "alias": "production",
}

COMMIT_MESSAGE = (
    "Initial version. Guardrails encode the documented misuse mode of each model in the POS "
    "family: order quantity must come from the q0.85 column not the median, elasticities rank "
    "but do not size, shrink is triage with no fraud label, and the supplier model failed "
    "validation so its columns are off limits."
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--register", action="store_true",
                    help="actually register. Without it, this only prints the proposal.")
    a = ap.parse_args()

    print(f"prompt name : {PROMPT_NAME}")
    print(f"variables   : store_number, week_start, demand_rows, replenishment_rows, "
          f"shrink_rows, pricing_rows, basket_rows")
    print(f"length      : {len(TEMPLATE):,} characters")
    print(f"tags        : {len(TAGS)}")
    if not a.register:
        print("\n--- template ---\n")
        print(TEMPLATE)
        print("\n(dry run -- nothing registered. Pass --register to write it.)")
        return 0

    os.environ["MLFLOW_ENABLE_ASYNC_LOGGING"] = "false"
    import mlflow
    from mlflow.genai import register_prompt, set_prompt_alias
    try:
        mlflow.config.enable_async_logging(False)
    except Exception:
        pass
    os.environ["MLFLOW_TRACKING_TOKEN"] = admiral_token()
    mlflow.set_tracking_uri(f"https://{cfg()['db_pos_data']['host']}/mlflow/")

    p = register_prompt(name=PROMPT_NAME, template=TEMPLATE,
                        commit_message=COMMIT_MESSAGE, tags=TAGS)
    # Registering makes the entry live, so the lifecycle tag says so. A
    # registry full of things labelled "proposed" that are actually in use is
    # how a registry stops being believed.
    print(f"  registered {p.name} version {p.version}", flush=True)
    try:
        set_prompt_alias(name=PROMPT_NAME, alias="production", version=p.version)
        print(f"  alias production -> v{p.version}", flush=True)
    except Exception as e:
        print(f"  alias not set: {type(e).__name__}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
