# Pharo Smalltalk Package

This package provides a live Emacs bridge for a running Pharo image via
`PharoSmalltalkInteropServer` / `SisServer`.

## Entry point

Load the package and install its defaults:

```elisp
(require 'pharo-smalltalk)
(pharo-smalltalk-install)
```

Minimal `load-path` example:

```elisp
(add-to-list 'load-path "/path/to/pharo-smalltalk")
(require 'pharo-smalltalk)
(pharo-smalltalk-install)
```

`pharo-smalltalk-install` does three things:

- loads optional support modules from `pharo-smalltalk-package-modules`
- registers `pharo-smalltalk-mode` for `.st`, `.smalltalk`, and `.tonel`
- binds `pharo-smalltalk-command-map` to `pharo-smalltalk-global-command-key`

## Included modules

- `pharo-smalltalk.el`: core bridge, major mode, Org Babel integration
- `pharo-smalltalk-xref.el`: xref backend
- `pharo-smalltalk-capf.el`: completion and eldoc
- `pharo-smalltalk-browser.el`: browser UI
- `pharo-smalltalk-test.el`: test runner and smoke checks
- `pharo-smalltalk-ert.el`: local ERT suite
- `pharo-smalltalk-pkg.el`: minimal package descriptor

## Local wrapper

If you keep local, user-specific defaults in another file, keep that wrapper
outside this package and let it call `pharo-smalltalk-install`.

## Tests

Batch ERT:

```sh
emacs --batch -Q -L . \
  -l pharo-smalltalk.el \
  -l pharo-smalltalk-xref.el \
  -l pharo-smalltalk-capf.el \
  -l pharo-smalltalk-test.el \
  -l pharo-smalltalk-ert.el \
  -f ert-run-tests-batch-and-exit
```

Live smoke tests from Emacs:

- `M-x pharo-smalltalk-test-run-smoke`
- `M-x pharo-smalltalk-run-ert-tests`
