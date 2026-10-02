package main

// Saved stickers: the ones favourited on the phone (WhatsApp syncs them through
// app state as "favoriteSticker"), the ones favourited here, and the ones made
// here. Each is kept as a file in WA/stickers, keyed by the SHA-256 of its bytes.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waSyncAction"
)

func (a *App) stickerDir() string {
	d := filepath.Join(a.dir, "stickers")
	os.MkdirAll(d, 0o700)
	return d
}

// keepSticker stores a copy of a sticker's bytes and returns its hash and path.
func (a *App) keepSticker(data []byte, mime string) (string, string, error) {
	if len(data) == 0 {
		return "", "", errors.New("empty sticker")
	}
	sum := sha256.Sum256(data)
	hash := hex.EncodeToString(sum[:])
	ext := ".webp"
	if mime == "application/was" {
		ext = ".was"
	}
	path := filepath.Join(a.stickerDir(), hash+ext)
	if _, err := os.Stat(path); err != nil {
		if err := os.WriteFile(path, data, 0o600); err != nil {
			return "", "", err
		}
	}
	return hash, path, nil
}

func stickersChanged() { emit(map[string]any{"t": "stickers"}) }

// favoriteSticker adds a sticker file to (or removes it from) Favorites on this Mac.
func (a *App) favoriteSticker(r req) (any, error) {
	data, err := os.ReadFile(r.Path)
	if err != nil {
		return nil, err
	}
	mime := r.Mime
	if mime == "" {
		mime = "image/webp"
	}
	hash, path, err := a.keepSticker(data, mime)
	if err != nil {
		return nil, err
	}
	_, err = a.db.Exec(`INSERT INTO stickers (hash, path, mime, width, height, animated, favorite, ts) VALUES (?,?,?,?,?,?,?,?)
		ON CONFLICT(hash) DO UPDATE SET favorite=excluded.favorite, ts=excluded.ts, path=excluded.path`,
		hash, path, mime, r.Width, r.Height, b2i(r.Animated), b2i(r.On), time.Now().UnixMilli())
	stickersChanged()
	return map[string]any{"hash": hash}, err
}

// stickerRef is what's needed to download a saved sticker later.
type stickerRef struct {
	DirectPath string `json:"p"`
	MediaKey   []byte `json:"k"`
	EncSHA     []byte `json:"e"`
	Mime       string `json:"m"`
	Width      uint32 `json:"w"`
	Height     uint32 `json:"hh"`
}

// onFavoriteSticker applies the phone's Favorites. Each one is listed at once (as
// "wa:<index>" until its file is here), then downloaded and keyed by its bytes.
func (a *App) onFavoriteSticker(index []string, act *waSyncAction.StickerAction) {
	key := strings.Join(index[1:], "|")
	a.log.Infof("favorite sticker %q: favorite=%v path=%v", key, act.GetIsFavorite(), act.GetDirectPath() != "")
	if !act.GetIsFavorite() {
		a.db.Exec(`UPDATE stickers SET favorite=0 WHERE wa_key=?`, key)
		stickersChanged()
		return
	}
	var have int
	if a.rdb.QueryRow(`SELECT COUNT(*) FROM stickers WHERE wa_key=? AND path != ''`, key).Scan(&have) == nil && have > 0 {
		a.db.Exec(`UPDATE stickers SET favorite=1 WHERE wa_key=?`, key)
		stickersChanged()
		return
	}
	mime := act.GetMimetype()
	if act.GetIsLottie() {
		mime = "application/was"
	}
	ref := stickerRef{DirectPath: act.GetDirectPath(), MediaKey: act.GetMediaKey(), EncSHA: act.GetFileEncSHA256(),
		Mime: mime, Width: act.GetWidth(), Height: act.GetHeight()}
	a.db.Exec(`INSERT INTO stickers (hash, mime, width, height, favorite, wa_key, media, ts) VALUES (?,?,?,?,1,?,?,?)
		ON CONFLICT(hash) DO UPDATE SET favorite=1, media=excluded.media`,
		"wa:"+key, mime, act.GetWidth(), act.GetHeight(), key, jsonString(ref), time.Now().UnixMilli())
	stickersChanged()
	go a.fetchSavedSticker("wa:" + key)
}

