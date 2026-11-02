<p align="center"><img src="src/icon-256.png" alt="Nanolight's icon" width="96" height="96"></p>

<h1 align="center">Nanolight</h1>
<p align="center"><b>A ⌘Space launcher for the Mac, drawn by <a href="https://github.com/justrach/nanoui">nanoui</a>.</b><br>
App and file search, a calculator, and web search. Built with Zig and nanoui.</p>

<p align="center"><a href="https://github.com/justrach/nanolight/raw/refs/heads/main/docs/promo.mp4"><img src="docs/promo-preview.gif" alt="Nanolight in 31 seconds: apps, initials, typos, math, Google suggestions and results in the panel, on a MacBook Air" width="760"></a><br><sub><a href="https://github.com/justrach/nanolight/raw/refs/heads/main/docs/promo.mp4"><b>Watch it with sound →</b></a> · <a href="docs/promo.md">How it was made</a></sub></p>

<p align="center"><img src="docs/images/nanolight.jpg" alt="Nanolight's panel has found Safari from &quot;saf&quot;" width="760"></p>

## What it does

- **App search** matches names, word prefixes, initials (`ss` for System Settings), subsequences, and typos (`chorme` for Chrome). Frequently opened apps rank higher.
- **File search** finds filenames in Desktop, Documents, and Downloads using Spotlight. Type `file:invoice` for files only. Return opens a result; ⌘Return reveals it in Finder. Matching ignores case and accents. Up to four recent matches appear below apps.
- **Inline completion** suggests an app name or Google completion. Tab or → accepts it; Return runs the selected result.
- **Calculator** evaluates expressions such as `2^10 * 3` → 3,072 (`0xC00`). Return copies the answer.
- **Google suggestions** appear below local results. Queries containing address or path characters are excluded.
- **Embedded search** shows Google results in the panel. Esc returns to the list; ⌘Return opens the browser; ⌘[ goes back.
- **Grok and X** searches are available as result actions.
- **Keyboard navigation**: ↑/↓ or ⌃N/⌃P select a result; ⌘1–⌘9 run a numbered result.
- **Menu bar app** with no Dock icon or continuous rendering while idle.

File matching runs locally; `file:` mode has no web requests or actions. Keep Spotlight indexing enabled, even if its keyboard shortcut is disabled. Files excluded from the index do not appear.

## Sync across Macs (optional)

Sync is optional. Choose **Sign In with Codegraff to Sync Across Macs…** from the menu bar and approve the sign-in in your browser. Macs on the same account share:

- the global keyboard shortcut,
- the Google suggestions preference,
- app launch counts used to rank suggestions.

The most recent shortcut and suggestions preferences win. Each app keeps the higher launch count from either Mac. Queries, search history, and files are not synced. The API key is stored in Keychain; **Sign Out of Codegraff** revokes it.

Syncing goes through your Codegraff account, so [Codegraff's terms](https://codegraff.com/terms) and [privacy policy](https://codegraff.com/privacy) apply to it. New accounts made by signing in from Nanolight get $2 of Codegraff credit.

## Install

Download `nanolight-macos-arm64.dmg` from the [latest release](https://github.com/justrach/nanolight/releases/latest), open it and drag Nanolight to Applications. macOS 14 or later, Apple silicon.

First-run setup offers ⌘Space, ⌥Space, ⌃Space, or ⌥⌘Space and checks for conflicts. Settings can also record a custom shortcut. To free ⌘Space, disable Spotlight's shortcut in System Settings → Keyboard → Keyboard Shortcuts → Spotlight. Signed releases support automatic updates.

## Build

You need Zig 0.17.0 and Xcode or the Command Line Tools.

```sh
zig build test      # search, math, suggestions and the panel, through nanoui's Tester
zig build run       # build and open it
zig build app       # zig-out/Nanolight.app, for /Applications
VERSION=0.1.0 sh macos/package.sh   # the release: signed app, disk image, update zip, manifest.json
```

`macos/package.sh` signs with `$CODESIGN_IDENTITY` and notarizes when notary credentials are set (see the script); otherwise it signs ad hoc. Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds, signs and attaches the release.

## How it's made

| File | What |
| --- | --- |
| `src/main.zig` | The app: the window, the hot key, the menu bar icon, updates |
| `src/view.zig` | The panel: query, rows, footer, keys |
| `src/results.zig` | What a query lists, in order |
| `src/search.zig` | Fuzzy matching and ranking, allocation-free |
| `src/files.zig` | Asynchronous local filename search through Spotlight |
| `src/calc.zig` | The calculator |
| `src/suggest.zig` | Google's completions: the privacy guard, decoding, the cache (after [browse](https://github.com/justrach/browse)) |
| `src/preview.zig` | The results page in the panel (WKWebView) |
| `src/onboard.zig`, `src/shortcut.zig`, `src/recorder.zig` | The welcome, which key is free, recording one's own |
| `src/film.zig`, `src/stage.zig`, `tools/film.sh` | The walkthrough, rendered offscreen |
| `src/promo.zig`, `src/promo_cards.zig`, `tools/promo.sh`, `tools/promo/` | The promo: nanoui's shots, Blender's laptop ([docs/promo.md](docs/promo.md)) |

The icon is drawn by `tools/icon.py`. `src/backdrop.jpg` (the film's cover art) was made with OpenAI's image model.

## License

MIT
