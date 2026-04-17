# Changelog

## Unreleased

- Ship Pharo-side patches under `pharo/`: transcript capture in
  `SisServer>>handleEval:` plus NeoJSON fallbacks for `Object` and
  `Association`. Includes a `pharo/install.st` runtime installer.
- Rewrite `README.md` as a full installation + usage manual.
- Fix workspace `u` input (buffer-local keymap in browser source view).
- Normalize Pharo CR line endings to LF when capturing Transcript output.

## 0.1.0 - 2026-04-16

- Package the live Pharo Smalltalk bridge behind `pharo-smalltalk-install`.
- Add optional submodule loading for xref, completion, browser, and test tools.
- Add a fixed smoke-test interface with `pharo-smalltalk-test-run-smoke`.
- Improve Org Babel output so Transcript and Result are shown together.
- Add cache TTL and maximum-entry controls for completion caches.
- Add ERT coverage for package install, metadata, cache pruning, xref grouping,
  and Transcript/result formatting.
