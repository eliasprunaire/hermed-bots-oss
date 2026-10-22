# Decision logs and subagent register

Any agent that spawns subagents keeps two files for the run.

## Decision log

Format is the show-me-your-work TSV. Copy the header from `.cursor/skills/show-me-your-work/references/decision-log-template.tsv`.

Default location is the current agent store, under `docs/decisions.tsv`. That file stays out of git.

Commit a copy under this directory when a reviewer needs the trail. Name it `<task-slug>.tsv`. Append only. Never rewrite a past row.

## Subagent register

Default location is `.audit/subagents.tsv` in the worktree. Cloud hooks `subagentStart` and `subagentStop` append there through `.cursor/hooks/log-subagent.sh`. `.audit/` is gitignored.

When the trail is committed, copy the register next to the decision log as `<task-slug>-subagents.tsv`.

The parent that spawned the Task also records id, role, model, state, and a stuck-after duration in the same store, so a replacement can probe a dead parent.
