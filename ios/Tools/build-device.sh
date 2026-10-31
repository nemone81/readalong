#!/bin/zsh
# Build di sviluppo firmata e installazione sull'iPhone collegato (checkpoint B).
#
#   ios/Tools/build-device.sh [UDID]
#   ENTITLEMENTS=build/NoCloud.entitlements ios/Tools/build-device.sh   # finche' il PLA non e' accettato
#
# Firma automatica tramite la chiave API di App Store Connect (stessa di
# BattleFits): registra il dispositivo e aggiorna l'App ID (iCloud KVS) da
# solo. La chiave, se manca sul Mac, viene letta da 1Password senza mai
# passare dal terminale.
set -euo pipefail

KEY_ID="S73NDWJ836"
ISSUER_ID="68aaf55f-4337-4921-bd34-a64c1284c2f8"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
BUNDLE_ID="it.fabiocrestoni.readalong"

cd "$(dirname "$0")/.."

if [[ ! -f "$KEY_PATH" ]]; then
  export OP_SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN:-$(cat ~/.config/op/claude-sa-token)}"
  ref=$(op item list --format json | python3 -c '
import json, sys
for i in json.load(sys.stdin):
    if i["title"] == "App Store Connect API - BattleFits":
        print("op://%s/%s/credential" % (i["vault"]["name"], i["id"]))')
  mkdir -p "$(dirname "$KEY_PATH")"
  (umask 077; op read "$ref" > "$KEY_PATH")
fi

UDID="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ {print $2; exit}')}"
[[ -n "$UDID" ]] || { echo "Nessun iPhone collegato (xcrun devicectl list devices)." >&2; exit 1; }

DERIVED="${DERIVED_DATA:-build/device}"
mkdir -p build
xcodegen generate --quiet
xcodebuild -project ReadAlong.xcodeproj -scheme ReadAlong \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  ${ENTITLEMENTS:+CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS"} \
  build > build/device.log 2>&1 || { grep -E "error:" build/device.log | sort -u | head -20; exit 1; }

APP="$DERIVED/Build/Products/Debug-iphoneos/ReadAlong.app"
echo "Build ok: $APP"
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" || {
  echo "Avvio non riuscito: al primo avvio l'iPhone puo' chiedere la fiducia allo sviluppatore (Impostazioni > Generali > VPN e gestione dispositivi)." >&2
}
