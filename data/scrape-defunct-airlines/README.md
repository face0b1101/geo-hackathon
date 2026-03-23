# Defunct Airlines Scraper

Optional Python tool to regenerate the defunct airlines dataset from Wikipedia.
The committed NDJSON file (`../adsb-airlines-defunct-data.ndjson`) works as-is —
you only need this tool if you want to refresh the data (e.g. after new airlines
cease operations).

## Last scraped

**23 March 2026** — 781 unique airlines with ICAO designator codes from 11
Wikipedia pages (5 regional + India, US ×4, UK).

## Prerequisites

- [uv](https://docs.astral.sh/uv/) (Python package manager)
- Python 3.13+
- A [Jina AI](https://jina.ai) API key (free tier available)

The scraper uses the [Jina Reader API](https://jina.ai/reader) to fetch
Wikipedia pages as clean markdown. No HTML parsing libraries required.

## Configuration

Set your Jina API key in one of two ways:

1. **Project `.env` file** (recommended) — add `JINA_API=jina_xxx` to
   `../../.env`. The scraper reads it automatically.
2. **Environment variable** — `JINA_API=jina_xxx uv run scrape.py`

A keyless mode works but has strict rate limits. An API key is recommended for
reliable operation across all 11 pages.

## Usage

```bash
cd data/scrape-defunct-airlines

# Generate the NDJSON (writes to ../adsb-airlines-defunct-data.ndjson)
uv run scrape.py

# Dry run — fetch and parse without writing the output file
uv run scrape.py --dry-run
```

The scraper prints a validation report at the end: total rows, unique ICAO
codes, duplicates removed, date parsing success rate, and region breakdown.

## After regenerating

Reload the Elasticsearch lookup index:

```bash
make deploy-indices FORCE=1
```

This deletes and recreates `adsb-airlines-defunct` with the updated data.

## Output

`../adsb-airlines-defunct-data.ndjson` — Elasticsearch bulk NDJSON with two
lines per airline (action line + document). Documents are sorted by ICAO code
and deduplicated (last-write-wins when the same code appears on multiple pages).

## Data source and licence

Data is sourced from Wikipedia's "List of defunct airlines" articles (CC BY-SA
4.0). See `../adsb-airlines-defunct-LICENCE.md` for full attribution.
