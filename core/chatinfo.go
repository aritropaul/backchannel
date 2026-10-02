package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"google.golang.org/protobuf/proto"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waSyncAction"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// The contact info panel's options: stars, disappearing messages, chat privacy,
// favorites, lists, clearing, groups in common, sharing a contact.

func (a *App) isPlaceholder(chat types.JID, id string) bool {
	var kind int
	err := a.rdb.QueryRow(`SELECT kind FROM messages WHERE chat=? AND id=?`, a.canon(chat).String(), id).Scan(&kind)
	return err == nil && kind == KPending
}

// ---- stars ----

func (a *App) star(chatS, id string, on bool) error {
	if err := a.ready(); err != nil {
		return err
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return err
	}
	var sender string
	var fromMe int
	if err := a.rdb.QueryRow(`SELECT sender, from_me FROM messages WHERE chat=? AND id=?`, chatS, id).Scan(&sender, &fromMe); err != nil {
		return err
	}
	// WhatsApp names the sender only for someone else's message in a group;
	// BuildStar writes "0" when the sender is the chat itself.
	sj := chat
	if fromMe == 0 && chat.Server == types.GroupServer {
		if j, err := types.ParseJID(sender); err == nil {
			sj = j
		}
	}
	if err := a.cli.SendAppState(a.ctx, appstate.BuildStar(chat, sj, id, fromMe == 1, on)); err != nil {
		return err
	}
	a.db.Exec(`UPDATE messages SET starred=? WHERE chat=? AND id=?`, b2i(on), chatS, id)
	a.touchMsg(chatS, id)
	return nil
}

// ---- disappearing messages and chat privacy ----

func (a *App) setTimer(chatS string, seconds int) error {
	if err := a.ready(); err != nil {
		return err
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return err
	}
	if err := a.cli.SetDisappearingTimer(a.ctx, chat, time.Duration(seconds)*time.Second, time.Now()); err != nil {
		return err
	}
	a.setChatField(chat, "ephemeral", seconds)
	return nil
}

// setExpiration stamps an outgoing message with the chat's disappearing timer.
func setExpiration(m *waE2E.Message, secs uint32) {
	if m.Conversation != nil {
		m.ExtendedTextMessage = &waE2E.ExtendedTextMessage{Text: m.Conversation}
		m.Conversation = nil
	}
	stamp := func(ci **waE2E.ContextInfo) {
		if *ci == nil {
			*ci = &waE2E.ContextInfo{}
		}
		(*ci).Expiration = proto.Uint32(secs)
	}
	switch {
	case m.ExtendedTextMessage != nil:
		stamp(&m.ExtendedTextMessage.ContextInfo)
	case m.ImageMessage != nil:
		stamp(&m.ImageMessage.ContextInfo)
	case m.VideoMessage != nil:
		stamp(&m.VideoMessage.ContextInfo)
	case m.AudioMessage != nil:
		stamp(&m.AudioMessage.ContextInfo)
	case m.DocumentMessage != nil:
		stamp(&m.DocumentMessage.ContextInfo)
	case m.StickerMessage != nil:
		stamp(&m.StickerMessage.ContextInfo)
	case m.ContactMessage != nil:
		stamp(&m.ContactMessage.ContextInfo)
	case m.ContactsArrayMessage != nil:
		stamp(&m.ContactsArrayMessage.ContextInfo)
	case m.PollCreationMessage != nil:
		stamp(&m.PollCreationMessage.ContextInfo)
	case m.EventMessage != nil:
		stamp(&m.EventMessage.ContextInfo)
	case m.LocationMessage != nil:
		stamp(&m.LocationMessage.ContextInfo)
	}
}

