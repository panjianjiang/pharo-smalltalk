Extension { #name : 'SisServer' }

{ #category : '*Sis-Bridge-Extras' }
SisServer >> handleEval: request [
	"Override of upstream Sis-Core handleEval: that also captures
	Transcript output produced during evaluation and optionally
	attaches a SisInspector tree for the result. Returns the dict
	with `result', `transcript', `success' (and `error' on failure).
	When the `inspect' query param is truthy, `result_tree' is added
	so callers can drill into the result without re-evaluating."
	| resultDict requestJson code transcript error inspect |
	resultDict := Dictionary new.
	resultDict at: 'success' put: false.
	requestJson := NeoJSONReader fromString: request entity contents.
	code := requestJson at: #code.
	inspect := self inspectFlagFromRequest: request.
	error := nil.
	transcript := self transcriptCapturedDuring: [
		[ resultDict at: 'result' put: (self class compiler evaluate: code) ]
			on: Error
			do: [ :ex | error := ex ] ].
	resultDict at: 'transcript' put: transcript.
	error ifNotNil: [ ^ self returnError: error by: resultDict ].
	inspect ifTrue: [
		| value |
		value := resultDict at: 'result' ifAbsent: [ nil ].
		((Smalltalk globals includesKey: #SisInspector) and: [ value notNil ])
			ifTrue: [
				resultDict at: 'result_tree' put: (SisInspector renderTreeOf: value) ] ].
	resultDict at: 'success' put: true.
	^ resultDict
]

{ #category : '*Sis-Bridge-Extras' }
SisServer >> inspectFlagFromRequest: request [
	"Read the optional `inspect' query param; default false."
	| raw |
	raw := request at: #inspect ifAbsent: [ 'false' ].
	^ raw asString asLowercase = 'true'
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
	"Slice the always-on SisTranscriptTee for the sequence range aBlock
	advances it through. Keeps eval captures behaving like before, but
	also lets /transcript/poll continue to see the same output because
	the tee is a single source of truth."
	| tee beforeSeq |
	tee := SisTranscriptTee install.
	beforeSeq := tee sequence.
	aBlock value.
	^ tee textBetween: beforeSeq and: tee sequence
]

{ #category : '*Sis-Bridge-Extras' }
SisServer >> handleTranscriptPoll: request [
	^ self returnResultDo: [
		| since |
		since := (request at: #since ifAbsent: [ '0' ]) asNumber truncated.
		SisTranscriptTee install snapshotSince: since ]
]

{ #category : '*Sis-Bridge-Extras' }
SisServer >> handleTranscriptClear: request [
	^ self returnResultDo: [
		SisTranscriptTee install clear.
		Dictionary new at: 'seq' put: 0; yourself ]
]

{ #category : '*Sis-Bridge-Extras' }
SisServer >> start [
	"Ensure the transcript tee is installed and our extra routes are
	registered on the current teapot, then hand off to Teapot's start."
	SisTranscriptTee install.
	SisTranscriptTee ensureRoutesOn: self.
	self teapot start
]
