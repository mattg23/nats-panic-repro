#!/usr/bin/env bash
# Reproduction for a nil pointer panic in nats-server
# (*stream).processSnapshotDeletes, after a node restart, while a client
# deletes streams and restores them from backups.
#
# The script starts a 3-node JetStream cluster on 127.0.0.1, makes some
# R3 streams with data, takes a backup of each stream, and then does two
# things at the same time:
#   1. The client loop deletes all streams and restores them from the
#      backups ("nats stream rm" and "nats stream restore"), again and
#      again.
#   2. The restart loop kills one server with SIGKILL every RESTART_EVERY
#      seconds (in turn n1, n2, n3) and starts it again after a short
#      down time.
# The script stops when a server log contains "panic:" or when DURATION
# seconds have passed.
#
# Settings (environment):
#   NATS_SERVER    path of nats-server (default: nats-server in PATH)
#   NATS           path of natscli (default: nats in PATH)
#   WORK           work directory (default: ./work, removed at start)
#   BASE_PORT      first client port (default 24222); the script uses
#                  BASE_PORT+0..2, +100..102 (routes), +200..202 (http)
#   DURATION       maximum run time in seconds (default 600)
#   RESTART_EVERY  seconds between two restarts (default 7)
#   STREAMS        number of streams (default 12)
#   KV             number of KV buckets with 20 keys each (default 0)
#   BIG_MSGS       messages of 1 KB in an extra stream BIG (default 0:
#                  no stream BIG)
#   SYNC_ALWAYS    1: "sync_interval: always" in the JetStream block
#                  (default 0)
#   DEBUG          1: start nats-server with -D (default 0)
#
# Exit code: 0 when the panic occurred, 1 when it did not.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATS_SERVER="${NATS_SERVER:-nats-server}"
NATS="${NATS:-nats}"
WORK="${WORK:-$HERE/work}"
BASE_PORT="${BASE_PORT:-24222}"
DURATION="${DURATION:-600}"
RESTART_EVERY="${RESTART_EVERY:-7}"
STREAMS="${STREAMS:-12}"
KV="${KV:-0}"
BIG_MSGS="${BIG_MSGS:-0}"
SYNC_ALWAYS="${SYNC_ALWAYS:-0}"
DEBUG="${DEBUG:-0}"

URLS="nats://127.0.0.1:$BASE_PORT,nats://127.0.0.1:$((BASE_PORT + 1)),nats://127.0.0.1:$((BASE_PORT + 2))"

log() {
    echo "$(date +%H:%M:%S.%3N) $*"
}

cli() {
    "$NATS" --server "$URLS" --timeout 5s "$@"
}

write_conf() {
    local i=$1
    local d="$WORK/n$i"
    local sync=""
    mkdir -p "$d/js"
    if [ "$SYNC_ALWAYS" = 1 ]; then
        sync="sync_interval: always"
    fi
    cat > "$d/nats.conf" <<EOF
server_name: n$i
listen: 127.0.0.1:$((BASE_PORT + i - 1))
http: 127.0.0.1:$((BASE_PORT + 200 + i - 1))
jetstream {
    store_dir: "$d/js"
    $sync
}
cluster {
    name: repro
    listen: 127.0.0.1:$((BASE_PORT + 100 + i - 1))
    routes: [
        nats-route://127.0.0.1:$((BASE_PORT + 100))
        nats-route://127.0.0.1:$((BASE_PORT + 101))
        nats-route://127.0.0.1:$((BASE_PORT + 102))
    ]
}
EOF
}

start_node() {
    local i=$1
    local dbg=""
    if [ "$DEBUG" = 1 ]; then
        dbg="-D"
    fi
    "$NATS_SERVER" -c "$WORK/n$i/nats.conf" $dbg >> "$WORK/n$i/server.log" 2>&1 &
    echo $! > "$WORK/n$i/pid"
}

kill_node() {
    local i=$1
    local f="$WORK/n$i/pid"
    if [ ! -f "$f" ]; then
        return 0
    fi
    kill -KILL "$(cat "$f")" 2> /dev/null
    wait "$(cat "$f")" 2> /dev/null
    rm -f "$f"
}

stop_all() {
    if [ -n "${CLIENT:-}" ]; then
        kill "$CLIENT" 2> /dev/null
        wait "$CLIENT" 2> /dev/null
        CLIENT=""
    fi
    local i
    for i in 1 2 3; do
        kill_node $i
    done
}

