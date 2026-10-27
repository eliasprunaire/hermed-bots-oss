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

## How the key reached `ssh` during the spike

The spike used a throwaway test key and a private agent. That path is not the product.

1. The probe created a private directory (mode 0700) under the temporary directory and started `ssh-agent -D -a <dir>/a`.
2. It ran `ssh-add -` and wrote the key on its standard input.
3. It ran `ssh-add -L` and stored the public part in `<dir>/key.pub`. The public part is not secret.
4. It ran `ssh -i <dir>/key.pub -o IdentitiesOnly=yes -o IdentityAgent=<dir>/a …`. `IdentitiesOnly` plus the public file told `ssh` which agent key to sign with.

Without `IdentitiesOnly` and `-i`, `ssh -v` also looked for `~/.ssh/id_rsa`, `id_ecdsa`, `id_ed25519` and their `_sk` forms before it offered the agent key. With them it offered one key, the agent key (`Offering public key: … explicit agent`). The house tool `vssh` used the same pattern.

A key protected by a passphrase failed at step 2 in 0.01 s (`rc=1`, `Enter passphrase for (stdin):`, no terminal). The probe showed that case and did not wait.

## Current product

The app launches `/usr/bin/ssh` with the user's alias and the default user config. It does not start `ssh-agent`, does not run `ssh-add`, does not write `key.pub`, and does not keep a temporary `known_hosts`. Identity comes from the session `SSH_AUTH_SOCK` and from `IdentityAgent` in the user's config. `IdentityAgent none` turns the agent off, the session socket included, and the connection view then shows a file identity. Arguments force `ForkAfterAuthentication=no` and `LogLevel=ERROR`.

Resolution runs `/usr/bin/ssh -G -vv` once per launch of `ssh`, with the arguments of that launch: the tunnel (`-N -T -L …`), the profile list (`hermes profile list`) and the Desktop lock read (one fixed remote command). Each launch is resolved and checked with its own arguments: one dump of the bare alias cannot validate the three launches.

The app does not interpret SSH config criteria. It refuses what it cannot read with certainty, and in case of doubt it refuses:

1. **Any `Match` block refuses the whole config**, whatever its form (`Match all`, `Match user *`, `Match host *`, `Match originalhost *`, `Match exec …` with or without quotes and escapes, `Match host <alias>`). OpenSSH writes `checking match for '<criteria>'` at `-vv` for every `Match` line it reads, applied or not, in an included file and in a `Host` block that does not apply too. The app looks for that line only and never reads the criteria. Message: "Ta config SSH contient un bloc Match…".
2. **A config that `ssh -G` cannot read is refused.** `ssh -G` exits with an error on an unclosed quote, an unknown option or a missing argument. A `-vv` log of 64 KB or more is refused too, because the log is cut there and a `Match` line after the cut would go unseen. An `Include` that matches no file (`include … matched no files`) is a doubt as well. Message: "Hermed Bots ne lit pas cette config SSH avec certitude…".
3. **An alias is known only when a `Host` block writes it as is.** OpenSSH writes `<file> line <n>: Applying options for <pattern>` with the first pattern of the `Host` line that covers the alias. The app accepts the line only when it has exactly that shape and the pattern is the alias itself, with no `*`, `?` or `!`, and with the same case. `Host *`, `Host **`, `Host mon*` and `Host * alias` never make an alias known, whatever values the block sets (`User`, `Port`, `HostName`, an identity): `ssh -G` accepts any name. Message: "Cet alias SSH est inconnu."

The real `ssh -G -vv -F` runs these rules in `RealSshConfigTests`: every form of `Match`, a `Match` in an included file or after another `Host`, a config cut at the limit, an unresolved `Include`, a config `ssh` cannot parse.

The app refuses any alias whose resolved config holds a ProxyJump or a ProxyCommand, in every mode, before the tunnel `ssh`. The value does not matter, and any one of the three launches is enough to refuse. Only `none` as the whole value, which removes an inherited relay, is not a relay. `none,none` is a list of two hops named `none`, so it is refused. The name of a hop does not prove where the hop leads. An alias can lead to a production host. The message tells the user to use an alias that connects directly.

Test mode also refuses a documented fake host on the typed alias, before any `ssh`, and on the resolved host of each launch. This file writes that host as `example-host`. The compiled tests on this tree still use the existing forbidden-host fixtures.

The check runs when the user connects. A config file edited afterwards is read again at the next connection or reopening, without a new check.

## The forward

The spike opened `ssh -N -T -L 127.0.0.1:<port>:127.0.0.1:8642 hvssh@<HOST>`. `GET /health` on it answered `{"status": "ok", "platform": "hermes-agent", "version": "0.22.2"}`. `ssh -W 127.0.0.1:22` through the same account failed with `stdio forwarding failed`: `PermitOpen` holds. `ssh` stopped on SIGTERM with `rc=0`. The product uses the same forward shape, with the alias as the host argument instead of `user@host`.

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
- SIGKILL cannot be caught. The group leader is a `sh` that reads a pipe only the app holds open. When the app dies the kernel closes the pipe and the `sh` runs `kill -KILL 0`, which kills its whole group. With this watchdog, SIGTERM and SIGKILL on the app left no `ssh` or `sh` behind (smoke run), and the lanes of HD-07 show the same for Cmd-Q and `terminate()`. The spike also had a private `ssh-agent` in that group; the product does not.
- The watchdog and every `ssh` share one process group. A reopen starts a new `ssh` in the same group.
- Each `ssh -G` runs under its own watchdog too. The call registers the group for the termination hooks, and kills the whole group at the timeout and at the end of the call. A `Match exec` command that sleeps keeps `ssh -G` alive: `killAll` ends both within 2 s (`testTerminatingTheAppLeavesNoSshDumpAlive`), and a timeout leaves no grandchild (`testATimedOutGuardedRunKillsEveryProcessOfItsGroup`). SIGKILL on the app uses the same watchdog as the tunnel. No test kills its own host, so that case follows from the watchdog tests and was not observed on `ssh -G`.

## When the host disappears

After `docker network disconnect bridge hv-hermes-test`, a probe that resolved `<HOST>` waited about 80 s per call. The cause is inferred: the name stops resolving. `ConnectTimeout` does not cover name resolution, so an `ssh` attempt can wait much longer than 5 s. The app ends an attempt after 20 s and tries again with a delay of 1, 2, 5, then 10 s. During a 38 s cut the app started a new `ssh` at +7 s and +17 s, and the tunnel was open again 1 s after `docker network connect`.

## Not observed

- `StrictHostKeyChecking=accept-new` on a real host: the first connection trusts the key it sees. The spike kept `known_hosts` in the private directory so each run started clean. The product leaves host-key files to the user's OpenSSH config.
- A changed host key (the table above quotes the OpenSSH text).
- A production host during the spike. Test mode now refuses that class of name on the full route before `ssh` starts. This file uses `example-host` as the documented placeholder.

## Reproduce

```
docs/spike/hd07-instruments/hv-ssh-endpoint.sh up      # container with sshd, no key printed
docs/spike/hd07-instruments/s12-observe.sh             # every observation above except the process-group ones
docs/spike/hd07-instruments/hv-ssh-endpoint.sh down
```
