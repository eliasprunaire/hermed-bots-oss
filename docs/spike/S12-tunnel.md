# S12: open the SSH tunnel from the app

Status: observed. Feeds HD-07 (`HermedBots/Transport/SSHTunnel.swift`). Chosen option at the time: the system `/usr/bin/ssh`. The product uses the user's SSH alias and config, not a private key held by the app.

Observed on 2026-10-19 on macOS 27.0.1 with `/usr/bin/ssh` `OpenSSH_10.3p1, LibreSSL 3.3.6`. The target is `sshd` (Debian trixie `openssh-server`) inside `hv-hermes-test`, image `hv-hermes:hd07`, built from `docs/spike/hd07-instruments/Dockerfile` on `hv-hermes:spike`. Hermes is v0.22.2. Only `hvssh` may log in, by public key, and `PermitOpen` allows `127.0.0.1:8642` only. Every key in this note is a throwaway test key, generated for the run and deleted after it. No key value appears here.

The Mac reaches `sshd` by the name `<HOST>` (OrbStack). No port 22 is published. The name resolves to `<IP>` (an OrbStack address). The docker bridge address of the container was `<IP>` after the reconnect of lane 9, so the two differ. The app targets the name, never an address.

## Question

The PRD asks whether the app can open the tunnel with the system `ssh` or with a library. Secrets must stay out of argv, logs, files and screenshots.

## Options

