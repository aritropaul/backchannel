package main

import (
	"database/sql"
	"errors"
	"strings"
	"time"

	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// loop applies events strictly in arrival order on one goroutine so the
// database always reflects a consistent prefix of what the server sent.
func (a *App) loop() {
	for evt := range a.events {
		a.handle(evt)
	}
}

func (a *App) handle(evt any) {
	switch e := evt.(type) {
	case *events.Message:
		// A message the phone resent on request (recoverMissing) is old news: store it
		// without notifying or counting it unread. One that fills in a "Waiting for this
		// message" placeholder is still news.
		a.onMessage(e, e.UnavailableRequestID == "" || a.isPlaceholder(e.Info.Chat, e.Info.ID))
	case *events.MediaRetry:
		a.onMediaRetry(e)
	case *events.UndecryptableMessage:
		a.onUndecryptable(e)
	case *events.HistorySync:
		a.onHistory(e)
	case *events.Receipt:
		a.onReceipt(e)
	case groupSize:
		a.setGroupSize(e.chat, e.n, e.info)
	case *events.IdentityChange:
		a.onIdentityChange(e)
	case *events.ChatPresence:
		chat := a.canon(e.Chat)
		emit(map[string]any{"t": "typing", "chat": chat.String(), "sender": a.canon(e.Sender).String(),
			"on": e.State == types.ChatPresenceComposing, "audio": e.Media == types.ChatPresenceMediaAudio})
	case *events.Presence:
		ev := map[string]any{"t": "presence", "jid": a.canon(e.From).String(), "online": !e.Unavailable}
		if !e.LastSeen.IsZero() {
			ev["last_seen"] = e.LastSeen.UnixMilli()
		}
		emit(ev)
	case *events.PushName:
		a.setPushName(a.canon(e.JID), e.NewPushName)
	case *events.Contact:
		name := e.Action.GetFullName()
		if name == "" {
			name = e.Action.GetFirstName()
		}
		a.db.Exec(`INSERT INTO contacts (jid, name) VALUES (?,?) ON CONFLICT(jid) DO UPDATE SET name=excluded.name`,
			a.canon(e.JID).String(), name)
		a.touchChats()
	case *events.Pin:
		pinned := int64(0)
		if e.Action.GetPinned() {
			pinned = e.Timestamp.Unix()
		}
		a.setChatField(e.JID, "pinned", pinned)
	case *events.Archive:
		a.setChatField(e.JID, "archived", b2i(e.Action.GetArchived()))
	case *events.Mute:
		until := int64(0)
		if e.Action.GetMuted() {
			until = e.Action.GetMuteEndTimestamp()
			if until <= 0 {
				until = -1
			} else if until > 1e12 { // some clients send ms
				until /= 1000
			}
		}
		a.setChatField(e.JID, "muted_until", until)
	case *events.MarkChatAsRead:
		chat := a.canon(e.JID).String()
		if e.Action.GetRead() {
			a.db.Exec(`UPDATE chats SET unread=0, marked_unread=0 WHERE jid=?`, chat)
		} else {
			a.db.Exec(`UPDATE chats SET marked_unread=1 WHERE jid=?`, chat)
		}
		a.touchChats()
	case *events.DeleteChat:
		a.onDeleteChat(e)
	case *events.ClearChat:
		a.onClearChat(e)
	case *events.DeleteForMe:
		a.onDeleteForMe(e)
	case *events.Star:
		chat := a.canon(e.ChatJID).String()
		a.db.Exec(`UPDATE messages SET starred=? WHERE chat=? AND id=?`, b2i(e.Action.GetStarred()), chat, e.MessageID)
		a.touchMsg(chat, e.MessageID)
	case *events.AppState:
		if len(e.Index) == 1 && e.Index[0] == appstate.IndexFavorites && e.SyncActionValue.GetFavoritesAction() != nil {
			a.setFavorites(e.SyncActionValue.GetFavoritesAction())
		}
		if len(e.Index) > 1 && e.Index[0] == appstate.IndexFavoriteSticker && e.SyncActionValue.GetStickerAction() != nil {
			a.onFavoriteSticker(e.Index, e.SyncActionValue.GetStickerAction())
		}
	case *events.LabelEdit:
		act := e.Action
		a.db.Exec(`INSERT INTO labels (id, name, color, type, ord, deleted) VALUES (?,?,?,?,?,?)
			ON CONFLICT(id) DO UPDATE SET name=excluded.name, color=excluded.color, type=excluded.type,
				ord=excluded.ord, deleted=excluded.deleted`,
			e.LabelID, act.GetName(), act.GetColor(), int(act.GetType()), act.GetOrderIndex(), b2i(act.GetDeleted()))
		a.touchChats()
	case *events.LabelAssociationChat:
		chat := a.canon(e.JID).String()
		if e.Action.GetLabeled() {
			a.db.Exec(`INSERT OR IGNORE INTO chat_labels (chat, label) VALUES (?,?)`, chat, e.LabelID)
		} else {
			a.db.Exec(`DELETE FROM chat_labels WHERE chat=? AND label=?`, chat, e.LabelID)
		}
		a.touchChats()
	case *events.GroupInfo:
		if e.Name != nil && e.Name.Name != "" {
			a.db.Exec(`INSERT INTO chats (jid, name, is_group) VALUES (?,?,1) ON CONFLICT(jid) DO UPDATE SET name=excluded.name`,
				e.JID.String(), e.Name.Name)
			a.touchChats()
		}
		if e.Ephemeral != nil {
			secs := 0
			if e.Ephemeral.IsEphemeral {
				secs = int(e.Ephemeral.DisappearingTimer)
			}
			a.setChatField(e.JID, "ephemeral", secs)
		}
		if len(e.Join) > 0 || len(e.Leave) > 0 || len(e.Promote) > 0 || len(e.Demote) > 0 {
			// Membership changed: refresh the count that group "Read" depends on.
			a.groupAsked.Delete(e.JID.String())
			a.fetchGroupSize(e.JID.String())
		}
	case *events.JoinedGroup:
		a.db.Exec(`INSERT INTO chats (jid, name, is_group, last_ts) VALUES (?,?,1,?) ON CONFLICT(jid) DO UPDATE SET name=excluded.name`,
			e.JID.String(), e.GroupName.Name, time.Now().UnixMilli())
		a.touchChats()
	case *events.Picture:
		chat := a.canon(e.JID).String()
		a.db.Exec(`UPDATE chats SET avatar='', avatar_ts=0 WHERE jid=?`, chat)
		a.avatarSeen.Delete(chat)
		a.touchChats()
	case *events.AppStateSyncComplete:
		a.importContacts()
		if e.Recovery {
			a.log.Infof("app state %s recovered from the phone (v%d)", e.Name, e.Version)
		}
	case *events.AppStateSyncError:
		if errors.Is(e.Error, appstate.ErrMismatchingLTHash) || strings.Contains(e.Error.Error(), "mismatching LTHash") {
			go a.recoverAppState(e.Name)
		}
	case *events.PairSuccess:
		emit(map[string]any{"t": "state", "s": "syncing", "me": e.ID.ToNonAD().String()})
	case *events.Connected:
		emit(map[string]any{"t": "state", "s": "connected", "me": a.me().String()})
		go a.afterConnect()
	case *events.Disconnected:
		emit(map[string]any{"t": "state", "s": "connecting"})
	case *events.KeepAliveTimeout:
		emit(map[string]any{"t": "state", "s": "connecting"})
	case *events.KeepAliveRestored:
		emit(map[string]any{"t": "state", "s": "connected", "me": a.me().String()})
	case *events.StreamReplaced:
		emit(map[string]any{"t": "state", "s": "replaced"})
	case *events.LoggedOut:
		a.wipeAppDB()
		emit(map[string]any{"t": "state", "s": "logged_out"})
		a.restartPairing()
	case *events.TemporaryBan:
		emit(map[string]any{"t": "state", "s": "banned", "msg": e.String()})
	}
}

func (a *App) setChatField(j types.JID, col string, v any) {
	chat := a.canon(j)
	ensureChat(a.db, chat.String(), chat.Server == types.GroupServer)
	a.db.Exec(`UPDATE chats SET `+col+`=? WHERE jid=?`, v, chat.String())
	a.touchChats()
}

func (a *App) afterConnect() {
	a.backfillPending.Range(func(k, _ any) bool {
		a.backfillPending.Delete(k)
		go a.backfill(k.(string))
		return true
	})
	if a.synced.Swap(true) {
		return
	}
	go func() {
		// After the offline queue has landed, so only real gaps are asked for.
		time.Sleep(15 * time.Second)
		a.recoverMissing()
	}()
	a.importContacts()
	if groups, err := a.cli.GetJoinedGroups(a.ctx); err == nil {
		tx, err := a.db.Begin()
		if err == nil {
			for _, g := range groups {
				// Member counts drive group "Read" (read by everyone else).
				eph := 0
				if g.IsEphemeral {
					eph = int(g.DisappearingTimer)
				}
				tx.Exec(`INSERT INTO chats (jid, name, is_group, participants, ephemeral) VALUES (?,?,1,?,?)
					ON CONFLICT(jid) DO UPDATE SET name=excluded.name, is_group=1, participants=excluded.participants,
						ephemeral=excluded.ephemeral`,
					g.JID.String(), g.Name, len(g.Participants), eph)
				a.putMembers(tx, g)
			}
			tx.Commit()
		}
		a.touchChats()
	}
	a.mergeLIDChats()
	if a.appActive.Load() {
		a.cli.SendPresence(a.ctx, types.PresenceAvailable)
	}
	a.resyncAppStateOnce()
	a.resyncStickersOnce()
	a.refetchStickersOnce()
}

// ---- messages ----

func (a *App) rowFor(info *types.MessageInfo) (*msgRow, types.JID, bool) {
	chat := a.canon(info.Chat)
	if skipChat(chat) {
		return nil, chat, false
	}
	sender := a.canon(info.Sender)
	return &msgRow{
		Chat:     chat.String(),
		ID:       info.ID,
		Sender:   sender.String(),
		PushName: info.PushName,
		FromMe:   info.IsFromMe,
		TS:       info.Timestamp.UnixMilli(),
	}, chat, true
}

func (a *App) onMessage(e *events.Message, live bool) {
	r, chat, ok := a.rowFor(&e.Info)
	if !ok {
		return
	}
	m := e.Message
	if pm := m.GetProtocolMessage(); pm != nil {
		target := pm.GetKey().GetID()
		switch pm.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			a.db.Exec(`UPDATE messages SET kind=?, text='', media='', thumb=NULL, quote_id='', reactions='' WHERE chat=? AND id=?`,
				KRevoked, r.Chat, target)
			a.touchMsg(r.Chat, target)
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			var nr msgRow
			if a.content(pm.GetEditedMessage(), &nr) {
				a.db.Exec(`UPDATE messages SET text=?, edited=1 WHERE chat=? AND id=? AND kind != ?`, nr.Text, r.Chat, target, KRevoked)
				a.touchMsg(r.Chat, target)
			}
		case waE2E.ProtocolMessage_EPHEMERAL_SETTING:
			a.setChatField(chat, "ephemeral", int(pm.GetEphemeralExpiration()))
		case waE2E.ProtocolMessage_LIMIT_SHARING:
			a.setChatField(chat, "limit_sharing", b2i(pm.GetLimitSharing().GetSharingLimited()))
		}
		return
	}
	if rm := m.GetReactionMessage(); rm != nil {
		a.onReaction(r.Chat, rm.GetKey().GetID(), r.Sender, rm.GetText(), r.TS)
		if live && !r.FromMe && rm.GetText() != "" {
			a.notifyReaction(r, chat, rm.GetKey().GetID(), rm.GetText())
		}
		return
	}
	if m.GetPollUpdateMessage() != nil {
		a.onPollVote(e, r)
		return
	}
	if m.GetEncEventResponseMessage() != nil {
		a.onEventResponse(e, r)
		return
	}
	if m.GetSecretEncryptedMessage() != nil {
		a.onSecretEdit(e, r)
		return
	}
	if e.IsEdit {
		// History sync delivers edits already unwrapped onto the original ID.
		var nr msgRow
		if a.content(m, &nr) {
			a.db.Exec(`UPDATE messages SET text=?, edited=1 WHERE chat=? AND id=?`, nr.Text, r.Chat, r.ID)
			a.touchMsg(r.Chat, r.ID)
		}
		return
	}
	if !a.content(m, r) {
		return
	}
	if r.FromMe {
		r.Status = StSent
		if e.SourceWebMsg != nil {
			r.Status = webStatus(e.SourceWebMsg.GetStatus())
		}
	}
	if !r.FromMe && r.PushName != "" {
		a.setPushName(a.canon(e.Info.Sender), r.PushName)
	}
	if err := upsertMessage(a.db, r); err != nil {
		a.log.Errorf("insert %s/%s: %v", r.Chat, r.ID, err)
		return
	}
	a.statMsgs.Add(1)
	bumpChat(a.db, r.Chat, chat.Server == types.GroupServer, r.TS, r.ID)
	a.touchMsg(r.Chat, r.ID)
	if needsThumb(r) {
		go a.fetchThumb(r.Chat, r.ID)
	}
	if !live {
		return
	}
	if r.FromMe {
		// Sent from the phone: WhatsApp treats that as having read the chat.
		a.db.Exec(`UPDATE chats SET unread=0, marked_unread=0 WHERE jid=?`, r.Chat)
		return
	}
	if a.appActive.Load() && a.activeChat.Load().(string) == r.Chat {
		a.cli.MarkRead(a.ctx, []types.MessageID{r.ID}, time.Now(), chat, e.Info.Sender)
		return
	}
	a.db.Exec(`UPDATE chats SET unread=unread+1 WHERE jid=?`, r.Chat)
	a.notify(r, chat)
}

