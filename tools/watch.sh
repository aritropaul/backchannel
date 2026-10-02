#!/bin/sh
# Live resource monitor for WA: one line every N seconds (default 2), also
# appended to build/stats.csv.
#   tools/watch.sh [interval]
INTERVAL=${1:-2}
DATA="$HOME/Library/Application Support/WA"
APP="$(cd "$(dirname "$0")/.." && pwd)/build/WA.app"
CSV="$(cd "$(dirname "$0")/.." && pwd)/build/stats.csv"
[ -f "$CSV" ] || echo "time,rss_mb,cpu,threads,app_db_mb,session_db_mb,media_mb,chats,messages" > "$CSV"
printf "%-8s %8s %6s %7s %9s %10s %8s %6s %9s\n" time rss_mb cpu% threads app.db session media chats messages
while :; do
  PID=$(pgrep -f "WA.app/Contents/MacOS/WA" | head -1)
  if [ -z "$PID" ]; then sleep "$INTERVAL"; continue; fi
  set -- $(ps -o rss=,%cpu= -p "$PID")
  RSS=$(( ${1:-0} / 1024 )); CPU=${2:-0}
  THREADS=$(( $(ps -M -p "$PID" | wc -l) - 1 ))
  mb() { [ -e "$1" ] && du -sk "$1" 2>/dev/null | awk '{printf "%.1f", $1/1024}' || echo 0; }
  APPDB=$(echo "$(mb "$DATA/app.db") + $(mb "$DATA/app.db-wal")" | bc)
  SESS=$(echo "$(mb "$DATA/session.db") + $(mb "$DATA/session.db-wal")" | bc)
  MEDIA=$(mb "$DATA/media")
  COUNTS=$(sqlite3 -readonly "file:$DATA/app.db?mode=ro" "select (select count(*) from chats where last_ts>0)||' '||(select count(*) from messages)" 2>/dev/null)
  set -- $COUNTS
  T=$(date +%H:%M:%S)
  printf "%-8s %8s %6s %7s %9s %10s %8s %6s %9s\n" "$T" "$RSS" "$CPU" "$THREADS" "$APPDB" "$SESS" "$MEDIA" "${1:-?}" "${2:-?}"
  echo "$T,$RSS,$CPU,$THREADS,$APPDB,$SESS,$MEDIA,${1:-},${2:-}" >> "$CSV"
  sleep "$INTERVAL"
done
