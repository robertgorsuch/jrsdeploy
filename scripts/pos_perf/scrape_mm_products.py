# scrape_mm_products.py -- build mm_products.csv for the products dimension table
#
# Crawls the public M&M Food Market storefront (English pages):
#   1. /en/categories/all-products?page=N     -> full product slug list
#   2. per-category listing pages             -> category assignment per slug
#   3. per-sub-category filtered listings     -> sub-category assignment per slug
#   4. /en/products/<slug>                    -> JSON-LD Product (PLU, name, description,
#                                                price, stock) + package size, ingredients,
#                                                nutrition panel parsed from the HTML
#
# Output columns carry no URLs or other source identifiers -- the PLU is the join key
# to pos_sales_detail. Throttled to ~1 request/0.7s.
#
# Usage: python scripts/pos_perf/scrape_mm_products.py [-o scripts/pos_perf/mm_products.csv]

import argparse
import csv
import html as htmllib
import json
import re
import sys
import time
import urllib.parse
import urllib.request

BASE = "https://www.mmfoodmarket.com"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
DELAY = 0.7

_last_fetch = [0.0]


def fetch(path):
    wait = DELAY - (time.time() - _last_fetch[0])
    if wait > 0:
        time.sleep(wait)
    url = path if path.startswith("http") else BASE + path
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                _last_fetch[0] = time.time()
                return r.read().decode("utf-8", "replace")
        except Exception as e:
            if attempt == 2:
                print(f"  FETCH FAILED {path}: {e}", file=sys.stderr)
                return ""
            time.sleep(2 * (attempt + 1))


def product_slugs(html):
    return set(re.findall(r'href="/products/([^"?]+)', html))


def crawl_listing(path, max_pages=60):
    """Yield product slugs across all pages of a listing/filter URL."""
    seen = set()
    for page in range(1, max_pages + 1):
        sep = "&" if "?" in path else "?"
        html = fetch(f"{path}{sep}page={page}")
        slugs = product_slugs(html)
        new = slugs - seen
        if not new:
            break
        seen |= new
    return seen


def flatten(seg):
    seg = re.sub(r"<script.*?</script>", " ", seg, flags=re.S)
    seg = re.sub(r"<svg.*?</svg>", " ", seg, flags=re.S)
    seg = re.sub(r"<[^>]+>", "|", seg)
    seg = htmllib.unescape(seg)
    seg = re.sub(r"\|+", " | ", seg)
    seg = re.sub(r"\s+", " ", seg)
    return re.sub(r"(?:\| +)+\|?", "| ", seg)


NUTRIENTS = {
    "fat_g": r"\| Fat \| ([\d.]+) g",
    "sat_fat_g": r"Saturated \| ([\d.]+) g",
    "carbs_g": r"Carbohydrate \| ([\d.]+) g",
    "fibre_g": r"Fibre \| ([\d.]+) g",
    "sugars_g": r"Sugars \| ([\d.]+) g",
    "protein_g": r"\| Protein \| ([\d.]+) g",
    "cholesterol_mg": r"Cholesterol \| ([\d.]+) mg",
    "sodium_mg": r"Sodium \| ([\d.]+) mg",
    "potassium_mg": r"Potassium \| ([\d.]+) mg",
}


