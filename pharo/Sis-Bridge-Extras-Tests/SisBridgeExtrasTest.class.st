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

{ #category : 'private' }
SisBridgeExtrasTest >> compileMethodResponseFor: aDictionary [
	^ SisServer current
		handleCompileMethod:
			(SisBridgeExtrasTestRequest withJson: (NeoJSONWriter toString: aDictionary))
]

{ #category : 'private' }
SisBridgeExtrasTest >> compileClassResponseFor: aDictionary [
	^ SisServer current
		handleCompileClass:
			(SisBridgeExtrasTestRequest withJson: (NeoJSONWriter toString: aDictionary))
]

{ #category : 'private' }
SisBridgeExtrasTest >> ensureDemoClassAbsent [
	(Smalltalk globals at: #SisCompileApiDemo ifAbsent: [ nil ])
		ifNotNil: [ :cls | cls removeFromSystem ].
	(PackageOrganizer default
		packageNamed: 'Sis-Compile-Api-Demo'
		ifAbsent: [ nil ])
		ifNotNil: [ :pkg | pkg removeFromSystem ]
]

{ #category : 'private' }
SisBridgeExtrasTest >> removeMethodResponseFor: aDictionary [
	^ SisServer current
		handleRemoveMethod:
			(SisBridgeExtrasTestRequest withJson: (NeoJSONWriter toString: aDictionary))
]

{ #category : 'private' }
SisBridgeExtrasTest >> removeClassResponseFor: aDictionary [
	^ SisServer current
		handleRemoveClass:
			(SisBridgeExtrasTestRequest withJson: (NeoJSONWriter toString: aDictionary))
]

{ #category : 'private' }
SisBridgeExtrasTest >> transcriptPollResponseSince: anInteger [
	^ SisServer current
		handleTranscriptPoll:
			(SisBridgeExtrasTestRequest
				withJson: '{}'
				params: (Dictionary new
					at: #since put: anInteger asString;
					yourself))
]

{ #category : 'private' }
SisBridgeExtrasTest >> transcriptClearResponse [
	^ SisServer current
		handleTranscriptClear: (SisBridgeExtrasTestRequest withJson: '{}')
]

{ #category : 'private' }
SisBridgeExtrasTest >> inspectExpressionResponseFor: aString [
	^ SisServer current
		handleInspectExpression:
			(SisBridgeExtrasTestRequest withJson:
				(NeoJSONWriter toString:
					(Dictionary new
						at: #expression put: aString;
						yourself)))
]

{ #category : 'private' }
SisBridgeExtrasTest >> inspectRefResponseFor: anInteger [
	^ SisServer current
		handleInspectRef:
			(SisBridgeExtrasTestRequest
				withJson: '{}'
				params: (Dictionary new
					at: #ref put: anInteger asString;
					yourself))
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
SisBridgeExtrasTest >> testTranscriptPollReturnsEntriesFromEval [
	| cleared resp poll |
	cleared := self transcriptClearResponse.
	self assert: ((cleared at: #result) at: 'seq') equals: 0.
	resp := self evalResponseForCode: 'Transcript show: ''poll''; cr. 1 + 2'.
	self assert: (resp at: #success).
	poll := self transcriptPollResponseSince: 0.
	self assert: (poll at: #success).
	self assert: (((poll at: #result) at: 'text') includesSubstring: 'poll').
	self assert: (((poll at: #result) at: 'seq') >= 1)
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testTranscriptClearResetsPollCursor [
	| first cleared second |
	self evalResponseForCode: 'Transcript show: ''clear-me''; cr. 7'.
	first := self transcriptPollResponseSince: 0.
	self assert: (((first at: #result) at: 'seq') >= 1).
	self assert: (((first at: #result) at: 'text') includesSubstring: 'clear-me').
	cleared := self transcriptClearResponse.
	self assert: ((cleared at: #result) at: 'seq') equals: 0.
	second := self transcriptPollResponseSince: 0.
	self assert: ((second at: #result) at: 'seq') equals: 0.
	self assert: ((second at: #result) at: 'text') equals: ''.
	self assert: ((second at: #result) at: 'entries') equals: #()
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
SisBridgeExtrasTest >> testInspectExpressionAndRefRoundTrip [
	| root child |
	root := self inspectExpressionResponseFor: 'OrderedCollection with: 10 with: 20'.
	self assert: (root at: #success).
	self assert: (((root at: #result) at: #class) = 'OrderedCollection').
	self assert: (((root at: #result) at: #ref) isInteger).
	child := self inspectRefResponseFor: ((root at: #result) at: #ref).
	self assert: (child at: #success).
	self assert: (((child at: #result) at: #class) = 'OrderedCollection')
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
SisBridgeExtrasTest >> testCompileClassCreatesAndReportsCreated [
	| resp cls |
	self ensureDemoClassAbsent.
	[
		resp := self compileClassResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #superclass put: 'Object';
			at: #package put: 'Sis-Compile-Api-Demo';
			at: #inst_vars put: #('a' 'b');
			yourself).
		self assert: (resp at: #success).
		self assert: ((resp at: #result) at: 'class_name') equals: 'SisCompileApiDemo'.
		self assert: ((resp at: #result) at: 'created').
		cls := Smalltalk globals at: #SisCompileApiDemo.
		self assert: cls instVarNames asArray equals: #('a' 'b')
	] ensure: [ self ensureDemoClassAbsent ]
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testCompileClassReportsUpdatedOnSecondCall [
	| first second |
	self ensureDemoClassAbsent.
	[
		first := self compileClassResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #superclass put: 'Object';
			at: #package put: 'Sis-Compile-Api-Demo';
			at: #inst_vars put: #('a');
			yourself).
		second := self compileClassResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #superclass put: 'Object';
			at: #package put: 'Sis-Compile-Api-Demo';
			at: #inst_vars put: #('a' 'b' 'c');
			yourself).
		self assert: ((first at: #result) at: 'created').
		self deny: ((second at: #result) at: 'created').
		self assert: (Smalltalk globals at: #SisCompileApiDemo) instVarNames asArray
			equals: #('a' 'b' 'c')
	] ensure: [ self ensureDemoClassAbsent ]
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testCompileMethodDefinesInstanceMethod [
	| cls resp |
	self ensureDemoClassAbsent.
	[
		self compileClassResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #superclass put: 'Object';
			at: #package put: 'Sis-Compile-Api-Demo';
			at: #inst_vars put: #('a' 'b');
			yourself).
		resp := self compileMethodResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #method_source put: 'sum	^ a + b';
			at: #category put: 'accessing';
			yourself).
		self assert: (resp at: #success).
		self assert: ((resp at: #result) at: 'selector') equals: 'sum'.
		self deny: ((resp at: #result) at: 'is_class_method').
		cls := Smalltalk globals at: #SisCompileApiDemo.
		self assert: (cls canUnderstand: #sum).
		self deny: (cls class canUnderstand: #sum)
	] ensure: [ self ensureDemoClassAbsent ]
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testCompileMethodDefinesClassSideWhenFlagIsTrue [
	| cls resp |
	self ensureDemoClassAbsent.
	[
		self compileClassResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #superclass put: 'Object';
			at: #package put: 'Sis-Compile-Api-Demo';
			yourself).
		resp := self compileMethodResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #method_source put: 'answer	^ 42';
			at: #is_class_method put: 'true';
			yourself).
		self assert: ((resp at: #result) at: 'is_class_method').
		cls := Smalltalk globals at: #SisCompileApiDemo.
		self assert: (cls class canUnderstand: #answer).
		self deny: (cls canUnderstand: #answer)
	] ensure: [ self ensureDemoClassAbsent ]
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testCompileMethodFirstCompileReportsOverwrittenFalse [
	| resp |
	self ensureDemoClassAbsent.
	[
		self compileClassResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #superclass put: 'Object';
			at: #package put: 'Sis-Compile-Api-Demo';
			at: #inst_vars put: #('a');
			yourself).
		resp := self compileMethodResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #method_source put: 'a	^ a';
			yourself).
		self deny: ((resp at: #result) at: 'overwritten').
		self deny: ((resp at: #result) includesKey: 'previous_source')
	] ensure: [ self ensureDemoClassAbsent ]
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testCompileMethodOverwriteCarriesPreviousSource [
	| first second |
	self ensureDemoClassAbsent.
	[
		self compileClassResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #superclass put: 'Object';
			at: #package put: 'Sis-Compile-Api-Demo';
			at: #inst_vars put: #('a');
			yourself).
		first := self compileMethodResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #method_source put: 'a	^ 1';
			yourself).
		second := self compileMethodResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #method_source put: 'a	^ 2';
			yourself).
		self deny: ((first at: #result) at: 'overwritten').
		self assert: ((second at: #result) at: 'overwritten').
		self assert: ((second at: #result) at: 'previous_source')
			equals: 'a	^ 1'
	] ensure: [ self ensureDemoClassAbsent ]
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testCompileMethodSyntaxErrorCarriesLineAndColumn [
	| resp err |
	self ensureDemoClassAbsent.
	[
		self compileClassResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #superclass put: 'Object';
			at: #package put: 'Sis-Compile-Api-Demo';
			yourself).
		resp := self compileMethodResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #method_source put: 'broken
	^ x @@@';
			yourself).
		self deny: (resp at: #success).
		err := resp at: #error.
		self assert: ((err at: 'source') includesSubstring: '@@@').
		self assert: (err at: 'line') equals: 2.
		self assert: (err at: 'column') > 0.
		self assert: (err at: 'location') isInteger.
		self assert: ((err at: 'message_text') isString)
	] ensure: [ self ensureDemoClassAbsent ]
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testRemoveMethodRemovesExistingSelector [
	| resp |
	self ensureDemoClassAbsent.
	[
		self compileClassResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #superclass put: 'Object';
			at: #package put: 'Sis-Compile-Api-Demo';
			yourself).
		self compileMethodResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #method_source put: 'noop	^ self';
			yourself).
		resp := self removeMethodResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #selector put: 'noop';
			yourself).
		self assert: ((resp at: #result) at: 'existed').
		self assert: ((resp at: #result) at: 'removed').
		self deny:
			((Smalltalk globals at: #SisCompileApiDemo)
				canUnderstand: #noop)
	] ensure: [ self ensureDemoClassAbsent ]
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testRemoveMethodIsNoOpWhenSelectorMissing [
	| resp |
	self ensureDemoClassAbsent.
	[
		self compileClassResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #superclass put: 'Object';
			at: #package put: 'Sis-Compile-Api-Demo';
			yourself).
		resp := self removeMethodResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #selector put: 'doesNotExist';
			yourself).
		self deny: ((resp at: #result) at: 'existed').
		self deny: ((resp at: #result) at: 'removed')
	] ensure: [ self ensureDemoClassAbsent ]
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testRemoveMethodIsNoOpWhenClassMissing [
	| resp |
	self ensureDemoClassAbsent.
	resp := self removeMethodResponseFor: (Dictionary new
		at: #class_name put: 'SisCompileApiDemo';
		at: #selector put: 'doesNotExist';
		yourself).
	self deny: ((resp at: #result) at: 'existed').
	self deny: ((resp at: #result) at: 'removed')
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testRemoveClassRoundTrip [
	| first second |
	self ensureDemoClassAbsent.
	self compileClassResponseFor: (Dictionary new
		at: #class_name put: 'SisCompileApiDemo';
		at: #superclass put: 'Object';
		at: #package put: 'Sis-Compile-Api-Demo';
		yourself).
	first := self removeClassResponseFor: (Dictionary new
		at: #class_name put: 'SisCompileApiDemo'; yourself).
	second := self removeClassResponseFor: (Dictionary new
		at: #class_name put: 'SisCompileApiDemo'; yourself).
	self assert: ((first at: #result) at: 'removed').
	self assert: ((first at: #result) at: 'existed').
	self deny: ((second at: #result) at: 'existed').
	self deny: ((second at: #result) at: 'removed').
	self ensureDemoClassAbsent
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testCompileMethodErrorsAreReportedOnSuccessFalse [
	| resp |
	self ensureDemoClassAbsent.
	[
		self compileClassResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #superclass put: 'Object';
			at: #package put: 'Sis-Compile-Api-Demo';
			yourself).
		resp := self compileMethodResponseFor: (Dictionary new
			at: #class_name put: 'SisCompileApiDemo';
			at: #method_source put: 'brokenMethod	^ @@@@';
			yourself).
		self deny: (resp at: #success).
		self assert: ((resp at: #error) at: 'description') isString
	] ensure: [ self ensureDemoClassAbsent ]
]

{ #category : 'tests' }
SisBridgeExtrasTest >> testTranscriptSerializesAsPrintString [
	self
		assert: (NeoJSONWriter toString: Transcript)
		equals: '"a StThreadSafeTranscript"'
]
