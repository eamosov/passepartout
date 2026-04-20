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

# ─── Step 2b: Ensure Ad Hoc profiles cover all server UDIDs ───
#
# Creates (or reuses) Ad Hoc profiles for every bundle ID via App Store Connect
# API, installs them locally and writes /tmp/adhoc_profiles.json with the
# bundle-id → profile-name mapping used later by the manual-signing export.

ensure_adhoc_profiles() {
    if [ -z "${ASC_KEY_ID}" ] || [ -z "${ASC_ISSUER_ID}" ] || [ -z "${ASC_KEY_FILE}" ]; then
        warn "ASC API not configured — skipping profile provisioning"
        return 0
    fi
    if [ -z "${UDID_JSON}" ]; then
        return 0
    fi

    log "Ensuring Ad Hoc profiles for all server UDIDs"
    UDID_JSON_EXPORT="${UDID_JSON}" \
    BUNDLE_IDS="com.eamosov.Passepartout,com.eamosov.Passepartout.Tunnel" \
        python3 - "${ASC_KEY_ID}" "${ASC_ISSUER_ID}" "${ASC_KEY_FILE}" << 'PYTHON'
import sys, os, time, json, base64, urllib.request, urllib.error, datetime
from pathlib import Path

key_id, issuer_id, key_file = sys.argv[1], sys.argv[2], sys.argv[3]
server_devices = json.loads(os.environ["UDID_JSON_EXPORT"])
bundle_ids = [b.strip() for b in os.environ["BUNDLE_IDS"].split(",") if b.strip()]

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
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        print(f"  API error {e.code} on {method} {path}: {err_body}", file=sys.stderr)
        return None

server_udids = set(server_devices.keys())

cert_resp = api_request("GET", "certificates?limit=200")
cert_id = None
if cert_resp:
    for c in cert_resp.get("data", []):
        t = c["attributes"]["certificateType"]
        if t in ("APPLE_DISTRIBUTION", "IOS_DISTRIBUTION", "DISTRIBUTION"):
            cert_id = c["id"]
            print(f"  Distribution cert: {c['attributes'].get('name','?')} ({t})")
            break
if not cert_id:
    print("  No distribution certificate found via ASC API", file=sys.stderr)
    sys.exit(1)

dev_resp = api_request("GET", "devices?filter[platform]=IOS&limit=200")
udid_to_devid = {}
for d in (dev_resp or {}).get("data", []):
    if d["attributes"].get("status") != "ENABLED":
        continue
    udid_to_devid[d["attributes"]["udid"]] = d["id"]
device_ids = sorted(udid_to_devid[u] for u in server_udids if u in udid_to_devid)
missing_on_portal = server_udids - set(udid_to_devid.keys())
if missing_on_portal:
    print(f"  Note: {len(missing_on_portal)} server UDID(s) not enabled on portal: {', '.join(sorted(missing_on_portal))}")

all_profiles = []
all_inc = []
url = "profiles?include=bundleId,devices&limit=200"
while url:
    r = api_request("GET", url)
    if not r: break
    all_profiles.extend(r.get("data", []))
    all_inc.extend(r.get("included", []))
    nxt = r.get("links", {}).get("next")
    url = nxt.split("/v1/", 1)[1] if nxt else None
inc_map = {(i["type"], i["id"]): i for i in all_inc}

def get_bundle_ref(bid):
    r = api_request("GET", f"bundleIds?filter[identifier]={bid}&limit=1")
    if r and r.get("data"):
        return r["data"][0]["id"]
    return None

def profile_devices(p):
    out = set()
    for dv in p["relationships"]["devices"]["data"]:
        di = inc_map.get(("devices", dv["id"]))
        if di:
            out.add(di["attributes"]["udid"])
    return out

def profile_bundle_identifier(p):
    br = p["relationships"]["bundleId"]["data"]
    bi = inc_map.get(("bundleIds", br["id"]))
    return bi["attributes"]["identifier"] if bi else None

def install_profile_content(uuid, content_b64):
    base = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
    os.makedirs(base, exist_ok=True)
    path = os.path.join(base, f"{uuid}.mobileprovision")
    Path(path).write_bytes(base64.b64decode(content_b64))
    return path

def fetch_profile_content(profile_id):
    r = api_request("GET", f"profiles/{profile_id}?fields[profiles]=profileContent,uuid,name")
    if r and r.get("data"):
        a = r["data"]["attributes"]
        return a.get("profileContent"), a.get("uuid"), a.get("name")
    return None, None, None

profile_mapping = {}
for bid in bundle_ids:
    bref = get_bundle_ref(bid)
    if not bref:
        print(f"  Bundle {bid}: not registered in ASC, skipping", file=sys.stderr)
        continue

    for_bundle = [
        p for p in all_profiles
        if p["attributes"].get("profileType") == "IOS_APP_ADHOC"
        and profile_bundle_identifier(p) == bid
    ]

    usable = None
    for p in for_bundle:
        if server_udids.issubset(profile_devices(p)):
            usable = p
            break

    if usable:
        name = usable["attributes"]["name"]
        uuid = usable["attributes"]["uuid"]
        content_b64, _, _ = fetch_profile_content(usable["id"])
        if content_b64:
            path = install_profile_content(uuid, content_b64)
            print(f"  {bid}: reusing '{name}' ({uuid}) → {path}")
        else:
            print(f"  {bid}: reusing '{name}' ({uuid}) (no content returned)")
        profile_mapping[bid] = {"name": name, "uuid": uuid}
        continue

    for p in for_bundle:
        missing = server_udids - profile_devices(p)
        print(f"  {bid}: deleting stale '{p['attributes']['name']}' (missing {len(missing)} UDID)")
        api_request("DELETE", f"profiles/{p['id']}")

    ts = datetime.datetime.now().strftime("%Y%m%d%H%M")
    short = bid.split(".")[-1] if "." in bid else bid
    new_name = f"AdHoc {bid} {ts}"
    if len(new_name) > 50:
        new_name = f"AdHoc {short} {ts}"[:50]

    body = {
        "data": {
            "type": "profiles",
            "attributes": {"name": new_name, "profileType": "IOS_APP_ADHOC"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bref}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
                "devices": {"data": [{"type": "devices", "id": d} for d in device_ids]},
            }
        }
    }
    r = api_request("POST", "profiles", body)
    if not r or not r.get("data"):
        print(f"  {bid}: FAILED to create profile", file=sys.stderr)
        sys.exit(1)

    uuid = r["data"]["attributes"]["uuid"]
    name = r["data"]["attributes"]["name"]
    content_b64 = r["data"]["attributes"].get("profileContent")
    if not content_b64:
        content_b64, _, _ = fetch_profile_content(r["data"]["id"])
    if content_b64:
        path = install_profile_content(uuid, content_b64)
        print(f"  {bid}: created '{name}' ({uuid}) with {len(device_ids)} UDID(s) → {path}")
    else:
        print(f"  {bid}: created '{name}' ({uuid}) but no content to install", file=sys.stderr)
        sys.exit(1)
    profile_mapping[bid] = {"name": name, "uuid": uuid}

