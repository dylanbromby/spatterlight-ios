#!/usr/bin/env python3
"""Download Infocom box feelies and InvisiClues map scans into the app bundle.

Source: https://www.invisiclues.org (packaging + /invisiclues/{slug} pages).
Uses the Internet Archive when the live site is slow or shows a bot check.
Re-run when the site adds games or images. Requires network access.

Optional (live site TLS fingerprint): tools/.fetch-venv with curl_cffi — see README.
"""

from __future__ import annotations

import argparse
import json
import re
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "iOS" / "InfocomGameAssets"
BASE = "https://www.invisiclues.org"
ARCHIVE_PREFIX = "https://web.archive.org/web/{ts}id_/https://www.invisiclues.org"
CDX = "https://web.archive.org/cdx/search/cdx"

SLUGS = [
    "amfv", "arthur", "ballyhoo", "beyond-zork", "border-zone", "bureaucracy",
    "cutthroats", "deadline", "enchanter", "hhgttg", "hhijinx", "infidel", "journey",
    "lgop", "lurking-horror", "moonmist", "nord-and-bert", "planetfall", "plundered-hearts",
    "rtz", "seastalker", "sherlock", "shogun", "sorcerer", "spellbreaker", "starcross",
    "stationfall", "suspect", "suspended", "trinity", "wishbringer", "witness",
    "zork-i", "zork-ii", "zork-iii", "zork-zero",
]

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    ),
    "Accept": (
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,"
        "image/webp,image/apng,*/*;q=0.8"
    ),
    "Accept-Language": "en-US,en;q=0.9",
    "Accept-Encoding": "gzip, deflate, br",
    "Sec-Ch-Ua": '"Google Chrome";v="131", "Chromium";v="131", "Not_A Brand";v="24"',
    "Sec-Ch-Ua-Mobile": "?0",
    "Sec-Ch-Ua-Platform": '"macOS"',
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "Upgrade-Insecure-Requests": "1",
}

PATH_RE = re.compile(r'data-thumbnail-for="([^"]+)"')
ALT_RE = re.compile(r'alt="([^"]*)"')

_snapshot_lists: dict[str, list[str]] = {}
_last_request_at = 0.0
_curl_session = None


def _optional_curl_session():
    global _curl_session
    if _curl_session is not None:
        return _curl_session
    try:
        from curl_cffi import requests as curl_requests  # type: ignore

        _curl_session = curl_requests.Session(impersonate="chrome131")
    except ImportError:
        _curl_session = False
    return _curl_session


def _pace(min_interval: float = 1.35) -> None:
    global _last_request_at
    elapsed = time.monotonic() - _last_request_at
    if elapsed < min_interval:
        time.sleep(min_interval - elapsed)
    _last_request_at = time.monotonic()


def fetch_bytes(url: str, timeout: float = 90, retries: int = 6) -> bytes | None:
    archive = "archive.org" in url
    min_interval = 1.5 if archive else 0.35

    for attempt in range(retries):
        _pace(min_interval)
        data = _fetch_once(url, timeout=timeout)
        if data is not None:
            return data
        if archive:
            time.sleep(min(45.0, 4.0 * (2**attempt)))
    return None


def _fetch_once(url: str, timeout: float) -> bytes | None:
    live = url.startswith(BASE)
    if live:
        session = _optional_curl_session()
        if session:
            try:
                resp = session.get(url, timeout=timeout, headers=BROWSER_HEADERS)
                if resp.status_code == 200:
                    return resp.content
                if resp.status_code in (403, 429, 503):
                    return None
            except Exception:
                return None

    archive_headers = {
        "User-Agent": BROWSER_HEADERS["User-Agent"],
        "Accept": "*/*",
        "Accept-Language": "en-US,en;q=0.9",
    }
    req = urllib.request.Request(
        url, headers=BROWSER_HEADERS if live else archive_headers
    )
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            if resp.status != 200:
                return None
            return resp.read()
    except urllib.error.HTTPError as err:
        if err.code in (429, 503):
            return None
        return None
    except (urllib.error.URLError, TimeoutError, OSError):
        return None


