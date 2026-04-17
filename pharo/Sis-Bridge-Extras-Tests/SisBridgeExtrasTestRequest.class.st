Class {
	#name : 'SisBridgeExtrasTestRequest',
	#superclass : 'Object',
	#instVars : [
		'contents',
		'params'
	],
	#category : 'Sis-Bridge-Extras-Tests',
	#package : 'Sis-Bridge-Extras-Tests'
}

{ #category : 'instance creation' }
SisBridgeExtrasTestRequest class >> withJson: aString [
	^ self new
		contents: aString;
		yourself
]

{ #category : 'instance creation' }
SisBridgeExtrasTestRequest class >> withJson: aString params: aDictionary [
	^ self new
		contents: aString;
		params: aDictionary;
		yourself
]

{ #category : 'accessing' }
SisBridgeExtrasTestRequest >> at: aKey ifAbsent: aBlock [
	^ self params at: aKey ifAbsent: aBlock
]

{ #category : 'accessing' }
SisBridgeExtrasTestRequest >> contents [
	^ contents
]

{ #category : 'accessing' }
SisBridgeExtrasTestRequest >> contents: aString [
	contents := aString
]

{ #category : 'accessing' }
SisBridgeExtrasTestRequest >> entity [
	^ self
]

{ #category : 'accessing' }
SisBridgeExtrasTestRequest >> params [
	^ params ifNil: [ params := Dictionary new ]
]

{ #category : 'accessing' }
SisBridgeExtrasTestRequest >> params: aDictionary [
	params := aDictionary
]
