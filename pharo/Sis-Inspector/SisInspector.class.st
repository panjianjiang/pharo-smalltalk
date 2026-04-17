Class {
	#name : 'SisInspector',
	#superclass : 'Object',
	#classInstVars : [
		'refs',
		'nextId'
	],
	#category : 'Sis-Inspector',
	#package : 'Sis-Inspector'
}

{ #category : 'accessing' }
SisInspector class >> childLimit [
	"Maximum number of inst vars or indexable entries to include in a tree."
	^ 200
]

{ #category : 'refs' }
SisInspector class >> clearRefs [
	"Empty the drill-down registry. Callers should invoke this when the
	Emacs-side inspector session ends, to avoid holding references."
	<script>
	refs := IdentityDictionary new.
	nextId := 0
]

{ #category : 'refs' }
SisInspector class >> ensureRegistry [
	refs ifNil: [ refs := IdentityDictionary new ].
	nextId ifNil: [ nextId := 0 ].
	^ refs
]

{ #category : 'refs' }
SisInspector class >> evictOldestIfFull [
	| max |
	max := self refLimit.
	self ensureRegistry size <= max ifTrue: [ ^ self ].
	"Evict the entry with the smallest id (oldest)."
	refs removeKey: (refs keys detectMin: [ :k | refs at: k ])
]

{ #category : 'inspecting' }
SisInspector class >> inspectExpression: aString [
	"Evaluate aString and return the inspection tree of the result.
	The tree's top-level ref is a fresh integer stored in the registry."
	| value |
	value := self class compiler evaluate: aString.
	^ self renderTreeOf: value
]

{ #category : 'inspecting' }
SisInspector class >> inspectRef: anInteger [
	"Return the inspection tree of the object previously stored under
	ref anInteger. Raises if the id is unknown."
	| object |
	object := self ensureRegistry
		at: anInteger
		ifAbsent: [
			Error signal: 'No object registered under ref ', anInteger printString ].
	^ self renderTreeOf: object
]

{ #category : 'refs' }
SisInspector class >> refLimit [
	"Soft cap on the registry size; oldest entries evicted on overflow."
	^ 1024
]

{ #category : 'refs' }
SisInspector class >> registerObject: anObject [
	"Store anObject in the registry and answer a freshly minted ref id."
	| id |
	self ensureRegistry.
	id := nextId := nextId + 1.
	refs at: id put: anObject.
	self evictOldestIfFull.
	^ id
]

{ #category : 'rendering' }
SisInspector class >> renderChildOfNameLike: aStringOrNil value: aValue [
	"Build a dictionary row for a child cell of an object."
	| row id |
	row := Dictionary new.
	aStringOrNil ifNotNil: [ row at: 'name' put: aStringOrNil asString ].
	id := self registerObject: aValue.
	row at: 'ref' put: id.
	row at: 'class' put: aValue class name asString.
	row at: 'print' put: (self safePrintStringOf: aValue).
	row at: 'has_children' put: (self hasDrillableChildren: aValue).
	^ row
]

{ #category : 'rendering' }
SisInspector class >> hasDrillableChildren: anObject [
	"Return true when anObject has inst vars or is indexable with content."
	(anObject class allInstVarNames isNotEmpty) ifTrue: [ ^ true ].
	(self sequenceSampleOf: anObject) ifNotNil: [ :seq |
		seq isEmpty ifFalse: [ ^ true ] ].
	^ false
]

{ #category : 'rendering' }
SisInspector class >> instVarRowsOf: anObject [
	"Build rows for named instance variables of anObject, up to childLimit."
	| names rows |
	names := anObject class allInstVarNames.
	rows := OrderedCollection new.
	names doWithIndex: [ :name :i |
		i > self childLimit ifTrue: [ ^ rows asArray ].
		rows add: (self renderChildOfNameLike: name value: (anObject instVarNamed: name)) ].
	^ rows asArray
]

{ #category : 'rendering' }
SisInspector class >> renderTreeOf: anObject [
	"Return a Dictionary describing anObject — its class, print string, and
	either named instance variables or indexable contents (truncated)."
	| root rootId rootSequence |
	rootId := self registerObject: anObject.
	root := Dictionary new.
	root at: 'ref' put: rootId.
	root at: 'class' put: anObject class name asString.
	root at: 'print' put: (self safePrintStringOf: anObject).
	root at: 'identity_hash' put: anObject identityHash.
	root at: 'inst_vars' put: (self instVarRowsOf: anObject).
	rootSequence := self sequenceSampleOf: anObject.
	rootSequence ifNotNil: [
		| indexRows |
		indexRows := OrderedCollection new.
		rootSequence
			withIndexDo: [ :value :i |
				i > self childLimit ifTrue: [ ^ self finalizeRoot: root indexables: indexRows asArray ].
				indexRows add: (self renderChildOfNameLike: i printString value: value) ].
		root at: 'indexable' put: indexRows asArray.
		root at: 'size' put: rootSequence size ].
	^ root
]

{ #category : 'rendering' }
SisInspector class >> finalizeRoot: root indexables: anArray [
	root at: 'indexable' put: anArray.
	^ root
]

{ #category : 'rendering' }
SisInspector class >> safePrintStringOf: anObject [
	"Bounded printString — at most 256 characters, errors caught."
	| limit s |
	limit := 256.
	^ [
		s := anObject printString.
		s size > limit ifTrue: [ s := (s first: limit) , '…' ].
		s ]
		on: Error
		do: [ :ex | '<print error: ', ex description, '>' ]
]

{ #category : 'rendering' }
SisInspector class >> sequenceSampleOf: anObject [
	"Return an iterable view if anObject is reasonably sequenceable,
	otherwise nil. Avoids expanding huge dictionaries / classes."
	(anObject isKindOf: SequenceableCollection) ifTrue: [ ^ anObject ].
	(anObject isKindOf: HashedCollection) ifTrue: [
		"For Set / Dictionary, use associations ordered by iteration."
		^ anObject associations ].
	anObject class isVariable ifTrue: [
		| size |
		size := anObject basicSize.
		size = 0 ifTrue: [ ^ nil ].
		^ (1 to: size) collect: [ :i | anObject basicAt: i ] ].
	^ nil
]
