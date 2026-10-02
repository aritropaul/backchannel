#!/usr/bin/env python3
"""Builds a synthetic store for UI work: `WA_PREVIEW_DIR=<dir> WA.app/Contents/MacOS/WA`.

All names and messages here are sample data. Nothing touches a real account.
usage: tools/make_preview_db.py <dir>
"""
import os, re, sqlite3, subprocess, sys, time, glob

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "build/preview"))
os.makedirs(os.path.join(out, "media"), exist_ok=True)
db_path = os.path.join(out, "app.db")
for suffix in ("", "-wal", "-shm"):
    if os.path.exists(db_path + suffix):
        os.remove(db_path + suffix)

schema = re.search(r"const schema = `(.*?)`", open(os.path.join(root, "core/db.go")).read(), re.S).group(1)
db = sqlite3.connect(db_path)
db.executescript("PRAGMA journal_mode=WAL;" + schema + "PRAGMA user_version=1;")

# A real photo for the image bubbles: any system wallpaper, resized.
photo = os.path.join(out, "media", "photo.jpg")
thumb_path = os.path.join(out, "media", "thumb.jpg")
src = next(iter(sorted(glob.glob("/System/Library/Desktop Pictures/*.heic"))), None)
if src:
    subprocess.run(["sips", "-s", "format", "jpeg", "-Z", "1400", src, "--out", photo], capture_output=True)
    subprocess.run(["sips", "-s", "format", "jpeg", "-Z", "64", src, "--out", thumb_path], capture_output=True)
thumb = open(thumb_path, "rb").read() if os.path.exists(thumb_path) else None
pw, ph = 1400, 788
if os.path.exists(photo):
    info = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", photo], capture_output=True, text=True).stdout
    pw = int(re.search(r"pixelWidth: (\d+)", info).group(1)); ph = int(re.search(r"pixelHeight: (\d+)", info).group(1))

ME = "15550000000@s.whatsapp.net"
now = int(time.time() * 1000)
MIN, HOUR, DAY = 60_000, 3_600_000, 86_400_000

contacts = {
    "15550000001@s.whatsapp.net": "Maya Chen",
    "15550000002@s.whatsapp.net": "Jonas Weber",
    "15550000003@s.whatsapp.net": "Priya Raman",
    "15550000004@s.whatsapp.net": "Leo Martins",
    "15550000005@s.whatsapp.net": "Sam Okafor",
    "15550000006@s.whatsapp.net": "Ines Duarte",
    "15550000007@s.whatsapp.net": "Theo Park",
}
for jid, name in contacts.items():
    db.execute("INSERT INTO contacts (jid, name, push_name) VALUES (?,?,?)", (jid, name, name.split()[0]))
db.execute("INSERT INTO contacts (jid, push_name) VALUES (?,?)", ("15550000099@s.whatsapp.net", "Rafa"))

