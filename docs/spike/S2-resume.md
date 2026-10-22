# S2: resume a turn by id after a cut, and avoid a double send

Status: observed. Feeds the replay of `run_events`.

Observed on `hv-hermes-test` (image `hv-hermes:spike`), 2026-10-18. Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb487a17c0a68801bba9ef0f56c81040a8`. The model is the fake provider (Q6 option s1); `HV_SLOW` makes a turn last about 20 s. Every request carries `Authorization: Bearer ****`.

## References

- Doc: [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server), headers `Idempotency-Key` (1 to 255 visible ASCII characters, kept 24 h on runs) and `Idempotency-Replayed`. [Programmatic Integration](https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration) says non keyed submissions "still create distinct runs" and gives no global exactly once guarantee.
- Code at `d923a5eb`: `gateway/platforms/api_server_runs.py:1084` (`Last-Event-ID` header or `last_seq` query parameter), `:1118` (`replay.truncated` event when the backlog no longer holds the requested id), `:461` and `:470` (replayed admission and conflict). `GET /v1/capabilities` reports `runs_idempotency: {"supported": true, "durable": true, "retention_seconds": 86400}`.

## Result in one table

| Case | Observed |
| --- | --- |
| Client side cut, server alive | `GET …/events` with `Last-Event-ID: N` replays from `N+1`, then continues live. The turn completed once. |
| Same `Idempotency-Key`, same body, sent again | HTTP 202 with header `Idempotency-Replayed: true` and the same `run_id`. No second run. |
| Same `Idempotency-Key`, different body | HTTP 409, code `idempotency_key_conflict`. |
| No key, identical body twice | two different `run_id` values. A resend without a key is a double send. |
| Container network cut with `docker network disconnect bridge` | New connections refused during the cut (curl exit 7). An already open stream stalled, then delivered the missed events in one burst after the reconnect. No event was lost. |
| Gateway restarted during a turn | The run becomes `interrupted`. The event stream is gone (HTTP 404). The same key answers `replayed: true` with status `interrupted`. The turn is not resumed. |

## Client side cut and resume

The probe cut its own connection after three events (`id` 0 to 2), then resumed by id:

```
POST /p/hv-bot-a/v1/runs            Idempotency-Key: hv-s2-B   {"input":"HV_SLOW go"}
-> 202 {"run_id": "run_8f44ca45dab94e098821d727257cd7a0", "status": "started", "replayed": false}
GET  …/events                       [t=158ms] id=0  [t=1163ms] id=1  [t=2165ms] id=2   CLIENT CUT

POST /p/hv-bot-a/v1/runs            Idempotency-Key: hv-s2-B   {"input":"HV_SLOW go"}   (turn still running)
-> 202  Idempotency-Replayed: true  {"run_id": "run_8f44…", "status": "running", "replayed": true}

GET  …/events                       Last-Event-ID: 2
-> 200  id=3 … id=8 at once (backlog), then id=9 … id=19 one per second, id=20 reasoning.available, id=21 run.completed, ": stream closed"

GET  /p/hv-bot-a/api/sessions/run_8f44…/messages
-> [("user", "HV_SLOW go"), ("assistant", "slow0 slow1 … slow19")]
```

The session holds one user message and one assistant message. The turn completed once.

## Network cut with a stream open

`docker network disconnect bridge hv-hermes-test` at about t = 5 s (15:45:15), `docker network connect bridge hv-hermes-test` six seconds later (15:45:21), stream opened before the cut:

```
[t=164ms]   id=0   [t=1170ms] id=1   [t=2174ms] id=2   [t=3176ms] id=3   [t=4181ms] id=4
(cut: no frame from t=4.2 s to t=11.5 s)
[t=11530ms] id=5 … id=11 (seven frames at once)   [t=12199ms] id=12 … [t=20266ms] id=21 run.completed
```

During the cut a new `curl` to `http://127.0.0.1:18642/health` failed (exit 7). After the reconnect it returned 200 within one second. A cut of six seconds did not break the open stream. A longer cut was not tried.

## Gateway restart during a turn

`docker restart hv-hermes-test` three seconds into a `HV_SLOW` turn. `/health` answered again after 6 s.

```
GET /p/hv-bot-a/v1/runs/run_3445cfe23ddf4e0fa190c649567ef0ea
{"object": "hermes.run", "status": "interrupted", "error": "The gateway restarted before this run settled.", "last_event": "run.interrupted", "shutdown_requested_at": 1792331175.33, …}

GET …/events   Last-Event-ID: 2   -> HTTP 404
POST /v1/runs  Idempotency-Key: hv-s2-C (same body) -> 202 Idempotency-Replayed: true, status "interrupted"
GET /api/sessions/run_3445…/messages -> [("user", "HV_SLOW go")]
```

After a restart the events of the run cannot be replayed, and the partial answer is not in the transcript. The status and the user message are kept. The doc also names `POST /v1/runs/{id}/resolve-unknown` for the `unknown` state; that state did not appear here and the route was not called.

## Reproduce

```
curl -sS -H "Authorization: Bearer $HV_TEST_API_KEY" -H 'Idempotency-Key: hv-s2-B' -H 'Content-Type: application/json' -d '{"input":"HV_SLOW go"}' http://127.0.0.1:18642/p/hv-bot-a/v1/runs
curl -sS -N -m 40 -H "Authorization: Bearer $HV_TEST_API_KEY" -H 'Last-Event-ID: 2' http://127.0.0.1:18642/p/hv-bot-a/v1/runs/<run_id>/events
docker network disconnect bridge hv-hermes-test
docker network connect bridge hv-hermes-test
```
