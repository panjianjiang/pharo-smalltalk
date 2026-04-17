Class {
	#name : 'BaselineOfPharoSmalltalkBridge',
	#superclass : 'BaselineOf',
	#category : 'BaselineOfPharoSmalltalkBridge',
	#package : 'BaselineOfPharoSmalltalkBridge'
}

{ #category : 'baselines' }
BaselineOfPharoSmalltalkBridge >> baseline: spec [
	<baseline>
	spec for: #'common' do: [
		spec
			baseline: 'PharoSmalltalkInteropServer'
				with: [
					spec repository:
						'github://mumez/PharoSmalltalkInteropServer:main/src' ];
			package: 'Sis-Bridge-Extras'
				with: [ spec requires: #( 'PharoSmalltalkInteropServer' ) ];
			package: 'Sis-Inspector'
				with: [ spec requires: #( 'PharoSmalltalkInteropServer' ) ];
			package: 'Sis-Bridge-Extras-Tests'
				with: [ spec requires: #( 'Sis-Bridge-Extras' 'PharoSmalltalkInteropServer' ) ];
			package: 'Sis-Inspector-Tests'
				with: [ spec requires: #( 'Sis-Inspector' ) ];
			group: 'default' with: #( 'Sis-Bridge-Extras' 'Sis-Inspector' );
			group: 'tests' with: #( 'default' 'Sis-Bridge-Extras-Tests' 'Sis-Inspector-Tests' ) ]
]
