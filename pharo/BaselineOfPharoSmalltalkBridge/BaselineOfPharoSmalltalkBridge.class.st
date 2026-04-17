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
				with: [ spec requires: #( 'PharoSmalltalkInteropServer' ) ] ]
]
