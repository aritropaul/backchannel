package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
)

// req is the single command envelope Swift sends through WACall.
type req struct {
	Op        string `json:"op"`
	Chat      string `json:"chat"`
	ID        string `json:"id"`
	Text      string `json:"text"`
	Quote     string `json:"quote"`
	Emoji     string `json:"emoji"`
	On        bool   `json:"on"`
	Hours     int    `json:"hours"`
	Path      string `json:"path"`
	Thumb     string `json:"thumb"`
	Width     int    `json:"width"`
	Height    int    `json:"height"`
	Mime      string `json:"mime"`
	Active    bool   `json:"active"`
	Dir       string `json:"dir"`
	Phone     string `json:"phone"`
	Seconds   int    `json:"seconds"`
	Wave      string `json:"waveform"` // base64, 64 bytes
	LinkURL   string `json:"link_url"`
	LinkTitle string `json:"link_title"`
	LinkDesc  string `json:"link_desc"`
	Name      string `json:"name"`  // file name shown to the recipient
	Bytes     int    `json:"bytes"` // video_prefix: how much of the file to fetch
}

func call(raw []byte) (out any) {
	var r req
	if err := json.Unmarshal(raw, &r); err != nil {
		return map[string]any{"error": err.Error()}
	}
	a := app
	if a == nil {
		return map[string]any{"error": "not started"}
	}
	defer func() {
		if p := recover(); p != nil {
			out = map[string]any{"error": fmt.Sprint("panic: ", p)}
		}
	}()
	var res any
	var err error
	switch r.Op {
	case "send_text":
		res, err = a.sendText(r)
	case "send_voice":
		res, err = a.sendVoice(r)
	case "resolve":
		res, err = a.resolve(r.Phone)
	case "profile":
		res, err = a.profile(r.Chat)
	case "send_image":
		res, err = a.sendImage(r)
	case "send_file":
		res, err = a.sendFile(r)
	case "backfill":
		go a.backfill(r.Chat)
	case "thumb":
		go a.fetchThumb(r.Chat, r.ID)
	case "video_prefix":
		res, err = a.videoPrefix(r.Chat, r.ID, r.Bytes)
	case "set_thumb":
		err = a.setThumb(r.Chat, r.ID, r.Thumb)
	case "set_waveform":
		err = a.setWaveform(r.Chat, r.ID, r.Wave)
	case "react":
		err = a.react(r.Chat, r.ID, r.Emoji)
	case "edit":
		err = a.edit(r.Chat, r.ID, r.Text)
	case "revoke":
		err = a.revoke(r.Chat, r.ID)
	case "retry":
		err = a.retry(r.Chat, r.ID)
	case "mark_read":
		go a.markRead(r.Chat)
	case "mark_unread":
		go a.markUnread(r.Chat)
	case "focus":
		a.focus(r.Chat, r.Active)
	case "typing":
		go a.typing(r.Chat, r.On)
	case "pin":
		go a.appState(r.Chat, "pin", r.On, 0)
	case "archive":
		go a.appState(r.Chat, "archive", r.On, 0)
	case "mute":
		go a.appState(r.Chat, "mute", r.On, r.Hours)
	case "download":
		go a.download(r.Chat, r.ID)
	case "avatar":
		a.requestAvatar(r.Chat)
	case "older":
		go a.requestOlder(r.Chat)
	case "subscribe":
		go a.subscribe(r.Chat)
	case "pair_phone":
		res, err = a.pairPhone(r.Phone)
	case "repair":
		a.restartPairing()
	case "logout":
		go func() {
			if a.cli != nil {
				a.cli.Logout(a.ctx)
			}
		}()
	default:
		err = errors.New("unknown op " + r.Op)
	}
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	if res == nil {
		return map[string]any{"ok": true}
	}
	return res
}

func (a *App) ready() error {
	if a.cli == nil || !a.cli.IsLoggedIn() {
		return errors.New("not connected")
	}
	return nil
}

func parseChat(s string) (types.JID, error) {
	j, err := types.ParseJID(s)
	if err != nil || j.IsEmpty() {
		return types.EmptyJID, fmt.Errorf("bad chat %q", s)
	}
	return j, nil
}

