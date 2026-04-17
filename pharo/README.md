# Pharo-side patches

The elisp package talks to a running Pharo image through
[PharoSmalltalkInteropServer] (`SisServer` on port 8086). Two
enhancements to SisServer are required for the Emacs UI to work well:

1. **Transcript capture in `handleEval:`** — `/eval` returns the
   Transcript output produced during evaluation alongside the result,
   so Emacs can show both without a second round-trip.
2. **NeoJSON fallback extensions** — a default `Object>>neoJsonOn:` and
   a specialized `Association>>neoJsonOn:` so arbitrary return values
   (classes, associations, morphs, ...) serialize cleanly instead of
   raising `NeoJSONMappingNotFound` as HTTP 500.

[PharoSmalltalkInteropServer]: https://github.com/mumez/PharoSmalltalkInteropServer

## Files

| File | Purpose |
| --- | --- |
| `Sis-Core/SisServer.class.st` | Full patched SisServer class (drop-in over the upstream Tonel file). |
| `Sis-Core/Object.extension.st` | Fallback `neoJsonOn:` for any object. |
| `Sis-Core/Association.extension.st` | One-entry-map `neoJsonOn:` for Associations. |
| `install.st` | Runtime installer — compiles the four methods into a loaded image without touching Tonel on disk. |

## Applying the patches

### Option A — live install from Playground (recommended)

With a Pharo 13 image that already has `Sis-Core` loaded:

```smalltalk
FileStream fileIn: '/path/to/pharo-smalltalk/pharo/install.st'.
SisServer restart.
```

Installation is idempotent: re-running it recompiles the same methods.

### Option B — Tonel drop-in

If you maintain your own clone of `PharoSmalltalkInteropServer` through
Iceberg, copy the files into the matching package directory and reload:

```sh
cp pharo/Sis-Core/SisServer.class.st \
   $PHARO_LOCAL/iceberg/mumez/PharoSmalltalkInteropServer/src/Sis-Core/
cp pharo/Sis-Core/Object.extension.st \
   $PHARO_LOCAL/iceberg/mumez/PharoSmalltalkInteropServer/src/Sis-Core/
cp pharo/Sis-Core/Association.extension.st \
   $PHARO_LOCAL/iceberg/mumez/PharoSmalltalkInteropServer/src/Sis-Core/
```

Then in the image: open Iceberg → `PharoSmalltalkInteropServer` →
right-click → *Load*, or evaluate
`(IceRepositoryCreator new location: '…' asFileReference) createRepository`.

## Verification

After install, from Emacs run:

```text
M-x pharo-smalltalk-test-run-smoke
```

or evaluate a line that writes to the Transcript — the output should
appear inline in the Emacs minibuffer or result buffer:

```smalltalk
Transcript crShow: 'hello from Pharo'. 1 + 2
```