// setLimitSharing is "Advanced chat privacy": the other side can't export the
// chat, auto-download its media or use its messages for AI features.
func (a *App) setLimitSharing(chatS string, on bool) error {
	if err := a.ready(); err != nil {
		return err
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return err
	}
	msg := &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
		Type: waE2E.ProtocolMessage_LIMIT_SHARING.Enum(),
		LimitSharing: &waCommon.LimitSharing{
			SharingLimited:               proto.Bool(on),
			Trigger:                      waCommon.LimitSharing_CHAT_SETTING.Enum(),
			LimitSharingSettingTimestamp: proto.Int64(time.Now().UnixMilli()),
			InitiatedByMe:                proto.Bool(true),
		},
	}}
	if _, err := a.cli.SendMessage(a.ctx, chat, msg); err != nil {
		return err
	}
	a.setChatField(chat, "limit_sharing", b2i(on))
	return nil
}

// ---- favorites: one account-wide list, replaced whole on every change ----

func (a *App) setFavorites(act *waSyncAction.FavoritesAction) {
	ids := []string{}
	for _, f := range act.GetFavorites() {
		ids = append(ids, f.GetID())
	}
	raw, _ := json.Marshal(ids)
	tx, err := a.db.Begin()
	if err != nil {
		return
	}
	tx.Exec(`UPDATE chats SET favorite=0 WHERE favorite=1`)
	for _, id := range ids {
		if j, err := types.ParseJID(id); err == nil {
			c := a.canon(j)
			ensureChat(tx, c.String(), c.Server == types.GroupServer)
			tx.Exec(`UPDATE chats SET favorite=1 WHERE jid=?`, c.String())
		}
	}
	tx.Exec(`INSERT INTO kv (k, v) VALUES ('favorites', ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`, string(raw))
	tx.Commit()
	a.touchChats()
}

func (a *App) favorite(chatS string, on bool) error {
	if err := a.ready(); err != nil {
		return err
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return err
	}
	var raw string
	if a.rdb.QueryRow(`SELECT v FROM kv WHERE k='favorites'`).Scan(&raw) != nil {
		// Sending a list we haven't seen would replace the phone's favorites.
		return errors.New("Favorites haven't synced from your phone yet. Try again in a minute.")
	}
	var ids []string
	json.Unmarshal([]byte(raw), &ids)
	usesLID := false
	keep := []*waSyncAction.FavoritesAction_Favorite{}
	for _, id := range ids {
		j, err := types.ParseJID(id)
		if err == nil && j.Server == types.HiddenUserServer {
			usesLID = true
		}
		if err == nil && a.canon(j).String() == chat.String() {
			continue
		}
		keep = append(keep, &waSyncAction.FavoritesAction_Favorite{ID: proto.String(id)})
	}
	if on {
		id := chat
		if usesLID && chat.Server == types.DefaultUserServer && a.cli.Store.LIDs != nil {
			if lid, err := a.cli.Store.LIDs.GetLIDForPN(a.ctx, chat); err == nil && !lid.IsEmpty() {
				id = lid
			}
		}
		keep = append(keep, &waSyncAction.FavoritesAction_Favorite{ID: proto.String(id.String())})
	}
	act := &waSyncAction.FavoritesAction{Favorites: keep}
	patch := appstate.PatchInfo{Type: appstate.WAPatchRegularHigh, Mutations: []appstate.MutationInfo{{
		Index:   []string{appstate.IndexFavorites},
		Version: 1,
		Value:   &waSyncAction.SyncActionValue{FavoritesAction: act},
	}}}
	if err := a.cli.SendAppState(a.ctx, patch); err != nil {
		return err
	}
	a.setFavorites(act)
	return nil
}

// ---- lists (labels) ----

func (a *App) labelChat(chatS, label string, on bool) error {
	if err := a.ready(); err != nil {
		return err
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return err
	}
	if err := a.cli.SendAppState(a.ctx, appstate.BuildLabelChat(chat, label, on)); err != nil {
		return err
	}
	if on {
		a.db.Exec(`INSERT OR IGNORE INTO chat_labels (chat, label) VALUES (?,?)`, chatS, label)
	} else {
		a.db.Exec(`DELETE FROM chat_labels WHERE chat=? AND label=?`, chatS, label)
	}
	a.touchChats()
	return nil
}