// quoteContext builds reply context from our stored row.
func (a *App) quoteContext(chat types.JID, quoteID string) *waE2E.ContextInfo {
	if quoteID == "" {
		return nil
	}
	var sender, text string
	var fromMe, kind int
	err := a.rdb.QueryRow(`SELECT sender, from_me, text, kind FROM messages WHERE chat=? AND id=?`, chat.String(), quoteID).
		Scan(&sender, &fromMe, &text, &kind)
	if err != nil {
		return nil
	}
	participant := sender
	if fromMe == 1 {
		participant = a.me().String()
	}
	if text == "" {
		text = previewText(&msgRow{Kind: kind})
	}
	return &waE2E.ContextInfo{
		StanzaID:      proto.String(quoteID),
		Participant:   proto.String(participant),
		QuotedMessage: &waE2E.Message{Conversation: proto.String(text)},
	}
}

func (a *App) sendText(q req) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	chat, err := parseChat(q.Chat)
	if err != nil {
		return nil, err
	}
	text := strings.TrimRight(q.Text, " \n\t")
	quote := q.Quote
	if text == "" {
		return nil, errors.New("empty")
	}
	msg := &waE2E.Message{}
	ci := a.quoteContext(chat, quote)
	var thumb []byte
	if q.Thumb != "" {
		thumb, _ = os.ReadFile(q.Thumb)
	}
	if ci != nil || q.LinkTitle != "" {
		ext := &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: ci}
		if q.LinkTitle != "" {
			ext.MatchedText = proto.String(q.LinkURL)
			ext.Title = proto.String(q.LinkTitle)
			if q.LinkDesc != "" {
				ext.Description = proto.String(q.LinkDesc)
			}
			if len(thumb) > 0 {
				ext.JPEGThumbnail = thumb
			}
		}
		msg.ExtendedTextMessage = ext
	} else {
		msg.Conversation = proto.String(text)
	}
	id := a.cli.GenerateMessageID()
	r := &msgRow{Chat: chat.String(), ID: id, Sender: a.me().String(), FromMe: true,
		TS: time.Now().UnixMilli(), Kind: KText, Text: text, Status: StPending,
		LinkURL: q.LinkURL, LinkTitle: q.LinkTitle, LinkDesc: q.LinkDesc}
	if q.LinkTitle != "" {
		r.Thumb = thumb
	}
	if ci != nil {
		r.QuoteID, r.QuoteSender = quote, ci.GetParticipant()
		var q msgRow
		a.rdb.QueryRow(`SELECT text, kind FROM messages WHERE chat=? AND id=?`, chat.String(), quote).Scan(&q.Text, &q.Kind)
		r.QuoteText, r.QuoteKind = q.Text, q.Kind
	}
	a.localEcho(r, chat)
	go a.deliver(chat, id, msg)
	return map[string]any{"id": id}, nil
}

// localEcho writes the outgoing row before the network round-trip so the
// bubble appears on the very next frame.
func (a *App) localEcho(r *msgRow, chat types.JID) {
	upsertMessage(a.db, r)
	bumpChat(a.db, r.Chat, chat.Server == types.GroupServer, r.TS, r.ID)
	a.db.Exec(`UPDATE chats SET unread=0, marked_unread=0, archived=0 WHERE jid=?`, r.Chat)
	a.touchMsg(r.Chat, r.ID)
	a.flush()
}

func (a *App) deliver(chat types.JID, id string, msg *waE2E.Message) {
	_, err := a.cli.SendMessage(a.ctx, chat, msg, whatsmeow.SendRequestExtra{ID: id})
	st := StSent
	if err != nil {
		a.log.Errorf("send %s: %v", id, err)
		st = StFailed
		a.db.Exec(`UPDATE messages SET status=? WHERE chat=? AND id=?`, st, chat.String(), id)
	} else {
		a.db.Exec(`UPDATE messages SET status=MAX(status, ?) WHERE chat=? AND id=?`, st, chat.String(), id)
	}
	a.touchMsg(chat.String(), id)
}

