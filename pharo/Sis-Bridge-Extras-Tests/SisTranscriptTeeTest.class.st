Class {
	#name : 'SisTranscriptTeeTest',
	#superclass : 'TestCase',
	#instVars : [
		'tee'
	],
	#category : 'Sis-Bridge-Extras-Tests',
	#package : 'Sis-Bridge-Extras-Tests'
}

{ #category : 'running' }
SisTranscriptTeeTest >> setUp [
	"Build a fresh tee that wraps a throwaway stream so we can assert on
	what was recorded without touching the real Transcript."
	super setUp.
	tee := SisTranscriptTee new.
	tee clear
]

{ #category : 'tests' }
SisTranscriptTeeTest >> testClearResetsSequenceAndEntries [
	tee record: 'a'. tee record: 'b'.
	tee clear.
	self assert: tee sequence equals: 0.
	self assert: tee entries isEmpty
]

{ #category : 'tests' }
SisTranscriptTeeTest >> testCapacityEvictsOldestEntries [
	tee capacity: 3.
	#('a' 'b' 'c' 'd' 'e') do: [ :s | tee record: s ].
	self assert: tee entries equals: #('c' 'd' 'e').
	self assert: tee sequence equals: 5
]

{ #category : 'tests' }
SisTranscriptTeeTest >> testSnapshotSinceReturnsEntriesAfterCursor [
	| snap |
	tee record: 'one'. tee record: 'two'. tee record: 'three'.
	snap := tee snapshotSince: 1.
	self assert: (snap at: 'seq') equals: 3.
	self assert: (snap at: 'text') equals: 'twothree'.
	self assert: (snap at: 'dropped') equals: 0.
	self assert: (snap at: 'entries') equals: #('two' 'three')
]

{ #category : 'tests' }
SisTranscriptTeeTest >> testSnapshotSinceZeroReturnsAll [
	| snap |
	tee record: 'x'. tee record: 'y'.
	snap := tee snapshotSince: 0.
	self assert: (snap at: 'text') equals: 'xy'.
	self assert: (snap at: 'dropped') equals: 0
]

{ #category : 'tests' }
SisTranscriptTeeTest >> testSnapshotReportsDroppedEntriesPastCapacity [
	| snap |
	tee capacity: 2.
	#('a' 'b' 'c' 'd') do: [ :s | tee record: s ].
	snap := tee snapshotSince: 0.
	self assert: (snap at: 'dropped') equals: 2.
	self assert: (snap at: 'entries') equals: #('c' 'd').
	self assert: (snap at: 'seq') equals: 4
]

{ #category : 'tests' }
SisTranscriptTeeTest >> testTextBetweenSlicesEvalWindow [
	| before after |
	tee record: 'pre'.
	before := tee sequence.
	tee record: 'mid1'. tee record: 'mid2'.
	after := tee sequence.
	tee record: 'post'.
	self
		assert: (tee textBetween: before and: after)
		equals: 'mid1mid2'
]

{ #category : 'tests' }
SisTranscriptTeeTest >> testShowRecordsAndForwardsToOriginal [
	| captured stub t |
	captured := WriteStream on: String new.
	stub := SisTranscriptTeeStreamStub on: captured.
	t := SisTranscriptTee new.
	t instVarNamed: 'original' put: stub.
	t show: 'hi'.
	self assert: t sequence equals: 1.
	self assert: t entries first equals: 'hi'.
	self assert: captured contents equals: 'hi'
]

{ #category : 'tests' }
SisTranscriptTeeTest >> testPrintSerializesAsWrappedOriginal [
	"neoJsonOn: must delegate to the original so callers that serialise
	Transcript don't see the tee leak out."
	| t |
	t := SisTranscriptTee new.
	t instVarNamed: 'original' put: 'fake-transcript'.
	self
		assert: (NeoJSONWriter toString: t)
		equals: '"''fake-transcript''"'
]
