package main

// The attach menu's kinds beyond photos and documents: polls (and votes),
// events (and responses), audio files, contact cards and stickers.

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/draw"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/util/random"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// ---- extra (messages.extra JSON) ----

type pollExtra struct {
	Options []string `json:"options"`
	Multi   bool     `json:"multi"`
}

type eventExtra struct {
	Description string `json:"desc,omitempty"`
	Location    string `json:"loc,omitempty"`
	JoinLink    string `json:"link,omitempty"`
	Start       int64  `json:"start"` // unix seconds
	End         int64  `json:"end,omitempty"`
	Canceled    bool   `json:"canceled,omitempty"`
	Guests      bool   `json:"guests,omitempty"` // invitees may bring a guest
}

type cardPhone struct {
	Number string `json:"num"`
	WAID   string `json:"waid,omitempty"` // digits; set when the number is on WhatsApp
}

type contactCard struct {
	Name   string      `json:"name"`
	Phones []cardPhone `json:"phones,omitempty"`
}

type contactExtra struct {
	Cards []contactCard `json:"cards"`
}

func jsonString(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	return string(b)
}

// pollCreation finds the poll in whichever field the sender's client used.
func pollCreation(m *waE2E.Message) *waE2E.PollCreationMessage {
	for _, p := range []*waE2E.PollCreationMessage{m.GetPollCreationMessage(), m.GetPollCreationMessageV2(),
		m.GetPollCreationMessageV3(), m.GetPollCreationMessageV5(), m.GetPollCreationMessageV6()} {
		if p != nil {
			return p
		}
	}
	return nil
}

func eventFrom(x *waE2E.EventMessage) eventExtra {
	loc := x.GetLocation()
	place := strings.TrimSpace(loc.GetName())
	if addr := strings.TrimSpace(loc.GetAddress()); addr != "" && addr != place {
		place = strings.Trim(place+", "+addr, ", ")
	}
	return eventExtra{Description: x.GetDescription(), Location: place, JoinLink: x.GetJoinLink(),
		Start: x.GetStartTime(), End: x.GetEndTime(), Canceled: x.GetIsCanceled(), Guests: x.GetExtraGuestsAllowed()}
}

// parseVCard pulls the name and phone numbers (with their WhatsApp IDs) out of a vCard.
func parseVCard(display, vcard string) contactCard {
	c := contactCard{Name: display}
	for _, line := range strings.Split(strings.ReplaceAll(vcard, "\r\n", "\n"), "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		params := strings.Split(key, ";")
		name := strings.ToUpper(params[0])
		if i := strings.LastIndex(name, "."); i >= 0 {
			name = name[i+1:] // item1.TEL
		}
		switch name {
		case "FN":
			if c.Name == "" {
				c.Name = strings.TrimSpace(value)
			}
		case "TEL":
			p := cardPhone{Number: strings.TrimSpace(value)}
			for _, prm := range params[1:] {
				if k, v, ok := strings.Cut(prm, "="); ok && strings.EqualFold(k, "waid") {
					p.WAID = v
				}
			}
			if p.Number != "" {
				c.Phones = append(c.Phones, p)
			}
		}
	}
	return c
}

// gifSource names the service a GIF came from, which the bubble credits.
func gifSource(a waE2E.VideoMessage_Attribution) string {
	switch a {
	case waE2E.VideoMessage_GIPHY:
		return "giphy"
	case waE2E.VideoMessage_TENOR:
		return "tenor"
	case waE2E.VideoMessage_KLIPY:
		return "klipy"
	}
	return ""
}

func digitsOnly(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, s)
}

// ---- who sent what ----

// origInfo describes a stored message the way whatsmeow needs it to vote on or
// respond to it. The message secret is kept under the identity WhatsApp used
// (phone number or LID); votes must be encrypted against that same one.
func (a *App) origInfo(chat types.JID, id string) (*types.MessageInfo, error) {
	var sender string
	var fromMe int
	if err := a.rdb.QueryRow(`SELECT sender, from_me FROM messages WHERE chat=? AND id=?`, chat.String(), id).
		Scan(&sender, &fromMe); err != nil {
		return nil, errors.New("message not found")
	}
	sj, _ := types.ParseJID(sender)
	if fromMe == 1 || sj.IsEmpty() {
		sj = a.me()
	}
	if _, real, err := a.cli.Store.MsgSecrets.GetMessageSecret(a.ctx, chat, sj, id); err == nil && !real.IsEmpty() {
		sj = real
	}
	return &types.MessageInfo{
		MessageSource: types.MessageSource{Chat: chat, Sender: sj, IsFromMe: fromMe == 1, IsGroup: chat.Server == types.GroupServer},
		ID:            id,
	}, nil
}