func (a *App) retry(chatS, id string) error {
	if err := a.ready(); err != nil {
		return err
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return err
	}
	var text string
	var kind, status int
	if err := a.rdb.QueryRow(`SELECT text, kind, status FROM messages WHERE chat=? AND id=? AND from_me=1`, chatS, id).Scan(&text, &kind, &status); err != nil {
		return err
	}
	if status != StFailed || kind != KText {
		return errors.New("only failed text messages can be retried")
	}
	a.db.Exec(`UPDATE messages SET status=? WHERE chat=? AND id=?`, StPending, chatS, id)
	a.touchMsg(chatS, id)
	go a.deliver(chat, id, &waE2E.Message{Conversation: proto.String(text)})
	return nil
}

func (a *App) senderOf(chat types.JID, id string) (types.JID, bool, error) {
	var sender string
	var fromMe int
	if err := a.rdb.QueryRow(`SELECT sender, from_me FROM messages WHERE chat=? AND id=?`, chat.String(), id).Scan(&sender, &fromMe); err != nil {
		return types.EmptyJID, false, err
	}
	if fromMe == 1 {
		return types.EmptyJID, true, nil
	}
	j, err := types.ParseJID(sender)
	return j, false, err
}

func (a *App) react(chatS, id, emoji string) error {
	if err := a.ready(); err != nil {
		return err
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return err
	}
	sender, _, err := a.senderOf(chat, id)
	if err != nil {
		return err
	}
	a.onReaction(chat.String(), id, a.me().String(), emoji, time.Now().UnixMilli())
	a.flush()
	go a.cli.SendMessage(a.ctx, chat, a.cli.BuildReaction(chat, sender, id, emoji))
	return nil
}

func (a *App) edit(chatS, id, text string) error {
	if err := a.ready(); err != nil {
		return err
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return err
	}
	if _, fromMe, err := a.senderOf(chat, id); err != nil || !fromMe {
		return errors.New("can only edit your own messages")
	}
	a.db.Exec(`UPDATE messages SET text=?, edited=1 WHERE chat=? AND id=?`, text, chatS, id)
	a.touchMsg(chatS, id)
	a.flush()
	go a.cli.SendMessage(a.ctx, chat, a.cli.BuildEdit(chat, id, &waE2E.Message{Conversation: proto.String(text)}))
	return nil
}

func (a *App) revoke(chatS, id string) error {
	if err := a.ready(); err != nil {
		return err
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return err
	}
	sender, fromMe, err := a.senderOf(chat, id)
	if err != nil {
		return err
	}
	if fromMe {
		sender = types.EmptyJID
	}
	a.db.Exec(`UPDATE messages SET kind=?, text='', media='', thumb=NULL, reactions='' WHERE chat=? AND id=?`, KRevoked, chatS, id)
	a.touchMsg(chatS, id)
	a.flush()
	go a.cli.SendMessage(a.ctx, chat, a.cli.BuildRevoke(chat, sender, id))
	return nil
}

// markRead sends read receipts for everything unread in the chat, newest
// first, grouped by sender as the protocol requires for groups.
func (a *App) markRead(chatS string) {
	chat, err := parseChat(chatS)
	if err != nil || a.ready() != nil {
		return
	}
	var unread, marked int
	a.rdb.QueryRow(`SELECT unread, marked_unread FROM chats WHERE jid=?`, chatS).Scan(&unread, &marked)
	a.db.Exec(`UPDATE chats SET unread=0, marked_unread=0 WHERE jid=?`, chatS)
	a.touchChats()
	if unread > 0 {
		n := unread
		if n > 100 {
			n = 100
		}
		rows, err := a.rdb.Query(`SELECT id, sender FROM messages WHERE chat=? AND from_me=0 ORDER BY ts DESC LIMIT ?`, chatS, n)
		if err == nil {
			bySender := map[string][]types.MessageID{}
			for rows.Next() {
				var id, s string
				if rows.Scan(&id, &s) == nil {
					bySender[s] = append(bySender[s], id)
				}
			}
			rows.Close()
			for s, ids := range bySender {
				sj, _ := types.ParseJID(s)
				if chat.Server != types.GroupServer {
					sj = types.EmptyJID
				}
				a.cli.MarkRead(a.ctx, ids, time.Now(), chat, sj)
			}
		}
	}
	if marked == 1 {
		ts, key := a.lastKey(chat)
		a.cli.SendAppState(a.ctx, appstate.BuildMarkChatAsRead(chat, true, ts, key))
	}
}

