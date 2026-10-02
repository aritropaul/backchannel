package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"google.golang.org/protobuf/proto"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// sink receives every outgoing event as a JSON object. The c-archive build
// points it at the Swift callback; the CLI build prints.
var sink func([]byte)

func emit(v any) {
	if sink == nil {
		return
	}
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	sink(b)
}

type App struct {
	ctx    context.Context
	dir    string
	db     *sql.DB // single writer
	rdb    *sql.DB // read-only pool
	store  *sqlstore.Container
	cli    *whatsmeow.Client
	log    waLog.Logger
	events chan any

	lidMu    sync.RWMutex
	lidToPN  map[string]types.JID
	lidMiss  map[string]time.Time
	pushMu   sync.Mutex
	pushSeen map[string]string

	activeChat atomic.Value // string: chat open in the focused window, "" if none
	appActive  atomic.Bool

	pend struct {
		sync.Mutex
		chats  bool
		msgs   map[string]map[string]struct{}
		reload map[string]struct{}
		timer  *time.Timer
	}

	avatarQ         chan string
	avatarSeen      sync.Map
	media           sync.Map // in-flight downloads
	olderAsked      sync.Map // chat -> time of last on-demand history request
	groupAsked      sync.Map // group -> time of last member-count lookup
	backfilled      sync.Map // chat -> struct{}: missing previews/waveforms already re-requested
	backfillPending sync.Map // chats opened before we were connected
	thumbAsked      sync.Map // chat/id -> thumbnail download attempted this session
	synced          atomic.Bool

	statMsgs  atomic.Int64 // messages written
	statConvs atomic.Int64 // history conversations imported
}

var app *App

// start opens both databases synchronously (so the UI can read local data
// immediately) and connects in the background. It reports whether a paired
// session exists and, if so, our own JID.
func start(dir string) (string, error) {
	if app != nil {
		return app.me().String(), nil
	}
	for _, d := range []string{dir, filepath.Join(dir, "media"), filepath.Join(dir, "avatars")} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return "", err
		}
	}
	db, err := openAppDB(filepath.Join(dir, "app.db"))
	if err != nil {
		return "", fmt.Errorf("app db: %w", err)
	}
	rdb, err := openReadDB(filepath.Join(dir, "app.db"))
	if err != nil {
		return "", fmt.Errorf("app read db: %w", err)
	}
	a := &App{
		ctx:      context.Background(),
		dir:      dir,
		db:       db,
		rdb:      rdb,
		lidMiss:  map[string]time.Time{},
		log:      newLogger(filepath.Join(dir, "core.log")),
		events:   make(chan any, 8192),
		lidToPN:  map[string]types.JID{},
		pushSeen: map[string]string{},
		avatarQ:  make(chan string, 4096),
	}
	a.activeChat.Store("")
	a.pend.msgs = map[string]map[string]struct{}{}
	a.pend.reload = map[string]struct{}{}
	app = a

	// Look like a regular WhatsApp Web session on a Mac: the most common
	// companion fingerprint there is.
	store.SetOSInfo("Mac OS", [3]uint32{26, 0, 0})
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_CHROME.Enum()
	store.DeviceProps.RequireFullSync = proto.Bool(true)
	if store.DeviceProps.HistorySyncConfig == nil {
		store.DeviceProps.HistorySyncConfig = &waCompanionReg.DeviceProps_HistorySyncConfig{}
	}
	hs := store.DeviceProps.HistorySyncConfig
	hs.FullSyncDaysLimit = proto.Uint32(3650)
	hs.FullSyncSizeMbLimit = proto.Uint32(10240)
	hs.StorageQuotaMb = proto.Uint32(10240)

	dsn := fmt.Sprintf("file:%s?_foreign_keys=on&_journal_mode=WAL&_synchronous=NORMAL&_busy_timeout=5000", filepath.Join(dir, "session.db"))
	c, err := sqlstore.New(a.ctx, "sqlite3", dsn, a.log.Sub("store"))
	if err != nil {
		return "", fmt.Errorf("session store: %w", err)
	}
	a.store = c
	me := ""
	if dev, err := c.GetFirstDevice(a.ctx); err == nil && dev.ID != nil {
		me = dev.ID.ToNonAD().String()
	}

	go a.loop()
	go a.avatarLoop()
	go a.statsLoop()
	go a.connect()
	return me, nil
}