# Gives 0 when a server log has a panic.
panicked() {
    grep -q "^panic:" "$WORK"/n*/server.log 2> /dev/null
}

show_panic() {
    local f
    for f in "$WORK"/n*/server.log; do
        if grep -q "^panic:" "$f"; then
            log "PANIC in $f:"
            grep -B 12 -A 22 "^panic:" "$f"
        fi
    done
}

# Wait for N seconds, but stop early when a server panics.
# Gives 0 on a panic.
watch_for() {
    local end=$(($(date +%s%N) / 1000000 + $1))
    while [ $(($(date +%s%N) / 1000000)) -lt $end ]; do
        if panicked; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

wait_js() {
    local n=0
    while [ $n -lt 60 ]; do
        if cli account info > /dev/null 2>&1; then
            return 0
        fi
        n=$((n + 1))
        sleep 1
    done
    return 1
}

stream_names() {
    local j=1
    while [ $j -le "$STREAMS" ]; do
        echo "S$j"
        j=$((j + 1))
    done
    j=1
    while [ $j -le "$KV" ]; do
        echo "KV_b$j"
        j=$((j + 1))
    done
    if [ "$BIG_MSGS" -gt 0 ]; then
        echo "BIG"
    fi
}

setup() {
    local j=1
    while [ $j -le "$STREAMS" ]; do
        cli stream add "S$j" --subjects "s$j.>" --storage file --replicas 3 --defaults > /dev/null
        cli pub "s$j.x" "m{{Count}}" --count 5 > /dev/null 2>&1
        j=$((j + 1))
    done
    local b=1
    while [ $b -le "$KV" ]; do
        cli kv add "b$b" --replicas 3 > /dev/null
        j=1
        while [ $j -le 20 ]; do
            cli kv put "b$b" "k$j" "v$j" > /dev/null
            j=$((j + 1))
        done
        b=$((b + 1))
    done
    if [ "$BIG_MSGS" -gt 0 ]; then
        cli stream add BIG --subjects "big.>" --storage file --replicas 3 --defaults > /dev/null
        cli pub big.x "{{Count}} {{Random 1000 1000}}" --count "$BIG_MSGS" > /dev/null 2>&1
    fi
    local s
    mkdir -p "$WORK/bk"
    for s in $(stream_names); do
        if ! cli stream backup "$s" "$WORK/bk/$s" --no-progress > /dev/null; then
            log "backup of $s failed"
            return 1
        fi
    done
    return 0
}

delete_all() {
    local s
    for s in $(stream_names); do
        cli stream rm -f "$s" > /dev/null 2>&1
    done
}

restore_all() {
    local s
    local out
    for s in $(stream_names); do
        if ! out="$(cli stream restore "$WORK/bk/$s" --no-progress 2>&1)"; then
            log "restore of $s failed: $(echo "$out" | tail -1)"
            return 1
        fi
    done
    return 0
}

# The client: delete all streams, restore them all from the backups,
# again and again. Runs in the background.
client_loop() {
    local c=0
    while true; do
        c=$((c + 1))
        delete_all
        if restore_all; then
            log "cycle $c: restore ok"
        else
            log "cycle $c: restore stopped"
        fi
    done
}

main() {
    rm -rf "$WORK"
    mkdir -p "$WORK"
    local i
    for i in 1 2 3; do
        write_conf $i
        start_node $i
    done
    trap 'stop_all; exit 1' INT TERM
    if ! wait_js; then
        log "no JetStream after 60 s"
        stop_all
        exit 1
    fi
    log "cluster up; making streams and backups"
    if ! setup; then
        stop_all
        exit 1
    fi
    log "backups done; start the delete/restore cycles and the restarts"
    client_loop &
    CLIENT=$!
    local t0=$SECONDS
    local k=1
    local hit=0
    while [ $((SECONDS - t0)) -lt "$DURATION" ]; do
        if watch_for $((RESTART_EVERY * 1000)); then
            hit=1
            break
        fi
        log "restart: kill -9 n$k"
        kill_node $k
        # A down time of 200 to 2000 ms.
        if watch_for $((200 + RANDOM % 1801)); then
            hit=1
            break
        fi
        start_node $k
        log "restart: n$k started again"
        k=$((k % 3 + 1))
    done
    if [ $hit = 1 ]; then
        # Let the server write the full stack trace.
        sleep 1
        log "panic after $((SECONDS - t0)) s"
        show_panic
    else
        log "no panic in $DURATION s"
    fi
    stop_all
    if [ $hit = 1 ]; then
        exit 0
    fi
    exit 1
}

main
