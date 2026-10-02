# WA

A native macOS 26 WhatsApp client. The UI is AppKit; the protocol layer is [whatsmeow](https://github.com/tulir/whatsmeow), linked in as a Go c-archive. It links to your phone as a companion device, the same way WhatsApp Web does.

> Unofficial client: WhatsApp can ban accounts it sees using third-party clients. whatsmeow uses the official multi-device companion protocol, which is lower risk, but the risk isn't zero.

## Build and run

```sh
make          # Go core (c-archive) + Xcode Release build -> build/WA.app
make run      # build and open
```

Requirements: Xcode 26, Go 1.26, xcodegen (`brew install xcodegen`). `make project` regenerates `app/WA.xcodeproj` from `app/project.yml`.

On first launch, scan the QR code from your phone (Settings → Linked Devices → Link a Device) or use "Link with phone number instead". Your data lives in `~/Library/Application Support/WA/` (`session.db` holds the keys, `app.db` holds chats and messages, plus `media/`, `avatars/` and `core.log`).

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
WA_PREVIEW_DIR=$PWD/build/preview build/WA.app/Contents/MacOS/WA          # synthetic chats, no network
WA_PREVIEW_DEMO=1 WA_SLOWMO=6 WA_PREVIEW_DIR=...                           # scripted send/typing/reply/tapback, 6× slow motion
```

`DESIGN.md` holds the visual and motion rules; `PRODUCT.md` holds product decisions.
