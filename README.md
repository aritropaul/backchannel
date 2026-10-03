# Backchannel

A native Mac app for WhatsApp (unofficial; not affiliated with WhatsApp or Meta). macOS 26. The UI is AppKit; the protocol layer is [whatsmeow](https://github.com/tulir/whatsmeow), linked in as a Go c-archive. It links to your phone as a companion device, the same way WhatsApp Web does.

> Unofficial client: WhatsApp can ban accounts it sees using third-party clients. whatsmeow uses the official multi-device companion protocol, which is lower risk, but the risk isn't zero.

## Build and run

```sh
make          # Go core (c-archive) + Xcode Release build -> build/Backchannel.app
make run      # build and open
make dmg      # build/Backchannel-<version>.dmg with the branded window (needs create-dmg)
```

Requirements: Xcode 26, Go 1.26, xcodegen (`brew install xcodegen`). `make project` regenerates `app/Backchannel.xcodeproj` from `app/project.yml`. The app icon is an Icon Composer document, `app/Icon/Backchannel.icon`.

On first launch, scan the QR code from your phone (Settings → Linked Devices → Link a Device) or use "Link with phone number instead". Your data lives in `~/Library/Application Support/Backchannel/` (`session.db` holds the keys, `app.db` holds chats and messages, plus `media/`, `avatars/` and `core.log`).

Coming from a build named WA: the first launch quits if WA is still running, then copies WA's settings, backs up `session.db` and `app.db` to `Application Support/Backchannel backup <date>/`, moves the data folder, and repoints the stored file paths (avatars, media, stickers). The phone stays linked.

## Releasing

```sh
make release VERSION=0.2.0
```

That archives the app, signs it with Developer ID through Xcode's account (the Apple ID signed in under Xcode › Settings › Accounts; Xcode manages the certificate in the cloud, so there's no certificate file, password or secret), sends it to Apple's notary service through the same account, staples the ticket, packs the branded DMG, checks it with Gatekeeper, and publishes `v0.2.0` on GitHub with the DMG and its SHA-256. The version comes from `VERSION`, the build number from the commit count. It releases only main as pushed with a clean tree; `PUBLISH=0 make release VERSION=0.2.0` does everything except publishing. The hardened runtime uses the entitlements in `app/Backchannel.entitlements` (camera, microphone and Photos).

Actions › Test build › Run workflow (`.github/workflows/release.yml`, a `macos-26` runner with Xcode 26.3) makes an ad-hoc signed test build on a clean machine and keeps it as an artifact for a week.

## Architecture

```
core/ (Go, -buildmode=c-archive)        app/Sources (Swift, AppKit)
  whatsmeow client + session.db           Core.swift      C bridge: WAStart / WACall / events
  events.go  → writes app.db (WAL)        Store.swift     read-only SQLite on the main thread
  actions.go ← JSON commands              MessageLayout   measured/drawn bubbles (TextKit 1)
  emits {"t":"msgs"/"chats"/...}          *ViewController NSTableView transcript + sidebar
```

- **The UI never waits on the network.** Go writes to `app.db`; Swift reads it directly with the system `SQLite3`. Both sides link the system `libsqlite3` (`-tags "libsqlite3 sqlite_omit_load_extension"`), because two SQLite copies touching one file can corrupt it.
- **Events say what changed, not the data.** Bursts are coalesced on the Go side (10 ms) and the sidebar reloads at most 8 times a second.
- **Sends echo locally.** The row is written before the network round trip.
- **Identities are canonicalised.** LID chats fold into the phone-number chat once the mapping is known.

## UI work without an account

```sh
python3 tools/make_preview_db.py build/preview
WA_PREVIEW_DIR=$PWD/build/preview build/Backchannel.app/Contents/MacOS/Backchannel          # synthetic chats, no network
WA_PREVIEW_DEMO=1 WA_SLOWMO=6 WA_PREVIEW_DIR=...                           # scripted send/typing/reply/tapback, 6× slow motion
```

`DESIGN.md` holds the visual and motion rules; `PRODUCT.md` holds product decisions.
