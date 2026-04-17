# Changelog

## Unreleased

- **Screenshot command**: new `pharo-smalltalk-show-screen' (bound to
  `C-c s v') wraps the server `/read-screen' endpoint.  Captures a
  PNG of the Pharo World (or `spec' / `roassal' with a prefix arg)
  and displays it per `pharo-smalltalk-screenshot-viewer': `auto'
  picks an `image-mode' buffer on GUI frames and `xdg-open' /
  `open' on TUI; a string value is treated as a shell command so
  terminal image protocols (`kitty +kitten icat', `wezterm imgcat',
  `imgcat') plug in directly.  Returns the structured response
  (summary + morph/presenter/canvas tree) to the caller.

- **Shared TTL cache for source endpoints**: `pharo-smalltalk-get-class-source`,
  `pharo-smalltalk-get-method-source`, and `pharo-smalltalk-get-class-comment`
  now consult shared hash tables (`pharo-smalltalk--class-source-cache`,
  `--method-source-cache`, `--class-comment-cache`).  xref `M-.`, the
  browser, and capf/eldoc all warm and read the same cache, so a second
  jump to the same definition is 0ms.  Cleared on the mutation hook.
- **Bridge-level async source fetchers** with in-flight dedup:
  `pharo-smalltalk-get-method-source-async` and `…-class-comment-async`
  drop duplicate dispatches for the same key while a fetch is pending,
  delivering the single response to all waiters.
- **capf prefetch-on-miss** for selector completion: `--methods-like`
  now returns the cached hit (or nil while a prefetch flies) without
  blocking the keystroke.  Async prefetch populates the cache so the
  next keystroke shows results.
- **Stale-symbol guard** in async eldoc: replies are dropped when point
  has moved out of the symbol's bounds or the buffer text under those
  bounds has changed, so a slow class-comment reply won't overwrite the
  next selector's eldoc text.
- Drop the now-redundant `pharo-smalltalk-capf--method-source-cache` /
  `--class-comment-cache` defvars and `--method-source-cache-max-entries`
  defcustom; capf delegates to the shared bridge cache.
- ERT 22 → 25: shared-cache hit + invalidate, async in-flight dedup,
  stale-guard discard.

- **Async eldoc release-on-empty**: when the deferred fetch returns
  nil (unknown class, missing source, server error), the eldoc
  callback is now still invoked with nil to release the eldoc slot.
  Previously the empty case silently skipped the callback, which left
  stale text on screen until the next cursor move. Adds an ERT.

- **Pharo packaging**: ship `BaselineOfPharoSmalltalkBridge` plus a
  `Sis-Bridge-Extras` Tonel package. Single-line install via
  `Metacello new baseline: 'PharoSmalltalkBridge'; …; load`. The
  legacy `pharo/install.st` script is kept as a fallback. The old
  `pharo/Sis-Core/` forked-class blob is removed.
- **MELPA-style headers**: full Author/Maintainer/URL/SPDX on the
  main file, `;;; Commentary:` and `;;; Code:` markers on every
  submodule, expanded `Commentary` block describing entry point.
- **Byte-compile clean** under `byte-compile-error-on-warn t`:
  declared `url-http-response-status` / `url-http-end-of-headers`
  and the lazy-loaded org variables; broke five docstrings under
  the 80-character limit.
- **CI**: `.github/workflows/ci.yml` runs byte-compile, ERT, and
  checkdoc on Emacs 29.1 / 29.4 / snapshot, plus `package-lint`
  on the main file.


- Ship Pharo-side patches under `pharo/`: transcript capture in
  `SisServer>>handleEval:` plus NeoJSON fallbacks for `Object` and
  `Association`. Includes a `pharo/install.st` runtime installer.
- Rewrite `README.md` as a full installation + usage manual.
- Fix workspace `u` input (buffer-local keymap in browser source view).
- Normalize Pharo CR line endings to LF when capturing Transcript output.
- **Fix `:json-false` truthiness bug**: failed evals previously returned
  nil silently; they now raise with the server-side error description.
  Adds `pharo-smalltalk--success-p` predicate used by `--result`,
  `--store-and-display`, `--unwrap-async`, and `show-last-result`.
- **Browser caches**: TTL-cache `list-packages`, `list-classes`,
  `list-extended-classes`, and `--class-protocols`. Cleared on the
  mutation hook and on `g` in the browser. Eliminates per-keystroke
  refetch stalls during browser drill-down.
- **Async eldoc**: `pharo-smalltalk-capf--eldoc` no longer blocks Emacs
  on cache miss — dispatches `--request-async` and fills via the
  eldoc deferred callback. Class-comment cache added.
- **Surface silent failures**: `pharo-smalltalk--warn-once` (rate-limited
  `[pharo-smalltalk]` messages) replaces blanket `(error nil)` swallows
  in `capf` / `eldoc`, so completion stoppages tell the user why.
- **Per-action result buffers**: `--store-and-display` now writes to
  `*Pharo <action>*` instead of a single shared buffer, so concurrent
  searches don't clobber each other.
- Remove ~30 stale `my/smalltalk-*` and unprefixed `pharo-*` aliases.
- ERT suite expanded from 14 → 21 tests covering success-predicate,
  failure-path raising, browser cache hit/invalidate, warn-once
  throttling, per-action buffer naming, and test-summary parsing.
- **Fix test summary parser**: `--parse-summary` now matches Pharo's
  singular labels (`1 failure`, `1 error`); previously the structured
  summary line was silently dropped whenever a count was exactly one.

## 0.1.0 - 2026-04-16

- Package the live Pharo Smalltalk bridge behind `pharo-smalltalk-install`.
- Add optional submodule loading for xref, completion, browser, and test tools.
- Add a fixed smoke-test interface with `pharo-smalltalk-test-run-smoke`.
- Improve Org Babel output so Transcript and Result are shown together.
- Add cache TTL and maximum-entry controls for completion caches.
- Add ERT coverage for package install, metadata, cache pruning, xref grouping,
  and Transcript/result formatting.
