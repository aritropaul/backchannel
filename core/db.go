package main

import (
	"database/sql"
	"fmt"
	"strings"
)

// Message kinds. Mirrored in Swift (MessageKind).
const (
	KText = iota
	KImage
	KVideo
	KAudio
	KVoice
	KDocument
	KSticker
	KLocation
	KContact
	KPoll
	KRevoked
	KUnsupported
	KPending // undecryptable, waiting for retry
	KNotice  // a system line in the chat, e.g. "security code changed"
)

// Outgoing status. Mirrored in Swift (MessageStatus).
const (
	StFailed    = -1
	StPending   = 0
	StSent      = 1
	StDelivered = 2
	StRead      = 3
	StPlayed    = 4
)

const schemaVersion = 3

// The UI reads this database directly (read-only), so the schema is the API.
// Keep column names stable; bump schemaVersion for breaking changes.
const schema = `
CREATE TABLE IF NOT EXISTS chats (
	jid           TEXT PRIMARY KEY,
	name          TEXT    NOT NULL DEFAULT '',
	is_group      INTEGER NOT NULL DEFAULT 0,
	last_ts       INTEGER NOT NULL DEFAULT 0,
	last_id       TEXT    NOT NULL DEFAULT '',
	unread        INTEGER NOT NULL DEFAULT 0,
	marked_unread INTEGER NOT NULL DEFAULT 0,
	pinned        INTEGER NOT NULL DEFAULT 0,
	archived      INTEGER NOT NULL DEFAULT 0,
	muted_until   INTEGER NOT NULL DEFAULT 0,
	avatar        TEXT    NOT NULL DEFAULT '',
	avatar_ts     INTEGER NOT NULL DEFAULT 0,
	participants  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS chats_order ON chats(archived, pinned DESC, last_ts DESC);

CREATE TABLE IF NOT EXISTS messages (
	chat         TEXT    NOT NULL,
	id           TEXT    NOT NULL,
	sender       TEXT    NOT NULL DEFAULT '',
	push_name    TEXT    NOT NULL DEFAULT '',
	from_me      INTEGER NOT NULL DEFAULT 0,
	ts           INTEGER NOT NULL,
	kind         INTEGER NOT NULL DEFAULT 0,
	text         TEXT    NOT NULL DEFAULT '',
	status       INTEGER NOT NULL DEFAULT 0,
	edited       INTEGER NOT NULL DEFAULT 0,
	quote_id     TEXT    NOT NULL DEFAULT '',
	quote_sender TEXT    NOT NULL DEFAULT '',
	quote_text   TEXT    NOT NULL DEFAULT '',
	quote_kind   INTEGER NOT NULL DEFAULT 0,
	reactions    TEXT    NOT NULL DEFAULT '',
	mime         TEXT    NOT NULL DEFAULT '',
	file_name    TEXT    NOT NULL DEFAULT '',
	file_size    INTEGER NOT NULL DEFAULT 0,
	seconds      INTEGER NOT NULL DEFAULT 0,
	width        INTEGER NOT NULL DEFAULT 0,
	height       INTEGER NOT NULL DEFAULT 0,
	thumb        BLOB,
	media        TEXT    NOT NULL DEFAULT '',
	media_path   TEXT    NOT NULL DEFAULT '',
	waveform     BLOB,
	link_url     TEXT    NOT NULL DEFAULT '',
	link_title   TEXT    NOT NULL DEFAULT '',
	link_desc    TEXT    NOT NULL DEFAULT '',
	UNIQUE (chat, id)
);
CREATE INDEX IF NOT EXISTS messages_ts ON messages(chat, ts);

CREATE TABLE IF NOT EXISTS reactions (
	chat    TEXT NOT NULL,
	msg_id  TEXT NOT NULL,
	sender  TEXT NOT NULL,
	emoji   TEXT NOT NULL,
	ts      INTEGER NOT NULL,
	PRIMARY KEY (chat, msg_id, sender)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS contacts (
	jid       TEXT PRIMARY KEY,
	name      TEXT NOT NULL DEFAULT '',
	push_name TEXT NOT NULL DEFAULT ''
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS avatars (
	jid  TEXT PRIMARY KEY,
	path TEXT NOT NULL DEFAULT '',
	ts   INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS kv (
	k TEXT PRIMARY KEY,
	v TEXT NOT NULL
) WITHOUT ROWID;

-- Per-member delivery/read state for my group messages; a group message only
-- reads as Delivered/Read once every other member has got there.
CREATE TABLE IF NOT EXISTS receipts (
	chat        TEXT    NOT NULL,
	msg_id      TEXT    NOT NULL,
	participant TEXT    NOT NULL,
	status      INTEGER NOT NULL,
	ts          INTEGER NOT NULL,
	PRIMARY KEY (chat, msg_id, participant)
) WITHOUT ROWID;

-- Full-text index over message text and file names, kept in step by triggers.
-- chat/id are stored so results join back without relying on rowid stability.
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
	text, file_name, chat UNINDEXED, id UNINDEXED,
	tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
	INSERT INTO messages_fts (rowid, text, file_name, chat, id)
		SELECT new.rowid, new.text, new.file_name, new.chat, new.id WHERE new.text != '' OR new.file_name != '';
END;
CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE OF text, file_name, chat ON messages
	WHEN old.text != new.text OR old.file_name != new.file_name OR old.chat != new.chat BEGIN
	DELETE FROM messages_fts WHERE rowid = old.rowid;
	INSERT INTO messages_fts (rowid, text, file_name, chat, id)
		SELECT new.rowid, new.text, new.file_name, new.chat, new.id WHERE new.text != '' OR new.file_name != '';
END;
CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN
	DELETE FROM messages_fts WHERE rowid = old.rowid;
END;
`