// ownIDFor is who I am to the person who sent the original: my LID, unless they
// addressed it by phone number.
func (a *App) ownIDFor(orig types.JID) types.JID {
	if orig.Server == types.DefaultUserServer {
		return a.cli.Store.GetJID().ToNonAD()
	}
	if lid := a.cli.Store.GetLID(); !lid.IsEmpty() {
		return lid.ToNonAD()
	}
	return a.cli.Store.GetJID().ToNonAD()
}

func keyFor(info *types.MessageInfo) *waCommon.MessageKey {
	k := &waCommon.MessageKey{RemoteJID: proto.String(info.Chat.String()), FromMe: proto.Bool(info.IsFromMe), ID: proto.String(info.ID)}
	if info.IsGroup {
		k.Participant = proto.String(info.Sender.ToNonAD().String())
	}
	return k
}

// keyAuthor is who sent the message a key points at, as stored in our rows.
func (a *App) keyAuthor(chat string, k *waCommon.MessageKey) string {
	if k.GetFromMe() {
		return a.me().String()
	}
	if p := k.GetParticipant(); p != "" {
		if j, err := types.ParseJID(p); err == nil {
			return a.canon(j).String()
		}
	}
	return chat
}

// ---- votes and responses ----

func putVote(x execer, chat, msgID, voter, choice string, guests int, ts int64) {
	x.Exec(`INSERT INTO votes (chat, msg_id, voter, choice, guests, ts) VALUES (?,?,?,?,?,?)
		ON CONFLICT(chat, msg_id, voter) DO UPDATE SET choice=excluded.choice, guests=excluded.guests, ts=excluded.ts
		WHERE excluded.ts >= votes.ts`, chat, msgID, voter, choice, guests, ts)
}

// pollOptions reads a poll's options; polls stored before options had their own
// field kept them as "○ option" lines under the question.
func pollOptions(x execer, chat, id string) (pollExtra, bool) {
	var text, extra string
	if x.QueryRow(`SELECT text, extra FROM messages WHERE chat=? AND id=? AND kind=?`, chat, id, KPoll).Scan(&text, &extra) != nil {
		return pollExtra{}, false
	}
	var p pollExtra
	if extra != "" && json.Unmarshal([]byte(extra), &p) == nil && len(p.Options) > 0 {
		return p, true
	}
	for _, line := range strings.Split(text, "\n") {
		if o, ok := strings.CutPrefix(line, "○ "); ok {
			p.Options = append(p.Options, o)
		}
	}
	p.Multi = true
	return p, len(p.Options) > 0
}

// optionNames maps the SHA-256 hashes a vote carries back to option names.
func optionNames(options []string, hashes [][]byte) []string {
	names := []string{}
	for _, o := range options {
		h := sha256.Sum256([]byte(o))
		for _, s := range hashes {
			if bytes.Equal(h[:], s) {
				names = append(names, o)
				break
			}
		}
	}
	return names
}

func (a *App) onPollVote(e *events.Message, r *msgRow) {
	pu := e.Message.GetPollUpdateMessage()
	pollID := pu.GetPollCreationMessageKey().GetID()
	vote, err := a.cli.DecryptPollVote(a.ctx, e)
	if err != nil {
		a.log.Warnf("poll vote %s on %s: %v", r.ID, pollID, err)
		return
	}
	p, ok := pollOptions(a.rdb, r.Chat, pollID)
	if !ok {
		a.log.Warnf("poll vote %s: poll %s unknown", r.ID, pollID)
		return
	}
	ts := pu.GetSenderTimestampMS()
	if ts == 0 {
		ts = r.TS
	}
	putVote(a.db, r.Chat, pollID, r.Sender, jsonString(optionNames(p.Options, vote.GetSelectedOptions())), 0, ts)
	a.touchMsg(r.Chat, pollID)
}