def wayback_timestamps(path: str, limit: int = 25) -> list[str]:
    if path in _snapshot_lists:
        return _snapshot_lists[path]
    timestamps: list[str] = []
    for url_variant in (f"www.invisiclues.org{path}", f"invisiclues.org{path}"):
        q = (
            f"{CDX}?url={url_variant}&filter=statuscode:200&filter=mimetype:text/html"
            f"&output=json&limit={limit}"
        )
        data = fetch_bytes(q, timeout=45, retries=4)
        if not data:
            continue
        try:
            rows = json.loads(data.decode("utf-8"))
        except json.JSONDecodeError:
            continue
        for row in reversed(rows[1:]):
            ts = row[1]
            if ts not in timestamps:
                timestamps.append(ts)
        if timestamps:
            break
    _snapshot_lists[path] = timestamps
    return timestamps


def _html_usable(text: str) -> bool:
    if len(text) < 400:
        return False
    lowered = text.lower()
    if "bot check" in lowered or "captcha" in lowered:
        return False
    if "data-thumbnail-for" in text:
        return True
    return False


def fetch_html(path: str, slug_ts: list[str] | None = None) -> str | None:
    timestamps = slug_ts if slug_ts is not None else wayback_timestamps(path)
    for ts in timestamps:
        url = ARCHIVE_PREFIX.format(ts=ts) + path
        data = fetch_bytes(url, timeout=120, retries=5)
        if not data:
            continue
        text = data.decode("utf-8", errors="replace")
        if _html_usable(text):
            return text

    # Live site (Chrome TLS fingerprint when curl_cffi is installed).
    data = fetch_bytes(BASE + path, timeout=25, retries=2)
    if data:
        text = data.decode("utf-8", errors="replace")
        if _html_usable(text):
            return text
    return None


def box_prefixes(slug: str) -> tuple[str, ...]:
    return (
        f"/public/img/packaging/{slug}/",
        f"/public/img/coverart/{slug}/",
    )


def parse_images(html: str, prefixes: tuple[str, ...]) -> list[dict]:
    seen: set[str] = set()
    items: list[dict] = []
    for chunk in html.split("<img"):
        if "data-thumbnail-for" not in chunk:
            continue
        tag = chunk.split(">", 1)[0]
        m = PATH_RE.search(tag)
        if not m:
            continue
        path = m.group(1)
        if "-thumb." in path or "/public/img/ads/" in path:
            continue
        if not any(path.startswith(p) for p in prefixes):
            continue
        if path in seen:
            continue
        seen.add(path)
        alt = ""
        am = ALT_RE.search(tag)
        if am:
            alt = am.group(1).strip()
        title = alt or Path(path).name
        items.append({"title": title, "sourcePath": path})
    return items


def download_image(path: str, dest: Path, slug_ts: list[str]) -> bool:
    if dest.exists() and dest.stat().st_size > 500:
        return True
    dest.parent.mkdir(parents=True, exist_ok=True)
    for ts in slug_ts:
        url = ARCHIVE_PREFIX.format(ts=ts) + path
        data = fetch_bytes(url, timeout=120, retries=4)
        if data and len(data) > 500:
            dest.write_bytes(data)
            return True
    data = fetch_bytes(BASE + path, timeout=25, retries=2)
    if data and len(data) > 500:
        dest.write_bytes(data)
        return True
    return False


