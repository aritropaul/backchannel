package main

import (
	"errors"
	"os"
	"strings"
	"time"

	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// Settings: the account-side switches WhatsApp keeps on the server (profile,
// privacy, blocked contacts, default timer), read and written for the
// Settings window. Network-bound; Swift calls these off the main thread.

// myProfile is what the Settings header and Profile pane show.
func (a *App) myProfile() (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	me := a.me()
	out := map[string]any{"jid": me.String(), "name": a.cli.Store.PushName, "phone": "+" + me.User,
		"platform": a.cli.Store.Platform}
	if !a.cli.Store.LID.IsEmpty() {
		out["lid"] = a.cli.Store.LID.ToNonAD().String()
	}
	// Asked by phone number, the server answers my own About with " "; by LID it
	// may give the real text. Fall back to the last About set from this Mac.
	about := ""
	for _, j := range []types.JID{me, a.cli.Store.LID} {
		if j.IsEmpty() {
			continue
		}
		if info, err := a.cli.GetUserInfo(a.ctx, []types.JID{j}); err == nil {
			for _, u := range info {
				if strings.TrimSpace(u.Status) != "" {
					about = u.Status
				}
			}
		}
		if about != "" {
			break
		}
	}
	if about == "" {
		a.rdb.QueryRow(`SELECT v FROM kv WHERE k='about'`).Scan(&about)
	}
	out["about"] = about
	out["picture"] = a.fullPicture(me)
	var timer string
	a.rdb.QueryRow(`SELECT v FROM kv WHERE k='default_timer'`).Scan(&timer)
	out["default_timer"] = timer
	var notices string
	a.rdb.QueryRow(`SELECT v FROM kv WHERE k='security_notices'`).Scan(&notices)
	out["security_notices"] = notices == "1"
	return out, nil
}

func (a *App) setName(name string) error {
	if err := a.ready(); err != nil {
		return err
	}
	if name == "" {
		return errors.New("name can't be empty")
	}
	if err := a.cli.SendAppState(a.ctx, appstate.BuildSettingPushName(name)); err != nil {
		return err
	}
	a.cli.Store.PushName = name
	a.setPushName(a.me(), name)
	return nil
}

func (a *App) setAbout(text string) error {
	if err := a.ready(); err != nil {
		return err
	}
	if err := a.cli.SetStatusMessage(a.ctx, types.SetStatusInput{Text: &text}); err != nil {
		return err
	}
	a.db.Exec(`INSERT INTO kv (k, v) VALUES ('about', ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`, text)
	return nil
}

// setPhoto sets my profile picture from a square JPEG the app prepared, or
// removes it when path is empty.
func (a *App) setPhoto(path string) (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	var data []byte
	if path != "" {
		var err error
		if data, err = os.ReadFile(path); err != nil {
			return nil, err
		}
	}
	if _, err := a.cli.SetGroupPhoto(a.ctx, a.me(), data); err != nil {
		return nil, err
	}
	me := a.me().String()
	a.db.Exec(`UPDATE chats SET avatar='', avatar_ts=0 WHERE jid=?`, me)
	a.db.Exec(`DELETE FROM avatars WHERE jid=?`, me)
	a.avatarSeen.Delete(me)
	a.touchChats()
	return map[string]any{"picture": a.fullPicture(a.me())}, nil
}

func (a *App) privacy() (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	p, err := a.cli.TryFetchPrivacySettings(a.ctx, true)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"last": string(p.LastSeen), "online": string(p.Online), "profile": string(p.Profile),
		"status": string(p.Status), "groupadd": string(p.GroupAdd), "readreceipts": string(p.ReadReceipts),
		"calladd": string(p.CallAdd), "messages": string(p.Messages),
	}, nil
}

func (a *App) setPrivacy(name, value string) error {
	if err := a.ready(); err != nil {
		return err
	}
	_, err := a.cli.SetPrivacySetting(a.ctx, types.PrivacySettingType(name), types.PrivacySetting(value))
	return err
}