var responseNames = map[waE2E.EventResponseMessage_EventResponseType]string{
	waE2E.EventResponseMessage_GOING:     "going",
	waE2E.EventResponseMessage_NOT_GOING: "not_going",
	waE2E.EventResponseMessage_MAYBE:     "maybe",
}

func (a *App) onEventResponse(e *events.Message, r *msgRow) {
	enc := e.Message.GetEncEventResponseMessage()
	key := enc.GetEventCreationMessageKey()
	plain, err := a.cli.DangerousInternals().DecryptMsgSecret(a.ctx, e, whatsmeow.EncSecretEventResponse, enc, key)
	if err != nil {
		a.log.Warnf("event response %s on %s: %v", r.ID, key.GetID(), err)
		return
	}
	var resp waE2E.EventResponseMessage
	if proto.Unmarshal(plain, &resp) != nil {
		return
	}
	ts := resp.GetTimestampMS()
	if ts == 0 {
		ts = r.TS
	}
	putVote(a.db, r.Chat, key.GetID(), r.Sender, responseNames[resp.GetResponse()], int(resp.GetExtraGuestCount()), ts)
	a.touchMsg(r.Chat, key.GetID())
}

// onSecretEdit applies an encrypted edit: an event changed or cancelled, a poll
// edited, or a message edited the newer way.
func (a *App) onSecretEdit(e *events.Message, r *msgRow) {
	sm := e.Message.GetSecretEncryptedMessage()
	target := sm.GetTargetMessageKey().GetID()
	dec, err := a.cli.DecryptSecretEncryptedMessage(a.ctx, e)
	if err != nil {
		a.log.Warnf("secret edit %s on %s: %v", r.ID, target, err)
		return
	}
	switch {
	case dec.GetEventMessage() != nil:
		ev := dec.GetEventMessage()
		a.db.Exec(`UPDATE messages SET text=?, extra=?, edited=1 WHERE chat=? AND id=? AND kind=?`,
			ev.GetName(), jsonString(eventFrom(ev)), r.Chat, target, KEvent)
	case pollCreation(dec) != nil:
		p := pollCreation(dec)
		opts := make([]string, 0, len(p.GetOptions()))
		for _, o := range p.GetOptions() {
			opts = append(opts, o.GetOptionName())
		}
		if len(opts) > 0 {
			a.db.Exec(`UPDATE messages SET text=?, extra=?, edited=1 WHERE chat=? AND id=? AND kind=?`,
				p.GetName(), jsonString(pollExtra{Options: opts, Multi: p.GetSelectableOptionsCount() != 1}), r.Chat, target, KPoll)
		}
	default:
		var nr msgRow
		if a.content(dec, &nr) && nr.Text != "" {
			a.db.Exec(`UPDATE messages SET text=?, edited=1 WHERE chat=? AND id=? AND kind != ?`, nr.Text, r.Chat, target, KRevoked)
		}
	}
	a.touchMsg(r.Chat, target)
}

// importInteractions stores the votes and responses history sync carries on a
// poll or event message itself (already decrypted by the phone).
func (a *App) importInteractions(tx *sql.Tx, r *msgRow, pollUpdates []*waWeb.PollUpdate, responses []*waWeb.EventResponse) {
	if r.Kind == KPoll && len(pollUpdates) > 0 {
		var p pollExtra
		json.Unmarshal([]byte(r.Extra), &p)
		if len(p.Options) == 0 {
			p, _ = pollOptions(tx, r.Chat, r.ID)
		}
		for _, u := range pollUpdates {
			voter := a.keyAuthor(r.Chat, u.GetPollUpdateMessageKey())
			putVote(tx, r.Chat, r.ID, voter, jsonString(optionNames(p.Options, u.GetVote().GetSelectedOptions())), 0, u.GetSenderTimestampMS())
		}
	}
	if r.Kind == KEvent {
		for _, er := range responses {
			resp := er.GetEventResponseMessage()
			voter := a.keyAuthor(r.Chat, er.GetEventResponseMessageKey())
			putVote(tx, r.Chat, r.ID, voter, responseNames[resp.GetResponse()], int(resp.GetExtraGuestCount()), er.GetTimestampMS())
		}
	}
}