// resyncAppStateOnce re-reads the two collections that hold stars, favorites and
// lists. They synced before this build stored them, and app state only sends changes.
func (a *App) resyncAppStateOnce() {
	var v string
	if a.rdb.QueryRow(`SELECT v FROM kv WHERE k='appstate_resync_v4b'`).Scan(&v) == nil {
		return
	}
	for _, name := range []appstate.WAPatchName{appstate.WAPatchRegularHigh, appstate.WAPatchRegular} {
		if err := a.cli.FetchAppState(a.ctx, name, true, false); err != nil {
			a.log.Warnf("app state resync %s: %v", name, err)
			return
		}
	}
	a.db.Exec(`INSERT INTO kv (k, v) VALUES ('appstate_resync_v4b', ?) ON CONFLICT(k) DO NOTHING`, itoa(int(time.Now().Unix())))
	a.log.Infof("app state resync: stars, favorites and lists re-read")
}

// ---- clearing ----

func messageRange(ts time.Time, key *waCommon.MessageKey) *waSyncAction.SyncActionMessageRange {
	r := &waSyncAction.SyncActionMessageRange{LastMessageTimestamp: proto.Int64(ts.Unix())}
	if key != nil {
		r.Messages = []*waSyncAction.SyncActionMessage{{Key: key, Timestamp: proto.Int64(ts.Unix())}}
	}
	return r
}

// clearChat empties a chat on every device and keeps it in the list.
func (a *App) clearChat(chatS string, keepStarred bool) error {
	if err := a.ready(); err != nil {
		return err
	}
	chat, err := parseChat(chatS)
	if err != nil {
		return err
	}
	ts, key := a.lastKey(chat)
	deleteStarred := "1"
	if keepStarred {
		deleteStarred = "0"
	}
	patch := appstate.PatchInfo{Type: appstate.WAPatchRegularHigh, Mutations: []appstate.MutationInfo{{
		Index:   []string{appstate.IndexClearChat, chat.String(), deleteStarred, "0"},
		Version: 6,
		Value:   &waSyncAction.SyncActionValue{ClearChatAction: &waSyncAction.ClearChatAction{MessageRange: messageRange(ts, key)}},
	}}}
	if err := a.cli.SendAppState(a.ctx, patch); err != nil {
		return err
	}
	a.clearLocal(chatS, ts.UnixMilli(), keepStarred)
	return nil
}

// clearLocal deletes a chat's messages up to a moment, so a clear that arrives
// late (or from a full resync) never takes newer messages with it.
func (a *App) clearLocal(chat string, upToMs int64, keepStarred bool) {
	q := `DELETE FROM messages WHERE chat=? AND ts<=?`
	if keepStarred {
		q += ` AND starred=0`
	}
	a.db.Exec(q, chat, upToMs)
	a.db.Exec(`DELETE FROM reactions WHERE chat=? AND msg_id NOT IN (SELECT id FROM messages WHERE chat=?)`, chat, chat)
	var id string
	if a.db.QueryRow(`SELECT id FROM messages WHERE chat=? ORDER BY ts DESC LIMIT 1`, chat).Scan(&id) != nil {
		id = ""
	}
	a.db.Exec(`UPDATE chats SET last_id=?, unread=0 WHERE jid=?`, id, chat)
	a.touchReload(chat)
}

// rangeEnd is the last moment a clear or delete covers. One replayed by a full
// resync without a range is skipped (0): "up to now" would take newer messages.
func rangeEnd(r *waSyncAction.SyncActionMessageRange, fullSync bool) int64 {
	if s := r.GetLastMessageTimestamp(); s > 0 {
		return s*1000 + 999
	}
	if fullSync {
		return 0
	}
	return time.Now().UnixMilli()
}

func (a *App) onClearChat(e *events.ClearChat) {
	if end := rangeEnd(e.Action.GetMessageRange(), e.FromFullSync); end > 0 {
		a.clearLocal(a.canon(e.JID).String(), end, true)
	}
}

