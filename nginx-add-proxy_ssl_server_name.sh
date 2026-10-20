#!/bin/bash
#
# nginx-add-proxy_ssl_server_name.sh
#
# Daemonized script to keep "proxy_ssl_server_name on;" in the
# "location / {" block of the nginx # server whose server_name matches a host.
#
# Watches a directory (default /usr/local/etc/nginx/sites-available).
#
# DSM rewrites/recreates these files on every "reverse-proxy" config saving, so
# the # daemon re-checks any matching file that is new or changed, patches it if
# needed, validates with "nginx -t" and reloads "nginx -s reload".
#
# Usage:
#   proxy_ssl_sni_watch.sh <server_name> [options]
#
# Options:
#   -d, --dir DIR        directory to watch   (default /usr/local/etc/nginx/sites-available)
#   -i, --interval SEC   poll interval        (default 5)
#   -l, --log FILE       log file             (default /var/log/proxy_ssl_sni_<host>.log)
#   -n, --dry-run        show what would change; never edit, test or reload
#       --once           check once and exit (no daemon loop)
#       --daemon         (alias --daemon_start) detach into the background (for Task Scheduler boot-up)
#       --stop           (alias --daemon_stop) stop the running daemon for this host
#       --status         say whether the daemon is running
#   -h, --help
#
# Env overrides (mainly for testing):
#   NGINX_TEST_CMD    default: "nginx -t"
#   NGINX_RELOAD_CMD  default: synosystemctl/systemctl reload nginx, else "nginx -s reload"
#   STATE_DIR         default: /var/run (pid file) and /var/tmp (backups)

set -uo pipefail

HOST=""
DIR="/usr/local/etc/nginx/sites-available"
INTERVAL=5
LOG=""
ONCE=0
DAEMON=0
STOP=0
STATUS=0
DRY_RUN=0

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dir)      DIR="$2"; shift 2 ;;
        -i|--interval) INTERVAL="$2"; shift 2 ;;
        -l|--log)      LOG="$2"; shift 2 ;;
        -n|--dry-run)  DRY_RUN=1; shift ;;
        --once)        ONCE=1; shift ;;
        --daemon|--daemon_start|--start) DAEMON=1; shift ;;
        --stop|--daemon_stop)            STOP=1; shift ;;
        --status)      STATUS=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            echo "Unknown option: $1" >&2; exit 2 ;;
        *)             if [ -z "$HOST" ]; then HOST="$1"; shift
                       else echo "Unexpected argument: $1" >&2; exit 2; fi ;;
    esac
done

[ -n "$HOST" ] || { usage >&2; exit 2; }

SAFE_HOST="$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9._-' '_')"
RUN_DIR="${STATE_DIR:-/var/run}"
BACKUP_DIR="${STATE_DIR:-/var/tmp}/proxy_ssl_sni/$SAFE_HOST"
PIDFILE="$RUN_DIR/proxy_ssl_sni_$SAFE_HOST.pid"
[ -n "$LOG" ] || LOG="/var/log/proxy_ssl_sni_$SAFE_HOST.log"

running_pid() {
    local p
    [ -f "$PIDFILE" ] || return 1
    p="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"
}

# ---------- status / stop ----------
if [ "$STATUS" -eq 1 ]; then
    if p="$(running_pid)"; then echo "Running (pid $p), log: $LOG"; else echo "Not running."; fi
    exit 0
fi
if [ "$STOP" -eq 1 ]; then
    if p="$(running_pid)"; then kill "$p" && echo "Stopped (pid $p)."; else echo "Not running."; fi
    exit 0
fi

# ---------- writable state (fail loudly, not silently) ----------
if [ "$DRY_RUN" -eq 0 ]; then
    [ "$(id -u)" -eq 0 ] || echo "WARNING: not running as root — editing nginx files and reloading will likely fail." >&2
    for d in "$RUN_DIR" "$BACKUP_DIR" "$(dirname "$LOG")"; do
        mkdir -p "$d" 2>/dev/null || { echo "ERROR: cannot create $d (run as root?)" >&2; exit 1; }
    done
    touch "$LOG" 2>/dev/null || { echo "ERROR: cannot write log $LOG (run as root?)" >&2; exit 1; }
fi

log() {
    local msg; msg="$(date '+%Y-%m-%d %H:%M:%S') [$HOST] $*"
    [ "$DRY_RUN" -eq 0 ] && echo "$msg" >> "$LOG" 2>/dev/null
    if [ -t 1 ] || [ "$DRY_RUN" -eq 1 ] || [ "$ONCE" -eq 1 ]; then echo "$msg"; fi
    return 0
}

