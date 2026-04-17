# pharo-smalltalk

A live Emacs bridge to a running Pharo image via
[PharoSmalltalkInteropServer] (`SisServer`). Provides a Smalltalk major
mode, a workspace, evaluation commands, xref/completion/eldoc backends,
and a Pharo-style system browser — all driven off HTTP endpoints served
by the Pharo image.

[PharoSmalltalkInteropServer]: https://github.com/mumez/PharoSmalltalkInteropServer

## Contents

- [Requirements](#requirements)
- [Install](#install)
  - [1. Pharo side](#1-pharo-side)
  - [2. Emacs side](#2-emacs-side)
- [Usage](#usage)
  - [Global prefix map](#global-prefix-map)
  - [Workspace](#workspace)
  - [System browser](#system-browser)
  - [Navigation](#navigation)
  - [Tests](#tests)
  - [Org Babel](#org-babel)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)

## Requirements

- Pharo 13 (or compatible) image.
- Emacs 29.1+.
- This repo's `BaselineOfPharoSmalltalkBridge`, which loads upstream
  [PharoSmalltalkInteropServer][pharosis] plus the `Sis-Bridge-Extras`
  package (Transcript capture + targeted NeoJSON helpers). Without the
  extras the `/eval` endpoint can return HTTP 500 for Transcript /
  Association-heavy results, and Transcript output is not surfaced to
  Emacs.

[pharosis]: https://github.com/mumez/PharoSmalltalkInteropServer

## Install

### 1. Pharo side

In a Pharo 13 image, load this repo's baseline — it pulls upstream
[PharoSmalltalkInteropServer] and the bridge extras in one shot:

```smalltalk
Metacello new
    baseline: 'PharoSmalltalkBridge';
    repository: 'github://panjianjiang/pharo-smalltalk:main/pharo';
    load.
SisServer current restart.
```

The extras add Transcript capture in `handleEval:` and targeted
NeoJSON helpers for `StThreadSafeTranscript` / `Association`. See
[`pharo/README.md`](pharo/README.md) for what each piece does,
override semantics, and the legacy `install.st` fallback.

[PharoSmalltalkInteropServer]: https://github.com/mumez/PharoSmalltalkInteropServer

### 2. Emacs side

Put this repo on your `load-path` and call the installer:

```elisp
(add-to-list 'load-path "/path/to/pharo-smalltalk")
(require 'pharo-smalltalk)
(pharo-smalltalk-install)
```

`pharo-smalltalk-install` performs three things:

- loads the optional submodules in `pharo-smalltalk-package-modules`
  (`xref`, `capf`, `test`, `browser` by default);
- registers `pharo-smalltalk-mode` for `.st`, `.smalltalk`, `.tonel`;
- binds the command prefix map to `pharo-smalltalk-global-command-key`
  (`C-c s` by default).

Verify the bridge:

```text
M-x pharo-smalltalk-ping     ; round-trips a tiny eval to the server
```

## Usage

### Global prefix map

With the default `C-c s` prefix:

| Key | Command |
| --- | --- |
| `C-c s e` | `pharo-smalltalk-eval-region-or-line` |
| `C-c s E` | `pharo-smalltalk-eval-region` |
| `C-c s b` | `pharo-smalltalk-eval-buffer` |
| `C-c s p` | `pharo-smalltalk-eval-paragraph-or-region` |
| `C-c s d` | `pharo-smalltalk-eval-string-debug` |
| `C-c s r` | `pharo-smalltalk-show-last-result` |
| `C-c s h` | `pharo-smalltalk-show-last-http-response` |
| `C-c s w` | open workspace |
| `C-c s B` | open browser |
| `C-c s F` | browse a class directly |
| `C-c s c` | `pharo-smalltalk-browse-class` (one-shot) |
| `C-c s m` | `pharo-smalltalk-show-method-source` |
| `C-c s I` | `pharo-smalltalk-inspect-class-at-point` |
| `C-c s s` / `S` / `R` | search implementors / references / refs-to-class |
| `C-c s C` / `M` / `T` | search classes / methods / traits like… |
| `C-c s D` | `pharo-smalltalk-show-class-comment` |
| `C-c s x` / `i` | export / import Tonel package |
| `C-c s P` | `pharo-smalltalk-ping` |
| `C-c s t c/p/s/r` | run test class / package / smoke / re-run |

Inside `pharo-smalltalk-mode` buffers these are also bound:

| Key | Command |
| --- | --- |
| `C-c C-z` | `pharo-smalltalk-send-chunk` |
| `C-c C-c` | `pharo-smalltalk-send-defun` |
| `C-c C-b` | `pharo-smalltalk-send-buffer` |
| `C-c C-k` | `pharo-smalltalk-load-file` |
| `C-c C-w` | open workspace |
| `C-c C-i` | inspect class at point |

### Workspace

`M-x pharo-smalltalk-workspace` (or `C-c s w`) opens a scratch buffer
with `pharo-smalltalk-mode`. Evaluate the current line or region with
`C-c s e`; the result (and any captured Transcript output) is shown in
the minibuffer, and the raw last response is available at
`C-c s r` / `C-c s h`.

### System browser

`M-x pharo-smalltalk-browse` (or `C-c s B`) opens a Pharo-style browser
that drills down: packages → classes → methods → source.

| Key | Action |
| --- | --- |
| `RET` | drill into the row at point |
| `u` / `^` | go back one level |
| `g` | refresh from server |
| `c` | toggle instance / class side (method list) |
| `q` | quit |

In the method source view, `u` returns to the method list (buffer-local
binding — does not pollute `pharo-smalltalk-mode-map`).

### Navigation

With `pharo-smalltalk-xref` loaded (default), `M-.` on a class or
selector uses the live image via the xref backend. `pharo-smalltalk-capf`
provides completion-at-point and eldoc-style method hints backed by
`list-methods` / `search-methods-like`.

### Tests

- `C-c s t c` — run tests in a class
- `C-c s t p` — run tests in a package
- `C-c s t s` — run the built-in smoke suite against the live server
- `C-c s t r` — re-run the last test selection

Batch ERT suite (hermetic, no running server required):

```sh
emacs --batch -Q -L . \
  -l pharo-smalltalk.el \
  -l pharo-smalltalk-xref.el \
  -l pharo-smalltalk-capf.el \
  -l pharo-smalltalk-test.el \
  -l pharo-smalltalk-ert.el \
  -f ert-run-tests-batch-and-exit
```

### Org Babel

Smalltalk source blocks are executable out of the box:

````org
#+BEGIN_SRC smalltalk
| s |
s := OrderedCollection new.
s add: 1; add: 2; add: 3.
Transcript crShow: 'hi'.
s sum
#+END_SRC
````

Transcript output and the result are shown together in the results
block.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `pharo-smalltalk-server-url` | `http://127.0.0.1:8086` | SisServer base URL |
| `pharo-smalltalk-timeout` | `10` | HTTP timeout (seconds) |
| `pharo-smalltalk-result-buffer-name` | `*Pharo Eval*` | result buffer |
| `pharo-smalltalk-workspace-buffer-name` | `*Pharo Workspace*` | workspace buffer |
| `pharo-smalltalk-default-method-category` | `as yet unclassified` | default protocol on compile |
| `pharo-smalltalk-prompt-for-missing-method-metadata` | `t` | prompt when metadata missing |
| `pharo-smalltalk-package-modules` | `(xref capf test browser)` | optional modules loaded on install |
| `pharo-smalltalk-global-command-key` | `C-c s` | global prefix key (nil to disable) |
| `pharo-smalltalk-auto-mode-patterns` | `.st` / `.smalltalk` / `.tonel` | file associations |
| `pharo-smalltalk-indent-offset` | `2` | indent step |
| `pharo-smalltalk-class-cache-ttl` | `30` | class-name cache TTL (seconds) |
| `pharo-smalltalk-capf-cache-ttl` | `15` | completion/query cache TTL (seconds) |

All are under the `pharo-smalltalk` customize group.

## Troubleshooting

- **HTTP 500 `NeoJSONMappingNotFound`** — you haven't applied
  `pharo/install.st` (or loaded `Sis-Bridge-Extras`). Without the
  extra `neoJsonOn:` methods, evaluating values such as `Transcript`
  or `Association` can fail to serialize.
- **Transcript output missing from Emacs result** — same fix: the
  patched `handleEval:` is what surfaces Transcript text in the
  response.
- **`u` key doesn't insert letter in workspace** — fixed in v0.1.0+;
  make sure you're on the current `pharo-smalltalk.el` /
  `pharo-smalltalk-browser.el`. The old code used `local-set-key`,
  which polluted the major-mode's shared keymap.
- **CR line endings in Transcript output** — normalized to LF by
  `pharo-smalltalk--extract-transcript` (v0.1.0+).
- **Server not reachable** — `M-x pharo-smalltalk-ping`; then check
  `SisServer current teapot isRunning` in Pharo.

## Modules

- `pharo-smalltalk.el` — core bridge, major mode, Org Babel integration
- `pharo-smalltalk-xref.el` — xref backend
- `pharo-smalltalk-capf.el` — completion-at-point and eldoc
- `pharo-smalltalk-browser.el` — tabulated-list system browser
- `pharo-smalltalk-test.el` — test runner and smoke checks
- `pharo-smalltalk-ert.el` — local ERT suite
- `pharo-smalltalk-pkg.el` — package descriptor
- [`pharo/`](pharo/) — server-side patches for SisServer and NeoJSON

## License

See [LICENSE](LICENSE).