Path("/tmp/adhoc_profiles.json").write_text(json.dumps(profile_mapping))
print(f"  Wrote mapping to /tmp/adhoc_profiles.json ({len(profile_mapping)} bundle(s))")
PYTHON
}

# ─── Step 3: Build Ad Hoc IPA ───

build_ipa() {
    local auth_args=()
    if [ -n "${ASC_KEY_ID}" ] && [ -n "${ASC_ISSUER_ID}" ] && [ -f "${ASC_KEY_FILE}" ]; then
        auth_args=(
            -authenticationKeyID "${ASC_KEY_ID}"
            -authenticationKeyIssuerID "${ASC_ISSUER_ID}"
            -authenticationKeyPath "${ASC_KEY_FILE}"
        )
    fi

    log "Building release archive"
    xcodebuild \
        -project "${PROJECT}" \
        -scheme "${SCHEME}" \
        -destination 'generic/platform=iOS' \
        -configuration Release \
        -allowProvisioningUpdates \
        "${auth_args[@]}" \
        archive \
        -archivePath "${ARCHIVE_PATH}" \
        2>&1 | tail -5

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        err "Archive build failed"
        return 1
    fi

    log "Exporting Ad Hoc IPA"
    if [ -f /tmp/adhoc_profiles.json ]; then
        python3 - << 'PYTHON' > /tmp/ExportOptions.plist
import json, plistlib, sys
mapping = json.load(open("/tmp/adhoc_profiles.json"))
plist = {
    "method": "release-testing",
    "teamID": "ZZ46P8LWV3",
    "signingStyle": "manual",
    "signingCertificate": "Apple Distribution",
    "stripSwiftSymbols": True,
    "compileBitcode": False,
    "provisioningProfiles": {bid: info["name"] for bid, info in mapping.items()},
}
sys.stdout.buffer.write(plistlib.dumps(plist))
PYTHON
    else
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
    fi

    rm -rf "${EXPORT_PATH}"
    xcodebuild \
        -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportPath "${EXPORT_PATH}" \
        -exportOptionsPlist /tmp/ExportOptions.plist \
        -allowProvisioningUpdates \
        "${auth_args[@]}" \
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
    rm -f /tmp/adhoc_profiles.json
    fetch_udids && register_devices && ensure_adhoc_profiles
fi

build_ipa

if [ "${UPLOAD}" = true ]; then
    upload_ipa
fi

echo ""
log "Done! IPA: ${EXPORT_PATH}/Passepartout.ipa"