func (a *App) markUnread(chatS string) {
	chat, err := parseChat(chatS)
	if err != nil || a.ready() != nil {
		return
	}
	a.db.Exec(`UPDATE chats SET marked_unread=1 WHERE jid=?`, chatS)
	a.touchChats()
	ts, key := a.lastKey(chat)
	a.cli.SendAppState(a.ctx, appstate.BuildMarkChatAsRead(chat, false, ts, key))
}

func (a *App) lastKey(chat types.JID) (time.Time, *waCommon.MessageKey) {
	var id, sender string
	var ts int64
	var fromMe int
	err := a.rdb.QueryRow(`SELECT id, sender, from_me, ts FROM messages WHERE chat=? ORDER BY ts DESC LIMIT 1`, chat.String()).
		Scan(&id, &sender, &fromMe, &ts)
	if err != nil {
		return time.Now(), nil
	}
	sj, _ := types.ParseJID(sender)
	if fromMe == 1 {
		sj = a.me()
	}
	return time.UnixMilli(ts), a.cli.BuildMessageKey(chat, sj, id)
}

func (a *App) appState(chatS, what string, on bool, hours int) {
	chat, err := parseChat(chatS)
	if err != nil || a.ready() != nil {
		return
	}
	var patch appstate.PatchInfo
	switch what {
	case "pin":
		v := int64(0)
		if on {
			v = time.Now().Unix()
		}
		a.db.Exec(`UPDATE chats SET pinned=? WHERE jid=?`, v, chatS)
		patch = appstate.BuildPin(chat, on)
	case "archive":
		a.db.Exec(`UPDATE chats SET archived=? WHERE jid=?`, b2i(on), chatS)
		if on {
			a.db.Exec(`UPDATE chats SET pinned=0 WHERE jid=?`, chatS)
		}
		ts, key := a.lastKey(chat)
		patch = appstate.BuildArchive(chat, on, ts, key)
	case "mute":
		var d time.Duration
		until := int64(0)
		if on {
			if hours <= 0 {
				until = -1
				d = 0
			} else {
				d = time.Duration(hours) * time.Hour
				until = time.Now().Add(d).Unix()
			}
		}
		a.db.Exec(`UPDATE chats SET muted_until=? WHERE jid=?`, until, chatS)
		if on && hours <= 0 {
			forever := int64(-1)
			patch = appstate.BuildMuteAbs(chat, true, &forever)
		} else {
			patch = appstate.BuildMute(chat, on, d)
		}
	}
	a.touchChats()
	if err := a.cli.SendAppState(a.ctx, patch); err != nil {
		a.log.Errorf("app state %s %s: %v", what, chatS, err)
	}
}

func (a *App) focus(chat string, active bool) {
	prevActive := a.appActive.Swap(active)
	a.activeChat.Store(chat)
	if a.cli == nil || !a.cli.IsLoggedIn() {
		return
	}
	if prevActive != active {
		// Like WhatsApp Web: online while focused, so the phone stays quiet
		// and typing indicators flow; offline otherwise.
		go func() {
			if active {
				a.cli.SendPresence(a.ctx, types.PresenceAvailable)
			} else {
				a.cli.SendPresence(a.ctx, types.PresenceUnavailable)
			}
		}()
	}
}

func (a *App) typing(chatS string, on bool) {
	chat, err := parseChat(chatS)
	if err != nil || a.ready() != nil {
		return
	}
	state := types.ChatPresencePaused
	if on {
		state = types.ChatPresenceComposing
	}
	a.cli.SendChatPresence(a.ctx, chat, state, types.ChatPresenceMediaText)
}

