# haro app

The Flutter desktop client (macOS + Linux) for haro, built to the redesign in `design/`.
It talks to the Python backend in `../backend`; see `CLAUDE.md` for the API contract.

## Run it

```bash
# terminal 1: the backend (from the repo root)
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
PYTHONPATH=. .venv/bin/python -m uvicorn haro.main:app --port 8000

# terminal 2: the app
cd app
flutter run -d macos        # or: -d linux
```

Run one backend at a time: it owns the database at `~/.haro/haro.db`, and a second one
starts read-only.

## Test

```bash
flutter analyze
flutter test                        # add `-t live --run-skipped` for the live-backend parse test
```

## Screenshots

`--dart-define=HARO_CAPTURE=true` (debug builds only) hides the macOS window buttons and
saves the app's own pixels on ⌃⌥⌘S, so shots show haro's UI without any OS chrome.