// ---- sending ----

func (a *App) sendPoll(r req) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	chat, err := parseChat(r.Chat)
	if err != nil {
		return nil, err
	}
	question := strings.TrimSpace(r.Text)
	var opts []string
	seen := map[string]bool{}
	for _, o := range r.Options {
		o = strings.TrimSpace(o)
		if o != "" && !seen[o] {
			seen[o] = true
			opts = append(opts, o)
		}
	}
	if question == "" || len(opts) < 2 {
		return nil, errors.New("a poll needs a question and at least two options")
	}
	if len(opts) > 12 {
		opts = opts[:12]
	}
	selectable := 0 // any number
	if !r.Multi {
		selectable = 1
	}
	msg := a.cli.BuildPollCreation(question, opts, selectable)
	id := a.cli.GenerateMessageID()
	row := &msgRow{Chat: chat.String(), ID: id, Sender: a.me().String(), FromMe: true, TS: time.Now().UnixMilli(),
		Kind: KPoll, Text: question, Status: StPending, Extra: jsonString(pollExtra{Options: opts, Multi: r.Multi})}
	a.localEcho(row, chat)
	go a.deliver(chat, id, msg)
	return map[string]any{"id": id}, nil
}

// votePoll sends my whole current selection on a poll (none retracts it).
func (a *App) votePoll(r req) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	chat, err := parseChat(r.Chat)
	if err != nil {
		return nil, err
	}
	p, ok := pollOptions(a.rdb, chat.String(), r.ID)
	if !ok {
		return nil, errors.New("poll not found")
	}
	var picked []string
	for _, o := range p.Options {
		for _, want := range r.Options {
			if o == want {
				picked = append(picked, o)
			}
		}
	}
	if !p.Multi && len(picked) > 1 {
		picked = picked[:1]
	}
	info, err := a.origInfo(chat, r.ID)
	if err != nil {
		return nil, err
	}
	msg, err := a.cli.BuildPollVote(a.ctx, info, picked)
	if err != nil {
		return nil, err
	}
	if picked == nil {
		picked = []string{}
	}
	putVote(a.db, chat.String(), r.ID, a.me().String(), jsonString(picked), 0, time.Now().UnixMilli())
	a.touchMsg(chat.String(), r.ID)
	go func() {
		if _, err := a.cli.SendMessage(a.ctx, chat, msg); err != nil {
			a.log.Errorf("poll vote on %s: %v", r.ID, err)
		}
	}()
	return map[string]any{"ok": true}, nil
}

func (a *App) sendEvent(r req) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	chat, err := parseChat(r.Chat)
	if err != nil {
		return nil, err
	}
	name := strings.TrimSpace(r.Text)
	if name == "" || r.Start <= 0 {
		return nil, errors.New("an event needs a name and a start time")
	}
	ev := &waE2E.EventMessage{Name: proto.String(name), StartTime: proto.Int64(r.Start), IsCanceled: proto.Bool(false),
		ExtraGuestsAllowed: proto.Bool(r.AllowGuests)}
	if d := strings.TrimSpace(r.Desc); d != "" {
		ev.Description = proto.String(d)
	}
	if r.End > r.Start {
		ev.EndTime = proto.Int64(r.End)
	}
	if l := strings.TrimSpace(r.Location); l != "" {
		ev.Location = &waE2E.LocationMessage{Name: proto.String(l)}
	}
	// Responses and edits are encrypted with this secret, as with polls.
	msg := &waE2E.Message{EventMessage: ev, MessageContextInfo: &waE2E.MessageContextInfo{MessageSecret: random.Bytes(32)}}
	id := a.cli.GenerateMessageID()
	row := &msgRow{Chat: chat.String(), ID: id, Sender: a.me().String(), FromMe: true, TS: time.Now().UnixMilli(),
		Kind: KEvent, Text: name, Status: StPending, Extra: jsonString(eventFrom(ev))}
	a.localEcho(row, chat)
	go a.deliver(chat, id, msg)
	return map[string]any{"id": id}, nil
}