func (a *App) subscribe(chatS string) {
	chat, err := parseChat(chatS)
	if err != nil || a.ready() != nil || chat.Server == types.GroupServer {
		return
	}
	a.cli.SubscribePresence(a.ctx, chat)
}

func (a *App) requestOlder(chatS string) {
	chat, err := parseChat(chatS)
	if err != nil || a.ready() != nil {
		return
	}
	if t, ok := a.olderAsked.Load(chatS); ok && time.Since(t.(time.Time)) < 15*time.Second {
		return
	}
	a.olderAsked.Store(chatS, time.Now())
	var id, sender string
	var ts int64
	var fromMe int
	err = a.rdb.QueryRow(`SELECT id, sender, from_me, ts FROM messages WHERE chat=? AND kind != ? ORDER BY ts ASC LIMIT 1`, chatS, KPending).
		Scan(&id, &sender, &fromMe, &ts)
	if err != nil {
		return
	}
	sj, _ := types.ParseJID(sender)
	info := &types.MessageInfo{
		MessageSource: types.MessageSource{Chat: chat, Sender: sj, IsFromMe: fromMe == 1, IsGroup: chat.Server == types.GroupServer},
		ID:            id,
		Timestamp:     time.UnixMilli(ts),
	}
	if _, err := a.cli.SendPeerMessage(a.ctx, a.cli.BuildHistorySyncRequest(info, 50)); err != nil {
		a.log.Errorf("older %s: %v", chatS, err)
	}
}

// sendVoice uploads an Ogg Opus voice note recorded by the app.
func (a *App) sendVoice(q req) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	chat, err := parseChat(q.Chat)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(q.Path)
	if err != nil {
		return nil, err
	}
	wave, _ := base64.StdEncoding.DecodeString(q.Wave)
	id := a.cli.GenerateMessageID()
	local := filepath.Join(a.dir, "media", safeName(id)+".ogg")
	os.WriteFile(local, data, 0o600)
	const mime = "audio/ogg; codecs=opus"
	row := &msgRow{Chat: chat.String(), ID: id, Sender: a.me().String(), FromMe: true, TS: time.Now().UnixMilli(),
		Kind: KVoice, Status: StPending, Mime: mime, Seconds: q.Seconds, FileSize: int64(len(data)),
		MediaPath: local, Waveform: wave}
	ci := a.quoteContext(chat, q.Quote)
	if ci != nil {
		row.QuoteID, row.QuoteSender = q.Quote, ci.GetParticipant()
		a.rdb.QueryRow(`SELECT text, kind FROM messages WHERE chat=? AND id=?`, chat.String(), q.Quote).Scan(&row.QuoteText, &row.QuoteKind)
	}
	a.localEcho(row, chat)
	go func() {
		up, err := a.cli.Upload(a.ctx, data, whatsmeow.MediaAudio)
		if err != nil {
			a.log.Errorf("upload voice %s: %v", id, err)
			a.db.Exec(`UPDATE messages SET status=? WHERE chat=? AND id=?`, StFailed, chat.String(), id)
			a.touchMsg(chat.String(), id)
			return
		}
		au := &waE2E.AudioMessage{
			Mimetype:      proto.String(mime),
			URL:           proto.String(up.URL),
			DirectPath:    proto.String(up.DirectPath),
			MediaKey:      up.MediaKey,
			FileEncSHA256: up.FileEncSHA256,
			FileSHA256:    up.FileSHA256,
			FileLength:    proto.Uint64(up.FileLength),
			Seconds:       proto.Uint32(uint32(q.Seconds)),
			PTT:           proto.Bool(true),
			ContextInfo:   ci,
		}
		if len(wave) > 0 {
			au.Waveform = wave
		}
		a.db.Exec(`UPDATE messages SET media=? WHERE chat=? AND id=?`, refFor(au, "audio"), chat.String(), id)
		a.deliver(chat, id, &waE2E.Message{AudioMessage: au})
	}()
	return map[string]any{"id": id}, nil
}