func (a *App) onDeleteChat(e *events.DeleteChat) {
	chat := a.canon(e.JID).String()
	end := rangeEnd(e.Action.GetMessageRange(), e.FromFullSync)
	if end == 0 {
		return
	}
	a.clearLocal(chat, end, false)
	var n int
	a.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE chat=?`, chat).Scan(&n)
	if n == 0 {
		a.db.Exec(`DELETE FROM chats WHERE jid=?`, chat)
	}
	a.touchReload(chat)
}

// clearMedia deletes this Mac's downloaded copies of a chat's media; the
// messages stay and download again when opened.
func (a *App) clearMedia(chat string) (any, error) {
	rows, err := a.rdb.Query(`SELECT media_path FROM messages WHERE chat=? AND media_path != ''`, chat)
	if err != nil {
		return nil, err
	}
	var paths []string
	for rows.Next() {
		var p string
		if rows.Scan(&p) == nil {
			paths = append(paths, p)
		}
	}
	rows.Close()
	var freed int64
	for _, p := range paths {
		if st, err := os.Stat(p); err == nil {
			freed += st.Size()
		}
		os.Remove(p)
	}
	a.db.Exec(`UPDATE messages SET media_path='' WHERE chat=? AND media_path != ''`, chat)
	a.touchReload(chat)
	return map[string]any{"freed": freed, "files": len(paths)}, nil
}

// ---- groups ----

// putMembers records who is in a group (by phone JID where known) and who's admin.
func (a *App) putMembers(x execer, g *types.GroupInfo) {
	x.Exec(`DELETE FROM members WHERE chat=?`, g.JID.String())
	for _, p := range g.Participants {
		pj := a.canon(p.JID)
		if !p.PhoneNumber.IsEmpty() {
			pj = a.canon(p.PhoneNumber)
		}
		x.Exec(`INSERT OR REPLACE INTO members (chat, jid, admin) VALUES (?,?,?)`, g.JID.String(), pj.String(),
			b2i(p.IsAdmin || p.IsSuperAdmin))
	}
}

func (a *App) createGroup(name string, people []string) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	if name == "" {
		return nil, errors.New("Give the group a name")
	}
	var ps []types.JID
	for _, s := range people {
		j, err := parseChat(s)
		if err != nil {
			return nil, err
		}
		ps = append(ps, j)
	}
	g, err := a.cli.CreateGroup(a.ctx, whatsmeow.ReqCreateGroup{Name: name, Participants: ps})
	if err != nil {
		return nil, err
	}
	a.db.Exec(`INSERT INTO chats (jid, name, is_group, last_ts, participants) VALUES (?,?,1,?,?)
		ON CONFLICT(jid) DO UPDATE SET name=excluded.name, last_ts=MAX(chats.last_ts, excluded.last_ts)`,
		g.JID.String(), name, time.Now().UnixMilli(), len(g.Participants))
	a.putMembers(a.db, g)
	a.touchChats()
	return map[string]any{"jid": g.JID.String()}, nil
}

func (a *App) addToGroup(groupS, personS string) error {
	if err := a.ready(); err != nil {
		return err
	}
	group, err := parseChat(groupS)
	if err != nil {
		return err
	}
	person, err := parseChat(personS)
	if err != nil {
		return err
	}
	res, err := a.cli.UpdateGroupParticipants(a.ctx, group, []types.JID{person}, whatsmeow.ParticipantChangeAdd)
	if err != nil {
		return err
	}
	for _, p := range res {
		switch p.Error {
		case 0:
		case 403:
			return errors.New("Their privacy settings don't let them be added. Invite them with a link from your phone instead.")
		case 409:
			return errors.New("They're already in this group.")
		default:
			return fmt.Errorf("WhatsApp didn't add them (error %d).", p.Error)
		}
	}
	a.db.Exec(`INSERT OR REPLACE INTO members (chat, jid, admin) VALUES (?,?,0)`, groupS, a.canon(person).String())
	a.groupAsked.Delete(groupS)
	a.fetchGroupSize(groupS)
	return nil
}

// ---- sharing a contact ----
