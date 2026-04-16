#!/bin/bash
#
# build.sh — Fetch UDIDs from server, register devices, build Ad Hoc IPA
#
# Usage:
#   ./build.sh              # full cycle: fetch UDIDs, register, build, copy to nekrovpn
#   ./build.sh --build-only # skip UDID fetch, just build
#
# Requirements:
#   - Xcode with logged-in Apple Developer account
#   - App Store Connect API key (for device registration):
#       export ASC_KEY_ID="XXXXXXXXXX"
#       export ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#       export ASC_KEY_FILE="$HOME/.appstoreconnect/AuthKey_XXXXXXXXXX.p8"
#
#   Or place these in ~/.config/passepartout-build.env
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="${SCRIPT_DIR}/app-apple/Passepartout.xcodeproj"
SCHEME="Passepartout"
ARCHIVE_PATH="/tmp/Passepartout.xcarchive"
EXPORT_PATH="/tmp/Passepartout-AdHoc"
NEKROVPN_DIR="${SCRIPT_DIR}/../nekrovpn"

# Server settings
NEKRO_URL="https://nekro.efreet.ru"
NEKRO_API_TOKEN="2217940d36ad3c737f4cb62edd8bf590ee1b69a1fda25910dd5b4064cd08abef"
UDID_URL="${NEKRO_URL}/api/admin/devices"

# Load env file if exists
ENV_FILE="${HOME}/.config/passepartout-build.env"
if [ -f "${ENV_FILE}" ]; then
    source "${ENV_FILE}"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}WARNING:${NC} $*"; }
err()  { echo -e "${RED}ERROR:${NC} $*" >&2; }

# ─── Step 1: Fetch UDIDs from server ───

fetch_udids() {
    log "Fetching UDIDs from ${UDID_URL}"
    UDID_JSON=$(curl -sf -H "Authorization: Bearer ${NEKRO_API_TOKEN}" "${UDID_URL}" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "${UDID_JSON}" ]; then
        warn "Could not fetch UDIDs from server (is it running?)"
        return 1
    fi

    DEVICE_COUNT=$(echo "${UDID_JSON}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
    log "Found ${DEVICE_COUNT} device(s) on server"

    if [ "${DEVICE_COUNT}" = "0" ]; then
        warn "No devices registered on server"
        return 0
    fi

    echo "${UDID_JSON}" | python3 -c "
import json, sys
devices = json.load(sys.stdin)
for udid, info in devices.items():
    name = info.get('device_name', 'Unknown')
    model = info.get('product', '')
    print(f'  {name} ({model}): {udid}')
"
    return 0
}

# ─── Step 2: Register devices in Apple Developer Portal ───

register_devices() {
    if [ -z "${ASC_KEY_ID}" ] || [ -z "${ASC_ISSUER_ID}" ] || [ -z "${ASC_KEY_FILE}" ]; then
        warn "App Store Connect API key not configured"
        warn "Set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_FILE to auto-register devices"
        warn "Or register devices manually at https://developer.apple.com/account/resources/devices"
        return 0
    fi

    if [ ! -f "${ASC_KEY_FILE}" ]; then
        err "API key file not found: ${ASC_KEY_FILE}"
        return 1
    fi

    log "Registering devices via App Store Connect API"
    UDID_JSON_EXPORT="${UDID_JSON}" python3 - "${ASC_KEY_ID}" "${ASC_ISSUER_ID}" "${ASC_KEY_FILE}" << 'PYTHON'
import sys, os, time, json, base64, urllib.request
from pathlib import Path

key_id, issuer_id, key_file = sys.argv[1], sys.argv[2], sys.argv[3]
server_devices = json.loads(os.environ["UDID_JSON_EXPORT"])

# Generate JWT
key_data = Path(key_file).read_bytes()
def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

header_b64 = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
now = int(time.time())
payload_b64 = b64url(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}).encode())
message = f"{header_b64}.{payload_b64}".encode()

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
private_key = serialization.load_pem_private_key(key_data, password=None)
der_sig = private_key.sign(message, ec.ECDSA(hashes.SHA256()))
r, s = utils.decode_dss_signature(der_sig)
jwt_token = f"{header_b64}.{payload_b64}.{b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"

