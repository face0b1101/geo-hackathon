#!/usr/bin/env python3
"""Scrape defunct airline data from Wikipedia and output Elasticsearch bulk NDJSON.

Uses the Jina Reader API (r.jina.ai) to fetch Wikipedia pages as clean markdown,
then parses the markdown tables to extract airlines with ICAO designator codes.

Usage:
    uv run scrape.py                          # uses JINA_API from ../../.env
    JINA_API=jina_xxx uv run scrape.py        # explicit key

Output: ../adsb-airlines-defunct-data.ndjson (relative to this script)

Data source: Wikipedia (CC BY-SA 4.0)
See ../adsb-airlines-defunct-LICENCE.md for full attribution.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from collections import Counter
from pathlib import Path

import requests
from dateutil import parser as dateparser

REGIONAL_PAGES: dict[str, str] = {
    "Africa": "https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_Africa",
    "Americas": "https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_the_Americas",
    "Asia": "https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_Asia",
    "Europe": "https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_Europe",
    "Oceania": "https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_Oceania",
}

COUNTRY_SUBPAGES: dict[str, tuple[str, str]] = {
    "India": (
        "Asia",
        "https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_India",
    ),
    "United States (A-C)": (
        "Americas",
        (
            "https://en.wikipedia.org/wiki/"
            "List_of_defunct_airlines_of_the_United_States_(A%E2%80%93C)"
        ),
    ),
    "United States (D-I)": (
        "Americas",
        (
            "https://en.wikipedia.org/wiki/"
            "List_of_defunct_airlines_of_the_United_States_(D%E2%80%93I)"
        ),
    ),
    "United States (J-P)": (
        "Americas",
        (
            "https://en.wikipedia.org/wiki/"
            "List_of_defunct_airlines_of_the_United_States_(J%E2%80%93P)"
        ),
    ),
    "United States (Q-Z)": (
        "Americas",
        (
            "https://en.wikipedia.org/wiki/"
            "List_of_defunct_airlines_of_the_United_States_(Q%E2%80%93Z)"
        ),
    ),
    "United Kingdom": (
        "Europe",
        "https://en.wikipedia.org/wiki/List_of_defunct_airlines_of_the_United_Kingdom",
    ),
}

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_FILE = SCRIPT_DIR.parent / "adsb-airlines-defunct-data.ndjson"
ENV_FILE = SCRIPT_DIR.parent.parent / ".env"

JINA_READER_URL = "https://r.jina.ai/"
REQUEST_DELAY = 0.5  # seconds between Jina requests


def load_jina_key() -> str:
    """Load JINA_API key from environment or .env file."""
    import os

    key = os.environ.get("JINA_API", "")
    if key:
        return key

    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line.startswith("JINA_API=") and not line.startswith("#"):
                return line.split("=", 1)[1].strip().strip('"').strip("'")

    return ""


def strip_md_links(text: str) -> str:
    """Remove markdown link syntax and image syntax, keeping link text."""
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    return text.strip()


def parse_date_field(raw: str) -> dict:
    """Parse a date string into {date, text} where date is ISO-formatted if parseable."""
    result: dict[str, str] = {"text": raw}
    if not raw:
        return result

    cleaned = re.sub(r"\[.*?\]", "", raw).strip()
    if not cleaned:
        return result

    try:
        dt = dateparser.parse(cleaned, fuzzy=True)
        if dt is not None:
            if re.fullmatch(r"\d{4}", cleaned):
                result["date"] = dt.strftime("%Y")
            elif re.search(r"\d{1,2}\s", cleaned) or re.search(r"\d{1,2}/", cleaned):
                result["date"] = dt.strftime("%Y-%m-%d")
            else:
                result["date"] = dt.strftime("%Y-%m")
    except (ValueError, OverflowError):
        pass

    return result


def fetch_markdown(url: str, jina_key: str) -> str:
    """Fetch a URL as markdown via the Jina Reader API."""
    headers: dict[str, str] = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-Retain-Images": "none",
    }
    if jina_key:
        headers["Authorization"] = f"Bearer {jina_key}"

    resp = requests.post(
        JINA_READER_URL,
        headers=headers,
        json={"url": url},
        timeout=60,
    )
    resp.raise_for_status()
    data = resp.json()
    return data.get("data", {}).get("content", "")


def identify_columns(header_cells: list[str]) -> dict[str, int] | None:
    """Map normalised column names to indices from a markdown header row."""
    col_map: dict[str, int] = {}
    for i, cell in enumerate(header_cells):
        text = strip_md_links(cell).lower().strip()
        if "airline" in text and "icao" not in text and "iata" not in text:
            col_map["airline"] = i
        elif "iata" in text:
            col_map["iata"] = i
        elif "icao" in text and "airline" not in text:
            col_map["icao"] = i
        elif "callsign" in text:
            col_map["callsign"] = i
        elif "commenced" in text:
            col_map["commenced"] = i
        elif "ceased" in text:
            col_map["ceased"] = i
        elif "notes" in text or "note" in text:
            col_map["notes"] = i
        elif "image" in text or "logo" in text:
            col_map["image"] = i

    if "icao" not in col_map:
        return None
    return col_map


def build_record(
    *,
    airline_name: str,
    icao: str,
    iata: str,
    callsign: str,
    country: str,
    region: str,
    commenced: str,
    ceased: str,
    notes: str,
    source_url: str,
) -> dict:
    """Build a normalised airline record dict."""
    record: dict = {
        "callsign_prefix": icao,
        "defunct_airline_name": airline_name,
        "defunct_icao": icao,
        "defunct_iata": iata or None,
        "defunct_callsign": callsign or None,
        "defunct_country": country,
        "defunct_region": region,
        "operations": {
            "commenced": parse_date_field(commenced),
            "ceased": parse_date_field(ceased),
        },
        "notes": notes or None,
        "source_url": source_url,
    }
    return {k: v for k, v in record.items() if v is not None}


def extract_from_markdown(
    text: str,
    region: str,
    source_url: str,
    country_override: str | None = None,
) -> list[dict]:
    """Parse airline tables from markdown text."""
    records: list[dict] = []
    lines = text.split("\n")
    current_country = country_override or "Unknown"
    i = 0

    while i < len(lines):
        line = lines[i].strip()

        heading_match = re.match(r"^(#{1,4})\s+(.+)", line)
        if heading_match and not country_override:
            current_country = strip_md_links(heading_match.group(2)).strip()

        if line.startswith("|") and "---" not in line:
            header_cells = [c.strip() for c in line.split("|")[1:-1]]
            col_map = identify_columns(header_cells)

            if i + 1 < len(lines) and re.match(r"^\|[\s\-:|]+\|$", lines[i + 1].strip()):
                i += 2
            else:
                i += 1
                continue

            if col_map is None:
                continue

            while i < len(lines) and lines[i].strip().startswith("|"):
                row_line = lines[i].strip()
                if re.match(r"^\|[\s\-:|]+\|$", row_line):
                    i += 1
                    continue
                cells = [c.strip() for c in row_line.split("|")[1:-1]]

                def get_md(key: str, _cells: list[str] = cells) -> str:
                    idx = col_map.get(key)
                    if idx is None or idx >= len(_cells):
                        return ""
                    return strip_md_links(_cells[idx]).strip()

                icao = get_md("icao").strip().upper()
                icao = re.sub(r"\[.*?\]", "", icao).strip()
                if not icao or len(icao) != 3 or not icao.isalpha():
                    i += 1
                    continue

                airline_name = get_md("airline")
                airline_name = re.sub(r"\[.*?\]", "", airline_name).strip()
                if not airline_name:
                    i += 1
                    continue

                record = build_record(
                    airline_name=airline_name,
                    icao=icao,
                    iata=get_md("iata"),
                    callsign=get_md("callsign"),
                    country=current_country,
                    region=region,
                    commenced=get_md("commenced"),
                    ceased=get_md("ceased"),
                    notes=get_md("notes"),
                    source_url=source_url,
                )
                records.append(record)
                i += 1
            continue

        i += 1

    return records


def write_ndjson(records: list[dict], path: Path) -> int:
    """Write bulk NDJSON, deduplicating by ICAO code (last-write-wins)."""
    seen: dict[str, dict] = {}
    for rec in records:
        icao = rec["callsign_prefix"]
        seen[icao] = rec

    with path.open("w", encoding="utf-8") as f:
        for icao, rec in sorted(seen.items()):
            action = json.dumps({"index": {"_index": "adsb-airlines-defunct", "_id": icao}})
            doc = json.dumps(rec, ensure_ascii=False)
            f.write(f"{action}\n{doc}\n")

    return len(seen)


def print_validation_report(
    all_records: list[dict],
    deduped_count: int,
    region_counts: Counter,
) -> None:
    """Print a summary validation report."""
    total_scraped = len(all_records)

    commenced_date_ok = sum(
        1 for r in all_records if "date" in r.get("operations", {}).get("commenced", {})
    )
    ceased_date_ok = sum(
        1 for r in all_records if "date" in r.get("operations", {}).get("ceased", {})
    )

    print("\n=== Validation Report ===")
    print(f"Total rows scraped (with ICAO codes): {total_scraped}")
    print(f"Unique ICAO codes (after dedup):      {deduped_count}")
    print(f"Duplicates removed:                   {total_scraped - deduped_count}")
    print("\nDate parsing success:")
    print(f"  commenced.date parsed: {commenced_date_ok}/{total_scraped}")
    print(f"  ceased.date parsed:    {ceased_date_ok}/{total_scraped}")
    print("\nRegion breakdown:")
    for region, count in region_counts.most_common():
        print(f"  {region:12s}: {count:4d}")

    print("\nSample records (first 5 unique ICAO codes):")
    seen_icaos: set[str] = set()
    sample_count = 0
    for rec in all_records:
        icao = rec["callsign_prefix"]
        if icao in seen_icaos:
            continue
        seen_icaos.add(icao)
        action = json.dumps({"index": {"_index": "adsb-airlines-defunct", "_id": icao}})
        doc = json.dumps(rec, ensure_ascii=False, indent=2)
        print(f"\n  {action}")
        print(f"  {doc}")
        sample_count += 1
        if sample_count >= 5:
            break


def main() -> None:
    parser = argparse.ArgumentParser(description="Scrape defunct airlines from Wikipedia")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Fetch and parse but do not write the output file",
    )
    args = parser.parse_args()

    jina_key = load_jina_key()
    if not jina_key:
        print(
            "WARNING: No JINA_API key found. Using keyless mode (strict rate limits).",
            file=sys.stderr,
        )

    all_pages: list[tuple[str, str, str, str | None]] = []
    for region, url in REGIONAL_PAGES.items():
        all_pages.append((region, url, region, None))
    for country, (region, url) in COUNTRY_SUBPAGES.items():
        all_pages.append((country, url, region, country.split(" (")[0]))

    all_records: list[dict] = []
    region_counts: Counter = Counter()

    print("Fetching from Wikipedia via Jina Reader API...")
    for label, url, region, country in all_pages:
        print(f"  {label}: {url}")
        try:
            md = fetch_markdown(url, jina_key)
        except Exception as e:
            print(f"    ERROR: {e}", file=sys.stderr)
            continue

        records = extract_from_markdown(md, region, url, country_override=country)
        all_records.extend(records)
        region_counts[region] += len(records)
        print(f"    → {len(records)} airlines with ICAO codes")
        time.sleep(REQUEST_DELAY)

    if not all_records:
        print(
            "ERROR: No records scraped. Check Jina API key and connectivity.",
            file=sys.stderr,
        )
        sys.exit(1)

    if args.dry_run:
        print("\n[dry-run] Skipping file write.")
    else:
        print(f"\nWriting {OUTPUT_FILE}...")
        deduped_count = write_ndjson(all_records, OUTPUT_FILE)
        print(f"  Written: {deduped_count} unique airlines")

    deduped_count = len({r["callsign_prefix"] for r in all_records})
    print_validation_report(all_records, deduped_count, region_counts)
    print(f"\nDone. Output: {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