func (a *App) connect() {
	dev, err := a.store.GetFirstDevice(a.ctx)
	if err != nil {
		emit(map[string]any{"t": "error", "msg": "device: " + err.Error()})
		return
	}
	cli := whatsmeow.NewClient(dev, a.log.Sub("client"))
	cli.AddEventHandler(func(evt any) {
		// Deep buffer, then real backpressure: if we ever fall behind, whatsmeow
		// slows down instead of us parking unbounded events (and their protos)
		// in memory.
		a.events <- evt
	})
	a.cli = cli

	if cli.Store.ID == nil {
		qr, err := cli.GetQRChannel(a.ctx)
		if err != nil {
			emit(map[string]any{"t": "error", "msg": "qr: " + err.Error()})
			return
		}
		if err := cli.Connect(); err != nil {
			emit(map[string]any{"t": "state", "s": "offline", "msg": err.Error()})
			return
		}
		go func() {
			for item := range qr {
				switch item.Event {
				case whatsmeow.QRChannelEventCode:
					emit(map[string]any{"t": "qr", "code": item.Code, "timeout": item.Timeout.Seconds()})
				case "success":
					emit(map[string]any{"t": "state", "s": "syncing"})
				case "timeout":
					emit(map[string]any{"t": "state", "s": "qr_timeout"})
				default:
					msg := item.Event
					if item.Error != nil {
						msg = item.Error.Error()
					}
					emit(map[string]any{"t": "state", "s": "pair_error", "msg": msg})
				}
			}
		}()
		return
	}
	emit(map[string]any{"t": "state", "s": "connecting", "me": cli.Store.ID.ToNonAD().String()})
	// whatsmeow only auto-reconnects after a first successful connection, so
	// retry the initial dial ourselves (e.g. launched while offline).
	for wait := 2 * time.Second; ; wait = min(wait*2, 60*time.Second) {
		err := cli.Connect()
		if err == nil || a.cli != cli {
			return
		}
		emit(map[string]any{"t": "state", "s": "offline", "msg": err.Error()})
		time.Sleep(wait)
	}
}

// restartPairing tears down the client and starts a fresh QR session.
func (a *App) restartPairing() {
	if a.cli != nil {
		a.cli.Disconnect()
	}
	go a.connect()
}

func (a *App) me() types.JID {
	if a.cli == nil || a.cli.Store.ID == nil {
		return types.EmptyJID
	}
	return a.cli.Store.ID.ToNonAD()
}

// canon maps a JID to the single identity we key chats and contacts by:
// the phone-number JID when a LID mapping is known, else the JID itself.
func (a *App) canon(j types.JID) types.JID {
	j = j.ToNonAD()
	if j.Server != types.HiddenUserServer || a.cli == nil {
		return j
	}
	a.lidMu.RLock()
	pn, ok := a.lidToPN[j.User]
	missAt, missed := a.lidMiss[j.User]
	a.lidMu.RUnlock()
	if ok {
		return pn
	}
	if missed && time.Since(missAt) < 30*time.Second {
		return j // recently unknown; don't hit the store for every message
	}
	pn, err := a.cli.Store.LIDs.GetPNForLID(a.ctx, j)
	if err != nil || pn.IsEmpty() {
		a.lidMu.Lock()
		a.lidMiss[j.User] = time.Now()
		a.lidMu.Unlock()
		return j
	}
	pn = pn.ToNonAD()
	a.lidMu.Lock()
	a.lidToPN[j.User] = pn
	delete(a.lidMiss, j.User)
	a.lidMu.Unlock()
	return pn
}

func skipChat(j types.JID) bool {
	switch j.Server {
	case types.BroadcastServer, types.NewsletterServer: // status, broadcast lists, channels
		return true
	}
	return j == types.PSAJID || j == types.LegacyPSAJID || j.IsEmpty()
}

// ---- change notifications, coalesced so bursts become one UI refresh ----