seq = [0]
def msg(chat, sender, ts, text="", kind=0, status=3, quote=None, reactions="", **kw):
    seq[0] += 1
    mid = f"M{seq[0]:05d}"
    q = quote or {}
    db.execute("""INSERT INTO messages (chat, id, sender, push_name, from_me, ts, kind, text, status, quote_id, quote_sender,
                  quote_text, quote_kind, reactions, mime, file_name, file_size, seconds, width, height, thumb, media, media_path, edited)
                  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
               (chat, mid, sender, contacts.get(sender, "").split(" ")[0], int(sender == ME), ts, kind, text,
                status if sender == ME else 0, q.get("id", ""), q.get("sender", ""), q.get("text", ""), q.get("kind", 0),
                reactions, kw.get("mime", ""), kw.get("file_name", ""), kw.get("file_size", 0), kw.get("seconds", 0),
                kw.get("width", 0), kw.get("height", 0), kw.get("thumb"), kw.get("media", ""), kw.get("media_path", ""), kw.get("edited", 0)))
    return mid

def chat(jid, name="", is_group=0, unread=0, pinned=0, archived=0, muted=0, marked=0):
    db.execute("INSERT INTO chats (jid, name, is_group, unread, pinned, archived, muted_until, marked_unread, avatar) VALUES (?,?,?,?,?,?,?,?,'-')",
               (jid, name, is_group, unread, pinned, archived, muted, marked))

def finish(jid):
    row = db.execute("SELECT id, ts FROM messages WHERE chat=? ORDER BY ts DESC, rowid DESC LIMIT 1", (jid,)).fetchone()
    if row:
        db.execute("UPDATE chats SET last_id=?, last_ts=? WHERE jid=?", (row[0], row[1], jid))

MAYA = "15550000001@s.whatsapp.net"
chat(MAYA, unread=2, pinned=1)
t = now - 2 * DAY - 5 * HOUR
msg(MAYA, MAYA, t, "Are we still on for the climbing gym this week?")
msg(MAYA, ME, t + 4 * MIN, "Yes! Thursday after work works for me")
msg(MAYA, ME, t + 4 * MIN + 20_000, "I'll book the 7pm slot", status=3)
t = now - DAY - 3 * HOUR
msg(MAYA, MAYA, t, "Booked a table for after too 🍜")
a = msg(MAYA, MAYA, t + MIN, "Also: *don't forget* the chalk bag this time. _Last_ time was ~fine~ a disaster 😅", reactions="😂\t1\t😂")
msg(MAYA, ME, t + 6 * MIN, "Haha fair. Adding it to my list right now", status=3,
    quote={"id": a, "sender": MAYA, "text": "Also: don't forget the chalk bag this time.", "kind": 0})
msg(MAYA, ME, t + 7 * MIN, "👍", status=3)
t = now - 2 * HOUR
msg(MAYA, MAYA, t, "Look at the view from the new wall", kind=1, width=pw, height=ph, thumb=thumb, media_path=photo, mime="image/jpeg")
msg(MAYA, MAYA, t + MIN, "The route setter said it's the hardest one in the city. Want to try it Thursday? It's apparently a 6c+ but everyone says it climbs like a 7a because of the crux near the top where you have to commit to a dyno with no feet. https://example.com/route-guide")
msg(MAYA, ME, t + 30 * MIN, "Absolutely. I've been training for exactly this.", status=2, edited=1)
msg(MAYA, MAYA, now - 12 * MIN, "Perfect, see you then 🙌")
msg(MAYA, MAYA, now - 11 * MIN, "🧗‍♀️🔥")
finish(MAYA)

TEAM = "120363000000000001@g.us"
chat(TEAM, "Weekend Crew 🏕️", is_group=1, unread=5, pinned=2)
t = now - 6 * HOUR
msg(TEAM, "15550000002@s.whatsapp.net", t, "Okay who's bringing the tent")
msg(TEAM, "15550000003@s.whatsapp.net", t + MIN, "I have the big one, fits 4")
msg(TEAM, "15550000003@s.whatsapp.net", t + MIN + 15_000, "Also bringing the camp stove")
q = msg(TEAM, "15550000004@s.whatsapp.net", t + 3 * MIN, "Packing list so far:\n- tent (Priya)\n- stove (Priya)\n- cooler (?)\n- `firewood` permit", reactions="👍❤️\t4\t")
msg(TEAM, ME, t + 10 * MIN, "I can grab the cooler and ice", status=3,
    quote={"id": q, "sender": "15550000004@s.whatsapp.net", "text": "Packing list so far: - tent (Priya) - stove (Priya) - cooler (?)", "kind": 0})
msg(TEAM, "15550000099@s.whatsapp.net", t + 40 * MIN, "", kind=10)
msg(TEAM, "15550000005@s.whatsapp.net", now - 50 * MIN, "Trail map for Saturday", kind=5, file_name="Ridge-Loop-Trail-Map.pdf", file_size=2_480_000, mime="application/pdf")
msg(TEAM, "15550000006@s.whatsapp.net", now - 40 * MIN, "", kind=4, seconds=17, mime="audio/ogg; codecs=opus")
msg(TEAM, "15550000002@s.whatsapp.net", now - 9 * MIN, "Forecast says clear skies ☀️ both days")
msg(TEAM, "15550000007@s.whatsapp.net", now - 4 * MIN, "Let's goooo")
finish(TEAM)

for i, (jid, unread, pinned, muted, text, mins, mine) in enumerate([
    ("15550000002@s.whatsapp.net", 0, 0, 0, "Sent you the invoice, no rush", 95, False),
    ("15550000003@s.whatsapp.net", 1, 0, 0, "Did you see the game last night?!", 180, False),
    ("120363000000000002@g.us", 0, 0, -1, "Reminder: rent is due Friday", 300, False),
    ("15550000004@s.whatsapp.net", 0, 0, 0, "Thanks again for dinner!", 26 * 60, True),
    ("15550000005@s.whatsapp.net", 0, 0, 0, "Photo", 3 * 24 * 60, False),
    ("15550000006@s.whatsapp.net", 0, 0, 0, "Happy birthday!! 🎂", 9 * 24 * 60, True),
    ("15550000007@s.whatsapp.net", 0, 0, 0, "Ok sounds good", 40 * 24 * 60, False),
]):
    name = "Flat 4B" if jid.endswith("@g.us") else ""
    chat(jid, name, is_group=int(jid.endswith("@g.us")), unread=unread, pinned=pinned, muted=muted)
    sender = ME if mine else (jid if not jid.endswith("@g.us") else "15550000003@s.whatsapp.net")
    kind = 1 if text == "Photo" else 0
    msg(jid, sender, now - mins * MIN, "" if kind else text, kind=kind, thumb=thumb if kind else None, width=pw, height=ph, status=3 if i % 2 else 2)
    finish(jid)

ARCH = "15550000099@s.whatsapp.net"
chat(ARCH, archived=1)
msg(ARCH, ARCH, now - 60 * DAY, "See you around")
finish(ARCH)

# A long chat to exercise paging.
LONG = "15550000008@s.whatsapp.net"
db.execute("INSERT INTO contacts (jid, name) VALUES (?,?)", (LONG, "Long Thread"))
chat(LONG)
for i in range(600):
    who = ME if i % 3 == 0 else LONG
    msg(LONG, who, now - (600 - i) * 37 * MIN, f"Message {i + 1}: " + "lorem ipsum dolor sit amet " * (1 + i % 5))
finish(LONG)

# --- avatars: Apple's sample user pictures for some people, monograms for the rest
pics = sorted(glob.glob("/Library/User Pictures/*/*.heic"))
os.makedirs(os.path.join(out, "avatars"), exist_ok=True)
def avatar(jid, i):
    if i >= len(pics): return
    dst = os.path.join(out, "avatars", jid.split("@")[0] + ".jpg")
    subprocess.run(["sips", "-s", "format", "jpeg", "-Z", "160", pics[i], "--out", dst], capture_output=True)
    db.execute("INSERT OR REPLACE INTO avatars (jid, path, ts) VALUES (?,?,?)", (jid, dst, int(time.time())))
    db.execute("UPDATE chats SET avatar=? WHERE jid=?", (dst, jid))
for i, jid in enumerate(["15550000001@s.whatsapp.net", "15550000003@s.whatsapp.net", "15550000005@s.whatsapp.net", "15550000007@s.whatsapp.net"]):
    avatar(jid, i * 3)
for jid in ["15550000002@s.whatsapp.net", "15550000004@s.whatsapp.net", "15550000006@s.whatsapp.net", "15550000099@s.whatsapp.net", "15550000008@s.whatsapp.net"]:
    db.execute("INSERT OR REPLACE INTO avatars (jid, path, ts) VALUES (?,?,?)", (jid, "-", int(time.time())))
db.execute("UPDATE chats SET avatar='-' WHERE avatar='' OR avatar NOT LIKE '%.jpg'")
# a number with no saved name or push name
NONAME = "15550000042@s.whatsapp.net"
chat(NONAME)
msg(NONAME, NONAME, now - 30 * MIN, "Hi, is this still available?")
finish(NONAME)

# --- a real Opus voice note with a waveform
voice = os.path.join(out, "media", "voice.ogg")
subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                "sine=f=220:d=6,volume='0.3+0.7*abs(sin(t*2.7))':eval=frame", "-ac", "1", "-c:a", "libopus", "-b:a", "24k", voice],
               capture_output=True)
import math
wave = bytes(int(15 + 85 * abs(math.sin(i / 64 * 6 * 2.7))) for i in range(64))
def voice_msg(chat_jid, sender, ts):
    seq[0] += 1
    mid = f"V{seq[0]:05d}"
    db.execute("""INSERT INTO messages (chat, id, sender, push_name, from_me, ts, kind, text, status, mime, seconds, media, media_path, waveform)
                  VALUES (?,?,?,?,?,?,4,'',3,'audio/ogg; codecs=opus',6,'x',?,?)""",
               (chat_jid, mid, sender, "", int(sender == ME), ts, voice, wave))
    return mid
voice_msg(MAYA, MAYA, now - 8 * MIN)
voice_msg(MAYA, ME, now - 7 * MIN)

# --- link previews: a bare link (rich card with banner) and text + link (small thumb)
banner = os.path.join(out, "media", "banner.jpg")
if src:
    subprocess.run(["sips", "-s", "format", "jpeg", "-Z", "600", src, "--out", banner], capture_output=True)
banner_bytes = open(banner, "rb").read() if os.path.exists(banner) else None
def link_msg(chat_jid, sender, ts, text, url, title, desc, thumbdata):
    seq[0] += 1
    mid = f"L{seq[0]:05d}"
    db.execute("""INSERT INTO messages (chat, id, sender, push_name, from_me, ts, kind, text, status, thumb, link_url, link_title, link_desc)
                  VALUES (?,?,?,?,?,?,0,?,3,?,?,?,?)""",
               (chat_jid, mid, sender, "", int(sender == ME), ts, text, thumbdata, url, title, desc))
link_msg(MAYA, ME, now - 6 * MIN, "https://www.apple.com/macos/macos-tahoe/", "https://www.apple.com/macos/macos-tahoe/",
         "macOS Tahoe - Apple", "", banner_bytes)
link_msg(MAYA, MAYA, now - 5 * MIN, "This is the gym I was talking about https://example.com/boulder-house", "https://example.com/boulder-house",
         "Boulder House — Climbing Gym", "", thumb)
finish(MAYA)

db.commit()
db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
db.close()
print(out)
