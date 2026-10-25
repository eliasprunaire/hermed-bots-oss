# AGENTS.md

Guidance for coding agents working in this repository.

- Read `README.md` and `docs/` before changing code. Plans live in `docs/plans/`.
- Run `npm test` and `npm run lint` before every commit; Swift code: `swift test --package-path Packages/HermesAdapter --skip PerfTests` and the Xcode scheme `HermedBots` (probe classes skipped). Performance probes are a separate pass on scheme `HermedBotsPerf`, documented in `docs/perf-probes.md`.
- Work on a branch and open a pull request against `main`; never push to `main` directly.
- No infrastructure information in the repository, commits, issues, pull requests or comments: no local paths (`/Users/<name>`, `/home/<name>`), host names, internal domains (`*.local`), private IPs, internal ports, machine names, Apple Team ID or signing identity, personal e-mail addresses. Redact before posting (`~`/`<HOME>`, `<HOST>`, `<IP>`). The `infra-guard` workflow enforces this.
- Evidence, raw logs and screenshots stay on the machine that produced them (see `.gitignore`); pull requests cite a redacted summary only.
- Machine-specific or operator-specific instructions do not belong in this repository.

## Rule to mechanism

| Rule | Mechanism that applies it |
| --- | --- |
| Frozen versions and approved distribution configuration | `scripts/distribution.js`, `test/distribution/release.test.js`, and `.github/workflows/release.yml` job `preflight`. |
| No Cursor attribution, no Co-authored-by, no Open in Cursor footer | `.githooks/commit-msg`, `scripts/check-pr-attribution.js`, job `pr-attribution`, and `scripts/squash-merge.js` with an empty squash body. `scripts/install-git-hooks.js` copies the hook scripts into `hermed-bots-hooks`. `git worktree add --no-checkout` then `git checkout`, and a linked worktree after the primary directory is renamed, can skip the hook. Those two Git layouts are already named here. CI still reads stored messages. |
| Marked `PASS` or `PASS+NOTES` with `<!-- dev-lead-verifier -->`, posted by an allowlisted verifier, on the exact head SHA | `scripts/verdict-gate.js` and `.github/workflows/verdict-gate.yml`. Docs-or-rules does not skip. |
| Verdict comment is not the PR author | `scripts/verdict-gate.js` compares the marked comment login to the PR author login. Two `cursor[bot]` posters still match. |
| Direct push to `main` | `.githooks/pre-push` via `scripts/check-pre-push.js`. After a GitHub push, `scripts/check-main-push.js` and `.github/workflows/main-push.yml`. Branch protection cannot be set from this token. |
| PR body lists `bc-` UUID ids under `## Agents` | `scripts/check-pr-attribution.js` |
| Program plans pass `check-plan.mjs` | `scripts/check-plans.js` and `.github/workflows/check-plans.yml` |
| No change to `.claude/`, `.codex/` or `.mcp.json` in a PR | `scripts/check-protected-paths.js` and `.github/workflows/protected-paths.yml` |
| Latest OS, SDK, language, and tool versions, no backward compatibility (macOS 27+ here) | The independent verifier checks deployment targets, SDK and toolchain versions, and any new fallback at each PR. Review. |
| No infrastructure information in diffs, PR bodies, pushes or comments | `scripts/infra-guard-ci.js`, `test/infra-guard-ci.test.js`, and job `scan` in `.github/workflows/infra-guard.yml` |