def api_request(method, path, body=None):
    url = f"https://api.appstoreconnect.apple.com/v1/{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method,
        headers={"Authorization": f"Bearer {jwt_token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        if e.code == 409:  # Already exists
            return {"conflict": True}
        print(f"  API error {e.code}: {err_body}", file=sys.stderr)
        return None

# Fetch registered devices
resp = api_request("GET", "devices?filter[platform]=IOS&limit=200")
registered = set()
if resp:
    for d in resp.get("data", []):
        registered.add(d["attributes"]["udid"])
print(f"  Apple Portal: {len(registered)} device(s) registered")

# Register new ones
new_count = 0
for udid, info in server_devices.items():
    if udid not in registered:
        name = info.get("device_name") or info.get("product") or "Unknown"
        print(f"  Registering: {name} ({udid})")
        result = api_request("POST", "devices", {
            "data": {"type": "devices", "attributes": {"name": name, "platform": "IOS", "udid": udid}}
        })
        if result:
            new_count += 1

if new_count:
    print(f"  Registered {new_count} new device(s)")
else:
    print(f"  All devices already registered")
PYTHON
}

# ─── Step 3: Build Ad Hoc IPA ───

build_ipa() {
    log "Building release archive"
    xcodebuild \
        -project "${PROJECT}" \
        -scheme "${SCHEME}" \
        -destination 'generic/platform=iOS' \
        -configuration Release \
        -allowProvisioningUpdates \
        archive \
        -archivePath "${ARCHIVE_PATH}" \
        2>&1 | tail -5

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        err "Archive build failed"
        return 1
    fi

    log "Exporting Ad Hoc IPA"
    cat > /tmp/ExportOptions.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>release-testing</string>
    <key>teamID</key>
    <string>ZZ46P8LWV3</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
</dict>
</plist>
EOF

    rm -rf "${EXPORT_PATH}"
    xcodebuild \
        -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportPath "${EXPORT_PATH}" \
        -exportOptionsPlist /tmp/ExportOptions.plist \
        -allowProvisioningUpdates \
        2>&1 | tail -5

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        err "Export failed"
        return 1
    fi

    IPA_SIZE=$(du -h "${EXPORT_PATH}/Passepartout.ipa" | cut -f1)
    log "IPA built: ${EXPORT_PATH}/Passepartout.ipa (${IPA_SIZE})"
}

# ─── Step 4: Upload IPA to server ───

upload_ipa() {
    local ipa="${EXPORT_PATH}/Passepartout.ipa"
    if [ ! -f "${ipa}" ]; then
        err "IPA not found: ${ipa}"
        return 1
    fi

    log "Uploading Passepartout.ipa to ${NEKRO_URL}"
    local http_code
    http_code=$(curl -s -o /tmp/upload-response.json -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${NEKRO_API_TOKEN}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${ipa}" \
        "${NEKRO_URL}/api/admin/upload/Passepartout.ipa")

    if [ "${http_code}" != "200" ]; then
        err "Upload failed (HTTP ${http_code})"
        cat /tmp/upload-response.json 2>/dev/null
        return 1
    fi

    log "Upload OK: $(cat /tmp/upload-response.json)"
}

# ─── Main ───

BUILD_ONLY=false
UPLOAD=false

for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=true ;;
        --upload)     UPLOAD=true ;;
    esac
done

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   Passepartout Ad Hoc Build Script   ║"
echo "╚══════════════════════════════════════╝"
echo ""

if [ "${BUILD_ONLY}" = false ]; then
    fetch_udids && register_devices
fi

build_ipa

if [ "${UPLOAD}" = true ]; then
    upload_ipa
fi

echo ""
log "Done! IPA: ${EXPORT_PATH}/Passepartout.ipa"