func (a *App) respondEvent(r req) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	chat, err := parseChat(r.Chat)
	if err != nil {
		return nil, err
	}
	var kind waE2E.EventResponseMessage_EventResponseType
	for k, v := range responseNames {
		if v == r.Response {
			kind = k
		}
	}
	if kind == 0 {
		return nil, errors.New("respond going, not_going or maybe")
	}
	info, err := a.origInfo(chat, r.ID)
	if err != nil {
		return nil, err
	}
	now := time.Now().UnixMilli()
	plain, err := proto.Marshal(&waE2E.EventResponseMessage{Response: kind.Enum(), TimestampMS: proto.Int64(now),
		ExtraGuestCount: proto.Int32(int32(max(0, r.Guests)))})
	if err != nil {
		return nil, err
	}
	ct, iv, err := a.cli.DangerousInternals().EncryptMsgSecret(a.ctx, a.ownIDFor(info.Sender), chat, info.Sender, info.ID,
		whatsmeow.EncSecretEventResponse, plain)
	if err != nil {
		return nil, err
	}
	msg := &waE2E.Message{EncEventResponseMessage: &waE2E.EncEventResponseMessage{
		EventCreationMessageKey: keyFor(info), EncPayload: ct, EncIV: iv}}
	putVote(a.db, chat.String(), r.ID, a.me().String(), r.Response, max(0, r.Guests), now)
	a.touchMsg(chat.String(), r.ID)
	go func() {
		if _, err := a.cli.SendMessage(a.ctx, chat, msg); err != nil {
			a.log.Errorf("event response on %s: %v", r.ID, err)
		}
	}()
	return map[string]any{"ok": true}, nil
}

// cancelEvent cancels an event I created: an encrypted edit of it with
// isCanceled set.
func (a *App) cancelEvent(r req) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	chat, err := parseChat(r.Chat)
	if err != nil {
		return nil, err
	}
	var name, extra string
	if err := a.rdb.QueryRow(`SELECT text, extra FROM messages WHERE chat=? AND id=? AND kind=? AND from_me=1`,
		chat.String(), r.ID, KEvent).Scan(&name, &extra); err != nil {
		return nil, errors.New("only events you created can be cancelled")
	}
	var ex eventExtra
	json.Unmarshal([]byte(extra), &ex)
	ex.Canceled = true
	ev := &waE2E.EventMessage{Name: proto.String(name), StartTime: proto.Int64(ex.Start), IsCanceled: proto.Bool(true),
		ExtraGuestsAllowed: proto.Bool(ex.Guests)}
	if ex.Description != "" {
		ev.Description = proto.String(ex.Description)
	}
	if ex.End > 0 {
		ev.EndTime = proto.Int64(ex.End)
	}
	if ex.Location != "" {
		ev.Location = &waE2E.LocationMessage{Name: proto.String(ex.Location)}
	}
	plain, err := proto.Marshal(&waE2E.Message{EventMessage: ev})
	if err != nil {
		return nil, err
	}
	info, err := a.origInfo(chat, r.ID)
	if err != nil {
		return nil, err
	}
	ct, iv, err := a.cli.DangerousInternals().EncryptMsgSecret(a.ctx, a.ownIDFor(info.Sender), chat, info.Sender, info.ID,
		whatsmeow.EncSecretEventEdit, plain)
	if err != nil {
		return nil, err
	}
	msg := &waE2E.Message{SecretEncryptedMessage: &waE2E.SecretEncryptedMessage{
		TargetMessageKey: keyFor(info), EncPayload: ct, EncIV: iv,
		SecretEncType: waE2E.SecretEncryptedMessage_EVENT_EDIT.Enum()}}
	a.db.Exec(`UPDATE messages SET extra=? WHERE chat=? AND id=?`, jsonString(ex), chat.String(), r.ID)
	a.touchMsg(chat.String(), r.ID)
	go func() {
		if _, err := a.cli.SendMessage(a.ctx, chat, msg); err != nil {
			a.log.Errorf("cancel event %s: %v", r.ID, err)
		}
	}()
	return map[string]any{"ok": true}, nil
}

