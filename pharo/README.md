# Pharo-side bridge

This directory holds the Pharo-side package that sits on top of upstream
[PharoSmalltalkInteropServer]:

1. **Transcript capture in `SisServer>>handleEval:`** — `/eval` returns
   the Transcript output produced during evaluation alongside the
   result, so Emacs can show both without a second round-trip.
2. **Targeted NeoJSON extensions** — `StThreadSafeTranscript>>neoJsonOn:`
   (Playground-style display string) and `Association>>neoJsonOn:`
   (one-entry map) so common `/eval` results serialize cleanly without
   globally changing NeoJSON's fallback for every object.

[PharoSmalltalkInteropServer]: https://github.com/mumez/PharoSmalltalkInteropServer

## Layout

| Path | Purpose |
| --- | --- |
| `BaselineOfPharoSmalltalkBridge/` | Metacello baseline for upstream server + `Sis-Bridge-Extras`. |
| `Sis-Bridge-Extras/` | `SisServer` override plus the targeted NeoJSON extensions. |
| `Sis-Bridge-Extras-Tests/` | Regression tests for `/eval`, Transcript capture, and serialization. |
| `install.st` | Local bootstrap script for loading `Sis-Bridge-Extras` from disk. |

## Recommended install — Metacello

In a Pharo 13 image, evaluate:

```smalltalk
Metacello new
    baseline: 'PharoSmalltalkBridge';
    repository: 'github://panjianjiang/pharo-smalltalk:main/pharo';
    load.
SisServer current restart.
```

This loads upstream `PharoSmalltalkInteropServer` first and then
`Sis-Bridge-Extras`. Re-running the same expression upgrades both.
Restart the server so `/eval` starts serving the patched `handleEval:`.

> **Override semantics**: `SisServer>>handleEval:` is shipped as an
> extension method owned by `Sis-Bridge-Extras`. After load, this
> package owns the selector — Pharo only stores one method per
> selector per class. Unloading `Sis-Bridge-Extras` will remove
> `handleEval:` entirely; reload upstream `PharoSmalltalkInteropServer`
> to restore the original.

Load the optional test package with:

```smalltalk
Metacello new
    baseline: 'PharoSmalltalkBridge';
    repository: 'github://panjianjiang/pharo-smalltalk:main/pharo';
    load: 'tests'.
```

## Fallback install — install.st

If this repository is already checked out locally and you want to load
from disk instead of GitHub, point the bootstrap script at the local
`pharo/` directory and evaluate it:

```smalltalk
Smalltalk globals
    at: #PharoSmalltalkBridgeInstallDirectory
    put: '/path/to/pharo-smalltalk/pharo' asFileReference.
Smalltalk compiler evaluate:
    ('/path/to/pharo-smalltalk/pharo/install.st' asFileReference contents).
SisServer restart.
```

`install.st` delegates to the same local Tonel sources via Metacello and
only loads `Sis-Bridge-Extras`. It assumes upstream
`PharoSmalltalkInteropServer` is already in the image.

## Verification

Quick checks after install:

```text
M-x pharo-smalltalk-test-run-smoke
```

```smalltalk
Transcript crShow: 'hello from Pharo'. 1 + 2
```

For Pharo-side regression coverage, run `SisBridgeExtrasTest`.
