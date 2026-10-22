# Security policy

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's private vulnerability reporting
("Security" tab, "Report a vulnerability") on this repository. Include the affected
version, steps to reproduce and the impact. You should receive an answer within 7 days.

## Supported versions

Only the latest release is supported. Hermed Bots targets the latest macOS release.

## Scope and handling

- Release signing material, notarization credentials and the update-feed signing key are
  stored only as GitHub Actions secrets of the protected `release` environment.
- Release builds are signed, notarized and stapled; updates are verified with a Sparkle
  EdDSA signature.
- The repository must not contain infrastructure information (local paths, host names,
  private IPs, machine names, signing identities). The `infra-guard` workflow checks every
  pull request, push and comment.