// sendAudio sends an audio file as music (the player bubble), not a voice note.
func (a *App) sendAudio(r req) (any, error) {
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
	mime := r.Mime
	if mime == "" {
		mime = "audio/mp4"
	}
	id := a.cli.GenerateMessageID()
	local := filepath.Join(a.dir, "media", safeName(id)+filepath.Ext(r.Path))
	os.WriteFile(local, data, 0o600)
	row := &msgRow{Chat: chat.String(), ID: id, Sender: a.me().String(), FromMe: true, TS: time.Now().UnixMilli(),
		Kind: KAudio, Status: StPending, Mime: mime, Seconds: r.Seconds, FileSize: int64(len(data)), MediaPath: local,
		FileName: r.Name}
	ci := a.quoteContext(chat, r.Quote)
	if ci != nil {
		row.QuoteID, row.QuoteSender = r.Quote, ci.GetParticipant()
		a.rdb.QueryRow(`SELECT text, kind FROM messages WHERE chat=? AND id=?`, chat.String(), r.Quote).Scan(&row.QuoteText, &row.QuoteKind)
	}
	a.localEcho(row, chat)
	go func() {
		up, err := a.cli.Upload(a.ctx, data, whatsmeow.MediaAudio)
		if err != nil {
			a.log.Errorf("upload audio %s: %v", id, err)
			a.db.Exec(`UPDATE messages SET status=? WHERE chat=? AND id=?`, StFailed, chat.String(), id)
			a.touchMsg(chat.String(), id)
			return
		}
		au := &waE2E.AudioMessage{
			Mimetype: proto.String(mime), URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath),
			MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(up.FileLength), Seconds: proto.Uint32(uint32(r.Seconds)), PTT: proto.Bool(false),
			ContextInfo: ci,
		}
		a.db.Exec(`UPDATE messages SET media=? WHERE chat=? AND id=?`, refFor(au, "audio"), chat.String(), id)
		a.deliver(chat, id, &waE2E.Message{AudioMessage: au})
	}()
	return map[string]any{"id": id}, nil
}

type contactReq struct {
	Name  string `json:"name"`
	Phone string `json:"phone"`
}

// vcardFor writes the vCard WhatsApp itself sends: the waid parameter is what
// gives the recipient a Message button.
func vcardFor(name, phone string) (string, contactCard) {
	digits := digitsOnly(phone)
	clean := strings.NewReplacer("\n", " ", ";", " ").Replace(strings.TrimSpace(name))
	vcard := fmt.Sprintf("BEGIN:VCARD\nVERSION:3.0\nN:;%s;;;\nFN:%s\nitem1.TEL;waid=%s:+%s\nitem1.X-ABLabel:Mobile\nEND:VCARD",
		clean, clean, digits, digits)
	return vcard, contactCard{Name: clean, Phones: []cardPhone{{Number: "+" + digits, WAID: digits}}}
}

// sendContacts shares one contact card, or several as one message.
func (a *App) sendContacts(chatS string, people []contactReq) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return nil, err
	}
	var msgs []*waE2E.ContactMessage
	var cards []contactCard
	for _, p := range people {
		if digitsOnly(p.Phone) == "" {
			continue
		}
		vcard, card := vcardFor(p.Name, p.Phone)
		msgs = append(msgs, &waE2E.ContactMessage{DisplayName: proto.String(card.Name), Vcard: proto.String(vcard)})
		cards = append(cards, card)
	}
	if len(msgs) == 0 {
		return nil, errors.New("no phone number to share")
	}
	msg := &waE2E.Message{}
	text := cards[0].Name
	if len(msgs) == 1 {
		msg.ContactMessage = msgs[0]
	} else {
		text = fmt.Sprintf("%d contacts", len(msgs))
		msg.ContactsArrayMessage = &waE2E.ContactsArrayMessage{DisplayName: proto.String(text), Contacts: msgs}
	}
	id := a.cli.GenerateMessageID()
	row := &msgRow{Chat: chat.String(), ID: id, Sender: a.me().String(), FromMe: true,
		TS: time.Now().UnixMilli(), Kind: KContact, Text: text, Status: StPending, Extra: jsonString(contactExtra{Cards: cards})}
	a.localEcho(row, chat)
	go a.deliver(chat, id, msg)
	return map[string]any{"id": id}, nil
}