func (a *App) touchChats() {
	a.pend.Lock()
	a.pend.chats = true
	a.scheduleFlush()
	a.pend.Unlock()
}

func (a *App) touchMsg(chat, id string) {
	a.pend.Lock()
	a.pend.chats = true
	m := a.pend.msgs[chat]
	if m == nil {
		m = map[string]struct{}{}
		a.pend.msgs[chat] = m
	}
	m[id] = struct{}{}
	a.scheduleFlush()
	a.pend.Unlock()
}

func (a *App) touchReload(chat string) {
	a.pend.Lock()
	a.pend.chats = true
	a.pend.reload[chat] = struct{}{}
	a.scheduleFlush()
	a.pend.Unlock()
}

func (a *App) touchAll() {
	a.pend.Lock()
	a.pend.chats = true
	a.pend.reload["*"] = struct{}{}
	a.scheduleFlush()
	a.pend.Unlock()
}

func (a *App) scheduleFlush() {
	if a.pend.timer == nil {
		a.pend.timer = time.AfterFunc(10*time.Millisecond, a.flush)
	}
}

func (a *App) flush() {
	a.pend.Lock()
	chats, msgs, reload := a.pend.chats, a.pend.msgs, a.pend.reload
	a.pend.chats = false
	a.pend.msgs = map[string]map[string]struct{}{}
	a.pend.reload = map[string]struct{}{}
	a.pend.timer = nil
	a.pend.Unlock()

	if _, all := reload["*"]; all {
		emit(map[string]any{"t": "reload", "chat": "*"})
		return
	}
	for chat := range reload {
		emit(map[string]any{"t": "reload", "chat": chat})
		delete(msgs, chat)
	}
	for chat, ids := range msgs {
		if len(ids) > 200 {
			emit(map[string]any{"t": "reload", "chat": chat})
			continue
		}
		list := make([]string, 0, len(ids))
		for id := range ids {
			list = append(list, id)
		}
		emit(map[string]any{"t": "msgs", "chat": chat, "ids": list})
	}
	if chats {
		emit(map[string]any{"t": "chats"})
	}
}

// statsLoop logs resource use so slow syncs and leaks show up in core.log:
// every 10s while messages are flowing, every minute once they stop, so an
// idle app isn't woken six times a minute to log the same line.
func (a *App) statsLoop() {
	var ms runtime.MemStats
	var lastMsgs int64
	every := 10 * time.Second
	for {
		time.Sleep(every)
		runtime.ReadMemStats(&ms)
		msgs := a.statMsgs.Load()
		a.log.Infof("stats heap=%dMB sys=%dMB goroutines=%d queue=%d/%d msgs=%d (+%d/%s) convs=%d",
			ms.HeapAlloc>>20, ms.Sys>>20, runtime.NumGoroutine(), len(a.events), cap(a.events),
			msgs, msgs-lastMsgs, every, a.statConvs.Load())
		if msgs != lastMsgs || len(a.events) > 0 {
			every = 10 * time.Second
		} else {
			every = time.Minute
		}
		lastMsgs = msgs
	}
}

// ---- logging to a file in the data dir (stdout is invisible in a .app) ----

type fileLogger struct {
	mod string
	f   *os.File
}

func newLogger(path string) waLog.Logger {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return waLog.Noop
	}
	return &fileLogger{mod: "core", f: f}
}

func (l *fileLogger) out(level, msg string, args ...any) {
	fmt.Fprintf(l.f, "%s [%s %s] %s\n", time.Now().Format("15:04:05.000"), l.mod, level, fmt.Sprintf(msg, args...))
}
func (l *fileLogger) Warnf(msg string, args ...any)  { l.out("WARN", msg, args...) }
func (l *fileLogger) Errorf(msg string, args ...any) { l.out("ERROR", msg, args...) }
func (l *fileLogger) Infof(msg string, args ...any)  { l.out("INFO", msg, args...) }
func (l *fileLogger) Debugf(string, ...any)          {}
func (l *fileLogger) Sub(mod string) waLog.Logger    { return &fileLogger{mod: l.mod + "/" + mod, f: l.f} }