// resolve finds the WhatsApp account for a phone number and makes sure a chat
// row exists so the UI can open it before the first message.
func (a *App) resolve(phone string) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	digits := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, phone)
	if len(digits) < 6 {
		return nil, errors.New("enter a full number with country code")
	}
	res, err := a.cli.IsOnWhatsApp(a.ctx, []string{"+" + digits})
	if err != nil {
		return nil, err
	}
	if len(res) == 0 || !res[0].IsIn {
		return nil, errors.New("this number isn't on WhatsApp")
	}
	jid := a.canon(res[0].JID).String()
	a.db.Exec(`INSERT INTO chats (jid, last_ts) VALUES (?,?) ON CONFLICT(jid) DO UPDATE SET last_ts=MAX(chats.last_ts, 1)`,
		jid, time.Now().UnixMilli())
	a.touchChats()
	a.flush()
	return map[string]any{"jid": jid}, nil
}

// profile gathers what the profile panel shows. Network-bound: Swift calls it
// off the main thread.
func (a *App) profile(chatS string) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	j, err := parseChat(chatS)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"jid": j.String(), "name": a.nameFor(j)}
	if j.Server == types.GroupServer {
		g, err := a.cli.GetGroupInfo(a.ctx, j)
		if err != nil {
			return nil, err
		}
		out["name"] = g.Name
		out["topic"] = g.Topic
		out["created"] = g.GroupCreated.UnixMilli()
		var people []map[string]any
		for _, p := range g.Participants {
			pj := a.canon(p.JID)
			if !p.PhoneNumber.IsEmpty() {
				pj = a.canon(p.PhoneNumber)
			}
			name := a.nameFor(pj)
			if pj == a.me() {
				name = "You"
			}
			people = append(people, map[string]any{"jid": pj.String(), "name": name,
				"admin": p.IsAdmin || p.IsSuperAdmin, "owner": p.IsSuperAdmin})
		}
		out["participants"] = people
		a.events <- groupSize{j.String(), len(g.Participants)}
	} else {
		if info, err := a.cli.GetUserInfo(a.ctx, []types.JID{j}); err == nil {
			for _, u := range info {
				out["about"] = u.Status
				if u.VerifiedName != nil && u.VerifiedName.Details != nil {
					out["business"] = u.VerifiedName.Details.GetVerifiedName()
				}
			}
		}
		if j.Server == types.DefaultUserServer {
			out["phone"] = "+" + j.User
		}
	}
	out["picture"] = a.fullPicture(j)
	return out, nil
}

func (a *App) pairPhone(phone string) (any, error) {
	if a.cli == nil {
		return nil, errors.New("not started")
	}
	digits := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, phone)
	code, err := a.cli.PairPhone(a.ctx, digits, true, whatsmeow.PairClientChrome, "Chrome (Mac OS)")
	if err != nil {
		return nil, err
	}
	return map[string]any{"code": code}, nil
}

