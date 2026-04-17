Extension { #name : 'Object' }

{ #category : '*Sis-Core' }
Object >> neoJsonOn: neoJSONWriter [
	"Fallback: serialize arbitrary objects as their printString.
	More specific classes (Number, String, Collection, Dictionary, Boolean,
	UndefinedObject, Symbol) override this."
	neoJSONWriter writeString: self printString
]
