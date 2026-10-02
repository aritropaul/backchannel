package main

// Media the server has dropped (old history) can still be on the phone: a media
// retry receipt asks it to upload the file again, and the answer carries a new
// path to download from.

import (
	"encoding/base64"
	"encoding/json"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waMmsRetry"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// requestMediaRetry asks the phone to re-upload one message's media, once per run.
func (a *App) requestMediaRetry(chat, id string, mediaKey []byte) bool {
	if _, asked := a.retried.LoadOrStore(chat+"/"+id, true); asked {
		return false
	}
	var sender string
	var fromMe int
	if a.rdb.QueryRow(`SELECT sender, from_me FROM messages WHERE chat=? AND id=?`, chat, id).Scan(&sender, &fromMe) != nil {
		return false
	}
	cj, err := types.ParseJID(chat)
	if err != nil {
		return false
	}
	sj, _ := types.ParseJID(sender)
	if fromMe == 1 || sj.IsEmpty() {
		sj = a.me()
	}
	info := &types.MessageInfo{
		MessageSource: types.MessageSource{Chat: cj, Sender: sj, IsFromMe: fromMe == 1, IsGroup: cj.Server == types.GroupServer},
		ID:            id,
	}
	if err := a.cli.SendMediaRetryReceipt(a.ctx, info, mediaKey); err != nil {
		a.log.Warnf("media retry %s/%s: %v", chat, id, err)
		return false
	}
	a.log.Infof("media retry %s/%s: asked the phone to re-upload", chat, id)
	return true
}

// onMediaRetry takes the phone's answer: a new path to download from, or a no.
func (a *App) onMediaRetry(e *events.MediaRetry) {
	chat := a.canon(e.ChatID).String()
	var media string
	if a.rdb.QueryRow(`SELECT media FROM messages WHERE chat=? AND id=?`, chat, e.MessageID).Scan(&media) != nil || media == "" {
		return
	}
	var ref mediaRef
	if json.Unmarshal([]byte(media), &ref) != nil {
		return
	}
	mk, _ := base64.StdEncoding.DecodeString(ref.MediaKey)
	notif, err := whatsmeow.DecryptMediaRetryNotification(e, mk)
	if err != nil || notif.GetResult() != waMmsRetry.MediaRetryNotification_SUCCESS || notif.GetDirectPath() == "" {
		a.log.Warnf("media retry %s/%s: phone couldn't re-upload (%v, %v)", chat, e.MessageID, notif.GetResult(), err)
		emit(map[string]any{"t": "media", "chat": chat, "id": e.MessageID, "status": "expired"})
		return
	}
	ref.DirectPath = notif.GetDirectPath()
	b, _ := json.Marshal(ref)
	a.db.Exec(`UPDATE messages SET media=? WHERE chat=? AND id=?`, string(b), chat, e.MessageID)
	go a.downloadMedia(chat, e.MessageID, false)
}
