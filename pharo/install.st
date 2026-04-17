"Install the Sis-Bridge-Extras patches shipped with pharo-smalltalk.

Assumes PharoSmalltalkInteropServer is already loaded in the image
(e.g. via Metacello from https://github.com/mumez/PharoSmalltalkInteropServer).

This script replaces SisServer>>handleEval: with a version that captures
Transcript output alongside the result, and installs two targeted NeoJSON
extension methods:
  - StThreadSafeTranscript>>neoJsonOn:
  - Association>>neoJsonOn:

Run from a Playground:
    Smalltalk compiler evaluate:
        '/path/to/pharo-smalltalk/pharo/install.st' asFileReference contents
"

| sisServer transcriptClass compile |
sisServer := Smalltalk globals at: #SisServer ifAbsent: [
	Error signal: 'PharoSmalltalkInteropServer is not loaded in this image.' ].
transcriptClass := Smalltalk globals
	at: #StThreadSafeTranscript
	ifAbsent: [ (Smalltalk globals at: #Transcript) class ].

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

"3. NeoJSON mapping for the Transcript singleton"
compile
	value: transcriptClass
	value: '*Sis-Bridge-Extras'
	value: 'neoJsonOn: neoJSONWriter
	"Match the Playground/UI convention for the Transcript singleton."
	neoJSONWriter writeString: self printString'.

"4. NeoJSON mapping for Association"
compile
	value: Association
	value: '*Sis-Bridge-Extras'
	value: 'neoJsonOn: neoJSONWriter
	"An Association serializes as a one-entry JSON object."
	neoJSONWriter writeMap: (Dictionary new
		at: self key asString put: self value;
		yourself)'.

Transcript crShow: 'Sis-Bridge-Extras patches installed. Restart the server with `SisServer restart`.'. 
