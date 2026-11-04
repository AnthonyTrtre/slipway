# make projet | build | test | test-kit | lancer | installer | tcc-reset
# Les produits de compilation vont hors iCloud (D008).
DD := $(HOME)/Developer/builds/slipway
XB := xcodebuild -project Slipway.xcodeproj -scheme Slipway -derivedDataPath $(DD)
APP := $(DD)/Build/Products/Release/Slipway.app

projet: ; xcodegen generate
build: projet ; $(XB) -configuration Release build
test: projet test-kit ; $(XB) test
# Logique pure (protocole, géométrie, session, sécurité, moteur) : aussi sous Linux.
test-kit: ; cd SlipwayKit && swift test --scratch-path $(DD)/kit
lancer: build ; open "$(APP)"
installer: build ; osascript -e 'quit app id "fr.anthony.slipway"'; sleep 1; ditto "$(APP)" "/Applications/Slipway.app" && open "/Applications/Slipway.app"
# Débogage seulement : oublie les autorisations Accessibilité et Surveillance de l'entrée de Slipway.
tcc-reset: ; tccutil reset Accessibility fr.anthony.slipway; tccutil reset ListenEvent fr.anthony.slipway