func (a *App) sendImage(r req) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	chat, err := parseChat(r.Chat)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(r.Path)
	if err != nil {
		return nil, err
	}
	thumb, _ := os.ReadFile(r.Thumb)
	id := a.cli.GenerateMessageID()
	// Keep our own copy so the bubble survives the temp file going away.
	local := filepath.Join(a.dir, "media", safeName(id)+filepath.Ext(r.Path))
	os.WriteFile(local, data, 0o600)
	mime := r.Mime
	if mime == "" {
		mime = "image/jpeg"
	}
	row := &msgRow{Chat: chat.String(), ID: id, Sender: a.me().String(), FromMe: true, TS: time.Now().UnixMilli(),
		Kind: KImage, Text: strings.TrimSpace(r.Text), Status: StPending, Mime: mime, Width: r.Width, Height: r.Height,
		Thumb: thumb, FileSize: int64(len(data)), MediaPath: local}
	ci := a.quoteContext(chat, r.Quote)
	if ci != nil {
		row.QuoteID, row.QuoteSender = r.Quote, ci.GetParticipant()
		a.rdb.QueryRow(`SELECT text, kind FROM messages WHERE chat=? AND id=?`, chat.String(), r.Quote).Scan(&row.QuoteText, &row.QuoteKind)
	}
	a.localEcho(row, chat)
	go func() {
		up, err := a.cli.Upload(a.ctx, data, whatsmeow.MediaImage)
		if err != nil {
			a.log.Errorf("upload %s: %v", id, err)
			a.db.Exec(`UPDATE messages SET status=? WHERE chat=? AND id=?`, StFailed, chat.String(), id)
			a.touchMsg(chat.String(), id)
			return
		}
		img := &waE2E.ImageMessage{
			Caption:       proto.String(row.Text),
			Mimetype:      proto.String(mime),
			URL:           proto.String(up.URL),
			DirectPath:    proto.String(up.DirectPath),
			MediaKey:      up.MediaKey,
			FileEncSHA256: up.FileEncSHA256,
			FileSHA256:    up.FileSHA256,
			FileLength:    proto.Uint64(up.FileLength),
			Width:         proto.Uint32(uint32(r.Width)),
			Height:        proto.Uint32(uint32(r.Height)),
			JPEGThumbnail: thumb,
			ContextInfo:   ci,
		}
		if row.Text == "" {
			img.Caption = nil
		}
		a.db.Exec(`UPDATE messages SET media=? WHERE chat=? AND id=?`, refFor(img, "image"), chat.String(), id)
		a.deliver(chat, id, &waE2E.Message{ImageMessage: img})
	}()
	return map[string]any{"id": id}, nil
}

// sendFile sends a video (mp4 with a thumbnail) or any other file as a document.
func (a *App) sendFile(r req) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	chat, err := parseChat(r.Chat)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(r.Path)
	if err != nil {
		return nil, err
	}
	name := r.Name
	if name == "" {
		name = filepath.Base(r.Path)
	}
	mime := r.Mime
	if mime == "" {
		mime = "application/octet-stream"
	}
	video := strings.HasPrefix(mime, "video/") && r.Thumb != ""
	var thumb []byte
	if r.Thumb != "" {
		thumb, _ = os.ReadFile(r.Thumb)
	}
	id := a.cli.GenerateMessageID()
	local := filepath.Join(a.dir, "media", safeName(id)+filepath.Ext(r.Path))
	os.WriteFile(local, data, 0o600)
	row := &msgRow{Chat: chat.String(), ID: id, Sender: a.me().String(), FromMe: true, TS: time.Now().UnixMilli(),
		Kind: KDocument, Text: strings.TrimSpace(r.Text), Status: StPending, Mime: mime, FileName: name,
		FileSize: int64(len(data)), MediaPath: local, Thumb: thumb}
	if video {
		row.Kind, row.FileName = KVideo, ""
		row.Width, row.Height, row.Seconds = r.Width, r.Height, r.Seconds
	}
	ci := a.quoteContext(chat, r.Quote)
	if ci != nil {
		row.QuoteID, row.QuoteSender = r.Quote, ci.GetParticipant()
		a.rdb.QueryRow(`SELECT text, kind FROM messages WHERE chat=? AND id=?`, chat.String(), r.Quote).Scan(&row.QuoteText, &row.QuoteKind)
	}
	a.localEcho(row, chat)
	go func() {
		mt := whatsmeow.MediaDocument
		if video {
			mt = whatsmeow.MediaVideo
		}
		up, err := a.cli.Upload(a.ctx, data, mt)
		if err != nil {
			a.log.Errorf("upload %s: %v", id, err)
			a.db.Exec(`UPDATE messages SET status=? WHERE chat=? AND id=?`, StFailed, chat.String(), id)
			a.touchMsg(chat.String(), id)
			return
		}
		var caption *string
		if row.Text != "" {
			caption = proto.String(row.Text)
		}
		msg := &waE2E.Message{}
		if video {
			v := &waE2E.VideoMessage{
				Caption: caption, Mimetype: proto.String(mime),
				URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
				FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: proto.Uint64(up.FileLength),
				Seconds: proto.Uint32(uint32(r.Seconds)), Width: proto.Uint32(uint32(r.Width)), Height: proto.Uint32(uint32(r.Height)),
				JPEGThumbnail: thumb, ContextInfo: ci,
			}
			msg.VideoMessage = v
			a.db.Exec(`UPDATE messages SET media=? WHERE chat=? AND id=?`, refFor(v, "video"), chat.String(), id)
		} else {
			d := &waE2E.DocumentMessage{
				Caption: caption, Mimetype: proto.String(mime), Title: proto.String(name), FileName: proto.String(name),
				URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
				FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: proto.Uint64(up.FileLength),
				ContextInfo: ci,
			}
			if len(thumb) > 0 {
				d.JPEGThumbnail = thumb
			}
			msg.DocumentMessage = d
			a.db.Exec(`UPDATE messages SET media=? WHERE chat=? AND id=?`, refFor(d, "document"), chat.String(), id)
		}
		a.deliver(chat, id, msg)
	}()
	return map[string]any{"id": id}, nil
}

