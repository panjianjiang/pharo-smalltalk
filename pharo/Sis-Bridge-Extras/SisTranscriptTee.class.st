Class {
	#name : 'SisTranscriptTee',
	#superclass : 'Object',
	#instVars : [
		'original',
		'entries',
		'sequence',
		'capacity',
		'mutex'
	],
	#classInstVars : [
		'instance',
		'teapotsRouted'
	],
	#category : 'Sis-Bridge-Extras',
	#package : 'Sis-Bridge-Extras'
}

{ #category : 'routes' }
SisTranscriptTee class >> ensureRoutesOn: aSisServer [
	"Register /transcript/poll and /transcript/clear on the server's teapot
	idempotently: we remember the teapot instance, so restarting (which
	rebuilds the teapot) re-arms the routes while a re-invocation on the
	same teapot is a no-op."
	| teapot |
	teapot := aSisServer teapot.
	teapotsRouted := teapotsRouted ifNil: [ IdentitySet new ].
	(teapotsRouted includes: teapot) ifTrue: [ ^ self ].
	teapot
		GET: '/transcript/poll' -> [ :req | aSisServer handleTranscriptPoll: req ];
		POST: '/transcript/clear' -> [ :req | aSisServer handleTranscriptClear: req ].
	teapotsRouted add: teapot
]

{ #category : 'accessing' }
SisTranscriptTee class >> install [
	"Replace the Transcript global with the singleton tee. Returns the tee."
	| tee |
	tee := self instance.
	(Smalltalk globals at: #Transcript) == tee ifFalse: [
		Smalltalk globals at: #Transcript put: tee ].
	^ tee
]

{ #category : 'accessing' }
SisTranscriptTee class >> instance [
	^ instance ifNil: [ instance := self new ]
]

{ #category : 'accessing' }
SisTranscriptTee class >> reset [
	"Forget the singleton and the set of routed teapots (testing hook)."
	<script>
	instance ifNotNil: [ instance uninstall ].
	instance := nil.
	teapotsRouted := nil
]

{ #category : 'initialize-release' }
SisTranscriptTee >> initialize [
	super initialize.
	original := Smalltalk globals at: #Transcript ifAbsent: [ nil ].
	entries := OrderedCollection new.
	sequence := 0.
	capacity := 4096.
	mutex := Semaphore forMutualExclusion
]

{ #category : 'accessing' }
SisTranscriptTee >> capacity [
	^ capacity
]

{ #category : 'accessing' }
SisTranscriptTee >> capacity: anInteger [
	capacity := anInteger
]

{ #category : 'recording' }
SisTranscriptTee >> clear [
	mutex critical: [
		entries := OrderedCollection new.
		sequence := 0 ]
]

{ #category : 'accessing' }
SisTranscriptTee >> entries [
	^ mutex critical: [ entries asArray ]
]

{ #category : 'accessing' }
SisTranscriptTee >> original [
	^ original
]

{ #category : 'accessing' }
SisTranscriptTee >> sequence [
	^ sequence
]

{ #category : 'recording' }
SisTranscriptTee >> record: aStringOrObject [
	"Append aStringOrObject's string representation as a new entry and
	advance the sequence. Drops oldest entries when capacity is exceeded."
	| s |
	s := aStringOrObject isString
		ifTrue: [ aStringOrObject ]
		ifFalse: [ aStringOrObject asString ].
	s isEmpty ifTrue: [ ^ self ].
	mutex critical: [
		entries add: s.
		sequence := sequence + 1.
		[ entries size > capacity ] whileTrue: [ entries removeFirst ] ]
]

{ #category : 'querying' }
SisTranscriptTee >> snapshotSince: aSeq [
	"Return a dictionary {seq, text, dropped, entries} covering entries
	whose sequence is strictly greater than aSeq (or all entries when
	aSeq is earlier than what we still hold)."
	^ mutex critical: [
		| normalisedSince firstAvailableSeq slice dropped fromIndex |
		normalisedSince := (aSeq isNil or: [ aSeq < 0 ])
			ifTrue: [ 0 ]
			ifFalse: [ aSeq ].
		firstAvailableSeq := sequence - entries size + 1.
		(normalisedSince + 1) < firstAvailableSeq
			ifTrue: [
				dropped := firstAvailableSeq - (normalisedSince + 1).
				slice := entries asArray ]
			ifFalse: [
				dropped := 0.
				fromIndex := normalisedSince - firstAvailableSeq + 2.
				fromIndex < 1 ifTrue: [ fromIndex := 1 ].
				slice := fromIndex > entries size
					ifTrue: [ #() ]
					ifFalse: [ (entries copyFrom: fromIndex to: entries size) asArray ] ].
		Dictionary new
			at: 'seq' put: sequence;
			at: 'text' put: (self joinedTextFrom: slice);
			at: 'dropped' put: dropped;
			at: 'entries' put: slice;
			yourself ]
]

{ #category : 'querying' }
SisTranscriptTee >> textBetween: beforeSeq and: afterSeq [
	"Return a single joined string for entries added while sequence moved
	from beforeSeq (exclusive) to afterSeq (inclusive). Used for eval
	capture so a single call still returns one string of transcript."
	beforeSeq = afterSeq ifTrue: [ ^ '' ].
	^ mutex critical: [
		| firstAvailableSeq fromIndex toIndex slice |
		firstAvailableSeq := sequence - entries size + 1.
		fromIndex := ((beforeSeq + 1) - firstAvailableSeq + 1) max: 1.
		toIndex := (afterSeq - firstAvailableSeq + 1) min: entries size.
		fromIndex > toIndex ifTrue: [ '' ] ifFalse: [
			slice := entries copyFrom: fromIndex to: toIndex.
			self joinedTextFrom: slice ] ]
]

{ #category : 'private' }
SisTranscriptTee >> joinedTextFrom: aCollection [
	^ String streamContents: [ :s |
		aCollection do: [ :entry | s nextPutAll: entry asString ] ]
]

{ #category : 'lifecycle' }
SisTranscriptTee >> uninstall [
	"Restore the Transcript global to the saved original, if any."
	(original notNil and: [ (Smalltalk globals at: #Transcript) == self ])
		ifTrue: [ Smalltalk globals at: #Transcript put: original ]
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> show: aString [
	self record: aString.
	^ original show: aString
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> cr [
	self record: String cr asString.
	^ original cr
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> nl [
	self record: String lf asString.
	^ original nl
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> crShow: aString [
	self record: String cr asString , aString.
	^ original crShow: aString
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> space [
	self record: ' '.
	^ original space
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> tab [
	self record: String tab asString.
	^ original tab
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> nextPutAll: aString [
	self record: aString.
	^ original nextPutAll: aString
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> nextPut: aCharacter [
	self record: aCharacter asString.
	^ original nextPut: aCharacter
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> << anObject [
	| s |
	s := anObject isString ifTrue: [ anObject ] ifFalse: [ anObject asString ].
	self record: s.
	^ original nextPutAll: s
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> flush [
	^ original flush
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> endEntry [
	^ original endEntry
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> print: anObject [
	^ self show: anObject printString
]

{ #category : 'printing' }
SisTranscriptTee >> printString [
	^ 'a SisTranscriptTee (wraps ', original printString, ')'
]

{ #category : 'Transcript protocol' }
SisTranscriptTee >> doesNotUnderstand: aMessage [
	"Forward anything we didn't explicitly wrap to the original."
	^ original perform: aMessage selector withArguments: aMessage arguments
]

{ #category : 'testing' }
SisTranscriptTee >> isTranscript [
	^ true
]

{ #category : 'serialization' }
SisTranscriptTee >> neoJsonOn: neoJSONWriter [
	"Preserve the pre-tee JSON contract: serialize as the wrapped
	original's printString. Callers still observing Transcript via
	/eval don't need to know the tee exists."
	neoJSONWriter writeString: original printString
]
