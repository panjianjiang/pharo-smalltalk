Extension { #name : 'SisServer' }

{ #category : '*Sis-Inspector' }
SisServer >> handleInspectExpression: request [
	"Evaluate the `expression' JSON body field and return the SisInspector
	tree for its result, with drill-down refs registered server-side."
	^ self returnResultDo: [
		| json expression |
		json := NeoJSONReader fromString: request entity contents.
		expression := json at: #expression.
		SisInspector inspectExpression: expression ]
]

{ #category : '*Sis-Inspector' }
SisServer >> handleInspectRef: request [
	"Look up the object under the `ref' query param (integer) and return
	its inspection tree.  Raises a user-facing error when the ref has
	been evicted from the registry."
	^ self returnResultDo: [
		| raw ref |
		raw := request at: #ref.
		ref := raw asNumber truncated.
		SisInspector inspectRef: ref ]
]
