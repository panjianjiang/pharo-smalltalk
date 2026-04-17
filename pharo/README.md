# Pharo-side bridge

This directory holds a Tonel-format Pharo project. It packages two
small additions on top of upstream
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
| `BaselineOfPharoSmalltalkBridge/` | Metacello baseline; depends on upstream + loads `Sis-Bridge-Extras`. |
| `Sis-Bridge-Extras/` | Tonel package containing the two NeoJSON extensions plus the `SisServer` override. |
| `Sis-Bridge-Extras-Tests/` | Optional integration tests for Transcript capture and serialization. |
| `install.st` | Legacy runtime installer kept as a fallback. |

## Recommended install — Metacello

In a Pharo 13 image, evaluate:

```smalltalk
Metacello new
    baseline: 'PharoSmalltalkBridge';
    repository: 'github://panjianjiang/pharo-smalltalk:main/pharo';
    load.
SisServer current restart.
```

This loads upstream `PharoSmalltalkInteropServer` first, then the
`Sis-Bridge-Extras` package on top. Re-running the same expression
upgrades both. Restart the server to make sure the new `handleEval:`
serves `/eval`.

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

If you already maintain a fork of `PharoSmalltalkInteropServer`
through Iceberg and don't want to add another Metacello dependency,
run the legacy script in any Playground:

```smalltalk
Smalltalk compiler evaluate:
    '/path/to/pharo-smalltalk/pharo/install.st' asFileReference contents.
SisServer restart.
```

`install.st` compiles the same four methods directly into the running
image. It is path-agnostic and idempotent.

## Verification

After install, from Emacs run:

```text
M-x pharo-smalltalk-test-run-smoke
```

or evaluate a line that writes to the Transcript and check that the
output appears inline:

```smalltalk
Transcript crShow: 'hello from Pharo'. 1 + 2
```

For Pharo-side regression coverage, run `SisBridgeExtrasTest`.
