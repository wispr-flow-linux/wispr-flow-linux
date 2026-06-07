# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Semantic versioning applies to the wrapper (`REPO_VERSION`); the bundled Wispr
Flow app version is tracked separately by the `+wispr{X.Y.Z}` suffix.

## [Unreleased]

## [v1.0.1] - 2026-06-07

### Added

- End-user install documentation: `docs/installation.md` plus a README
  Installation section (APT, DNF, AUR, AppImage, manual).
- AppImage auto-update metadata: CI embeds `gh-releases-zsync` update info and
  emits a companion `.AppImage.zsync`.
- `wispr-flow --doctor` install-integrity checks: chrome-sandbox setuid,
  Electron runtime, desktop entry, and free disk.

### Changed

- README opening rewritten in declarative style; Status and Supported-environments
  sections removed.
- rpm spec hardened: `%defattr` default and explicit `%global debug_package %{nil}`.
- `verify-patches.sh` dropped `set -e` per the bash styleguide.

### Fixed

- rpm could ship a non-setuid / missing chrome-sandbox; the setuid `4755` bit is
  now baked into the FHS tree and the build fails on "File listed twice".
- `build.sh --clean` was a no-op; it now prunes intermediates while keeping the
  package and `downloads/`.
- `build-linux.sh` staged a stale version (`APP_VERSION` default `1.5.619` →
  `1.5.695`).

## [v1.0.0] - 2026-06-07

Initial release — unofficial Linux repackaging of Wispr Flow (1.5.695) as
`.deb` / `.rpm` / AppImage for amd64 and arm64, with the clean-room Rust helper
(text injection, clipboard, global key capture), the Linux platform-gate
patches, Nix flake, docs tree, and the tag-driven release/publish pipeline.

[Unreleased]: https://github.com/wispr-flow-linux/wispr-flow-linux/compare/v1.0.1+wispr1.5.695...HEAD
[v1.0.1]: https://github.com/wispr-flow-linux/wispr-flow-linux/compare/v1.0.0+wispr1.5.695...v1.0.1+wispr1.5.695
[v1.0.0]: https://github.com/wispr-flow-linux/wispr-flow-linux/releases/tag/v1.0.0+wispr1.5.695
