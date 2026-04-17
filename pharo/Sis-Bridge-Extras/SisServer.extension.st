Extension { #name : 'SisServer' }

{ #category : '*Sis-Bridge-Extras' }
SisServer >> handleEval: request [
	"Override of upstream Sis-Core handleEval: that also captures
	Transcript output produced during evaluation. Returns the dict
	with `result', `transcript', `success' (and `error' on failure)."
	| resultDict requestJson code transcript error |
	resultDict := Dictionary new.
	resultDict at: 'success' put: false.
	requestJson := NeoJSONReader fromString: request entity contents.
	code := requestJson at: #code.
	error := nil.
	transcript := self transcriptCapturedDuring: [
		[ resultDict at: 'result' put: (self class compiler evaluate: code) ]
			on: Error
			do: [ :ex | error := ex ] ].
	resultDict at: 'transcript' put: transcript.
	error ifNotNil: [ ^ self returnError: error by: resultDict ].
	resultDict at: 'success' put: true.
	^ resultDict
]

{ #category : '*Sis-Bridge-Extras' }
SisServer >> returnError: anError by: resultDict [
	| errorInfo signalerContext |
	errorInfo := Dictionary new.
	errorInfo at: 'description' put: anError description.
	signalerContext := anError signalerContext.
	errorInfo
		at: 'stack_trace'
		put:
			(signalerContext
				ifNil: [ '' ]
				ifNotNil: [
					String streamContents: [ :strm |
						signalerContext debugStack: self stackSize on: strm ] ]).
	errorInfo
		at: 'receiver'
		put:
			(signalerContext
				ifNil: [
					Dictionary new
						at: 'class' put: anError class name;
						at: 'self' put: anError printString;
						yourself ]
				ifNotNil: [ self receiverErrorInfoFrom: signalerContext receiver ]).
	resultDict at: 'error' put: errorInfo.
	^ resultDict
]

{ #category : '*Sis-Bridge-Extras' }
SisServer >> transcriptCapturedDuring: aBlock [
	"Evaluate aBlock with a dedicated Transcript instance and answer
	the captured text without depending on Transcript internals."
	| originalTranscript transcriptClass capturedTranscript |
	originalTranscript := Smalltalk globals at: #Transcript.
	transcriptClass := Smalltalk globals
		at: #StThreadSafeTranscript
		ifAbsent: [ originalTranscript class ].
	capturedTranscript := (transcriptClass respondsTo: #createTestingInstance)
		ifTrue: [ transcriptClass createTestingInstance ]
		ifFalse: [ transcriptClass basicNew initialize; yourself ].
	[
		Smalltalk globals at: #Transcript put: capturedTranscript.
		aBlock value ]
		ensure: [ Smalltalk globals at: #Transcript put: originalTranscript ].
	^ capturedTranscript contents
]
