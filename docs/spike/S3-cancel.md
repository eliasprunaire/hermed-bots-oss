# S3: cancel a turn, including a running tool

Status: observed. Feeds `cancel_run`. One case is not covered by the route: a tool started with `background=true` outlives its run.

Observed on `hv-hermes-test` (image `hv-hermes:spike`), 2026-10-18. Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb487a17c0a68801bba9ef0f56c81040a8`. The model is the fake provider (Q6 option s1). Every request carries `Authorization: Bearer ****`. The Hermes tool is `terminal`.

## References

- Doc: [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server): `POST /v1/runs/{run_id}/stop` "returns `{"status": "stopping"}` immediately. The run settles as `cancelled`". `GET /v1/capabilities` lists `run_stop: true`.
- Code at `d923a5eb`: `gateway/platforms/api_server_runs.py:1253` (`_handle_stop_run`). The code that kills the tool processes was not read; the effect is taken from `ps`.
- The PRD risk "server side cancel does not stop a tool already launched" (kill switch incomplete) is answered case by case below.

## Result in one table

| Tool started by the turn | After `POST …/stop` | Process left in the container |
| --- | --- | --- |
| foreground `sleep 300` | `stopping`, then `cancelled` within 1 s | none |
| foreground command that starts `sleep 303` in a new session (`start_new_session=True`) and then runs `sleep 300` | `cancelled` within 1 s | none: both `sleep` processes are gone, the detached one included |
| `terminal` with `background=true` (`sleep 301`) | the run is already `completed`; the route answers 200 with the run unchanged | `sleep 301` stays alive, parent PID is the gateway process |
| provider stuck in retries (HTTP 500) | `cancelled` within 2 s | not applicable |

## Foreground tool

```
POST /p/hv-bot-a/v1/runs   {"input":"HV_TOOL_SLEEP go"}
GET  …/events              id=0 tool.started {"tool": "terminal", "preview": "sleep 300"}

docker exec hv-hermes-test ps -eo pid,ppid,pgid,sid,etime,args    (before the stop)
   1660   230   1660   1660  00:00  /usr/bin/bash -c source /opt/data/cache/scratch/hermes-snap-….sh …
   1662  1660   1660   1660  00:00  sleep 300

POST /p/hv-bot-a/v1/runs/run_7caa8e268a6a4b87bbeb2f178390f5cf/stop
HTTP/1.1 200 OK
{"run_id": "run_7caa8e268a6a4b87bbeb2f178390f5cf", "status": "stopping"}

GET  …/events              id=1 tool.completed  id=2 run.cancelled          (1.3 s after the start)
GET  /p/hv-bot-a/v1/runs/run_7caa…   -> {"status": "cancelled", "last_event": "run.cancelled", "interrupted": true, "completed": false}
docker exec hv-hermes-test ps …      -> header line only, no `sleep`
```

The first capture of this case showed `tool.completed` with `"error": true` and `"preview": "{\"output\": \"[Command interrupted]\", \"exit_code\": 130, \"error\": null}"`, then `run.cancelled` with `"turn_exit_reason": "interrupted_by_user"`.

## Descendant in another session

The command was `python3 -c "import os,subprocess; subprocess.Popen(['sleep','303'], start_new_session=True); os.system('sleep 300')"`. This command needs an approval (event `approval.request`, see S1), so the probe answered `once` first. Processes before the stop:

```
 1648   385   1648   1648  00:02  /usr/bin/bash -c source …
 1650  1648   1648   1648  00:02  python3 -c import os,subprocess; subprocess.Popen(['sleep','303'], start_new…
 1651  1650   1651   1651  00:02  sleep 303          (own session and group)
 1652  1650   1648   1648  00:02  sh -c -- sleep 300
 1653  1652   1648   1648  00:02  sleep 300
```

One second after `POST …/stop`, 5 s and 15 s later, `ps` showed no `sleep`. The stop reaches processes that left the process group of the tool.

Hermes refuses the shell wrappers `nohup`, `disown` and `setsid` in a foreground command (`tools/terminal_tool_guards.py:104`, message "Foreground command uses shell-level background wrappers"), so the wrapper form of this test could not run.

## Background tool

```
POST /p/hv-bot-a/v1/runs   {"input":"HV_TOOL_BG go"}
GET  …/events              tool.started, tool.completed, message.delta, run.completed (195 ms)

docker exec hv-hermes-test ps …      ->  1913  385  1913  1913  00:00  sleep 301
POST …/runs/run_c0c8447fa2584620a4d1234d6be1eeb0/stop
HTTP/1.1 200 OK   {"object": "hermes.run", "status": "completed", "last_event": "run.completed", …}
docker exec hv-hermes-test ps …      ->  1913  385  1913  1913  00:03  sleep 301     (still alive)
```

A background process belongs to the gateway, not to the run. Stopping the run, or every run, does not end it. By the tool schema (`tools/terminal_tool.py:1507`) the call returns a `session_id` so that Hermes tracks the process. No route in the route table of this version (`gateway/platforms/api_server.py:1718`) lists or kills such a process.

## What this means for the kill switch levels

This is a record, not a proposal. `cancel_run` stops a running turn and the foreground process tree of its tool, including a descendant in a new session. It does not stop a `background=true` process that the turn left running. The PRD levels K1 (API cancel) and K3 (stop the Hermes process by the user) differ on that case.

## Reproduce

```
curl -sS -X POST -H "Authorization: Bearer $HV_TEST_API_KEY" -H 'Content-Type: application/json' -d '{"input":"HV_TOOL_SLEEP go"}' http://127.0.0.1:18642/p/hv-bot-a/v1/runs
docker exec hv-hermes-test ps -eo pid,ppid,pgid,sid,etime,args
curl -sS -X POST -H "Authorization: Bearer $HV_TEST_API_KEY" http://127.0.0.1:18642/p/hv-bot-a/v1/runs/<run_id>/stop
```
