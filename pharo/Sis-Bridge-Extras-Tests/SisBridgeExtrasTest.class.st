Class {
	#name : 'SisBridgeExtrasTest',
	#superclass : 'TestCase',
	#category : 'Sis-Bridge-Extras-Tests',
	#package : 'Sis-Bridge-Extras-Tests'
}

{ #category : 'private' }
SisBridgeExtrasTest >> evalResponseForCode: aString [
	^ self evalResponseForCode: aString params: nil
]

{ #category : 'private' }
SisBridgeExtrasTest >> evalResponseForCode: aString params: aDictionary [
	| request |
	request := SisBridgeExtrasTestRequest
		withJson:
			(NeoJSONWriter toString:
				(Dictionary new
					at: #code put: aString;
					yourself))
		params: (aDictionary ifNil: [ Dictionary new ]).
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
SisBridgeExtrasTest >> testEvalWithoutInspectHasNoResultTree [
	| resp |
	resp := self evalResponseForCode: 'OrderedCollection new add: 10; yourself'.
	self assert: (resp at: #success).
	self deny: (resp includesKey: #result_tree)
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testEvalWithInspectAttachesResultTree [
	| resp tree |
	resp := self
		evalResponseForCode: 'OrderedCollection new add: 10; yourself'
		params: (Dictionary new at: #inspect put: 'true'; yourself).
	self assert: (resp at: #success).
	tree := resp at: #result_tree.
	self assert: (tree at: #class) equals: 'OrderedCollection'.
	self assert: (tree at: #size) equals: 1.
	self assert: (tree at: #ref) isInteger
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testEvalWithInspectFalseHasNoResultTree [
	| resp |
	resp := self
		evalResponseForCode: '42'
		params: (Dictionary new at: #inspect put: 'false'; yourself).
	self assert: (resp at: #success).
	self deny: (resp includesKey: #result_tree)
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testTranscriptSerializesAsPrintString [
	self
		assert: (NeoJSONWriter toString: Transcript)
		equals: '"a StThreadSafeTranscript"'
]
