Class {
	#name : 'SisTranscriptTeeStreamStub',
	#superclass : 'Object',
	#instVars : [
		'stream'
	],
	#category : 'Sis-Bridge-Extras-Tests',
	#package : 'Sis-Bridge-Extras-Tests'
}

{ #category : 'instance creation' }
SisTranscriptTeeStreamStub class >> on: aWriteStream [
	^ self new stream: aWriteStream; yourself
]

{ #category : 'accessing' }
SisTranscriptTeeStreamStub >> contents [
	^ stream contents
]

{ #category : 'accessing' }
SisTranscriptTeeStreamStub >> stream [
	^ stream
]

{ #category : 'accessing' }
SisTranscriptTeeStreamStub >> stream: aWriteStream [
	stream := aWriteStream
]

{ #category : 'Transcript protocol' }
SisTranscriptTeeStreamStub >> show: aString [
	stream nextPutAll: aString
]

{ #category : 'Transcript protocol' }
SisTranscriptTeeStreamStub >> cr [
	stream nextPut: Character cr
]

{ #category : 'Transcript protocol' }
SisTranscriptTeeStreamStub >> nl [
	stream nextPut: Character lf
]

{ #category : 'Transcript protocol' }
SisTranscriptTeeStreamStub >> crShow: aString [
	self cr. self show: aString
]

{ #category : 'Transcript protocol' }
SisTranscriptTeeStreamStub >> space [
	stream nextPut: Character space
]

{ #category : 'Transcript protocol' }
SisTranscriptTeeStreamStub >> tab [
	stream nextPut: Character tab
]

{ #category : 'Transcript protocol' }
SisTranscriptTeeStreamStub >> nextPutAll: aString [
	stream nextPutAll: aString
]

{ #category : 'Transcript protocol' }
SisTranscriptTeeStreamStub >> nextPut: aCharacter [
	stream nextPut: aCharacter
]

{ #category : 'Transcript protocol' }
SisTranscriptTeeStreamStub >> flush [
	^ self
]

{ #category : 'Transcript protocol' }
SisTranscriptTeeStreamStub >> endEntry [
	^ self
]

{ #category : 'Transcript protocol' }
SisTranscriptTeeStreamStub >> printString [
	^ '''fake-transcript'''
]
