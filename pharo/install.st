"Bootstrap the Sis-Bridge-Extras package from a local pharo-smalltalk checkout.

This script intentionally delegates to the Tonel sources in `pharo/` so the
package files remain the single source of truth.

Usage from a Playground:

    Smalltalk globals
        at: #PharoSmalltalkBridgeInstallDirectory
        put: '/path/to/pharo-smalltalk/pharo' asFileReference.
    Smalltalk compiler evaluate:
        ('/path/to/pharo-smalltalk/pharo/install.st' asFileReference contents)
"

| installDirectory repositoryUrl |
installDirectory := Smalltalk globals
	at: #PharoSmalltalkBridgeInstallDirectory
	ifAbsent: [
		Error signal:
			'Set Smalltalk globals at: #PharoSmalltalkBridgeInstallDirectory put: ''/path/to/pharo-smalltalk/pharo'' asFileReference before evaluating install.st.' ].

installDirectory := installDirectory asFileReference.
(installDirectory exists and: [ installDirectory isDirectory ]) ifFalse: [
	Error signal: 'Invalid install directory: ', installDirectory fullName ].

repositoryUrl := 'tonel://', installDirectory fullName.

Metacello new
	baseline: 'PharoSmalltalkBridge';
	repository: repositoryUrl;
	load: #( 'Sis-Bridge-Extras' ).

Transcript
	crShow:
		'Sis-Bridge-Extras loaded from ',
		installDirectory fullName,
		'. Restart the server with `SisServer restart` if it is already running.'.