def rebuild_catalog_from_disk() -> dict:
    """Rebuild catalog.json from files already under InfocomGameAssets/{slug}/box|maps/."""
    catalog: dict = {"version": 1, "source": BASE, "games": {}}
    if not OUT.is_dir():
        return catalog
    for slug_dir in sorted(OUT.iterdir()):
        if not slug_dir.is_dir() or slug_dir.name.startswith("."):
            continue
        slug = slug_dir.name
        entry: dict = {"inTheBox": [], "maps": []}
        for kind, key in (("box", "inTheBox"), ("maps", "maps")):
            kind_dir = slug_dir / kind
            if not kind_dir.is_dir():
                continue
            for path in sorted(kind_dir.iterdir()):
                if not path.is_file() or path.stat().st_size < 100:
                    continue
                if path.suffix.lower() not in {".jpg", ".jpeg", ".png", ".gif", ".webp"}:
                    continue
                rel = f"{slug}/{kind}/{path.name}"
                title = path.stem.replace("-", " ").replace("_", " ").title()
                entry[key].append({"title": title, "file": rel})
        if entry["inTheBox"] or entry["maps"]:
            catalog["games"][slug] = entry
    return catalog


def load_catalog() -> dict:
    catalog_path = OUT / "catalog.json"
    if catalog_path.exists():
        try:
            existing = json.loads(catalog_path.read_text(encoding="utf-8"))
            if isinstance(existing.get("games"), dict):
                return existing
        except json.JSONDecodeError:
            pass
    return {"version": 1, "source": BASE, "games": {}}


def process_slug(slug: str, catalog: dict) -> None:
    print(f"=== {slug} ===", flush=True)
    slug_ts = wayback_timestamps(f"/{slug}")
    if not slug_ts:
        print("  skip: no Wayback snapshots", flush=True)
        return

    game_html = fetch_html(f"/{slug}", slug_ts=slug_ts)
    if not game_html:
        print("  skip: no game page (archive rate limit or missing HTML)", flush=True)
        return

    box = parse_images(game_html, box_prefixes(slug))
    hints_html = fetch_html(f"/invisiclues/{slug}", slug_ts=slug_ts)
    map_prefix = (f"/public/img/invisiclues/{slug}/",)
    maps = parse_images(hints_html, map_prefix) if hints_html else []

    if not box and not maps:
        print("  skip: no images in HTML", flush=True)
        return

    entry = {"inTheBox": [], "maps": []}
    for kind, items in (("box", box), ("maps", maps)):
        key = "inTheBox" if kind == "box" else "maps"
        for item in items:
            name = Path(item["sourcePath"]).name
            rel = f"{slug}/{kind}/{name}"
            dest = OUT / rel
            ok = download_image(item["sourcePath"], dest, slug_ts)
            if not ok:
                print(f"  failed: {item['sourcePath']}", flush=True)
                continue
            entry[key].append({"title": item["title"], "file": rel})

    if entry["inTheBox"] or entry["maps"]:
        catalog["games"][slug] = entry
        print(
            f"  saved {len(entry['inTheBox'])} box, {len(entry['maps'])} maps",
            flush=True,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch Infocom assets into iOS/InfocomGameAssets")
    parser.add_argument(
        "--slug",
        action="append",
        dest="slugs",
        help="Only fetch these slugs (repeatable)",
    )
    parser.add_argument(
        "--rebuild-catalog",
        action="store_true",
        help="Scan iOS/InfocomGameAssets on disk and rewrite catalog.json (no network)",
    )
    args = parser.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    if args.rebuild_catalog:
        catalog = rebuild_catalog_from_disk()
        (OUT / "catalog.json").write_text(
            json.dumps(catalog, indent=2) + "\n", encoding="utf-8"
        )
        print(f"Wrote {OUT / 'catalog.json'} ({len(catalog['games'])} games)", flush=True)
        return

    catalog = load_catalog()
    slugs = args.slugs if args.slugs else SLUGS

    curl = _optional_curl_session()
    if curl:
        print("Using curl_cffi (Chrome TLS) for live invisiclues.org when needed.", flush=True)
    else:
        print(
            "Wayback-only mode (install tools/.fetch-venv for live site bypass).",
            flush=True,
        )

    for slug in slugs:
        process_slug(slug, catalog)
        (OUT / "catalog.json").write_text(
            json.dumps(catalog, indent=2) + "\n", encoding="utf-8"
        )

    print(f"Wrote {OUT / 'catalog.json'} ({len(catalog['games'])} games)", flush=True)


if __name__ == "__main__":
    main()
