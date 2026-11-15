# Bundled ccusage helper

QuickVibeHost bundles the Universal macOS build of `ccusage` so the status tab
can read local Claude/Codex usage without Node.js or a first-launch download.

- Package: `@ccusage/ccusage-darwin-arm64` + `@ccusage/ccusage-darwin-x64`
- Version: 20.0.19
- Architectures: arm64 and x86_64
- Minimum macOS: 14
- License: MIT (see `CCUSAGE_LICENSE`)
- Universal binary SHA-256: `65fa5e95cd247716432ba6b6e61784096d244f4bb5e8377e35ec64885de78e4c`

The helper is invoked with `--offline`. Local prompts, transcript contents,
model names, projects, and usage totals are not uploaded by QuickVibeHost.
