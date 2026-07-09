#!/bin/bash
# =============================================================================
# Manicrypt — Pipeline de release une-commande
#
# Usage : ./scripts/release.sh <version>        (ex: ./scripts/release.sh 0.4.0)
#
# Étapes : bump version -> archive Release -> export Developer ID ->
#          notarisation Apple -> staple -> zip -> signature EdDSA Sparkle ->
#          mise à jour appcast.xml -> commit/push -> GitHub Release
#
# Prérequis (une fois) :
#   - Certificat "Developer ID Application" dans le trousseau (équipe 3SL9M22QDY)
#   - xcrun notarytool store-credentials manicrypt-notary (Apple ID nicolazicdev@gmail.com)
#   - Clé privée EdDSA Sparkle dans le trousseau (generate_keys, fait le 2026-07-09)
#   - gh CLI authentifié sur le compte Bidiche49 (le script switch tout seul)
# =============================================================================
set -euo pipefail

VERSION="${1:?Usage: ./scripts/release.sh <version>  (ex: 0.4.0)}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Manicrypt"
NOTARY_PROFILE="manicrypt-notary"
GH_ACCOUNT="Bidiche49"
BUILD_DIR="$REPO_DIR/build/release-$VERSION"
ARCHIVE="$BUILD_DIR/Manicrypt.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
ZIP_NAME="Manicrypt-$VERSION.zip"
APPCAST="$REPO_DIR/appcast.xml"
FEED_DOWNLOAD_URL="https://github.com/Bidiche49/Manicrypt/releases/download/v$VERSION/$ZIP_NAME"
MIN_SYSTEM_VERSION="15.0"

cd "$REPO_DIR"

# --- Garde-fous -------------------------------------------------------------
[ "$(git branch --show-current)" = "master" ] || { echo "❌ Les releases se font depuis master (branche courante: $(git branch --show-current))"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "❌ Working tree non propre — commite ou stash d'abord"; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" || { echo "❌ Certificat Developer ID Application absent du trousseau"; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || { echo "❌ Profil notarytool '$NOTARY_PROFILE' absent — lancer: xcrun notarytool store-credentials $NOTARY_PROFILE"; exit 1; }

# Localiser sign_update (fourni par le package SPM Sparkle)
SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" /private/tmp -path "*artifacts/sparkle/Sparkle/bin/sign_update" 2>/dev/null | head -1)"
[ -n "$SIGN_UPDATE" ] || { echo "❌ sign_update introuvable — builder une fois dans Xcode pour résoudre le package Sparkle"; exit 1; }

# --- 1. Bump version (MARKETING_VERSION + CURRENT_PROJECT_VERSION+1) ---------
CURRENT_BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' Manicrypt.xcodeproj/project.pbxproj | head -1)
NEW_BUILD=$((CURRENT_BUILD + 1))
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" Manicrypt.xcodeproj/project.pbxproj
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" Manicrypt.xcodeproj/project.pbxproj
echo "✅ Version: $VERSION (build $NEW_BUILD)"

# --- 2. Archive Release ------------------------------------------------------
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
xcodebuild -project Manicrypt.xcodeproj -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates archive | tail -2

# --- 3. Export signé Developer ID -------------------------------------------
cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>3SL9M22QDY</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -allowProvisioningUpdates | tail -2
APP="$EXPORT_DIR/Manicrypt.app"
[ -d "$APP" ] || { echo "❌ Export échoué"; exit 1; }

# --- 4. Notarisation + staple ------------------------------------------------
ditto -c -k --keepParent "$APP" "$BUILD_DIR/notarize.zip"
echo "⏳ Notarisation Apple (1-5 min)…"
xcrun notarytool submit "$BUILD_DIR/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP" 2>&1 | grep -q "accepted" && echo "✅ Gatekeeper: accepted" || { echo "❌ spctl refuse l'app"; exit 1; }

# --- 5. Zip final + signature EdDSA Sparkle ----------------------------------
ditto -c -k --keepParent "$APP" "$BUILD_DIR/$ZIP_NAME"
ED_SIGNATURE=$("$SIGN_UPDATE" "$BUILD_DIR/$ZIP_NAME")   # -> sparkle:edSignature="..." length="..."
echo "✅ Signature Sparkle: $ED_SIGNATURE"

# --- 6. Mise à jour appcast.xml ----------------------------------------------
PUB_DATE=$(LC_ALL=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")
ITEM="        <item>\\
            <title>Version $VERSION</title>\\
            <pubDate>$PUB_DATE</pubDate>\\
            <sparkle:version>$NEW_BUILD</sparkle:version>\\
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>\\
            <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>\\
            <enclosure url=\"$FEED_DOWNLOAD_URL\" $ED_SIGNATURE type=\"application/octet-stream\"/>\\
        </item>"
sed -i '' "s|<!-- RELEASES -->|<!-- RELEASES -->\\
$ITEM|" "$APPCAST"
echo "✅ appcast.xml mis à jour"

# --- 7. Commit + push + GitHub Release ---------------------------------------
PREV_GH_USER=$(gh api user -q .login 2>/dev/null || echo "")
gh auth switch --user "$GH_ACCOUNT" >/dev/null
git add appcast.xml Manicrypt.xcodeproj/project.pbxproj
git commit -m "[RELEASE] v$VERSION (build $NEW_BUILD)"
git tag "v$VERSION"
git push && git push --tags
gh release create "v$VERSION" "$BUILD_DIR/$ZIP_NAME" --title "Manicrypt v$VERSION" --notes "Mise à jour automatique via Sparkle."
[ -n "$PREV_GH_USER" ] && [ "$PREV_GH_USER" != "$GH_ACCOUNT" ] && gh auth switch --user "$PREV_GH_USER" >/dev/null

echo ""
echo "🎉 Release v$VERSION publiée."
echo "   Les apps installées se mettront à jour automatiquement."
echo "   Lien de première installation : https://github.com/Bidiche49/Manicrypt/releases/latest"