// sendSticker sends an image as a sticker: a 512×512 WebP with transparency,
// under WhatsApp's 100 KB limit for still stickers.
func (a *App) sendSticker(r req) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	chat, err := parseChat(r.Chat)
	if err != nil {
		return nil, err
	}
	const side = 512
	mime := "image/webp"
	width, height := uint32(side), uint32(side)
	made := false
	var data []byte
	switch ext := strings.ToLower(filepath.Ext(r.Path)); ext {
	case ".webp", ".was":
		// A sticker someone sent or I saved: sent as it is, animation and all.
		if data, err = os.ReadFile(r.Path); err != nil {
			return nil, err
		}
		if ext == ".was" || r.Mime == "application/was" {
			mime = "application/was"
		}
		if r.Width > 0 && r.Height > 0 {
			width, height = uint32(r.Width), uint32(r.Height)
		}
	default:
		// Made here: a 512×512 picture, encoded to WebP under the 100 KB limit.
		f, err := os.Open(r.Path)
		if err != nil {
			return nil, err
		}
		src, _, err := image.Decode(f)
		f.Close()
		if err != nil {
			return nil, fmt.Errorf("sticker image: %w", err)
		}
		canvas := image.NewNRGBA(image.Rect(0, 0, side, side))
		b := src.Bounds()
		if b.Dx() != side || b.Dy() != side {
			return nil, errors.New("sticker image must be 512×512")
		}
		draw.Draw(canvas, canvas.Bounds(), src, b.Min, draw.Src)
		for _, q := range []float32{85, 70, 55, 40, 25} {
			if data, err = encodeWebP(canvas, q); err != nil {
				return nil, err
			}
			if len(data) <= 100_000 {
				break
			}
		}
		made = true
	}
	// Every sticker I send is kept; ones made here show under My Stickers.
	if hash, path, err := a.keepSticker(data, mime); err == nil {
		a.db.Exec(`INSERT INTO stickers (hash, path, mime, width, height, animated, created, ts) VALUES (?,?,?,?,?,?,?,?)
			ON CONFLICT(hash) DO UPDATE SET created=MAX(stickers.created, excluded.created), ts=excluded.ts`,
			hash, path, mime, width, height, b2i(r.Animated), b2i(made), time.Now().UnixMilli())
		stickersChanged()
	}
	id := a.cli.GenerateMessageID()
	ext := ".webp"
	if mime == "application/was" {
		ext = ".was"
	}
	local := filepath.Join(a.dir, "media", safeName(id)+ext)
	os.WriteFile(local, data, 0o600)
	row := &msgRow{Chat: chat.String(), ID: id, Sender: a.me().String(), FromMe: true, TS: time.Now().UnixMilli(),
		Kind: KSticker, Status: StPending, Mime: mime, Width: int(width), Height: int(height), FileSize: int64(len(data)),
		MediaPath: local}
	ci := a.quoteContext(chat, r.Quote)
	if ci != nil {
		row.QuoteID, row.QuoteSender = r.Quote, ci.GetParticipant()
		a.rdb.QueryRow(`SELECT text, kind FROM messages WHERE chat=? AND id=?`, chat.String(), r.Quote).Scan(&row.QuoteText, &row.QuoteKind)
	}
	a.localEcho(row, chat)
	go func() {
		up, err := a.cli.Upload(a.ctx, data, whatsmeow.MediaImage)
		if err != nil {
			a.log.Errorf("upload sticker %s: %v", id, err)
			a.db.Exec(`UPDATE messages SET status=? WHERE chat=? AND id=?`, StFailed, chat.String(), id)
			a.touchMsg(chat.String(), id)
			return
		}
		st := &waE2E.StickerMessage{
			Mimetype: proto.String(mime), URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath),
			MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(up.FileLength), Width: proto.Uint32(width), Height: proto.Uint32(height),
			StickerSentTS: proto.Int64(time.Now().UnixMilli()), ContextInfo: ci,
		}
		if r.Animated {
			st.IsAnimated = proto.Bool(true)
		}
		if mime == "application/was" {
			st.IsLottie = proto.Bool(true)
		}
		a.db.Exec(`UPDATE messages SET media=? WHERE chat=? AND id=?`, refFor(st, "image"), chat.String(), id)
		a.deliver(chat, id, &waE2E.Message{StickerMessage: st})
	}()
	return map[string]any{"id": id}, nil
}