func (a *App) onUndecryptable(e *events.UndecryptableMessage) {
	r, chat, ok := a.rowFor(&e.Info)
	if !ok {
		return
	}
	if e.IsUnavailable && e.UnavailableType == events.UnavailableTypeViewOnce {
		r.Kind, r.Text = KUnsupported, "View once message. Open it on your phone."
	} else {
		r.Kind, r.Text = KPending, "Waiting for this message. This may take a while."
	}
	a.db.Exec(`INSERT INTO messages (chat, id, sender, push_name, from_me, ts, kind, text) VALUES (?,?,?,?,?,?,?,?)
		ON CONFLICT(chat, id) DO NOTHING`, r.Chat, r.ID, r.Sender, r.PushName, b2i(r.FromMe), r.TS, r.Kind, r.Text)
	bumpChat(a.db, r.Chat, chat.Server == types.GroupServer, r.TS, r.ID)
	a.touchMsg(r.Chat, r.ID)
}

func (a *App) onReaction(chat, msgID, sender, emoji string, ts int64) {
	if emoji == "" {
		a.db.Exec(`DELETE FROM reactions WHERE chat=? AND msg_id=? AND sender=?`, chat, msgID, sender)
	} else {
		a.db.Exec(`INSERT INTO reactions (chat, msg_id, sender, emoji, ts) VALUES (?,?,?,?,?)
			ON CONFLICT(chat, msg_id, sender) DO UPDATE SET emoji=excluded.emoji, ts=excluded.ts`, chat, msgID, sender, emoji, ts)
	}
	refreshReactions(a.db, chat, msgID, a.me().String())
	a.touchMsg(chat, msgID)
}

