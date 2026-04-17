Class {
	#name : 'SisBridgeExtrasTestRequest',
	#superclass : 'Object',
	#instVars : [
		'contents'
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
