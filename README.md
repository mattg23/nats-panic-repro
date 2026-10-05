Disclaimer: repro script & README is AI generated.


# nats-server v2.14.6: nil pointer panic in (*stream).processSnapshotDeletes

Two bash scripts that start a 3-node JetStream cluster on 127.0.0.1 and
make a restarted server panic. Each script uses its own work directory
and its own ports, kills only the server processes that it started, and
stops all of them at the end.

## Requirements

- Linux, bash, curl
- nats-server v2.14.6 (official release binary, linux-amd64)
- natscli 0.4.0

## targeted.sh (fast, recommended)

```
NATS_SERVER=/path/to/nats-server NATS=/path/to/natscli ./targeted.sh
```

The script makes one R3 stream S with 5 messages and takes a backup of
it. Then, in each attempt, it does these steps:

1. Delete S and restore it from the backup (`nats stream restore`).
2. Read the leader of S (`nats stream info S --json`).
3. Kill the leader with SIGKILL, and start it again after 500 ms.
4. Watch the server logs for `panic:`.

Result on our laptop: 6 of 6 runs panicked in the first attempt, about
3 s after the start of the script.

Ports: 24322-24324 (client), 24422-24424 (routes), 24522-24524 (http).
Change them with BASE_PORT. Work directory: ./work-targeted.

## soak.sh (the original workload)

```
NATS_SERVER=/path/to/nats-server NATS=/path/to/nats STREAMS=3 DURATION=600 ./soak.sh
```

A client loop deletes all streams and restores them again and again.
At the same time, the script kills one server with SIGKILL every 7 s
(n1, n2, n3 in turn) and starts it again after 0.2 to 2 s. Result: 3 of
3 runs panicked, after 115 s, 187 s and 264 s.

## Logs

- `logs/targeted-run-output.log`: the output of targeted.sh.
- `logs/targeted-run-n1-server.log`: the debug log of the server that
  panicked in that run.
- `logs/soak-run-output.log` and `logs/soak-run-panicked-server.log`:
  the same for one soak.sh run.

Exit code of both scripts: 0 when the panic occurred, 1 when it did not.


Internal repro data:
dst seed (internal): sb-dst 34e4510, dst-old2/seeds/nats-panic-snapshot-after-restart
(dst f875093, seed 1, proc-restart@hubs:nats); pj WP-127, R-163, R-166