// backfill re-requests, from the phone, history around messages imported
// before we stored link previews and voice waveforms. The phone resends the
// original messages (with the sender's own preview and waveform) and the
// upsert fills the empty columns. Once per chat per session, at most a few
// requests of 50 messages each.
func (a *App) backfill(chatS string) {
	if _, done := a.backfilled.LoadOrStore(chatS, true); done {
		return
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return
	}
	if a.ready() != nil {
		// Opened before the connection came up: run once connected.
		a.backfilled.Delete(chatS)
		a.backfillPending.Store(chatS, true)
		return
	}
	rows, err := a.rdb.Query(`SELECT ts FROM messages WHERE chat=? AND
		((kind=? AND link_title='' AND (text LIKE '%http://%' OR text LIKE '%https://%')) OR (kind=? AND waveform IS NULL))
		ORDER BY ts DESC LIMIT 300`, chatS, KText, KVoice)
	if err != nil {
		return
	}
	var gaps []int64
	for rows.Next() {
		var ts int64
		if rows.Scan(&ts) == nil {
			gaps = append(gaps, ts)
		}
	}
	rows.Close()
	covered := int64(1 << 62)
	sent := 0
	for _, ts := range gaps {
		if ts >= covered || sent >= 4 {
			continue
		}
		// Anchor on the message right after the gap: the phone answers with
		// the 50 messages before the anchor, which include the gap.
		var id, sender string
		var ats int64
		var fromMe int
		if a.rdb.QueryRow(`SELECT id, sender, from_me, ts FROM messages WHERE chat=? AND ts > ? AND kind != ? ORDER BY ts ASC LIMIT 1`,
			chatS, ts, KPending).Scan(&id, &sender, &fromMe, &ats) != nil {
			continue // the newest message: nothing after it to anchor on
		}
		var oldest int64
		a.rdb.QueryRow(`SELECT MIN(ts) FROM (SELECT ts FROM messages WHERE chat=? AND ts < ? ORDER BY ts DESC LIMIT 50)`,
			chatS, ats).Scan(&oldest)
		covered = oldest
		sj, _ := types.ParseJID(sender)
		info := &types.MessageInfo{
			MessageSource: types.MessageSource{Chat: chat, Sender: sj, IsFromMe: fromMe == 1, IsGroup: chat.Server == types.GroupServer},
			ID:            id,
			Timestamp:     time.UnixMilli(ats),
		}
		if _, err := a.cli.SendPeerMessage(a.ctx, a.cli.BuildHistorySyncRequest(info, 50)); err != nil {
			a.log.Errorf("backfill %s: %v", chatS, err)
			return
		}
		sent++
		a.log.Infof("backfill %s: requested 50 before %s", chatS, id)
		time.Sleep(time.Second)
	}
}

// setWaveform stores a waveform the app computed from a downloaded voice note
// whose sender didn't include one.
func (a *App) setWaveform(chat, id, b64 string) error {
	wave, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(wave) == 0 {
		return errors.New("bad waveform")
	}
	a.db.Exec(`UPDATE messages SET waveform=? WHERE chat=? AND id=? AND waveform IS NULL`, wave, chat, id)
	a.touchMsg(chat, id)
	return nil
}
