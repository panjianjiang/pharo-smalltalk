Extension { #name : 'Association' }

{ #category : '*Sis-Core' }
Association >> neoJsonOn: neoJSONWriter [
	"An Association serializes as a one-entry JSON object."
	neoJSONWriter writeMap: (Dictionary new
		at: self key asString put: self value;
		yourself)
]
