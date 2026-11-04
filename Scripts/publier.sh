#!/bin/zsh
# Fabrique une version publiable de Slipway : build Release signé, archive de mise à jour Sparkle
# (Slipway-<version>.zip, signée EdDSA), appcast.xml et DMG, à joindre à la Release GitHub v<version>.
# Les apps installées lisent releases/latest/download/appcast.xml et se mettent à jour seules.
# La clé EdDSA reste dans le Trousseau (compte « utahpik-slipway ») ; elle n'est jamais affichée.
#
# Usage : Scripts/publier.sh <version>       ex. Scripts/publier.sh 0.2.0
#         puis : gh release create v<version> ~/Developer/builds/slipway-publication/{*.dmg,*.sha256,*.zip,appcast.xml}
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${1:?usage : publier.sh <version>}
SORTIE="$HOME/Developer/builds/slipway-publication"
DD="$SORTIE/derived"
APP="$DD/Build/Products/Release/Slipway.app"
rm -rf "$SORTIE"; mkdir -p "$SORTIE"

xcodegen generate --quiet
# Numéro de build croissant (date) : Sparkle compare CFBundleVersion.
xcodebuild -project Slipway.xcodeproj -scheme Slipway -configuration Release -derivedDataPath "$DD" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" -quiet build
codesign --verify --deep --strict "$APP"

SPARKLE="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"
MAJ="$SORTIE/maj"; mkdir -p "$MAJ"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$MAJ/Slipway-$VERSION.zip"
"$SPARKLE/generate_appcast" --account utahpik-slipway \
  --download-url-prefix "https://github.com/AnthonyTrtre/slipway/releases/download/v$VERSION/" \
  --link "https://github.com/AnthonyTrtre/slipway" --maximum-versions 1 "$MAJ"
mv "$MAJ/Slipway-$VERSION.zip" "$MAJ/appcast.xml" "$SORTIE/"; rm -rf "$MAJ"

PREPA="$SORTIE/dmg"; mkdir -p "$PREPA"
ditto "$APP" "$PREPA/Slipway.app"
ln -s /Applications "$PREPA/Applications"
hdiutil create -quiet -volname "Slipway $VERSION" -srcfolder "$PREPA" -fs HFS+ -format UDZO "$SORTIE/Slipway-$VERSION.dmg"
rm -rf "$PREPA" "$DD"
( cd "$SORTIE" && shasum -a 256 "Slipway-$VERSION.dmg" "Slipway-$VERSION.zip" | tee SHA256SUMS.txt )
echo "Prêt : $SORTIE (DMG, zip Sparkle, appcast.xml, SHA256SUMS.txt)"
