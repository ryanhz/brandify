#!/usr/bin/env bash
# End-to-end check of the brandify pipeline on a real emulator or simulator:
# doctor, capture, frame and export, then checks every output file and its size.
#
#   tool/e2e.sh fresh android     # `flutter create` app + `brandify init`
#   tool/e2e.sh example ios       # the example app in this repo
#
# Environment:
#   BRANDIFY_E2E_AVD   AVD for the fresh app (default: the one `init` picks)
#   BRANDIFY_E2E_DIR   where to create the fresh app (default: a temp dir)
#
# Runs on Linux and macOS (bash 3.2). Needs python3 to read PNG headers.
set -euo pipefail

mode=${1:-}
platform=${2:-}
case "$platform" in
  android) device=pixel ;;
  ios) device=iphone69 ;;
  *) mode= ;;
esac
case "$mode" in
  fresh | example) ;;
  *)
    echo "usage: $0 <fresh|example> <android|ios>" >&2
    exit 64
    ;;
esac

repo=$(cd "$(dirname "$0")/.." && pwd)
step() { printf '\n==> %s\n' "$*"; }
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# -- the app ------------------------------------------------------------------

if [ "$mode" = fresh ]; then
  base=${BRANDIFY_E2E_DIR:-$(mktemp -d)}
  app="$base/brandify_e2e_app"
  rm -rf "$app"
  step "flutter create $app"
  flutter create --project-name brandify_e2e_app --platforms android,ios "$app" >/dev/null
  cd "$app"
  step "add brandify and brandify_flutter (path dependencies, as the README's pub add)"
  flutter pub add "dev:brandify:{\"path\":\"$repo/packages/brandify\"}" \
    "dev:brandify_flutter:{\"path\":\"$repo/packages/brandify_flutter\"}"
  step "brandify init"
  dart run brandify init
  if [ -n "${BRANDIFY_E2E_AVD:-}" ]; then
    sed -i.bak "s/^\(    avd: \)[^ ]*/\1$BRANDIFY_E2E_AVD/" brandify.yaml && rm brandify.yaml.bak
  fi
  step "brandify init again: must refuse to overwrite"
  if dart run brandify init >/dev/null 2>&1; then fail "second init overwrote the config"; fi
else
  app="$repo/example"
  cd "$app"
  flutter pub get >/dev/null
fi

# -- the pipeline ---------------------------------------------------------------

step "brandify doctor -d $device"
dart run brandify doctor -d "$device"
step "brandify capture -d $device"
dart run brandify capture -d "$device"
step "brandify frame -d $device"
dart run brandify frame -d "$device"
step "brandify export -d $device --replace"
dart run brandify export -d "$device" --replace

# -- checks ---------------------------------------------------------------------

step "checking outputs"
python3 - "$app" "$device" "$platform" <<'EOF'
import hashlib, json, os, struct, sys

app, device, platform = sys.argv[1:]
raw_root = os.path.join(app, "build/brandify/raw", device)
framed_root = os.path.join(app, "build/brandify/framed", device)

def size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"FAIL: {path} is not a PNG")
    return struct.unpack(">II", head[16:24])

def digest(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()

def store_files(locale):
    if platform == "android":
        d = os.path.join(app, "fastlane/metadata/android", locale, "images/phoneScreenshots")
    else:
        d = os.path.join(app, "fastlane/screenshots", locale)
    if not os.path.isdir(d):
        sys.exit(f"FAIL: no export folder {d}")
    return {f: os.path.join(d, f) for f in os.listdir(d) if f.endswith(".png")}

locales = sorted(os.listdir(raw_root)) if os.path.isdir(raw_root) else []
if not locales:
    sys.exit(f"FAIL: no captures in {raw_root}")
total = 0
for locale in locales:
    raw_dir = os.path.join(raw_root, locale)
    shots = sorted(f for f in os.listdir(raw_dir) if f.endswith(".png"))
    if not shots:
        sys.exit(f"FAIL: no PNGs in {raw_dir}")
    exported = store_files(locale)
    exported_digests = {digest(p): name for name, p in exported.items()}
    for shot in shots:
        raw = os.path.join(raw_dir, shot)
        framed = os.path.join(framed_root, locale, shot)
        if not os.path.isfile(framed):
            sys.exit(f"FAIL: {framed} missing")
        rw, rh = size(raw)
        fw, fh = size(framed)
        if platform == "android":
            # Google Play phone slot: 9:16 at the capture's width.
            want = (rw, rw * 16 // 9)
        else:
            # App Store 6.9" display class: the capture's own size.
            want = (1320, 2868)
            if (rw, rh) != want:
                sys.exit(f"FAIL: {raw} is {rw}x{rh}, want {want[0]}x{want[1]}")
        if (fw, fh) != want:
            sys.exit(f"FAIL: {framed} is {fw}x{fh}, want {want[0]}x{want[1]}")
        name = exported_digests.get(digest(framed))
        if name is None or not name.endswith("_" + shot):
            sys.exit(f"FAIL: {locale}/{shot} not exported unchanged (export folder: {sorted(exported)})")
        print(f"ok  {device} {locale} {shot}: raw {rw}x{rh}, framed {fw}x{fh}, exported as {name}")
        total += 1
    if len(exported) != len(shots):
        sys.exit(f"FAIL: {locale}: {len(exported)} exported files for {len(shots)} captures")

record = os.path.join(app, "fastlane/.brandify-export.json")
if not os.path.isfile(record):
    sys.exit(f"FAIL: {record} missing")
json.load(open(record))
print(f"\nall {total} screenshots checked")
EOF
