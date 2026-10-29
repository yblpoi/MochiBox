<div align="center">
  <img src="Design/mochibox-icon/Mochibox.iconset/icon_128x128@2x.png" width="112" alt="MochiBox">
  <h1>MochiBox</h1>
  <p><strong>Drop a game in. Play it in Chinese.</strong></p>
  <p>Real-time translation and a chest of in-game tweaks for RPG Maker games on macOS<br>
  Live translation · Full-text pass · Shared glossary · On-the-fly edits</p>
  <p>No game files touched · No Wine · No locale switching · Everything stays on your Mac</p>

  ![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)
  ![RPG Maker MV / MZ](https://img.shields.io/badge/RPG%20Maker-MV%20%7C%20MZ-8a63d2)
  ![License AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)

  [简体中文](README.md) | **English**
</div>

---

## What it is

MochiBox adds Chinese to Japanese RPG Maker games. Drop a game folder (or an `.app`) into the
window, pick a translation backend, press **Start** — dialogue, menus, item descriptions and battle
messages are already Chinese by the time they are drawn.

Translation happens **at the drawing layer**. MochiBox hosts the game page inside its own WebKit
window, injects a small agent script, and swaps the text argument right before the engine's own
draw call runs. As a result:

- the scripts, assets and saves the game reads stay exactly as shipped — **not a byte on disk changes**;
- translations are **cached per sentence**, so a repeated line never hits the backend twice;
- in passthrough mode **no network request is made at all**.

It is not a translation patch and not a subtitle overlay: because it hooks the engine's own drawing
entry points, text that only exists at runtime — menus, status windows, battle logs — is covered too.

## Features

- **Live translation** — dialogue, system messages, item and skill descriptions, menu options and
  battle logs are replaced as they are drawn. No restart, no reloading a save. Numbers, `%1`
  placeholders and control codes are preserved; when the segment count does not line up, the
  original text is drawn instead of a misaligned translation.
- **Full-text pass** — scan `$data*`, every map and every runtime-seen string, dedupe by source text,
  translate in batches, persist per game, export, and push the result back into the running game.
  It is an explicit pre-pass and does not change the live path.
- **Glossary** — locked mapping for system terms, names and places; category-ordered prompting so
  names are learned before descriptions and dialogue; post-translation checks for lost placeholders,
  leftover kana, unchanged output, glossary violations and length anomalies. Editable, importable and
  exportable per game.
- **Cheat panel** — gold, items, actor stats and levels, switches, variables, encounters, movement
  speed, teleport with a teleport-point list, font scaling. It edits **runtime memory**, never a save
  file, and destructive actions ask first.
- **Data write-back (optional)** — character names and status announcements are assembled at runtime
  and have no whole-string entry to look up, so translations can be written back into `$data*` name
  fields. Two toggles let you keep only the announcements, or disable the whole block and restore
  the original values.
- **Embedded kernel, zero Wine** — a Windows release is a static site plus a shell. MochiBox serves
  the folder read-only on loopback and opens it in an embedded WebKit view. `Game.exe` is never
  executed and no external browser is launched on the default path.
- **Local first** — no telemetry (flag is always `false` and no implementation exists). Settings,
  cache and logs live in `~/Library/Application Support/MochiBox/`; the API key is written with mode
  `0600`. Only text fragments go to the backend you configure.

## Quick start

1. **Configure a backend** — Settings → backend: OpenAI-compatible (endpoint / model / key),
   DeepL (key), or *passthrough* (no translation, no network — handy for a first smoke test).
2. **Add a game** — drag the folder (or `.app`) into the window, or use **+**. The detected engine
   shows up in the library.
3. **Press Start** — rows appearing in the stream pane mean the agent is live. The cheat and
   full-text panes only load data once a session is attached.

## Support

| Item | Notes |
|---|---|
| Platform | macOS 13+, arm64 build (Apple Silicon) |
| Engines | **RPG Maker MV / MZ** can launch; XP / VX / VX Ace / 2000, Wolf, Ren'Py, KiriKiri, TyranoBuilder, Unity, Godot and Siglus are detected but cannot start a session |
| Releases | Windows builds (no Wine) and macOS builds |
| Language pair | Japanese → Simplified Chinese (fixed) |
| Backends | OpenAI-compatible / DeepL / passthrough (offline) |

## FAQ

**"App is damaged" or "cannot verify the developer"?**

The bundle is ad-hoc signed and not notarized, so Gatekeeper blocks the first launch. Right-click →
Open → Open (once), or:

```bash
xattr -dr com.apple.quarantine /path/to/MochiBox.app
open /path/to/MochiBox.app
```

**Does it upload my game?**

No. The folder is only served read-only to the embedded window on loopback; only text fragments go
to your backend.

**Does it modify my saves?**

No. Saves stay in the game's own browser storage, isolated per game. MochiBox only keeps the
loopback port stable so the origin — and therefore the save — stays the same.

**Why is nothing translated at first?**

Text is collected only when the engine actually draws it. Some games play an opening movie before
the title screen; during videos, CGs and image-only UIs there is simply nothing to translate.

**Boxes or missing glyphs?**

Text is rendered with the system PingFang font by default, and you can pick another installed font
in Settings. Text pre-rendered into images cannot be replaced.

**Can I get the original text back?**

Games that already ship Chinese are skipped automatically. Otherwise switch the backend to
passthrough, or turn translation off.

**Mac App Store?**

No, and it is not planned: the app launches third-party programs and drives their debugging ports,
and it expects the user to bring an API key.

## Build from source

Command Line Tools only — no Xcode, no SwiftPM/CocoaPods, no runtime dependencies:

```bash
bash Scripts/build.sh
# artifact: build/MochiBox.app (ad-hoc signed)
```

<details>
<summary>Build gate, self-test and the optional media toolchain</summary>

`build.sh` runs a layering gate first: the core layers must not import SwiftUI / AppKit, which is
what lets `--selftest` run without a graphical session (e.g. over SSH). The same script accepts an
optional static `ffmpeg` for VP9-alpha media — WebKit drops the alpha plane at parse time, so such
clips are transcoded to HEVC-with-alpha. Without it the transcode layer disables itself and assets
are served byte-for-byte. See `docs/media-compat-vp9-alpha.md`.

```bash
bash Scripts/build-ffmpeg.sh                  # builds vendor/media/ffmpeg (not tracked)
./build/MochiBox.app/Contents/MacOS/MochiBox --help
./build/MochiBox.app/Contents/MacOS/MochiBox --selftest
```

</details>

## Known limitations

- **No claim of supporting every MV/MZ game.** Real-device verification covered a small number of
  commercial titles; the rest is unverified. Breakage usually comes from plugins that replace the
  drawing path, text baked into images, or fonts missing glyphs.
- The language pair is fixed at Japanese → Simplified Chinese.
- The live path has no offline pre-translation: the first line waits for a backend round-trip.
  Use the full-text pass if you want to play fully offline.
- Nothing is collected while a movie, CG or image-only UI is on screen.
- Glossary constraints are hard requirements only for OpenAI-compatible backends; DeepL has no
  system prompt, so the hint is best-effort.
- Unscanned runtime sentences fall back to the "dialogue" category.
- A stale in-flight result can overwrite a just-saved term once; the next redraw recovers.

## Development

Architecture, acceptance criteria, QA and handover notes live in `docs/`
(index: [docs/README.md](docs/README.md)). Only code, tests, documentation and build scripts are
tracked; build output and unpacked game material are ignored.

```bash
bash Tests/e2e/run.sh --suite contract   # protocol layer, no GUI, no network
bash Tests/e2e/run.sh --suite domain     # persistence / redaction / logging / resilience / cache / full text
bash Tests/e2e/run.sh --suite kernel     # embedded WKWebView
bash Tests/e2e/run.sh --suite faults     # 401 / 429 / 500 / malformed JSON / port conflicts
bash Tests/e2e/run.sh --suite all
```

## Special thanks

- **[MTool](https://mtool.app/)** — for pioneering translation and modification for RPG Maker
  games. This project's feature set, interaction design and compatibility notes owe a lot to it.

## License

**GNU Affero General Public License v3.0** — see [LICENSE](LICENSE).

## Disclaimer

MochiBox is an independent implementation. It ships no code or assets from any game, engine vendor,
or storefront. It reads the user's own local game directory and sends only text fragments to the
backend the user configures. Do not use it to redistribute game assets or to circumvent copy
protection.
