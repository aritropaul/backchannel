package main

import (
	"database/sql"
	"path/filepath"
	"time"

	"go.mau.fi/whatsmeow/types"
)

// recoverMissing asks the phone to resend messages this Mac decrypted but never
// stored. whatsmeow keeps a secret for nearly every message it decrypts, so its
// table knows IDs app.db can lack: an insert that failed, or a run against a
// damaged database (2026-10-02: a stale build dropped the tables and the next run
// lost every incoming message to a constraint error). The phone answers with the
// full message, which lands through onMessage like any other. Each ID is asked
// for once, ever (kv).
func (a *App) recoverMissing() {
	if a.ready() != nil {
		return
	}
	sdb, err := sql.Open("sqlite3", "file:"+filepath.Join(a.dir, "session.db")+"?mode=ro&_busy_timeout=5000")
	if err != nil {
		return
	}
	defer sdb.Close()
	rows, err := sdb.Query(`SELECT chat_jid, sender_jid, message_id FROM whatsmeow_message_secrets ORDER BY rowid DESC LIMIT 300`)
	if err != nil {
		a.log.Warnf("recover: read secrets: %v", err)
		return
	}
	type key struct {
		chat, sender types.JID
		id           string
	}
	var want []key
	for rows.Next() {
		var c, s, id string
		if rows.Scan(&c, &s, &id) != nil {
			continue
		}
		chat, err1 := types.ParseJID(c)
		sender, err2 := types.ParseJID(s)
		if err1 != nil || err2 != nil || chat.Server == types.BroadcastServer || skipChat(a.canon(chat)) {
			continue
		}
		var v string
		if a.rdb.QueryRow(`SELECT id FROM messages WHERE chat=? AND id=?`, a.canon(chat).String(), id).Scan(&v) == nil {
			continue
		}
		if a.rdb.QueryRow(`SELECT v FROM kv WHERE k=?`, "resend:"+id).Scan(&v) == nil {
			continue
		}
		want = append(want, key{chat, sender, id})
	}
	rows.Close()
	asked := 0
	for _, k := range want {
		if a.ready() != nil {
			break
		}
		if _, err := a.cli.SendPeerMessage(a.ctx, a.cli.BuildUnavailableMessageRequest(k.chat, k.sender, k.id)); err != nil {
			a.log.Warnf("recover: resend request for %s/%s: %v", k.chat, k.id, err)
			continue
		}
		a.db.Exec(`INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO NOTHING`, "resend:"+k.id, itoa(int(time.Now().Unix())))
		asked++
		time.Sleep(250 * time.Millisecond)
	}
	if asked > 0 {
		a.log.Infof("recover: asked the phone to resend %d messages missing from app.db", asked)
	}
}