func webStatus(s waWeb.WebMessageInfo_Status) int {
	switch s {
	case waWeb.WebMessageInfo_ERROR:
		return StFailed
	case waWeb.WebMessageInfo_PENDING:
		return StPending
	case waWeb.WebMessageInfo_DELIVERY_ACK:
		return StDelivered
	case waWeb.WebMessageInfo_READ:
		return StRead
	case waWeb.WebMessageInfo_PLAYED:
		return StPlayed
	}
	return StSent
}

func (a *App) onReceipt(e *events.Receipt) {
	chat := a.canon(e.Chat).String()
	var st int
	switch e.Type {
	case types.ReceiptTypeDelivered:
		st = StDelivered
	case types.ReceiptTypeRead:
		st = StRead
	case types.ReceiptTypePlayed:
		st = StPlayed
	case types.ReceiptTypeReadSelf, types.ReceiptTypePlayedSelf:
		// Read on another of my devices.
		a.db.Exec(`UPDATE chats SET unread=0, marked_unread=0 WHERE jid=?`, chat)
		a.touchChats()
		return
	default:
		return
	}
	if e.IsFromMe {
		return
	}
	if e.IsGroup {
		a.onGroupReceipt(chat, a.canon(e.Sender).String(), e.MessageIDs, st, e.Timestamp.UnixMilli())
		return
	}
	for _, id := range e.MessageIDs {
		a.db.Exec(`UPDATE messages SET status=? WHERE chat=? AND id=? AND from_me=1 AND status < ? AND status >= 0`, st, chat, id, st)
		a.touchMsg(chat, id)
	}
}

