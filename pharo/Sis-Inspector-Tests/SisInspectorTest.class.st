Class {
	#name : 'SisInspectorTest',
	#superclass : 'TestCase',
	#category : 'Sis-Inspector-Tests',
	#package : 'Sis-Inspector-Tests'
}

{ #category : 'running' }
SisInspectorTest >> setUp [
	super setUp.
	SisInspector clearRefs
]

{ #category : 'tests' }
SisInspectorTest >> testExpressionRootCarriesClassAndPrint [
	| tree |
	tree := SisInspector inspectExpression: 'OrderedCollection new add: 10; add: 20; yourself'.
	self assert: (tree at: 'class') equals: 'OrderedCollection'.
	self assert: (tree at: 'size') equals: 2.
	self assert: ((tree at: 'print') includesSubstring: '10').
	self assert: ((tree at: 'print') includesSubstring: '20').
	self assert: (tree includesKey: 'inst_vars').
	self assert: (tree includesKey: 'indexable')
]

{ #category : 'tests' }
SisInspectorTest >> testIndexableRowsCarryRefs [
	| tree indexable |
	tree := SisInspector inspectExpression: '#(42 84) asOrderedCollection'.
	indexable := tree at: 'indexable'.
	self assert: indexable size equals: 2.
	self assert: ((indexable first at: 'class')) equals: 'SmallInteger'.
	self assert: ((indexable first at: 'print')) equals: '42'.
	self assert: ((indexable first at: 'ref')) isInteger
]

{ #category : 'tests' }
SisInspectorTest >> testInstVarRowsForCompositeObject [
	| tree instVars firstIndexRow |
	tree := SisInspector inspectExpression: 'OrderedCollection new'.
	instVars := tree at: 'inst_vars'.
	self assert: instVars isArray.
	self deny: instVars isEmpty.
	firstIndexRow := instVars detect: [ :r | (r at: 'name') = 'firstIndex' ] ifNone: [ nil ].
	self deny: firstIndexRow isNil.
	self assert: (firstIndexRow at: 'class') equals: 'SmallInteger'
]

{ #category : 'tests' }
SisInspectorTest >> testRefRoundTrip [
	| tree indexable childRef drill |
	tree := SisInspector inspectExpression: '#(7) asOrderedCollection'.
	indexable := tree at: 'indexable'.
	childRef := indexable first at: 'ref'.
	drill := SisInspector inspectRef: childRef.
	self assert: (drill at: 'class') equals: 'SmallInteger'.
	self assert: (drill at: 'print') equals: '7'
]

{ #category : 'tests' }
SisInspectorTest >> testUnknownRefRaises [
	self should: [ SisInspector inspectRef: 999999 ] raise: Error
]

{ #category : 'tests' }
SisInspectorTest >> testChildLimitTruncatesHugeSequences [
	| tree indexable limit |
	limit := SisInspector childLimit.
	tree := SisInspector inspectExpression: '(1 to: ', (limit + 10) printString, ') asOrderedCollection'.
	indexable := tree at: 'indexable'.
	self assert: indexable size <= limit
]

{ #category : 'tests' }
SisInspectorTest >> testPrintStringBounded [
	| tree |
	tree := SisInspector inspectExpression: 'String new: 4096 withAll: $x'.
	self assert: (tree at: 'print') size <= 260
]
