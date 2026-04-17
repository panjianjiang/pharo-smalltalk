Class {
	#name : 'SisBridgeExtrasTest',
	#superclass : 'TestCase',
	#category : 'Sis-Bridge-Extras-Tests',
	#package : 'Sis-Bridge-Extras-Tests'
}

{ #category : 'private' }
SisBridgeExtrasTest >> baseUrl [
	| port |
	port := SisServer current teapotConfig at: #port ifAbsent: [ 8086 ].
	^ ('http://localhost:{1}' format: { port }) asUrl
]

{ #category : 'private' }
SisBridgeExtrasTest >> ensureServerRunning [
	(SisServer current teapot isRunning) ifFalse: [ SisServer current start ]
]

{ #category : 'private' }
SisBridgeExtrasTest >> post: anUrl dictionary: dict [
	| json resp |
	json := NeoJSONWriter toString: dict.
	resp := ZnEasy post: anUrl data: (ZnEntity json: json).
	^ NeoJSONReader fromString: resp contents
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testAssociationSerializesAsOneEntryMap [
	self
		assert: (NeoJSONWriter toString: ('foo' -> 1))
		equals: '{"foo":1}'
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testEvalReturnsTranscriptPayload [
	| url resp |
	self ensureServerRunning.
	url := self baseUrl / 'eval'.
	resp := self
		post: url
		dictionary: { ('code' -> 'Transcript show: ''bridge''; cr. 1 + 2') }
				asDictionary.
	self assert: (resp at: #success).
	self assert: (resp at: #result) equals: 3.
	self assert: ((resp at: #transcript) includesSubstring: 'bridge')
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testTranscriptSerializesAsPrintString [
	| json |
	json := NeoJSONWriter toString: Transcript.
	self assert: (json includesSubstring: 'StThreadSafeTranscript')
]
