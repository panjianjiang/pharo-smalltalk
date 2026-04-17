Extension { #name : 'SisServer' }

{ #category : '*Sis-Bridge-Extras' }
SisServer >> handleEval: request [
	"Override of upstream Sis-Core handleEval: that also captures
	Transcript output produced during evaluation. Returns the dict
	with `result', `transcript', `success' (and `error' on failure)."
	| resultDict requestJson code transcript beforeIndex |
	resultDict := Dictionary new.
	resultDict at: 'success' put: false.
	requestJson := NeoJSONReader fromString: request entity contents.
	code := requestJson at: #code.
	transcript := Smalltalk globals at: #Transcript.
	beforeIndex := transcript instVarNamed: 'index'.
	[ resultDict at: 'result' put: (self class compiler evaluate: code) ]
		on: Error
		do: [ :ex |
			resultDict
				at: 'transcript'
				put: (self transcriptCapturedFrom: beforeIndex on: transcript).
			^ self returnError: ex by: resultDict ].
	resultDict
		at: 'transcript'
		put: (self transcriptCapturedFrom: beforeIndex on: transcript).
	resultDict at: 'success' put: true.
	^ resultDict
]

{ #category : '*Sis-Bridge-Extras' }
SisServer >> transcriptCapturedFrom: beforeIndex on: transcript [
	"Slice the StThreadSafeTranscript ring buffer between beforeIndex
	(snapshot taken before evaluation) and its current write index."
	| afterIndex recordings maxSize |
	afterIndex := transcript instVarNamed: 'index'.
	recordings := transcript instVarNamed: 'recordings'.
	maxSize := recordings size.
	afterIndex = beforeIndex ifTrue: [ ^ '' ].
	^ String streamContents: [ :s |
		afterIndex > beforeIndex
			ifTrue: [
				beforeIndex + 1 to: afterIndex do: [ :i |
					(recordings at: i) ifNotNil: [ :e | s << e asString ] ] ]
			ifFalse: [
				beforeIndex + 1 to: maxSize do: [ :i |
					(recordings at: i) ifNotNil: [ :e | s << e asString ] ].
				1 to: afterIndex do: [ :i |
					(recordings at: i) ifNotNil: [ :e | s << e asString ] ] ] ]
]