| Option | What was observed |
| --- | --- |
| `ssh` with the key as a file | Not allowed: the key must not touch the disk. |
| `ssh -o IdentityFile=/dev/fd/3` with the key in a pipe | `ssh` blocks. The test killed it after 12 s (`rc=143`). |
| `ssh -o IdentityFile=/dev/stdin` with the key on standard input | `ssh` refuses the key: `Permissions 0660 for '/dev/stdin' are too open`, then `Permission denied (publickey)` (`rc=255`). |
| `ssh` plus a private `ssh-agent`, key added by `ssh-add -` | Works. `ssh-add -` reads the key on standard input and answers `Identity added: (stdin)`. The key is in the agent's memory, not in argv, an environment variable or a file. |
| Library `swift-nio-ssh` (Apple, Apache-2.0, last release 0.15.0 on 2026-07-28) | Not built. The [README](https://github.com/apple/swift-nio-ssh) says it is "more like libssh2 than openssh" and "does not ship production-ready SSH clients". It lists direct TCP port forwarding (`.directTCPIP`), Ed25519 and ECDSA keys, and public key authentication by a delegate. The app would write the local listener, the channel bridge and the host key check. The README names no `known_hosts` handling and no OpenSSH private key parser. |
| Library `Citadel` (MIT, last push 2026-06-12) | Not built. The [README](https://github.com/orlandos-nl/Citadel) lists TCP-IP forwarding and OpenSSH key parsing for RSA and SwiftCrypto key types. |

Neither library was built or run. The comparison rests on their READMEs and release dates.

## Decision

The app runs `/usr/bin/ssh` as a child process. The spike used a private `ssh-agent` for a throwaway test key. The product later dropped that path and uses the user's agent and config.

- No new dependency. `ssh` already does the key types, `known_hosts`, keep-alive and the forward.
- The cost is a process to supervise. HD-07 does it: one process group, one watchdog, one stderr classifier.
- The absolute path matters. In Ayo's shell `ssh` is an alias of `vssh`. The app never resolves `ssh` through `PATH`.

## How the key reaches `ssh`

1. The app creates a private directory (mode 0700) under the temporary directory and starts `ssh-agent -D -a <dir>/a`.
2. It runs `ssh-add -` and writes the key on its standard input.
3. It runs `ssh-add -L` and stores the public part in `<dir>/key.pub`. The public part is not secret.
4. It runs `ssh -i <dir>/key.pub -o IdentitiesOnly=yes -o IdentityAgent=<dir>/a …`. `IdentitiesOnly` plus the public file tells `ssh` which agent key to sign with.

Without `IdentitiesOnly` and `-i`, `ssh -v` also looks for `~/.ssh/id_rsa`, `id_ecdsa`, `id_ed25519` and their `_sk` forms before it offers the agent key. With them it offers one key, the agent key (`Offering public key: … explicit agent`). The house tool `vssh` uses the same pattern.

A key protected by a passphrase fails at step 2 in 0.01 s (`rc=1`, `Enter passphrase for (stdin):`, no terminal). The app shows "unreadable key" and does not wait.

## The forward

`ssh -N -T -L 127.0.0.1:<port>:127.0.0.1:8642 hvssh@<HOST>` opens a local port. `GET /health` on it answers `{"status": "ok", "platform": "hermes-agent", "version": "0.22.2"}`. `ssh -W 127.0.0.1:22` through the same account fails with `stdio forwarding failed`: `PermitOpen` holds. `ssh` stops on SIGTERM with `rc=0`.

## Failure texts

`-o LogLevel=ERROR` and `-o BatchMode=yes` leave one line on stderr and exit with 255.

| Case | stderr | App state |
| --- | --- | --- |
| Key refused | `hvssh@<HOST>: Permission denied (publickey).` | failed, no retry |
| Port closed | `ssh: connect to host 127.0.0.1 port 2: Connection refused` | retry with a growing delay |
| Host key changed | `REMOTE HOST IDENTIFICATION HAS CHANGED` or `Host key verification failed.` (text from the OpenSSH manual, not triggered in this run) | failed, no retry |

A path with spaces in a `-o` value needs quotes. `-o "UserKnownHostsFile=/a b/kh"` exits 0 and writes the file nowhere. `-o 'UserKnownHostsFile="/a b/kh"'` writes it. `ssh` also keeps the first value of an option, so the app gives each option once.

## No orphan

- A first smoke run sent SIGTERM to the app. The app crashed (`Trace/BPT trap`) and left `ssh` and `ssh-agent` alive. The cause is inferred: the signal handler closure was isolated to the main actor and ran on a global queue. The handler is now not isolated, and the crash did not come back.
- SIGKILL cannot be caught. The group leader is therefore a `sh` that reads a pipe only the app holds open. When the app dies the kernel closes the pipe, and the `sh` removes the private directory and runs `kill -KILL 0`, which kills its whole group. With this watchdog, SIGTERM and SIGKILL on the app left no `ssh`, `ssh-agent` or `sh` behind (smoke run), and the lanes of HD-07 show the same for Cmd-Q and `terminate()`.
- The agent, the watchdog and every `ssh` share one process group. A reopen starts a new `ssh` in the same group.

## When the host disappears

After `docker network disconnect bridge hv-hermes-test`, a probe that resolved `<HOST>` waited about 80 s per call. The cause is inferred: the name stops resolving. `ConnectTimeout` does not cover name resolution, so an `ssh` attempt can wait much longer than 5 s. The app ends an attempt after 20 s and tries again with a delay of 1, 2, 5, then 10 s. During a 38 s cut the app started a new `ssh` at +7 s and +17 s, and the tunnel was open again 1 s after `docker network connect`.

## Not observed

- `StrictHostKeyChecking=accept-new` on a real host: the first connection trusts the key it sees. The test mode keeps `known_hosts` in the private directory, so each run starts clean. A real run keeps it in `~/Library/Application Support/Hermed Bots/known_hosts`.
- A changed host key (the table above quotes the OpenSSH text).
- perso-hermes. No agent opened, resolved or read it.

## Reproduce

```
docs/spike/hd07-instruments/hv-ssh-endpoint.sh up      # container with sshd, no key printed
docs/spike/hd07-instruments/s12-observe.sh             # every observation above except the process-group ones
docs/spike/hd07-instruments/hv-ssh-endpoint.sh down
```
