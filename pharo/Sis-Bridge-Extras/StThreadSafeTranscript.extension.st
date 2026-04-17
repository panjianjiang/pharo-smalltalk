Extension { #name : 'StThreadSafeTranscript' }

{ #category : '*Sis-Bridge-Extras' }
StThreadSafeTranscript >> neoJsonOn: neoJSONWriter [
	"Match the Playground/UI convention for the Transcript singleton."
	neoJSONWriter writeString: self printString
]
