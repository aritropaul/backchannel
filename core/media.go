package main

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/util/hkdfutil"
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
func (a *App) download(chat, id string) { a.downloadMedia(chat, id, false) }

// downloadMedia downloads; with retry, media the server no longer has (old
// history) is asked for again from the phone, as WhatsApp's companions do.
func (a *App) downloadMedia(chat, id string, retry bool) {
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
			if retry && a.requestMediaRetry(chat, id, mk) {
				status = "retrying"
			}
		}
		emit(map[string]any{"t": "media", "chat": chat, "id": id, "status": status})
		return
	}
	a.db.Exec(`UPDATE messages SET media_path=? WHERE chat=? AND id=?`, path, chat, id)
	a.touchMsg(chat, id)
	emit(map[string]any{"t": "media", "chat": chat, "id": id, "status": "downloaded"})
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

// fetchThumb downloads the small separate thumbnail of an image or video that
// arrived without an inline JPEGThumbnail, and a document's first-page preview (sharper
// than the tiny inline one, so it replaces it). The UI asks for visible rows.
func (a *App) fetchThumb(chat, id string) {
	key := chat + "/" + id
	if _, seen := a.thumbAsked.LoadOrStore(key, true); seen || a.ready() != nil {
		if a.ready() != nil {
			a.thumbAsked.Delete(key)
		}
		return
	}
	var media string
	var has int
	if a.rdb.QueryRow(`SELECT media, thumb IS NOT NULL FROM messages WHERE chat=? AND id=?`, chat, id).Scan(&media, &has) != nil ||
		media == "" {
		return
	}
	var ref mediaRef
	if json.Unmarshal([]byte(media), &ref) != nil || ref.ThumbPath == "" || (has == 1 && ref.Type != "document") {
		if ref.ThumbPath == "" {
			a.thumbAsked.Delete(key) // a later backfill may bring the thumbnail path
		}
		return
	}
	mk, _ := base64.StdEncoding.DecodeString(ref.MediaKey)
	sha, _ := base64.StdEncoding.DecodeString(ref.ThumbSHA)
	esha, _ := base64.StdEncoding.DecodeString(ref.ThumbEncSHA)
	if ref.Type == "document" {
		// whatsmeow only knows link-preview thumbnails; a document's has its own keys and path.
		data, err := a.cli.DownloadMediaWithPath(a.ctx, ref.ThumbPath, esha, sha, mk,
			whatsmeow.MediaType("WhatsApp Document Thumbnail Keys"), "thumbnail-document", false)
		if err != nil || len(data) == 0 {
			a.log.Warnf("document thumbnail %s: %v", key, err)
			return
		}
		// Done for good: drop the path so later launches don't fetch it again.
		ref.ThumbPath, ref.ThumbSHA, ref.ThumbEncSHA = "", "", ""
		b, _ := json.Marshal(ref)
		a.db.Exec(`UPDATE messages SET thumb=?, media=? WHERE chat=? AND id=?`, data, string(b), chat, id)
		a.touchMsg(chat, id)
		return
	}
	var msg whatsmeow.DownloadableThumbnail
	switch ref.Type {
	case "image":
		msg = &waE2E.ImageMessage{ThumbnailDirectPath: proto.String(ref.ThumbPath), ThumbnailSHA256: sha, ThumbnailEncSHA256: esha, MediaKey: mk}
	case "video":
		msg = &waE2E.VideoMessage{ThumbnailDirectPath: proto.String(ref.ThumbPath), ThumbnailSHA256: sha, ThumbnailEncSHA256: esha, MediaKey: mk}
	default:
		return
	}
	data, err := a.cli.DownloadThumbnail(a.ctx, msg)
	if err != nil || len(data) == 0 {
		a.log.Warnf("thumbnail %s: %v", key, err)
		return
	}
	a.db.Exec(`UPDATE messages SET thumb=? WHERE chat=? AND id=? AND thumb IS NULL`, data, chat, id)
	a.touchMsg(chat, id)
}

// videoPrefix downloads and decrypts only the first `want` bytes of a video:
// AES-CBC decrypts any block-aligned prefix, and a faststart mp4 keeps its
// index and first keyframe up front. The UI pulls frame 1 out of it for the
// thumbnail and deletes the file; the whole video only downloads when played.
func (a *App) videoPrefix(chat, id string, want int) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	if want <= 0 || want > 4<<20 {
		want = 512 << 10
	}
	var media string
	if err := a.rdb.QueryRow(`SELECT media FROM messages WHERE chat=? AND id=? AND kind=?`, chat, id, KVideo).Scan(&media); err != nil || media == "" {
		return nil, errors.New("no video")
	}
	var ref mediaRef
	if json.Unmarshal([]byte(media), &ref) != nil || ref.DirectPath == "" {
		return nil, errors.New("bad media ref")
	}
	mk, _ := base64.StdEncoding.DecodeString(ref.MediaKey)
	eh, _ := base64.StdEncoding.DecodeString(ref.FileEncSHA)
	keys := hkdfutil.SHA256(mk, nil, []byte(whatsmeow.MediaVideo), 112)
	iv, cipherKey := keys[:16], keys[16:48]
	conn, err := a.cli.DangerousInternals().RefreshMediaConn(a.ctx, false)
	if err != nil {
		return nil, err
	}
	var lastErr error
	for _, host := range conn.Hosts {
		url := fmt.Sprintf("https://%s%s&hash=%s&mms-type=video&__wa-mms=", host.Hostname, ref.DirectPath, base64.URLEncoding.EncodeToString(eh))
		req, err := http.NewRequestWithContext(a.ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Origin", "https://web.whatsapp.com")
		req.Header.Set("Referer", "https://web.whatsapp.com/")
		req.Header.Set("Range", fmt.Sprintf("bytes=0-%d", want-1))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		data, err := io.ReadAll(io.LimitReader(resp.Body, int64(want)))
		resp.Body.Close()
		if resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone || resp.StatusCode == http.StatusForbidden {
			return nil, fmt.Errorf("expired (%d)", resp.StatusCode)
		}
		if (resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent) || err != nil {
			lastErr = fmt.Errorf("status %d: %v", resp.StatusCode, err)
			continue
		}
		whole := resp.StatusCode == http.StatusOK || int64(len(data)) < int64(want)
		if whole && len(data) > 10 {
			data = data[:len(data)-10] // the whole file came back: drop the trailing MAC
		}
		data = data[:len(data)/aes.BlockSize*aes.BlockSize]
		if len(data) == 0 {
			return nil, errors.New("empty")
		}
		block, err := aes.NewCipher(cipherKey)
		if err != nil {
			return nil, err
		}
		plain := make([]byte, len(data))
		cipher.NewCBCDecrypter(block, iv).CryptBlocks(plain, data)
		path := filepath.Join(a.dir, "media", safeName(id)+".prefix.mp4")
		if err := os.WriteFile(path, plain, 0o600); err != nil {
			return nil, err
		}
		return map[string]any{"path": path}, nil
	}
	return nil, fmt.Errorf("video prefix %s: %v", id, lastErr)
}

// setThumb stores a thumbnail the app made (a video's first frame).
func (a *App) setThumb(chat, id, b64 string) error {
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(data) == 0 {
		return errors.New("bad thumbnail")
	}
	a.db.Exec(`UPDATE messages SET thumb=? WHERE chat=? AND id=? AND thumb IS NULL`, data, chat, id)
	a.touchMsg(chat, id)
	return nil
}