// setDefaultTimer sets the disappearing-message timer for new chats. WhatsApp
// has no read-back for it, so the last value set here is remembered locally.
func (a *App) setDefaultTimer(seconds int) error {
	if err := a.ready(); err != nil {
		return err
	}
	if err := a.cli.SetDefaultDisappearingTimer(a.ctx, time.Duration(seconds)*time.Second); err != nil {
		return err
	}
	a.db.Exec(`INSERT INTO kv (k, v) VALUES ('default_timer', ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`, itoa(seconds))
	return nil
}

func (a *App) blocklist() (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	bl, err := a.cli.GetBlocklist(a.ctx)
	if err != nil {
		return nil, err
	}
	people := []map[string]any{}
	for _, j := range bl.JIDs {
		c := a.canon(j)
		phone := ""
		if c.Server == types.DefaultUserServer {
			phone = "+" + c.User
		}
		people = append(people, map[string]any{"jid": c.String(), "name": a.nameFor(c), "phone": phone})
	}
	return map[string]any{"blocked": people}, nil
}

func (a *App) block(jidS string, on bool) error {
	if err := a.ready(); err != nil {
		return err
	}
	j, err := parseChat(jidS)
	if err != nil {
		return err
	}
	action := events.BlocklistChangeActionUnblock
	if on {
		action = events.BlocklistChangeActionBlock
	}
	_, err = a.cli.UpdateBlocklist(a.ctx, j, action)
	return err
}

// devices lists my other linked devices (this Mac isn't included).
func (a *App) devices() (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	list, err := a.cli.GetUserDevices(a.ctx, []types.JID{a.me()})
	if err != nil {
		return nil, err
	}
	var out []map[string]any
	for _, d := range list {
		out = append(out, map[string]any{"device": int(d.Device), "primary": d.Device == 0})
	}
	return map[string]any{"devices": out, "this": int(a.cli.Store.ID.Device)}, nil
}

// archiveAll archives every chat that isn't archived (WhatsApp has no bulk call).
func (a *App) archiveAll() (any, error) {
	if err := a.ready(); err != nil {
		return nil, err
	}
	rows, err := a.rdb.Query(`SELECT jid FROM chats WHERE archived=0 AND last_ts > 0`)
	if err != nil {
		return nil, err
	}
	var jids []string
	for rows.Next() {
		var j string
		if rows.Scan(&j) == nil {
			jids = append(jids, j)
		}
	}
	rows.Close()
	go func() {
		for _, j := range jids {
			a.appState(j, "archive", true, 0)
		}
	}()
	return map[string]any{"count": len(jids)}, nil
}

func (a *App) setSecurityNotices(on bool) {
	v := "0"
	if on {
		v = "1"
	}
	a.db.Exec(`INSERT INTO kv (k, v) VALUES ('security_notices', ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`, v)
}

// onIdentityChange posts "security code changed" into the chat when the
// owner has security notifications on (WhatsApp's own toggle).
func (a *App) onIdentityChange(e *events.IdentityChange) {
	var on string
	a.db.QueryRow(`SELECT v FROM kv WHERE k='security_notices'`).Scan(&on)
	if on != "1" || e.Implicit {
		return
	}
	chat := a.canon(e.JID)
	var exists int
	a.db.QueryRow(`SELECT 1 FROM chats WHERE jid=?`, chat.String()).Scan(&exists)
	if exists == 0 {
		return
	}
	ts := e.Timestamp
	if ts.IsZero() {
		ts = time.Now()
	}
	r := &msgRow{Chat: chat.String(), ID: "notice-" + itoa(int(ts.UnixMilli())), Sender: chat.String(), TS: ts.UnixMilli(),
		Kind: KNotice, Text: "Your security code with " + a.nameFor(chat) + " changed."}
	upsertMessage(a.db, r)
	a.touchMsg(r.Chat, r.ID)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
