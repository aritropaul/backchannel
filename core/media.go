package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
)

var mediaTypes = map[string]whatsmeow.MediaType{
	"image":    whatsmeow.MediaImage,
	"video":    whatsmeow.MediaVideo,
	"audio":    whatsmeow.MediaAudio,
	"document": whatsmeow.MediaDocument,
}

var extForMime = map[string]string{
	"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif",
	"video/mp4": ".mp4", "video/quicktime": ".mov", "audio/ogg": ".ogg", "audio/mpeg": ".mp3",
	"audio/mp4": ".m4a", "audio/aac": ".aac", "application/pdf": ".pdf",
}

func safeName(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '/' || r == ':' || r == '\\' || r == 0 {
			return '_'
		}
		return r
	}, s)
}

// download fetches an attachment once and records its local path; the UI
// picks it up from the row on the next refresh.
func (a *App) download(chat, id string) {
	key := chat + "/" + id
	if _, busy := a.media.LoadOrStore(key, true); busy {
		return
	}
	defer a.media.Delete(key)
	if a.ready() != nil {
		return
	}
	var media, mime, fileName, existing string
	if err := a.rdb.QueryRow(`SELECT media, mime, file_name, media_path FROM messages WHERE chat=? AND id=?`, chat, id).
		Scan(&media, &mime, &fileName, &existing); err != nil || media == "" {
		return
	}
	if existing != "" {
		if _, err := os.Stat(existing); err == nil {
			return
		}
	}
	var ref mediaRef
	if json.Unmarshal([]byte(media), &ref) != nil {
		return
	}
	mk, _ := base64.StdEncoding.DecodeString(ref.MediaKey)
	fh, _ := base64.StdEncoding.DecodeString(ref.FileSHA)
	eh, _ := base64.StdEncoding.DecodeString(ref.FileEncSHA)
	ext := extForMime[strings.Split(mime, ";")[0]]
	if ext == "" {
		ext = filepath.Ext(fileName)
	}
	path := filepath.Join(a.dir, "media", safeName(id)+ext)
	f, err := os.Create(path)
	if err != nil {
		return
	}
	err = a.cli.DownloadMediaWithPathToFile(a.ctx, ref.DirectPath, eh, fh, mk, mediaTypes[ref.Type], "", false, f)
	f.Close()
	if err != nil {
		os.Remove(path)
		a.log.Errorf("download %s: %v", key, err)
		status := "failed"
		if errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) || errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410) ||
			strings.Contains(err.Error(), "status code 403") {
			status = "expired"
		}
		emit(map[string]any{"t": "media", "chat": chat, "id": id, "status": status})
		return
	}
	a.db.Exec(`UPDATE messages SET media_path=? WHERE chat=? AND id=?`, path, chat, id)
	a.touchMsg(chat, id)
}

// ---- avatars: fetched lazily for visible rows, one at a time, cached on disk ----

func (a *App) requestAvatar(chat string) {
	if _, seen := a.avatarSeen.LoadOrStore(chat, true); seen {
		return
	}
	select {
	case a.avatarQ <- chat:
	default:
		a.avatarSeen.Delete(chat)
	}
}

func (a *App) avatarLoop() {
	for chat := range a.avatarQ {
		if a.ready() != nil {
			a.avatarSeen.Delete(chat)
			time.Sleep(time.Second)
			continue
		}
		a.fetchAvatar(chat)
		time.Sleep(150 * time.Millisecond) // stay well under IQ rate limits
	}
}

func (a *App) fetchAvatar(chat string) {
	j, err := types.ParseJID(chat)
	if err != nil {
		return
	}
	var cur string
	var ts int64
	a.rdb.QueryRow(`SELECT avatar, avatar_ts FROM chats WHERE jid=?`, chat).Scan(&cur, &ts)
	if cur != "" && time.Since(time.Unix(ts, 0)) < 24*time.Hour {
		if cur == "-" {
			return
		}
		if _, err := os.Stat(cur); err == nil {
			return
		}
	}
	info, err := a.cli.GetProfilePictureInfo(a.ctx, j, &whatsmeow.GetProfilePictureParams{Preview: true})
	if err != nil || info == nil || info.URL == "" {
		switch {
		case errors.Is(err, whatsmeow.ErrProfilePictureNotSet), errors.Is(err, whatsmeow.ErrProfilePictureUnauthorized), err == nil:
			a.setAvatar(chat, "-")
		case errors.Is(err, whatsmeow.ErrIQRateOverLimit):
			a.log.Warnf("avatar %s: rate limited, backing off", chat)
			a.avatarSeen.Delete(chat)
			time.Sleep(5 * time.Second)
		default:
			a.log.Warnf("avatar %s: %v", chat, err)
			a.avatarSeen.Delete(chat)
		}
		return
	}
	resp, err := http.Get(info.URL)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return
	}
	path := filepath.Join(a.dir, "avatars", safeName(chat)+"-"+safeName(info.ID)+".jpg")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return
	}
	if cur != "" && cur != "-" && cur != path {
		os.Remove(cur)
	}
	a.setAvatar(chat, path)
	emit(map[string]any{"t": "avatar", "chat": chat, "path": path})
}

// fullPicture fetches (and caches) the full-size profile picture for the profile panel.
func (a *App) fullPicture(j types.JID) string {
	info, err := a.cli.GetProfilePictureInfo(a.ctx, j, &whatsmeow.GetProfilePictureParams{Preview: false})
	if err != nil || info == nil || info.URL == "" {
		return ""
	}
	path := filepath.Join(a.dir, "avatars", "full-"+safeName(j.String())+"-"+safeName(info.ID)+".jpg")
	if _, err := os.Stat(path); err == nil {
		return path
	}
	resp, err := http.Get(info.URL)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil || resp.StatusCode != http.StatusOK {
		return ""
	}
	if os.WriteFile(path, data, 0o600) != nil {
		return ""
	}
	return path
}

// setAvatar records a picture (or "-" for none) for any JID: chats and group senders.
func (a *App) setAvatar(jid, path string) {
	now := time.Now().Unix()
	a.db.Exec(`INSERT INTO avatars (jid, path, ts) VALUES (?,?,?) ON CONFLICT(jid) DO UPDATE SET path=excluded.path, ts=excluded.ts`, jid, path, now)
	a.db.Exec(`UPDATE chats SET avatar=?, avatar_ts=? WHERE jid=?`, path, now, jid)
	a.touchChats()
}
