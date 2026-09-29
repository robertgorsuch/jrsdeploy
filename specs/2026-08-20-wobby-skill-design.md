# Wobby Skill — Design

Date: 2026-08-20
Status: Approved (design); spec pending user review

## Purpose

A project-level Claude Code skill named `wobby` that automates the Actian AI
Analyst (Wobby) Public API at `https://app.wobby.ai/api/public/v1` for
semantic-layer operations: export, inspection, diffing, and import/sync of
models, relationships, metrics, glossary terms, and AI analyst (agent)
definitions. Primary use cases: version-controlling the semantic layer in
git, promoting definitions between tenants (dev -> prod), and offline bulk
edits followed by a sync.

Out of scope (no public API exists for these, or UI-only): analyst Q&A /
chat, threads, datasets, data-source management, OSI / Excel export formats,
Slack / Teams integrations.

## Verified API facts (discovered live, 2026-08-20)

- Auth: `Authorization: Bearer <key>` — org-scoped API key from
  Studio > Settings > API Keys. Docs show `sk_` prefixes; real tenant keys
  observed with `ak_` prefix. Both are opaque bearer tokens.
- Deployed surface: `GET /environment` (supports `?entity_types=` filter,
  comma-separated: `models`, `relationships`, `metrics`, `glossary`,
  `ai_analysts`) and `PUT /environment` (bidirectional sync; returns 422
  when referenced data sources are missing in the target tenant).
- Everything else guessed or shown in docs is NOT deployed: `/agents`,
  `/ai_analysts`, `/threads`, `/datasets`, `/data_sources`,
  `/semantic-layer` (docs example — aspirational), `/openapi.json` all 404.
- Payload: "Lossless format" `version: "1.0"` with `exported_at`, `models`
  (source, grain, dimensions, measures, filters), `relationships`,
  `metrics`, `glossary`, `ai_analysts`. Fully documented at
  docs.actian.com/ai-analyst (mirror of docs.wobby.ai).
- Rate limit: 2 requests per 5 seconds per IP; violation = 1-hour IP ban.
  Observed: intermittent 429s even at 1 req / 6 s while a ban is in effect.

## Structure

```
.claude/skills/wobby/
  SKILL.md                    # frontmatter triggers + quickstart + workflows
  wobby.config.example.json   # { "baseUrl": "https://app.wobby.ai", "apiKey": "" }
  wobby.config.json           # real credentials — gitignored, never committed
  scripts/
    _wobby_common.ps1         # config load, throttled Invoke-WobbyApi
    environment.ps1           # export / summary / list / diff / import
  references/
    api.md                    # auth, base URL, endpoints, rate limits, docs-vs-reality
    environment-format.md     # Lossless 1.0 schema reference
    gotchas.md                # symptom-indexed: 429/ban, 422, key prefixes, filters
```

`.gitignore` gains `wobby.config.json` and the local environment cache file
(repo is public; keys and tenant data must never land in it).

## Components

### `_wobby_common.ps1`

- `Get-WobbyConfig` — reads `wobby.config.json` next to the scripts dir;
  clear error naming the example file if missing.
- `Invoke-WobbyApi` — single choke point for all HTTP:
  - Hard throttle: persists a last-call timestamp file in `$env:TEMP`
    (`wobby_last_call.txt`) so the >= 3.5 s minimum spacing holds across
    separate PowerShell processes, not just within one.
  - On 429: abort immediately with a message explaining the 1-hour IP ban;
    never auto-retry.
  - PowerShell 5.1 compatible (Invoke-RestMethod, TLS 1.2, no `?:`).

### `environment.ps1` (single entry script, `-Action` parameter)

- `export` — GET full environment (or `-EntityTypes` subset) to
  `-OutFile` (default: a local cache file under the skill dir, gitignored).
  One API call.
- `summary` — entity counts and names from the cache; zero API calls.
  `-Refresh` re-exports first.
- `list` — dump one entity type (models / metrics / glossary / analysts)
  from the cache as a table; zero API calls.
- `diff` — compare a local file against the cache (or two files):
  added / removed / changed entities by id and name; zero API calls.
- `import` — PUT a local JSON file. Prints a diff preview against the
  cache and refuses to send without `-Force`.

Call-minimization is a design rule, not an optimization: given the rate
limit, every read workflow runs off one cached export.

### References

- `api.md` — everything under "Verified API facts" above, plus curl and
  script examples.
- `environment-format.md` — Lossless 1.0 schema: entity shapes, field
  meanings, enum values (source types TABLE / VIEW / CUSTOM_QUERY,
  relationship types, time grains), authored from official docs
  cross-checked against a live export.
- `gotchas.md` — symptom-indexed (matching the jasper-deploy pattern):
  429 -> you are likely banned for 1 h, wait, do not hammer; 422 on PUT ->
  data source names must already exist in the target tenant; docs say
  `sk_` / `/semantic-layer` but reality is `ak_` / `/environment`.

## Error handling

- Missing / empty config: actionable setup message, exit 1.
- 401: "key invalid or revoked — create a new one in Studio > Settings >
  API Keys."
- 422 on import: surface the response body (names the missing data
  sources).
- 429: abort with ban explanation (above).

## Testing (live tenant, after current ban clears)

1. `export` full + filtered — verify HTTP 200 and payload version "1.0".
2. `summary` / `list` — verify counts match the export, zero API calls.
3. `diff` — edit a copy of the export locally, verify change detection.
4. `import` — no-op round trip: PUT the unmodified export back, expect 200
   and an unchanged subsequent export. (User-approved for this tenant.)
5. Throttle: two back-to-back script invocations must self-space >= 3.5 s.

## Security

- Repo is public. Real key lives only in gitignored `wobby.config.json`.
- The example config, spec, SKILL.md, and references contain no real keys
  or tenant-specific identifiers beyond the public base URL.
