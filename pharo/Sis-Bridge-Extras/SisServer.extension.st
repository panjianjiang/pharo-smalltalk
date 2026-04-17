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
	SisTranscriptTee ensureExtraRoutesOn: self.
	self teapot start
]

{ #category : '*Sis-Bridge-Extras' }
SisServer >> handleCompileMethod: request [
	"Compile a single method on a named class.  Body JSON keys:
		class_name       (required, String)
		method_source    (required, String — the full Smalltalk source)
		category         (optional, String, defaults to 'as yet unclassified')
		is_class_method  (optional, Boolean or 'true'/'false')
	Returns {selector, class_name, is_class_method, category}."
	^ self returnResultDo: [
		| json className isClassSide source category target selector |
		json := NeoJSONReader fromString: request entity contents.
		className := json at: #class_name.
		source := json at: #method_source.
		category := json at: #category ifAbsent: [ 'as yet unclassified' ].
		isClassSide := self coerceBoolean: (json at: #is_class_method ifAbsent: [ false ]).
		target := Smalltalk globals at: className asSymbol.
		isClassSide ifTrue: [ target := target class ].
		selector := target compile: source classified: category.
		Dictionary new
			at: 'selector' put: selector asString;
			at: 'class_name' put: className;
			at: 'is_class_method' put: isClassSide;
			at: 'category' put: category;
			yourself ]
]

{ #category : '*Sis-Bridge-Extras' }
SisServer >> handleCompileClass: request [
	"Create or update a class via ShiftClassBuilder.  Body JSON keys:
		class_name       (required, String)
		superclass       (optional, String, defaults to 'Object')
		package          (required, String)
		tag              (optional, String)
		inst_vars        (optional, Array of String)
		class_vars       (optional, Array of String)
		class_inst_vars  (optional, Array of String)
	Returns {class_name, created: true|false}."
	^ self returnResultDo: [
		| json className superclassName package tag instVars classVars
		  classInstVars existing builder superclass cls |
		json := NeoJSONReader fromString: request entity contents.
		className := json at: #class_name.
		superclassName := (json at: #superclass ifAbsent: [ 'Object' ]) asString.
		package := json at: #package.
		tag := json at: #tag ifAbsent: [ nil ].
		instVars := (json at: #inst_vars ifAbsent: [ #() ]) asArray.
		classVars := (json at: #class_vars ifAbsent: [ #() ]) asArray.
		classInstVars := (json at: #class_inst_vars ifAbsent: [ #() ]) asArray.
		existing := Smalltalk globals at: className asSymbol ifAbsent: [ nil ].
		superclass := Smalltalk globals at: superclassName asSymbol ifAbsent: [ Object ].
		builder := ShiftClassBuilder new.
		existing
			ifNil: [ builder name: className asSymbol ]
			ifNotNil: [ builder fillFor: existing ].
		builder superclass: superclass.
		builder slotsFromString: (self joinTokens: instVars).
		builder sharedVariables: (self joinTokens: classVars) asClassVariableCollection.
		builder classSlots: (self joinTokens: classInstVars) asSlotCollection.
		builder package: package asSymbol.
		tag ifNotNil: [ builder tag: tag asSymbol ].
		cls := builder install.
		Dictionary new
			at: 'class_name' put: cls name asString;
			at: 'created' put: existing isNil;
			yourself ]
]

{ #category : '*Sis-Bridge-Extras' }
SisServer >> coerceBoolean: aValue [
	"Accept booleans as JSON true/false, or 'true'/'false'/'1'/'0'/1/0."
	aValue = true ifTrue: [ ^ true ].
	aValue = false ifTrue: [ ^ false ].
	aValue isString ifTrue: [
		| normalised |
		normalised := aValue asString asLowercase trimBoth.
		(#('true' '1' 'yes') includes: normalised) ifTrue: [ ^ true ].
		(#('false' '0' 'no' '') includes: normalised) ifTrue: [ ^ false ] ].
	aValue isNumber ifTrue: [ ^ aValue ~= 0 ].
	^ false
]

{ #category : '*Sis-Bridge-Extras' }
SisServer >> joinTokens: aCollection [
	"Return aCollection's elements joined by single spaces, skipping
	falsy / empty entries. Matches `ShiftClassBuilder slotsFromString:'
	expectations for empty slots."
	^ String streamContents: [ :s |
		| first |
		first := true.
		aCollection do: [ :each |
			| token |
			token := each ifNil: [ '' ] ifNotNil: [ each asString trimBoth ].
			token isEmpty ifFalse: [
				first ifFalse: [ s nextPut: Character space ].
				s nextPutAll: token.
				first := false ] ] ]
]