// Every table the app owns, for drops and wipes.
var appTables = []string{"chats", "messages", "reactions", "contacts", "avatars", "kv", "receipts", "messages_fts"}

func openAppDB(path string) (*sql.DB, error) {
	dsn := fmt.Sprintf("file:%s?_journal_mode=WAL&_synchronous=NORMAL&_busy_timeout=5000&_txlock=immediate&_foreign_keys=off", path)
	db, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, err
	}
	// One writer connection: SQLite serializes writes anyway, and this keeps
	// statement order deterministic. Readers (the UI) use their own connection.
	db.SetMaxOpenConns(1)
	var v int
	if err := db.QueryRow("PRAGMA user_version").Scan(&v); err != nil {
		return nil, err
	}
	// Additive migrations keep synced history (WhatsApp won't resend it).
	fillFTS := false
	if v == 1 {
		for _, q := range []string{
			`ALTER TABLE messages ADD COLUMN waveform BLOB`,
			`ALTER TABLE messages ADD COLUMN link_url TEXT NOT NULL DEFAULT ''`,
			`ALTER TABLE messages ADD COLUMN link_title TEXT NOT NULL DEFAULT ''`,
			`ALTER TABLE messages ADD COLUMN link_desc TEXT NOT NULL DEFAULT ''`,
		} {
			if _, err := db.Exec(q); err != nil && !strings.Contains(err.Error(), "duplicate column") {
				return nil, err
			}
		}
		v = 2
	}
	if v == 2 {
		if _, err := db.Exec(`ALTER TABLE chats ADD COLUMN participants INTEGER NOT NULL DEFAULT 0`); err != nil &&
			!strings.Contains(err.Error(), "duplicate column") {
			return nil, err
		}
		fillFTS = true
		v = schemaVersion
	}
	if v != 0 && v != schemaVersion {
		// Unknown future/past layout: cache only, drop and resync.
		for _, t := range appTables {
			if _, err := db.Exec("DROP TABLE IF EXISTS " + t); err != nil {
				return nil, err
			}
		}
	}
	if _, err := db.Exec(schema); err != nil {
		return nil, err
	}
	if fillFTS {
		// Index history that predates the triggers.
		if _, err := db.Exec(`INSERT INTO messages_fts (rowid, text, file_name, chat, id)
			SELECT rowid, text, file_name, chat, id FROM messages WHERE text != '' OR file_name != ''`); err != nil {
			return nil, err
		}
	}
	if _, err := db.Exec(fmt.Sprintf("PRAGMA user_version=%d", schemaVersion)); err != nil {
		return nil, err
	}
	// Pictures fetched before the avatars table existed live on chat rows.
	db.Exec(`INSERT OR IGNORE INTO avatars (jid, path, ts) SELECT jid, avatar, avatar_ts FROM chats WHERE avatar != ''`)
	return db, nil
}

// openReadDB is a separate read-only pool. Lookups never compete for the single
// writer connection, so a read inside a write transaction can't deadlock, and
// UI-driven reads don't queue behind a long history import.
func openReadDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite3", fmt.Sprintf("file:%s?mode=ro&_busy_timeout=5000", path))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	return db, nil
}

func (a *App) wipeAppDB() {
	for _, t := range appTables {
		a.db.Exec("DELETE FROM " + t)
	}
	a.touchAll()
}

// execer lets helpers run inside or outside a transaction.
type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
	QueryRow(query string, args ...any) *sql.Row
	Query(query string, args ...any) (*sql.Rows, error)
}

