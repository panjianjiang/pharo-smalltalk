Class {
	#name : 'SisBridgeExtrasTest',
	#superclass : 'TestCase',
	#category : 'Sis-Bridge-Extras-Tests',
	#package : 'Sis-Bridge-Extras-Tests'
}

{ #category : 'private' }
SisBridgeExtrasTest >> evalResponseForCode: aString [
	| request |
	request := SisBridgeExtrasTestRequest
		withJson:
			(NeoJSONWriter toString:
				(Dictionary new
					at: #code put: aString;
					yourself)).
	^ SisServer current handleEval: request
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testAssociationSerializesAsOneEntryMap [
	self
		assert: (NeoJSONWriter toString: ('foo' -> 1))
		equals: '{"foo":1}'
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testEvalReturnsTranscriptPayload [
	| resp |
	resp := self evalResponseForCode: 'Transcript show: ''bridge''; cr. 1 + 2'.
	self assert: (resp at: #success).
	self assert: (resp at: #result) equals: 3.
	self assert: ((resp at: #transcript) includesSubstring: 'bridge')
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testEvalReturnsTranscriptPayloadOnFailure [
	| resp |
	resp := self
		evalResponseForCode: 'Transcript show: ''boom''; cr. Error signal: ''kapow'''.
	self deny: (resp at: #success).
	self assert: ((resp at: #transcript) includesSubstring: 'boom')
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testTranscriptSerializesAsPrintString [
	self
		assert: (NeoJSONWriter toString: Transcript)
		equals: '"a StThreadSafeTranscript"'
]
