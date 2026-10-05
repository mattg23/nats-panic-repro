#!/usr/bin/env bash
# Targeted reproduction for the nil pointer panic in nats-server
# (*stream).processSnapshotDeletes.
#
# The script starts a 3-node JetStream cluster on 127.0.0.1, makes one R3
# stream S with 5 messages and takes a backup of it. Then it does these
# steps again and again:
#   1. Delete S and restore it from the backup.
#   2. Read the leader of S (a read only, no new meta entry).
#   3. Kill the leader with SIGKILL at once, and start it again after
#      DOWN_MS milliseconds.
#   4. Watch the server logs for "panic:" for WATCH_S seconds.
#   5. If there is no panic, wait until all servers are healthy.
# The node that did the restore must stop before it stores the next meta
# entry. Then, after the restart, it applies the restore assignment again
# and starts the stream monitor without a stream (mset == nil).
#
# Settings (environment):
#   NATS_SERVER  path of nats-server (default: nats-server in PATH)
#   NATS         path of natscli (default: nats in PATH)
#   WORK         work directory (default: ./work-targeted, removed at start)
#   BASE_PORT    first client port (default 24322); the script uses
#                BASE_PORT+0..2, +100..102 (routes), +200..202 (http)
#   ATTEMPTS     maximum number of attempts (default 30)
#   DOWN_MS      down time of the killed server (default 500)
#   WATCH_S      seconds to watch for a panic after the restart (default 5)
#
# Needs: bash, curl. Exit code: 0 when the panic occurred, 1 when it did not.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATS_SERVER="${NATS_SERVER:-nats-server}"
NATS="${NATS:-nats}"
WORK="${WORK:-$HERE/work-targeted}"
BASE_PORT="${BASE_PORT:-24322}"
ATTEMPTS="${ATTEMPTS:-30}"
DOWN_MS="${DOWN_MS:-500}"
WATCH_S="${WATCH_S:-5}"

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
    mkdir -p "$d/js"
    cat > "$d/nats.conf" <<EOF
server_name: n$i
listen: 127.0.0.1:$((BASE_PORT + i - 1))
http: 127.0.0.1:$((BASE_PORT + 200 + i - 1))
jetstream {
    store_dir: "$d/js"
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
    "$NATS_SERVER" -c "$WORK/n$i/nats.conf" -D >> "$WORK/n$i/server.log" 2>&1 &
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

# Wait for N milliseconds, but stop early when a server panics.
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

# Gives 0 when all three servers answer 200 on /healthz within 60 s.
wait_healthy() {
    local n=0
    local i
    local ok
    local code
    while [ $n -lt 600 ]; do
        ok=1
        for i in 1 2 3; do
            code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$((BASE_PORT + 200 + i - 1))/healthz")"
            if [ "$code" != 200 ]; then
                ok=0
            fi
        done
        if [ $ok = 1 ]; then
            return 0
        fi
        if panicked; then
            return 1
        fi
        n=$((n + 1))
        sleep 0.1
    done
    return 1
}

# Prints the server name of the leader of stream S (n1, n2 or n3).
leader_of_s() {
    cli stream info S --json 2> /dev/null | grep -o '"leader": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
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
    if ! wait_healthy; then
        log "the cluster is not healthy after 60 s"
        stop_all
        exit 1
    fi
    cli stream add S --subjects "s.>" --storage file --replicas 3 --defaults > /dev/null
    cli pub s.x "m{{Count}}" --count 5 > /dev/null 2>&1
    if ! cli stream backup S "$WORK/bk" --no-progress > /dev/null; then
        log "backup of S failed"
        stop_all
        exit 1
    fi
    log "cluster up, stream S has a backup"
    local a=1
    local hit=0
    local out
    local ld
    local k
    while [ $a -le "$ATTEMPTS" ]; do
        cli stream rm -f S > /dev/null 2>&1
        if ! out="$(cli stream restore "$WORK/bk" --no-progress 2>&1)"; then
            log "attempt $a: restore failed: $(echo "$out" | tail -1)"
        fi
        ld="$(leader_of_s)"
        k="${ld#n}"
        if [ "$k" != 1 ] && [ "$k" != 2 ] && [ "$k" != 3 ]; then
            log "attempt $a: no leader for S ('$ld'), next attempt"
            wait_healthy
            a=$((a + 1))
            continue
        fi
        kill_node "$k"
        log "attempt $a: restored S, killed its leader n$k"
        watch_for "$DOWN_MS"
        start_node "$k"
        if watch_for $((WATCH_S * 1000)); then
            hit=1
            break
        fi
        if ! wait_healthy; then
            if panicked; then
                hit=1
                break
            fi
            log "attempt $a: the cluster did not become healthy"
        fi
        a=$((a + 1))
    done
    if [ $hit = 1 ]; then
        # Let the server write the full stack trace.
        sleep 1
        log "panic in attempt $a"
        show_panic
    else
        log "no panic in $ATTEMPTS attempts"
    fi
    stop_all
    if [ $hit = 1 ]; then
        exit 0
    fi
    exit 1
}

main