def parse_product(slug):
    html = fetch(f"/en/products/{slug}")
    if not html:
        return None
    row = {"slug": slug}

    # JSON-LD Product block
    for block in re.findall(r'<script type="application/ld\+json">(.*?)</script>', html, re.S):
        try:
            d = json.loads(block)
        except ValueError:
            continue
        if d.get("@type") == "Product":
            row["plu"] = str(d.get("productID") or "").strip()
            row["product_name"] = (d.get("name") or "").strip()
            row["web_description"] = re.sub(r"\s+", " ", d.get("description") or "").strip()
            offer = d.get("offers") or {}
            row["price_cad"] = offer.get("price") or ""
            row["in_stock"] = "Y" if "InStock" in str(offer.get("availability", "")) else "N"
            break
    if not row.get("plu"):
        return None

    # package size: first lb/kg/g token(s) shown before the tab section
    head = html.split("Ingredients")[0]
    sizes = re.findall(r">\s*([\d.]+\s?(?:lb|kg|g|oz|mL|L))\s*<", head)
    uniq = []
    for s in sizes:
        s = re.sub(r"\s+", " ", s)
        if s not in uniq:
            uniq.append(s)
    row["package_size"] = " / ".join(uniq[:2])
    m = re.search(r"([\d.]+)\s?g\b", row["package_size"])
    if m:
        row["size_g"] = m.group(1)
    else:
        m = re.search(r"([\d.]+)\s?kg\b", row["package_size"])
        row["size_g"] = str(round(float(m.group(1)) * 1000)) if m else ""

    text = flatten(html)

    # ingredients (+ optional allergens block) between the doubled "Ingredients"
    # tab heading and the packaging disclaimer
    m = re.search(
        r"Ingredients \| Ingredients \| ([^|]{20,4000}?) \|"
        r"(?: Allergens \| ([^|]{2,300}?) \|)? For the most accurate",
        text)
    row["ingredients"] = m.group(1).strip() if m else ""
    row["allergens"] = (m.group(2) or "").strip() if m else ""

    # nutrition panel
    m = re.search(r"Nutrition Facts \| Per ([^|]+?) \|", text)
    if m:
        row["serving_size"] = m.group(1).strip()
        g = re.search(r"\(([\d.]+)\s?g\)", row["serving_size"])
        row["serving_g"] = g.group(1) if g else ""
    m = re.search(r"Calories (\d+)", text)
    row["calories"] = m.group(1) if m else ""
    for col, pat in NUTRIENTS.items():
        m = re.search(pat, text)
        row[col] = m.group(1) if m else ""
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default="scripts/pos_perf/mm_products.csv")
    args = ap.parse_args()

    print("1) enumerating all products ...")
    all_html = fetch("/en/categories/all-products")
    m = re.search(r"(\d+) results", all_html)
    print(f"   site reports {m.group(1) if m else '?'} products")
    all_slugs = crawl_listing("/en/categories/all-products")
    print(f"   {len(all_slugs)} distinct product slugs")

    # top-level categories from the nav of the all-products page, crawled in
    # merchandise-first priority order so promo/attribute listings ("On sale
    # now", "Gluten-free", ...) never claim a product's primary category.
    PRIORITY = ["prepared-meals", "appetizers", "butcher", "seafood", "sides",
                "vegetables", "desserts", "bakery", "pantry-essentials",
                "kitchen-essentials", "single-serve", "vegetarian", "vegan",
                "gluten-free", "new-arrivals", "on-sale-now"]
    NOT_A_CATEGORY = {"on-sale-now", "new-arrivals", "gluten-free", "vegan",
                      "vegetarian", "single-serve"}
    # attribute listings kept as Y/N flag columns instead of categories
    FLAG_CATS = {"single-serve": "single_serve", "vegetarian": "vegetarian",
                 "vegan": "vegan", "gluten-free": "gluten_free"}
    cats = sorted(set(re.findall(r'href="/categories/([a-z0-9-]+)"', all_html)) - {"all-products"},
                  key=lambda c: (PRIORITY.index(c) if c in PRIORITY else len(PRIORITY) - 3, c))
    print(f"2) crawling {len(cats)} categories: {', '.join(cats)}")
    cat_of, subcat_of, flags_of = {}, {}, {}
    for cat in cats:
        first = fetch(f"/en/categories/{cat}")
        title = re.search(r"<h1[^>]*>\s*([^<]+?)\s*</h1>", first)
        cat_name = title.group(1).strip() if title else cat.replace("-", " ").title()
        slugs = crawl_listing(f"/en/categories/{cat}")
        if cat not in NOT_A_CATEGORY:
            for s in slugs:
                cat_of.setdefault(s, cat_name)
        elif cat == "single-serve":
            for s in slugs:  # real merchandise line; last-resort category
                cat_of.setdefault(s, cat_name)
        if cat in FLAG_CATS:
            for s in slugs:
                flags_of.setdefault(s, set()).add(FLAG_CATS[cat])
        # sub-category facet links on this category page
        subs = set(re.findall(r"sub_category%5B%5D=([^&\"']+)", first))
        for sub in subs:
            sub_name = urllib.parse.unquote_plus(sub)
            sslugs = crawl_listing(f"/en/categories/{cat}?sub_category%5B%5D={sub}")
            for s in sslugs:
                subcat_of.setdefault(s, sub_name)
        print(f"   {cat_name}: {len(slugs)} products, {len(subs)} sub-categories")

    print(f"3) fetching {len(all_slugs)} product pages ...")
    rows, seen_plu = [], set()
    for i, slug in enumerate(sorted(all_slugs), 1):
        row = parse_product(slug)
        if i % 50 == 0:
            print(f"   {i}/{len(all_slugs)}")
        if not row:
            continue
        if row["plu"] in seen_plu:
            continue
        seen_plu.add(row["plu"])
        row["category"] = cat_of.get(slug, "")
        row["sub_category"] = subcat_of.get(slug, "")
        for flag in ("single_serve", "vegetarian", "vegan", "gluten_free"):
            row[flag] = "Y" if flag in flags_of.get(slug, ()) else "N"
        rows.append(row)

    cols = ["plu", "product_name", "web_description", "category", "sub_category",
            "single_serve", "vegetarian", "vegan", "gluten_free",
            "package_size", "size_g", "price_cad", "in_stock", "ingredients",
            "allergens", "serving_size", "serving_g", "calories"] + list(NUTRIENTS)
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {len(rows)} products -> {args.out}")


if __name__ == "__main__":
    main()