type msgRow struct {
	Chat, ID, Sender, PushName string
	FromMe                     bool
	TS                         int64 // unix ms
	Kind                       int
	Text                       string
	Status                     int
	QuoteID, QuoteSender       string
	QuoteText                  string
	QuoteKind                  int
	Mime, FileName             string
	FileSize                   int64
	Seconds, Width, Height     int
	Thumb                      []byte
	Media                      string
	MediaPath                  string
	Waveform                   []byte
	LinkURL, LinkTitle         string
	LinkDesc                   string
}

// upsertMessage inserts or refreshes a message. Status only ever moves forward,
// a downloaded media_path is kept, and a revoked message stays revoked.
func upsertMessage(x execer, m *msgRow) error {
	_, err := x.Exec(`INSERT INTO messages
		(chat, id, sender, push_name, from_me, ts, kind, text, status, quote_id, quote_sender, quote_text, quote_kind,
		 mime, file_name, file_size, seconds, width, height, thumb, media, media_path, waveform, link_url, link_title, link_desc)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(chat, id) DO UPDATE SET
			sender=excluded.sender,
			push_name=CASE WHEN excluded.push_name != '' THEN excluded.push_name ELSE messages.push_name END,
			kind=CASE WHEN messages.kind = 10 THEN 10 ELSE excluded.kind END,
			text=CASE WHEN messages.kind = 10 OR messages.edited = 1 THEN messages.text ELSE excluded.text END,
			status=MAX(messages.status, excluded.status),
			quote_id=excluded.quote_id, quote_sender=excluded.quote_sender,
			quote_text=excluded.quote_text, quote_kind=excluded.quote_kind,
			mime=excluded.mime, file_name=excluded.file_name, file_size=excluded.file_size,
			seconds=excluded.seconds, width=excluded.width, height=excluded.height,
			thumb=COALESCE(excluded.thumb, messages.thumb),
			media=CASE WHEN excluded.media != '' THEN excluded.media ELSE messages.media END,
			media_path=CASE WHEN messages.media_path != '' THEN messages.media_path ELSE excluded.media_path END,
			waveform=COALESCE(excluded.waveform, messages.waveform),
			link_url=excluded.link_url, link_title=excluded.link_title, link_desc=excluded.link_desc`,
		m.Chat, m.ID, m.Sender, m.PushName, b2i(m.FromMe), m.TS, m.Kind, m.Text, m.Status,
		m.QuoteID, m.QuoteSender, m.QuoteText, m.QuoteKind,
		m.Mime, m.FileName, m.FileSize, m.Seconds, m.Width, m.Height, nilIfEmpty(m.Thumb), m.Media, m.MediaPath,
		nilIfEmpty(m.Waveform), m.LinkURL, m.LinkTitle, m.LinkDesc)
	return err
}

// bumpChat moves the chat's "last message" pointer forward if this message is newer.
func bumpChat(x execer, chat string, isGroup bool, ts int64, id string) error {
	_, err := x.Exec(`INSERT INTO chats (jid, is_group, last_ts, last_id) VALUES (?,?,?,?)
		ON CONFLICT(jid) DO UPDATE SET
			last_id=CASE WHEN excluded.last_ts >= chats.last_ts THEN excluded.last_id ELSE chats.last_id END,
			last_ts=MAX(chats.last_ts, excluded.last_ts)`,
		chat, b2i(isGroup), ts, id)
	return err
}

func ensureChat(x execer, chat string, isGroup bool) error {
	_, err := x.Exec(`INSERT INTO chats (jid, is_group) VALUES (?,?) ON CONFLICT(jid) DO NOTHING`, chat, b2i(isGroup))
	return err
}

// refreshReactions recomputes the denormalized summary the UI renders:
// "<up to 3 distinct emoji by count>\t<total>\t<my emoji>".
func refreshReactions(x execer, chat, msgID, me string) error {
	rows, err := x.Query(`SELECT emoji, COUNT(*) c, MAX(sender = ?) mine FROM reactions
		WHERE chat=? AND msg_id=? AND emoji != '' GROUP BY emoji ORDER BY c DESC, MIN(ts) ASC`, me, chat, msgID)
	if err != nil {
		return err
	}
	var top strings.Builder
	total, n := 0, 0
	mine := ""
	for rows.Next() {
		var e string
		var c, m int
		if rows.Scan(&e, &c, &m) == nil {
			if n < 3 {
				top.WriteString(e)
			}
			n++
			total += c
			if m == 1 {
				mine = e
			}
		}
	}
	rows.Close()
	summary := ""
	if total > 0 {
		summary = fmt.Sprintf("%s\t%d\t%s", top.String(), total, mine)
	}
	_, err = x.Exec(`UPDATE messages SET reactions=? WHERE chat=? AND id=?`, summary, chat, msgID)
	return err
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

func nilIfEmpty(b []byte) any {
	if len(b) == 0 {
		return nil
	}
	return b
}
