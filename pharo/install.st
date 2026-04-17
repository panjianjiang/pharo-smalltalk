"Install the Sis-Core patches shipped with pharo-smalltalk.

Assumes PharoSmalltalkInteropServer is already loaded in the image
(e.g. via Metacello from https://github.com/mumez/PharoSmalltalkInteropServer).

This script replaces SisServer>>handleEval: with a version that captures
Transcript output alongside the result, and installs two NeoJSON
extension methods (Object>>neoJsonOn: and Association>>neoJsonOn:) so
arbitrary return values serialize cleanly over HTTP.

Run via:
    `./pharo Pharo.image eval --save ""`
    or from Playground:  `FileStream fileIn: '/path/to/pharo/install.st'`
"

| sisServer scriptDir sisCoreDir compile |
sisServer := Smalltalk globals at: #SisServer ifAbsent: [
	Error signal: 'PharoSmalltalkInteropServer is not loaded in this image.' ].

scriptDir := (FileLocator imageDirectory asFileReference parent) fullName asFileReference.
"Resolve this script's directory relative to the repo checkout."
sisCoreDir := (FileLocator imageDirectory asFileReference
	/ '..' / 'pharo-smalltalk' / 'pharo' / 'Sis-Core') asFileReference.
sisCoreDir exists ifFalse: [
	"Fallback: ask user to set it manually."
	Transcript crShow: 'Adjust `sisCoreDir` at the top of install.st to point to pharo/Sis-Core/ in this repo.'.
	^ self ].

compile := [ :targetClass :category :source |
	targetClass compile: source classified: category.
	Transcript crShow: targetClass name , ' >> ', (source readStream upTo: Character space) ].

"1. handleEval: with Transcript capture"
compile
	value: sisServer
	value: 'private - actions'
	value: 'handleEval: request
	| resultDict requestJson code transcript beforeIndex |
	resultDict := Dictionary new.
	resultDict at: ''success'' put: false.
	requestJson := NeoJSONReader fromString: request entity contents.
	code := requestJson at: #code.
	transcript := Smalltalk globals at: #Transcript.
	beforeIndex := transcript instVarNamed: ''index''.
	[ resultDict at: ''result'' put: (self class compiler evaluate: code) ]
		on: Error
		do: [ :ex |
			resultDict at: ''transcript'' put: (self transcriptCapturedFrom: beforeIndex on: transcript).
			^ self returnError: ex by: resultDict ].
	resultDict at: ''transcript'' put: (self transcriptCapturedFrom: beforeIndex on: transcript).
	resultDict at: ''success'' put: true.
	^ resultDict'.

"2. transcriptCapturedFrom:on: helper"
compile
	value: sisServer
	value: 'private - actions'
	value: 'transcriptCapturedFrom: beforeIndex on: transcript
	| afterIndex recordings maxSize |
	afterIndex := transcript instVarNamed: ''index''.
	recordings := transcript instVarNamed: ''recordings''.
	maxSize := recordings size.
	afterIndex = beforeIndex ifTrue: [ ^ '''' ].
	^ String streamContents: [ :s |
		afterIndex > beforeIndex
			ifTrue: [
				beforeIndex + 1 to: afterIndex do: [ :i |
					(recordings at: i) ifNotNil: [ :e | s << e asString ] ] ]
			ifFalse: [
				beforeIndex + 1 to: maxSize do: [ :i |
					(recordings at: i) ifNotNil: [ :e | s << e asString ] ].
				1 to: afterIndex do: [ :i |
					(recordings at: i) ifNotNil: [ :e | s << e asString ] ] ] ]'.

"3. NeoJSON fallback for arbitrary objects"
compile
	value: Object
	value: '*Sis-Core'
	value: 'neoJsonOn: neoJSONWriter
	"Fallback: serialize arbitrary objects as their printString."
	neoJSONWriter writeString: self printString'.

"4. NeoJSON mapping for Association"
compile
	value: Association
	value: '*Sis-Core'
	value: 'neoJsonOn: neoJSONWriter
	"An Association serializes as a one-entry JSON object."
	neoJSONWriter writeMap: (Dictionary new
		at: self key asString put: self value;
		yourself)'.

Transcript crShow: 'Sis-Core patches installed. Restart the server with `SisServer restart`.'.
