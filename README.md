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

Push a version tag and GitHub Actions builds the DMG and publishes it as a release (`.github/workflows/release.yml`, on a `macos-26` runner with Xcode 26.3):

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The tag sets the version (`CFBundleShortVersionString` 0.2.0) and the run number sets the build. Running the workflow by hand (Actions › Release › Run workflow) makes a test build that's kept as an artifact for a week and publishes nothing. Locally, `VERSION=0.2.0 BUILD=12 make dmg` stamps the same way.

Signing and notarization switch on when these repository secrets exist (Settings › Secrets and variables › Actions). Without them the release is ad-hoc signed, and people approve it once in System Settings › Privacy & Security.

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | Your Developer ID Application certificate and key, exported as a .p12 and base64-encoded (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | The password you gave the .p12 |
| `APPLE_ID` | The Apple ID email of your developer account |
| `APPLE_TEAM_ID` | Your 10-character team ID |
| `APPLE_APP_PASSWORD` | An app-specific password for that Apple ID (account.apple.com › Sign-In and Security) |

`gh secret set MACOS_CERTIFICATE < cert.b64` and so on sets them from the terminal. Signed releases use the hardened runtime with the entitlements in `app/Backchannel.entitlements` (camera and microphone).

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