# ---------- detach ----------
if [ "$DAEMON" -eq 1 ]; then
    if p="$(running_pid)"; then echo "Already running (pid $p)."; exit 0; fi
    args=("$HOST" --dir "$DIR" --interval "$INTERVAL" --log "$LOG")
    [ "$DRY_RUN" -eq 1 ] && args+=(--dry-run)
    if command -v setsid >/dev/null 2>&1; then
        nohup setsid "$0" "${args[@]}" </dev/null >>"$LOG" 2>&1 &
    else
        nohup "$0" "${args[@]}" </dev/null >>"$LOG" 2>&1 &
    fi
    disown 2>/dev/null
    sleep 2
    if p="$(running_pid)"; then
        echo "Started in background (pid $p). Log: $LOG"
        exit 0
    fi
    echo "ERROR: daemon did not start. Last log lines:" >&2
    tail -n 20 "$LOG" >&2 2>/dev/null
    exit 1
fi

# ---------- single instance ----------
if [ "$ONCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    if p="$(running_pid)"; then echo "Already running (pid $p)." >&2; exit 1; fi
    echo $$ > "$PIDFILE" || { echo "ERROR: cannot write $PIDFILE" >&2; exit 1; }
    trap 'log "Stopping."; rm -f "$PIDFILE"; exit 0' INT TERM
    trap 'rm -f "$PIDFILE"' EXIT
fi

nginx_test() {
    if [ -n "${NGINX_TEST_CMD:-}" ]; then eval "$NGINX_TEST_CMD"; else nginx -t; fi
}
nginx_reload() {
    if [ -n "${NGINX_RELOAD_CMD:-}" ]; then eval "$NGINX_RELOAD_CMD"; return; fi
    if command -v synosystemctl >/dev/null 2>&1; then synosystemctl reload nginx && return; fi
    if command -v systemctl >/dev/null 2>&1; then systemctl reload nginx && return; fi
    nginx -s reload
}

# ---------- atomic write ----------
# atomic_replace SRC DEST [EXPECTED]
# Writes SRC's content to a hidden temp file next to DEST (same filesystem,
# owner/perms copied from DEST), then mv's it over DEST, so nginx never sees
# a partial file. The leading dot keeps it out of nginx's "include *" glob
# and out of our own grep. If EXPECTED (a file) is given and DEST's content
# no longer matches it (DSM rewrote/replaced it meanwhile), nothing is
# written: return 2.
atomic_replace() {
    local src="$1" dest="$2" expected="${3:-}" t
    t="$(dirname "$dest")/.$(basename "$dest").sni.$$"
    cp -p "$dest" "$t" 2>/dev/null || return 1
    cat "$src" > "$t" || { rm -f "$t"; return 1; }
    if [ -n "$expected" ] && ! cmp -s "$expected" "$dest"; then
        rm -f "$t"; return 2
    fi
    mv -f "$t" "$dest" || { rm -f "$t"; return 1; }
}

# ---------- patcher ----------
# patch_file FILE BACKUP -> prints: added | wouldadd | present | nolocation | nomatch | gone | error
# "added": FILE atomically replaced (owner/perms kept), original saved to BACKUP.
# "gone": DSM removed/replaced FILE while we were patching it; nothing written.
# "wouldadd" (dry run): diff printed, nothing written.
patch_file() {
    local f="$1" bak="$2" tmp status orig added present matched rc
    orig="$(mktemp)"
    cp "$f" "$orig" 2>/dev/null || { rm -f "$orig"; echo gone; return; }   # snapshot what we parse
    tmp="$(mktemp)"; status="$(mktemp)"
    awk -v host="$HOST" -v statusfile="$status" '
    function count(s, ch,   t) { t = s; return gsub(ch, "", t) }
    function flush(   i, ind) {
        print buf[1]
        if (!seen) {
            match(buf[1], /^[ \t]*/)
            ind = substr(buf[1], 1, RLENGTH) "    "
            print ind "proxy_ssl_server_name on;"
            added++
        } else present++
        for (i = 2; i <= n; i++) print buf[i]
        n = 0; in_loc = 0
    }
    BEGIN { depth = 0 }
    {
        line = $0; code = line; sub(/#.*/, "", code); before = depth
        if (!in_server && before == 0 && code ~ /^[ \t]*server[ \t]*\{/) { in_server = 1; matched = 0 }
        if (in_server && !in_loc && code ~ /^[ \t]*server_name[ \t]/) {
            s = code; sub(/^[ \t]*server_name[ \t]+/, "", s); sub(/;.*/, "", s)
            k = split(s, toks, /[ \t]+/)
            for (i = 1; i <= k; i++) if (toks[i] == host) { matched = 1; nmatched++; break }
        }
        if (in_server && matched && !in_loc && code ~ /^[ \t]*location[ \t]+\/[ \t]*\{/) {
            in_loc = 1; loc_depth = before; seen = 0; n = 0
        }
        depth += count(code, "{") - count(code, "}")
        if (in_loc) {
            buf[++n] = line
            if (n > 1 && code ~ /^[ \t]*proxy_ssl_server_name[ \t]/) seen = 1
            if (depth <= loc_depth) flush()
        } else print line
        if (in_server && depth == 0) { in_server = 0; matched = 0 }
    }
    END {
        if (in_loc) flush()
        printf "%d %d %d\n", added, present, nmatched > statusfile
    }' "$orig" > "$tmp"

    read -r added present matched < "$status"
    rm -f "$status"

    if [ "${matched:-0}" -eq 0 ]; then
        echo nomatch
    elif [ "${added:-0}" -gt 0 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            diff -u "$orig" "$tmp" | sed "1s#$orig#$f#" >&2
            echo wouldadd
        else
            cp -p "$f" "$bak" 2>/dev/null; cat "$orig" > "$bak"
            atomic_replace "$tmp" "$f" "$orig"; rc=$?
            case $rc in
                0) echo added ;;
                2) rm -f "$bak"; echo gone ;;
                *) rm -f "$bak"; echo error ;;
            esac
        fi
    elif [ "${present:-0}" -gt 0 ]; then
        echo present
    else
        echo nolocation
    fi
    rm -f "$tmp" "$orig"
}

sig() { stat -c '%i:%Y:%s' "$1" 2>/dev/null; }

# ---------- main ----------
HOST_RE="$(printf '%s' "$HOST" | sed 's/[.[\*^$()+?{}|]/\\&/g')"
GREP_RE="server_name[^;]*[[:space:]]${HOST_RE}([[:space:];]|$)"

declare -A SEEN     # file -> signature last handled
WAITING_LOGGED=0

check_once() {
    local files=() f result reloaded=0 BAK
    mapfile -t files < <(grep -lsE -- "$GREP_RE" "$DIR"/* 2>/dev/null)

    for f in "${!SEEN[@]}"; do
        if [ ! -e "$f" ]; then
            log "File removed: $f — waiting for replacement."
            unset 'SEEN[$f]'
        fi
    done

    if [ "${#files[@]}" -eq 0 ]; then
        if [ "$WAITING_LOGGED" -eq 0 ]; then
            log "No file in $DIR has server_name $HOST — waiting."
            WAITING_LOGGED=1
        fi
        return
    fi
    WAITING_LOGGED=0

    for f in "${files[@]}"; do
        [ -f "$f" ] || continue
        [ "${SEEN[$f]:-}" = "$(sig "$f")" ] && continue    # unchanged since last check

        [ "$ONCE" -eq 0 ] && sleep 1                       # let DSM finish writing
        BAK="$BACKUP_DIR/$(basename "$f").$(date +%Y%m%d-%H%M%S)"
        result="$(patch_file "$f" "$BAK")"
        case "$result" in
            added)
                if nginx_test >>"$LOG" 2>&1; then
                    log "Added proxy_ssl_server_name to $f (backup: $BAK)"
                    reloaded=1
                else
                    atomic_replace "$BAK" "$f"
                    log "nginx -t FAILED after patching $f — reverted. See $LOG."
                fi
                ;;
            wouldadd)   log "DRY RUN: would add proxy_ssl_server_name to $f (diff above)" ;;
            present)    log "OK: $f already has proxy_ssl_server_name" ;;
            nolocation) log "WARN: $f matches $HOST but has no 'location / {' block" ;;
            gone)       log "$f was replaced/removed while patching — will pick up the new one." ;;
            error)      log "ERROR: could not write $f (permissions? disk full?)" ;;
            nomatch)    : ;;                               # grep false positive (e.g. comment)
        esac
        SEEN[$f]="$(sig "$f")"
    done

    if [ "$reloaded" -eq 1 ]; then
        if nginx_reload >>"$LOG" 2>&1; then log "nginx reloaded."
        else log "ERROR: nginx reload failed — see $LOG."; fi
    fi

    if [ "$DRY_RUN" -eq 0 ]; then   # keep only the 10 newest backups
        ls -1t "$BACKUP_DIR" 2>/dev/null | tail -n +11 | while read -r old; do rm -f "$BACKUP_DIR/$old"; done
    fi
}

[ -d "$DIR" ] || log "WARN: $DIR does not exist yet — will keep checking."

if [ "$ONCE" -eq 1 ]; then
    check_once
    exit 0
fi

log "Started (pid $$), watching $DIR every ${INTERVAL}s.$([ "$DRY_RUN" -eq 1 ] && echo ' DRY RUN — no edits.')"
while :; do
    check_once
    sleep "$INTERVAL" &
    wait $!
done
