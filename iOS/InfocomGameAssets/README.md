# Bundled Infocom game assets

Box feelies and InvisiClues map scans (from [InvisiClues.org](https://www.invisiclues.org)), vendored for offline use.

Regenerate (uses [Internet Archive](https://web.archive.org) when the live site blocks bots; optional Chrome TLS impersonation for live fetches):

```bash
python3 -m venv tools/.fetch-venv
tools/.fetch-venv/bin/pip install -r tools/fetch-requirements.txt
tools/.fetch-venv/bin/python tools/fetch_infocom_game_assets.py
```

Single game: `.../fetch_infocom_game_assets.py --slug zork-i`

Then rebuild the iOS app. `catalog.json` lists images per game slug (`zork-i`, `deadline`, …).

### If your IP is blocked

InvisiClues and/or the Internet Archive may stop responding (timeouts, bot pages, HTTP 429) after heavy automated fetching. That is usually temporary IP rate limiting, not a script bug.

- Wait a few hours (or use another network / VPN / phone hotspot) and run the fetch again.
- Or open the site in a normal browser on an unblocked connection, save images into `{slug}/box/` and `{slug}/maps/` here, then run  
  `python3 tools/fetch_infocom_game_assets.py --rebuild-catalog` (no network).

Layout per game:

- `zork-i/box/*.jpg` — box art and “in the box” feelies  
- `zork-i/maps/*.jpg` — InvisiClues map scans  