// onGroupReceipt records one member's receipt; the message's own status only
// advances once every other member has reached it, as WhatsApp shows it.
func (a *App) onGroupReceipt(chat, member string, ids []types.MessageID, st int, ts int64) {
	others := a.groupOthers(chat)
	for _, id := range ids {
		a.db.Exec(`INSERT INTO receipts (chat, msg_id, participant, status, ts) VALUES (?,?,?,?,?)
			ON CONFLICT(chat, msg_id, participant) DO UPDATE SET status=MAX(receipts.status, excluded.status), ts=excluded.ts`,
			chat, id, member, st, ts)
		a.applyGroupStatus(chat, id, others)
	}
}

// applyGroupStatus derives a group message's status from its receipts. With an
// unknown member count it claims no more than Delivered.
func (a *App) applyGroupStatus(chat, id string, others int) {
	var delivered, read, played int
	a.db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(status >= ?), 0), COALESCE(SUM(status >= ?), 0)
		FROM receipts WHERE chat=? AND msg_id=?`, StRead, StPlayed, chat, id).Scan(&delivered, &read, &played)
	st := StSent
	switch {
	case others <= 0:
		if delivered > 0 {
			st = StDelivered
		}
	case played >= others:
		st = StPlayed
	case read >= others:
		st = StRead
	case delivered >= others:
		st = StDelivered
	}
	if res, err := a.db.Exec(`UPDATE messages SET status=? WHERE chat=? AND id=? AND from_me=1 AND status >= 0 AND status < ?`,
		st, chat, id, st); err == nil {
		if n, _ := res.RowsAffected(); n > 0 {
			a.touchMsg(chat, id)
		}
	}
}

// groupOthers is the number of members besides me, or 0 while unknown (a
// lookup is started; statuses are recomputed when it lands).
func (a *App) groupOthers(chat string) int {
	var n int
	a.db.QueryRow(`SELECT participants FROM chats WHERE jid=?`, chat).Scan(&n)
	if n > 0 {
		return n - 1
	}
	a.fetchGroupSize(chat)
	return 0
}

func (a *App) fetchGroupSize(chat string) {
	if t, ok := a.groupAsked.Load(chat); ok && time.Since(t.(time.Time)) < 10*time.Minute {
		return
	}
	a.groupAsked.Store(chat, time.Now())
	go func() {
		j, err := types.ParseJID(chat)
		if err != nil || a.ready() != nil {
			return
		}
		g, err := a.cli.GetGroupInfo(a.ctx, j)
		if err != nil {
			a.log.Warnf("group size %s: %v", chat, err)
			return
		}
		a.events <- groupSize{chat, len(g.Participants), g}
	}()
}

// groupSize is queued onto the event loop so writes stay on one goroutine.
type groupSize struct {
	chat string
	n    int
	info *types.GroupInfo
}

func (a *App) setGroupSize(chat string, n int, info *types.GroupInfo) {
	if info != nil {
		a.putMembers(a.db, info)
	}
	if n <= 0 {
		return
	}
	a.db.Exec(`UPDATE chats SET participants=? WHERE jid=?`, n, chat)
	rows, err := a.db.Query(`SELECT DISTINCT msg_id FROM receipts WHERE chat=?`, chat)
	if err != nil {
		return
	}
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	for _, id := range ids {
		a.applyGroupStatus(chat, id, n-1)
	}
}

// ---- history sync ----

func (a *App) onHistory(e *events.HistorySync) {
	d := e.Data
	switch d.GetSyncType() {
	case waHistorySync.HistorySync_PUSH_NAME:
		tx, err := a.db.Begin()
		if err != nil {
			return
		}
		for _, p := range d.GetPushnames() {
			if p.GetPushname() == "" || p.GetPushname() == "-" {
				continue
			}
			if j, err := types.ParseJID(p.GetID()); err == nil {
				tx.Exec(`INSERT INTO contacts (jid, push_name) VALUES (?,?) ON CONFLICT(jid) DO UPDATE SET push_name=excluded.push_name`,
					a.canon(j).String(), p.GetPushname())
			}
		}
		tx.Commit()
		a.touchChats()
		return
	case waHistorySync.HistorySync_INITIAL_BOOTSTRAP, waHistorySync.HistorySync_RECENT,
		waHistorySync.HistorySync_FULL, waHistorySync.HistorySync_ON_DEMAND:
	default:
		return
	}
	t0 := time.Now()
	before := a.statMsgs.Load()
	for _, conv := range d.GetConversations() {
		a.importConversation(conv, d.GetSyncType())
	}
	a.log.Infof("history %s chunk=%d progress=%d%%: %d conversations, %d messages in %s (queue %d)",
		d.GetSyncType(), d.GetChunkOrder(), d.GetProgress(), len(d.GetConversations()),
		a.statMsgs.Load()-before, time.Since(t0).Round(time.Millisecond), len(a.events))
	emit(map[string]any{"t": "sync", "progress": d.GetProgress(), "type": d.GetSyncType().String()})
	a.mergeLIDChats()
}

func (a *App) importConversation(conv *waHistorySync.Conversation, typ waHistorySync.HistorySync_HistorySyncType) {
	raw, err := types.ParseJID(conv.GetID())
	if err != nil {
		return
	}
	chat := a.canon(raw)
	if skipChat(chat) {
		return
	}
	isGroup := chat.Server == types.GroupServer
	tx, err := a.db.Begin()
	if err != nil {
		return
	}
	defer tx.Rollback()

	name := conv.GetName()
	if name == "" && isGroup {
		name = conv.GetDisplayName()
	}
	ts := int64(conv.GetConversationTimestamp())
	if ts == 0 {
		ts = int64(conv.GetLastMsgTimestamp())
	}
	pinned := int64(0)
	if conv.GetPinned() != 0 {
		pinned = int64(conv.GetPinned())
	}
	muted := int64(conv.GetMuteEndTime())
	if muted > 1e12 {
		muted /= 1000
	}
	// History is a snapshot; live app-state events are authoritative, so only
	// seed metadata for chats we haven't seen, and never move counts backwards
	// on later chunks of the same chat.
	if isGroup && len(conv.GetParticipant()) > 0 {
		tx.Exec(`UPDATE chats SET participants=? WHERE jid=?`, len(conv.GetParticipant()), chat.String())
	}
	tx.Exec(`INSERT INTO chats (jid, name, is_group, last_ts, unread, marked_unread, pinned, archived, muted_until)
		VALUES (?,?,?,?,?,?,?,?,?)
		ON CONFLICT(jid) DO UPDATE SET
			name=CASE WHEN excluded.name != '' THEN excluded.name ELSE chats.name END,
			is_group=excluded.is_group`,
		chat.String(), name, b2i(isGroup), ts*1000, conv.GetUnreadCount(), b2i(conv.GetMarkedAsUnread()),
		pinned, b2i(conv.GetArchived()), muted)

	if conv.EphemeralExpiration != nil {
		tx.Exec(`UPDATE chats SET ephemeral=? WHERE jid=?`, conv.GetEphemeralExpiration(), chat.String())
	}
	if conv.LimitSharing != nil {
		tx.Exec(`UPDATE chats SET limit_sharing=? WHERE jid=?`, b2i(conv.GetLimitSharing()), chat.String())
	}

	msgs := conv.GetMessages() // newest first
	var thumbs []string        // re-sent photos/videos whose thumbnail is a separate download
	for i := len(msgs) - 1; i >= 0; i-- {
		wm := msgs[i].GetMessage()
		if wm == nil || wm.GetMessage() == nil {
			continue
		}
		evt, err := a.cli.ParseWebMessage(chat, wm)
		if err != nil {
			continue
		}
		r, _, ok := a.rowFor(&evt.Info)
		if !ok {
			continue
		}
		r.Chat = chat.String()
		m := evt.Message
		if pm := m.GetProtocolMessage(); pm != nil {
			if pm.GetType() == waE2E.ProtocolMessage_REVOKE {
				tx.Exec(`UPDATE messages SET kind=?, text='', media='', thumb=NULL WHERE chat=? AND id=?`, KRevoked, r.Chat, pm.GetKey().GetID())
			}
			continue
		}
		if rm := m.GetReactionMessage(); rm != nil {
			continue // reactions in history arrive on the target message itself
		}
		if evt.IsEdit || isEditProto(evt.RawMessage) {
			var nr msgRow
			if a.content(m, &nr) {
				tx.Exec(`UPDATE messages SET text=?, edited=1 WHERE chat=? AND id=?`, nr.Text, r.Chat, r.ID)
			}
			continue
		}
		if wm.GetMessageStubType() == waWeb.WebMessageInfo_REVOKE {
			r.Kind = KRevoked
		} else if !a.content(m, r) {
			continue
		}
		if r.FromMe {
			r.Status = webStatus(wm.GetStatus())
		}
		r.Starred = wm.GetStarred()
		if err := upsertMessage(tx, r); err != nil {
			continue
		}
		if typ == waHistorySync.HistorySync_ON_DEMAND && needsThumb(r) {
			thumbs = append(thumbs, r.ID)
		}
		a.statMsgs.Add(1)
		for _, rc := range wm.GetReactions() {
			sj, err := types.ParseJID(rc.GetKey().GetParticipant())
			if err != nil || rc.GetKey().GetFromMe() {
				sj = a.me()
			}
			tx.Exec(`INSERT INTO reactions (chat, msg_id, sender, emoji, ts) VALUES (?,?,?,?,?)
				ON CONFLICT(chat, msg_id, sender) DO UPDATE SET emoji=excluded.emoji`,
				r.Chat, r.ID, a.canon(sj).String(), rc.GetText(), rc.GetSenderTimestampMS())
		}
		if len(wm.GetReactions()) > 0 {
			refreshReactions(tx, r.Chat, r.ID, a.me().String())
		}
		a.importInteractions(tx, r, wm.GetPollUpdates(), wm.GetEventResponses())
		bumpChat(tx, r.Chat, isGroup, r.TS, r.ID)
	}
	if err := tx.Commit(); err != nil {
		a.log.Errorf("history commit %s: %v", chat, err)
		return
	}
	a.statConvs.Add(1)
	if len(thumbs) > 0 {
		go func() {
			for _, id := range thumbs {
				a.fetchThumb(chat.String(), id)
			}
		}()
	}
	if typ == waHistorySync.HistorySync_ON_DEMAND || len(msgs) > 0 {
		a.touchReload(chat.String())
	} else {
		a.touchChats()
	}
}

func isEditProto(m *waE2E.Message) bool {
	return m.GetProtocolMessage().GetType() == waE2E.ProtocolMessage_MESSAGE_EDIT
}

// ---- identity merging ----

// mergeLIDChats folds chats keyed by a LID into the phone-number chat once
// the mapping is known, so one person never shows up twice.
func (a *App) mergeLIDChats() {
	rows, err := a.rdb.Query(`SELECT jid FROM chats WHERE jid LIKE '%@lid'`)
	if err != nil {
		return
	}
	var lids []string
	for rows.Next() {
		var s string
		if rows.Scan(&s) == nil {
			lids = append(lids, s)
		}
	}
	rows.Close()
	merged := false
	for _, s := range lids {
		lid, err := types.ParseJID(s)
		if err != nil {
			continue
		}
		pn := a.canon(lid)
		if pn.Server == types.HiddenUserServer {
			continue
		}
		if err := a.mergeChat(s, pn.String()); err == nil {
			merged = true
		}
	}
	if merged {
		a.touchAll()
	}
}

func (a *App) mergeChat(from, to string) error {
	tx, err := a.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	tx.Exec(`UPDATE OR IGNORE messages SET chat=? WHERE chat=?`, to, from)
	tx.Exec(`DELETE FROM messages WHERE chat=?`, from)
	tx.Exec(`UPDATE OR IGNORE reactions SET chat=? WHERE chat=?`, to, from)
	var c struct {
		name                         string
		lastTS                       int64
		lastID                       string
		unread, marked, pinned, arch int64
		muted                        int64
	}
	err = tx.QueryRow(`SELECT name, last_ts, last_id, unread, marked_unread, pinned, archived, muted_until FROM chats WHERE jid=?`, from).
		Scan(&c.name, &c.lastTS, &c.lastID, &c.unread, &c.marked, &c.pinned, &c.arch, &c.muted)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	tx.Exec(`INSERT INTO chats (jid, name, last_ts, last_id, unread, marked_unread, pinned, archived, muted_until)
		VALUES (?,?,?,?,?,?,?,?,?)
		ON CONFLICT(jid) DO UPDATE SET
			last_id=CASE WHEN excluded.last_ts > chats.last_ts THEN excluded.last_id ELSE chats.last_id END,
			last_ts=MAX(chats.last_ts, excluded.last_ts),
			unread=chats.unread + excluded.unread,
			marked_unread=MAX(chats.marked_unread, excluded.marked_unread),
			pinned=MAX(chats.pinned, excluded.pinned)`,
		to, c.name, c.lastTS, c.lastID, c.unread, c.marked, c.pinned, c.arch, c.muted)
	tx.Exec(`DELETE FROM chats WHERE jid=?`, from)
	tx.Exec(`INSERT INTO contacts (jid, push_name) SELECT ?, push_name FROM contacts WHERE jid=? AND push_name != ''
		ON CONFLICT(jid) DO UPDATE SET push_name=CASE WHEN contacts.push_name = '' THEN excluded.push_name ELSE contacts.push_name END`, to, from)
	return tx.Commit()
}

// ---- names ----

func (a *App) setPushName(j types.JID, name string) {
	if name == "" || name == "-" {
		return
	}
	key := j.String()
	a.pushMu.Lock()
	same := a.pushSeen[key] == name
	a.pushSeen[key] = name
	a.pushMu.Unlock()
	if same {
		return
	}
	a.db.Exec(`INSERT INTO contacts (jid, push_name) VALUES (?,?) ON CONFLICT(jid) DO UPDATE SET push_name=excluded.push_name`, key, name)
	a.touchChats()
}

func (a *App) importContacts() {
	if a.cli == nil {
		return
	}
	all, err := a.cli.Store.Contacts.GetAllContacts(a.ctx)
	if err != nil {
		return
	}
	tx, err := a.db.Begin()
	if err != nil {
		return
	}
	for j, c := range all {
		name := c.FullName
		if name == "" {
			name = c.FirstName
		}
		if name == "" {
			name = c.BusinessName
		}
		tx.Exec(`INSERT INTO contacts (jid, name, push_name) VALUES (?,?,?) ON CONFLICT(jid) DO UPDATE SET
			name=CASE WHEN excluded.name != '' THEN excluded.name ELSE contacts.name END,
			push_name=CASE WHEN excluded.push_name != '' THEN excluded.push_name ELSE contacts.push_name END`,
			a.canon(j).String(), name, c.PushName)
	}
	tx.Commit()
	a.touchChats()
}

// nameFor resolves a display name: saved contact > push name > group name > +number.
func (a *App) nameFor(j types.JID) string {
	var name, push string
	a.rdb.QueryRow(`SELECT name, push_name FROM contacts WHERE jid=?`, j.String()).Scan(&name, &push)
	if name != "" {
		return name
	}
	if push != "" {
		return push
	}
	if j.Server == types.GroupServer {
		a.rdb.QueryRow(`SELECT name FROM chats WHERE jid=?`, j.String()).Scan(&name)
		if name != "" {
			return name
		}
	}
	if j.Server == types.DefaultUserServer {
		return "+" + j.User
	}
	return ""
}

// notifyReaction tells the owner someone reacted to one of their messages
// (shown only if "Reaction notifications" is on in the app's settings).
func (a *App) notifyReaction(r *msgRow, chat types.JID, target, emoji string) {
	var fromMe, kind int
	var text, fileName string
	if a.rdb.QueryRow(`SELECT from_me, kind, text, file_name FROM messages WHERE chat=? AND id=?`, r.Chat, target).
		Scan(&fromMe, &kind, &text, &fileName) != nil || fromMe != 1 {
		return
	}
	var muted int64
	var archived int
	a.rdb.QueryRow(`SELECT muted_until, archived FROM chats WHERE jid=?`, r.Chat).Scan(&muted, &archived)
	sj, _ := types.ParseJID(r.Sender)
	who := a.nameFor(sj)
	if who == "" {
		who = r.PushName
	}
	body := "Reacted " + emoji + " to “" + previewText(&msgRow{Kind: kind, Text: text, FileName: fileName}) + "”"
	if chat.Server == types.GroupServer && who != "" {
		body = strings.TrimSpace(who) + " reacted " + emoji + " to “" + previewText(&msgRow{Kind: kind, Text: text, FileName: fileName}) + "”"
	}
	emit(map[string]any{"t": "notify", "chat": r.Chat, "id": "reaction-" + r.ID, "title": a.nameFor(chat), "body": body,
		"muted": archived == 1 || muted == -1 || muted > time.Now().Unix(), "reaction": true})
}

func (a *App) notify(r *msgRow, chat types.JID) {
	var muted int64
	var archived int
	a.rdb.QueryRow(`SELECT muted_until, archived FROM chats WHERE jid=?`, r.Chat).Scan(&muted, &archived)
	// Archived chats stay archived and stay quiet, like WhatsApp's "Keep chats archived".
	isMuted := archived == 1 || muted == -1 || muted > time.Now().Unix()
	title := a.nameFor(chat)
	body := previewText(r)
	if chat.Server == types.GroupServer {
		sj, _ := types.ParseJID(r.Sender)
		sender := a.nameFor(sj)
		if sender == "" {
			sender = r.PushName
		}
		if sender != "" {
			body = strings.TrimSpace(sender) + ": " + body
		}
	}
	emit(map[string]any{"t": "notify", "chat": r.Chat, "id": r.ID, "title": title, "body": body, "muted": isMuted})
}

// needsThumb: a photo or video that came without an inline thumbnail but with
// a separately downloadable one.
func needsThumb(r *msgRow) bool {
	return (r.Kind == KImage || r.Kind == KVideo) && len(r.Thumb) == 0 && strings.Contains(r.Media, `"thumb_path"`)
}