// fetchSavedSticker downloads a saved sticker listed without its file.
func (a *App) fetchSavedSticker(hash string) error {
	var media, key string
	var fav int
	var ts int64
	if err := a.rdb.QueryRow(`SELECT media, wa_key, favorite, ts FROM stickers WHERE hash=?`, hash).Scan(&media, &key, &fav, &ts); err != nil {
		return err
	}
	var ref stickerRef
	if json.Unmarshal([]byte(media), &ref) != nil || ref.DirectPath == "" {
		return errors.New("no media reference")
	}
	data, err := a.cli.DownloadMediaWithPath(a.ctx, ref.DirectPath, ref.EncSHA, nil, ref.MediaKey, whatsmeow.MediaImage, "image", true)
	if err != nil {
		a.log.Warnf("saved sticker %s: %v", hash, err)
		return err
	}
	real, path, err := a.keepSticker(data, ref.Mime)
	if err != nil {
		return err
	}
	a.db.Exec(`DELETE FROM stickers WHERE hash=?`, hash)
	a.db.Exec(`INSERT INTO stickers (hash, path, mime, width, height, favorite, wa_key, ts) VALUES (?,?,?,?,?,?,?,?)
		ON CONFLICT(hash) DO UPDATE SET favorite=MAX(stickers.favorite, excluded.favorite), wa_key=excluded.wa_key, path=excluded.path`,
		real, path, ref.Mime, ref.Width, ref.Height, fav, key, ts)
	stickersChanged()
	return nil
}

// refetchFavoriteStickers asks the phone again for the collection Favorites live in
// (regular_low): its version is reset so the recovery copy applies in full and every
// favoriteSticker entry arrives again. Full syncs of it fail verification here.
func (a *App) refetchFavoriteStickers() {
	if err := a.cli.Store.AppState.DeleteAppStateVersion(a.ctx, string(appstate.WAPatchRegularLow)); err != nil {
		a.log.Warnf("refetch stickers: %v", err)
		return
	}
	a.db.Exec(`DELETE FROM kv WHERE k=?`, "appstate_recovery_"+string(appstate.WAPatchRegularLow))
	a.recoverAppState(appstate.WAPatchRegularLow)
}

// resyncStickersOnce re-reads app state once so Favorites made on the phone before
// this build arrive (full syncs emit every mutation; see EmitAppStateEventsOnFullSync).
func (a *App) resyncStickersOnce() {
	const key = "appstate_resync_stickers_v1"
	var v string
	if a.rdb.QueryRow(`SELECT v FROM kv WHERE k=?`, key).Scan(&v) == nil {
		return
	}
	// Once, whatever happens: a collection that fails verification is recovered from
	// the phone instead (see recoverAppState), not fully re-fetched on every launch.
	a.db.Exec(`INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO NOTHING`, key, itoa(int(time.Now().Unix())))
	for _, name := range []appstate.WAPatchName{appstate.WAPatchRegularLow, appstate.WAPatchRegularHigh, appstate.WAPatchRegular} {
		if err := a.cli.FetchAppState(a.ctx, name, true, false); err != nil {
			a.log.Warnf("sticker resync %s: %v", name, err)
		}
	}
	a.log.Infof("app state resync: favourite stickers re-read")
}

// refetchStickersOnce runs refetchFavoriteStickers once: the first recovery's
// Favorites were dropped by an older build when their downloads failed.
func (a *App) refetchStickersOnce() {
	const key = "appstate_refetch_stickers_v2"
	var v string
	if a.rdb.QueryRow(`SELECT v FROM kv WHERE k=?`, key).Scan(&v) == nil {
		return
	}
	a.db.Exec(`INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO NOTHING`, key, itoa(int(time.Now().Unix())))
	a.refetchFavoriteStickers()
}

// recoverAppState asks the phone for a fresh copy of a collection that failed
// verification ("mismatching LTHash"), as WhatsApp's own companions do. The answer
// is applied by whatsmeow and arrives as ordinary app state events. At most every
// six hours per collection.
func (a *App) recoverAppState(name appstate.WAPatchName) {
	key := "appstate_recovery_" + string(name)
	var last string
	if a.rdb.QueryRow(`SELECT v FROM kv WHERE k=?`, key).Scan(&last) == nil {
		if t, err := strconv.ParseInt(last, 10, 64); err == nil && time.Since(time.Unix(t, 0)) < 6*time.Hour {
			return
		}
	}
	a.db.Exec(`INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`, key, itoa(int(time.Now().Unix())))
	if _, err := a.cli.SendPeerMessage(a.ctx, whatsmeow.BuildAppStateRecoveryRequest(name)); err != nil {
		a.log.Warnf("app state recovery %s: %v", name, err)
		return
	}
	a.log.Infof("app state %s failed verification; asked the phone for a fresh copy", name)
}
