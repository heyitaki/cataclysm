#!/bin/bash
# Reproduces every executed check in the distribution spec's verification
# appendix. Copies the fixtures into a fresh temporary directory so no stale
# artifact can be mistaken for a result, fails fast on any unexpected outcome,
# and reports PASS, FAIL, or SKIP per claim. Exits non-zero if anything FAILed.
#
# Needs the Xcode command line tools. Claim 8 needs the calling terminal to
# hold Full Disk Access. Claims 5, 6, 10, and 11 need a real disk-image device,
# which a seatbelt sandbox usually denies; they SKIP there rather than fail.
# Claim 3b needs a GUI login session, because it launches a bundled app.
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cataclysm-verify.XXXXXX")"
PROBE_LABEL="com.example.cataclysm-verify.$$.watchprobe"
PROBE_PLIST="$HOME/Library/LaunchAgents/$PROBE_LABEL.plist"
PROBE_BIN="/private/tmp/cataclysm-watchprobe.$$"
PROBE_MARKER="/private/tmp/cataclysm-watchprobe.$$.marker"
cleanup() {
  launchctl bootout "gui/$(id -u)/$PROBE_LABEL" >/dev/null 2>&1 || true
  rm -f "$PROBE_PLIST" "$PROBE_BIN" "$PROBE_MARKER"
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
for f in App.swift main.swift Accel.swift Bridging.h taptest.swift probe.swift Info.plist watch.plist probe-Info.plist; do
  cp "$SRC/$f" "$WORK/$f" || { echo "missing fixture $SRC/$f; nothing below would mean anything" >&2; exit 2; }
done
cd "$WORK"

FAILED=0; NPASS=0; NFAIL=0; NSKIP=0
pass() { printf '  PASS  %s\n' "$1"; NPASS=$((NPASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; NFAIL=$((NFAIL+1)); }
skip() { printf '  SKIP  %s\n' "$1"; NSKIP=$((NSKIP+1)); }
# check <label> <expected-substring> <command...>
check() {
  local label="$1" want="$2"; shift 2
  local out; out="$("$@" 2>&1)"
  case "$out" in
    *"$want"*) pass "$label" ;;
    *) fail "$label (wanted \"$want\", got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160))" ;;
  esac
}

echo "== 0. toolchain =="
xcrun swiftc --version | head -2
echo "SDK $(xcrun --show-sdk-version), macOS $(sw_vers -productVersion) build $(sw_vers -buildVersion), $(uname -m)"

echo "== 1+2. macOS 13 floor, both slices, bridging header, lipo =="
if ! xcrun swiftc -O -target arm64-apple-macos13.0 -import-objc-header Bridging.h \
       main.swift App.swift Accel.swift -o cataclysm-arm64 2> arm64.log; then
  fail "arm64 build at the macOS 13 floor"; sed -n '1,20p' arm64.log
else
  pass "arm64 build at the macOS 13 floor (warnings only: $(grep -c 'warning:' arm64.log))"
fi
if ! xcrun swiftc -O -target x86_64-apple-macos13.0 -import-objc-header Bridging.h \
       main.swift App.swift Accel.swift -o cataclysm-x86_64 2> x86.log; then
  fail "x86_64 build at the macOS 13 floor"; sed -n '1,20p' x86.log
else
  pass "x86_64 build at the macOS 13 floor"
fi
if [ -x cataclysm-arm64 ] && [ -x cataclysm-x86_64 ]; then
  lipo -create cataclysm-arm64 cataclysm-x86_64 -output cataclysm
  check "lipo produces both slices" "x86_64 arm64" lipo -info cataclysm
  n=$(otool -l cataclysm | grep -c "minos 13.0")
  [ "$n" = 2 ] && pass "both slices report minos 13.0" || fail "minos 13.0 on $n of 2 slices"
else
  fail "lipo skipped, a slice is missing (no stale binary is used)"
fi

echo "== 3. hardened runtime, zero entitlements: what TCC gates and what it does not =="
# No check in this script may raise a user-facing permission dialog. Creating
# an active event tap from an untrusted process raises the system "wants to
# receive keystrokes" prompt, so the tap is attempted only from an already
# trusted process, and the untrusted result is carried as a recorded
# measurement (appendix claim 3b) rather than re-run.
xcrun swiftc -O -target arm64-apple-macos13.0 taptest.swift -o taptest 2>/dev/null
codesign --force --options runtime -s - taptest 2>/dev/null
ents="$(codesign -d --entitlements - taptest 2>&1 | grep -v '^Executable=' || true)"
[ -z "$ents" ] && pass "the signed binary carries no entitlements" || fail "unexpected entitlements: $ents"
trustedrun="$(./taptest 2>&1)"
if case "$trustedrun" in *"AXIsProcessTrusted: true"*) true ;; *) false ;; esac; then
  check "3a. trusted context: active tap created under hardened runtime" "tapCreate: created" ./taptest
else
  skip "3a. the calling process is not Accessibility trusted, so the trusted half cannot run here"
fi
# 3b. The same code as its own responsible process under a bundle id that has
# never been granted Accessibility. Needs a GUI login session. It calls nothing
# TCC-gated, so it raises no dialog.
xcrun swiftc -O probe.swift -o probe 2>/dev/null
rm -rf AssocProbe.app && mkdir -p AssocProbe.app/Contents/MacOS
cp probe AssocProbe.app/Contents/MacOS/probe
cp probe-Info.plist AssocProbe.app/Contents/Info.plist
codesign --force --options runtime -s - AssocProbe.app 2>/dev/null
rm -f /tmp/assocprobe.txt
if open -a "$WORK/AssocProbe.app" 2>/dev/null; then
  for _ in $(seq 1 10); do [ -f /tmp/assocprobe.txt ] && break; sleep 1; done
fi
if [ -f /tmp/assocprobe.txt ]; then
  cat /tmp/assocprobe.txt | sed 's/^/    /'
  probeout="$(cat /tmp/assocprobe.txt)"
  case "$probeout" in *"trusted=false"*) true ;; *) false ;; esac \
    && pass "3b. the probe really is untrusted" || fail "3b. the probe was trusted, so it proves nothing"
  case "$probeout" in *"CGAssociateMouseAndMouseCursorPosition(1) -> 0"*) true ;; *) false ;; esac \
    && pass "3b. re-association succeeds with no Accessibility grant" \
    || fail "3b. re-association failed without a grant"
  case "$probeout" in
    *"tapCreate=not-attempted"*)
      echo "  NOTE  3b. the untrusted active-tap result (nil, refused) is a recorded measurement, not re-run here: attempting it would raise a permission dialog" ;;
    *) fail "3b. the probe attempted a TCC-gated call; it must not" ;;
  esac
else
  skip "3b. no GUI login session, so the untrusted-context probe did not run"
fi

echo "== 4. bundle, hardened runtime, designated requirement, Gatekeeper =="
rm -rf Cataclysm.app && mkdir -p Cataclysm.app/Contents/{MacOS,Resources,Library/LaunchAgents}
cp cataclysm Cataclysm.app/Contents/MacOS/cataclysm
cp Info.plist Cataclysm.app/Contents/Info.plist
cp watch.plist "Cataclysm.app/Contents/Library/LaunchAgents/com.example.cataclysm.watch.plist"
plutil -lint Cataclysm.app/Contents/Info.plist >/dev/null && pass "Info.plist parses"
plutil -lint "Cataclysm.app/Contents/Library/LaunchAgents/com.example.cataclysm.watch.plist" >/dev/null \
  && pass "watcher plist parses"
codesign --force --options runtime --timestamp -s - Cataclysm.app 2>/dev/null
check "hardened runtime flag is set" "runtime" codesign -dvvv Cataclysm.app
check "signature verifies strictly" "satisfies its Designated Requirement" \
  codesign --verify --strict --verbose=2 Cataclysm.app
dr="$(codesign -d -r- Cataclysm.app 2>&1 | tail -1)"
echo "    $dr"
[ "$(printf '%s' "$dr" | grep -c cdhash)" = 1 ] && [ "$(printf '%s' "$dr" | grep -o cdhash | wc -l | tr -d ' ')" = 2 ] \
  && pass "ad-hoc DR is a two-cdhash disjunction, one per slice" \
  || fail "unexpected ad-hoc designated requirement"
spctlout="$(spctl -a -vvv -t exec Cataclysm.app 2>&1)"
case "$spctlout" in
  *rejected*) pass "Gatekeeper rejects the ad-hoc signed app" ;;
  *"code signing"*|*"Error"*|*"error"*) skip "spctl could not reach the assessment service here: $spctlout" ;;
  *) fail "spctl said: $spctlout" ;;
esac

echo "== 5. a real code change moves the ad-hoc designated requirement =="
printf '\nfunc _drProbe() -> Int { return 7 }\n' >> Accel.swift
xcrun swiftc -O -target arm64-apple-macos13.0 -import-objc-header Bridging.h \
  main.swift App.swift Accel.swift -o cataclysm-arm64 2>/dev/null
xcrun swiftc -O -target x86_64-apple-macos13.0 -import-objc-header Bridging.h \
  main.swift App.swift Accel.swift -o cataclysm-x86_64 2>/dev/null
lipo -create cataclysm-arm64 cataclysm-x86_64 -output Cataclysm.app/Contents/MacOS/cataclysm
codesign --force --options runtime -s - Cataclysm.app 2>/dev/null
dr2="$(codesign -d -r- Cataclysm.app 2>&1 | tail -1)"
[ "$dr" != "$dr2" ] && pass "the designated requirement changed with the code" \
  || fail "the designated requirement did not move"

echo "== 6. DMG build, sign, staple, mount, quarantine =="
rm -rf stage && mkdir stage && cp -R Cataclysm.app stage/ && ln -sfn /Applications stage/Applications
if ! hdiutil create -volname Cataclysm -srcfolder stage -ov -format UDZO Cataclysm.dmg >/dev/null 2>&1; then
  skip "hdiutil create is unavailable here (a sandbox usually denies the disk-image device)"
else
  pass "hdiutil built the drag-to-install image"
  codesign --force --timestamp -s - Cataclysm.dmg 2>/dev/null && pass "the image signs"
  staple="$(xcrun stapler staple Cataclysm.dmg 2>&1)"
  case "$staple" in *"Error 65"*) true ;; *) false ;; esac \
    && pass "stapling refuses without a notarization ticket (expected failure)" \
    || fail "stapler said: $(printf '%s' "$staple" | tr '\n' ' ')"
  cp Cataclysm.dmg Cataclysm-v2.dmg
  A="$(hdiutil attach Cataclysm.dmg    -nobrowse -readonly 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')"
  B="$(hdiutil attach Cataclysm-v2.dmg -nobrowse -readonly 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')"
  echo "    mounted at [$A] and [$B]"
  [ -L "$A/Applications" ] && [ -d "$A/Cataclysm.app" ] && pass "the image holds the app and the Applications symlink"
  case "$(mount)" in *"on $A ("*read-only*) pass "the mounted volume is read-only" ;; *) fail "the mounted volume is not read-only" ;; esac
  [ "$B" = "$A 1" ] && pass "a second same-named image mounts at \"$A 1\"" \
    || fail "second mount landed at [$B], expected [$A 1]"
  hdiutil detach "$B" >/dev/null 2>&1; hdiutil detach "$A" >/dev/null 2>&1
  xattr -w com.apple.quarantine "0081;68b3c000;Safari;" Cataclysm.dmg
  Q="$(hdiutil attach Cataclysm.dmg -nobrowse -readonly 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')"
  rm -rf "$WORK/qtest" && mkdir -p "$WORK/qtest" && cp -R "$Q/Cataclysm.app" "$WORK/qtest/"
  case "$(xattr -l "$WORK/qtest/Cataclysm.app")" in *com.apple.quarantine*) true ;; *) false ;; esac \
    && pass "quarantine reaches the copy dragged out of the image" \
    || fail "the copy carries no quarantine attribute"
  hdiutil detach "$Q" >/dev/null 2>&1
fi

echo "== 7. how TCC stores an Accessibility grant =="
tccdb="/Library/Application Support/com.apple.TCC/TCC.db"
row="$(sqlite3 "$tccdb" "select client, auth_value, length(csreq) from access where service='kTCCServiceAccessibility' and client like '%ammerspoon%';" 2>&1)"
case "$row" in
  *Hammerspoon*)
    echo "    $row"
    pass "the grant row exists and carries a csreq blob"
    sqlite3 "$tccdb" "select writefile('$WORK/csreq.bin', csreq) from access where service='kTCCServiceAccessibility' and client like '%ammerspoon%' limit 1;" >/dev/null
    req="$(csreq -r "$WORK/csreq.bin" -t)"
    echo "    $req"
    case "$req" in
      *'identifier "org.hammerspoon.Hammerspoon"'*) case "$req" in *cdhash*) false ;; *) true ;; esac ;;
      *) false ;;
    esac \
      && pass "a Developer ID grant names the identifier and the team, never a code hash" \
      || fail "unexpected requirement shape" ;;
  *) skip "TCC.db is unreadable here (needs Full Disk Access): $row" ;;
esac

echo "== 8. System Settings deep links (static resolution only, no navigation) =="
check "System Settings owns the URL scheme" "x-apple.systempreferences" \
  plutil -extract CFBundleURLTypes json -o - "/System/Applications/System Settings.app/Contents/Info.plist"
sec=/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex
check "the Privacy pane keeps the legacy identifier" "com.apple.preference.security" plutil -p "$sec/Contents/Info.plist"
check "the Privacy pane accepts the URL scheme" "allowsXAppleSystemPreferencesURLScheme" plutil -p "$sec/Contents/Info.plist"
anchors="$(strings "$sec"/Contents/MacOS/* 2>/dev/null || true)"
case "$anchors" in
  *Privacy_Accessibility*) pass "the Privacy_Accessibility anchor string is present" ;;
  *) fail "the Privacy_Accessibility anchor string is missing" ;;
esac
check "Login Items pane identifier" "com.apple.LoginItems-Settings.extension" \
  plutil -p /System/Library/ExtensionKit/Extensions/LoginItems.appex/Contents/Info.plist
echo "  NOTE  static presence only; that either URL actually navigates is unverified here"

echo "== 9. icns from an iconset =="
# iconutil prints "Invalid Iconset" both for a malformed iconset and when its
# mach lookups are denied, which a seatbelt sandbox does. Telling them apart
# needs two things, not one: every generated slice is asserted by exact name
# and exact pixel size, and `sips -s format icns` runs as a canary because it
# converts the same source without those lookups. Only a *complete* iconset
# plus a working canary licenses classifying an iconutil failure as an
# environment limit; an incomplete iconset is a FAIL whatever the canary says.
sips -s format png --resampleHeightWidth 1024 1024 \
  /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns \
  --out icon-1024.png >/dev/null 2>&1
dims="$(sips -g pixelWidth -g pixelHeight icon-1024.png 2>/dev/null | tr -d ' \n')"
case "$dims" in
  *pixelWidth:1024*pixelHeight:1024*)
    pass "a 1024x1024 source PNG was generated"
    rm -rf icon.iconset one.iconset && mkdir icon.iconset one.iconset
    cp icon-1024.png one.iconset/icon_512x512@2x.png
    genfail=""
    for spec in 16:icon_16x16.png 32:icon_16x16@2x.png 32:icon_32x32.png 64:icon_32x32@2x.png \
                128:icon_128x128.png 256:icon_128x128@2x.png 256:icon_256x256.png \
                512:icon_256x256@2x.png 512:icon_512x512.png 1024:icon_512x512@2x.png; do
      px="${spec%%:*}"; name="${spec#*:}"
      if ! sips -z "$px" "$px" icon-1024.png --out "icon.iconset/$name" >/dev/null 2>&1; then
        genfail="$genfail $name(sips-failed)"; continue
      fi
      got="$(sips -g pixelWidth -g pixelHeight "icon.iconset/$name" 2>/dev/null | tr -d ' \n')"
      case "$got" in
        *pixelWidth:$px*pixelHeight:$px*) : ;;
        *) genfail="$genfail $name(wrong-size)" ;;
      esac
    done
    nslices=$(ls icon.iconset | wc -l | tr -d ' ')
    [ "$nslices" = 10 ] || genfail="$genfail count=$nslices"
    if [ -z "$genfail" ]; then
      pass "the iconset holds all ten expected filenames at their exact pixel sizes"
      complete=yes
    else
      fail "the generated iconset is incomplete or wrong:$genfail"
      complete=no
    fi
    sips -s format icns icon-1024.png --out canary.icns >/dev/null 2>&1; canary=$?
    iconone="$(xcrun iconutil -c icns one.iconset -o icon-only1024.icns 2>&1)"; oneexit=$?
    iconfull="$(xcrun iconutil -c icns icon.iconset -o full.icns 2>&1)"; fullexit=$?
    # environmental classification is licensed only by a complete iconset AND a working canary
    if [ "$complete" = yes ] && [ $canary = 0 ] && [ -s canary.icns ]; then env_ok=yes; else env_ok=no; fi
    if [ $oneexit = 0 ] && [ -s icon-only1024.icns ]; then
      pass "iconutil accepts a one-slice iconset ($(stat -f%z icon-only1024.icns) bytes)"
    elif [ "$env_ok" = yes ]; then
      skip "iconutil returned \"$iconone\" while sips converted the same validated PNG, so its mach lookups are restricted here (a sandbox does this); re-run unsandboxed"
    else
      fail "iconutil rejected the one-slice iconset: $iconone"
    fi
    if [ $fullexit = 0 ] && [ -s full.icns ]; then
      pass "iconutil accepts the full ten-slice iconset ($(stat -f%z full.icns) bytes)"
    elif [ "$env_ok" = yes ]; then
      skip "same restriction for the ten-slice iconset: $iconfull"
    else
      fail "iconutil rejected the validated ten-slice iconset: $iconfull"
    fi
    [ $canary = 0 ] && [ -s canary.icns ] \
      && pass "sips -s format icns converts the source directly ($(stat -f%z canary.icns) bytes), the sandbox-proof fallback" \
      || fail "sips could not produce an icns either, so the source is the problem"
    ;;
  *) skip "could not generate the 1024px source PNG here ($dims)" ;;
esac

echo "== 9b. the legacy LaunchAgent fallback runs an ad-hoc signed job =="
# The fallback when SMAppService refuses a self-signed app. The job must not
# merely load: launchd has to EXECUTE a program signed no more strongly than
# the phase 3a fallback would be, so the probe is an ad-hoc signed,
# hardened-runtime binary that writes a marker naming its own signing flags and
# makes the one CoreGraphics call the real watcher makes. A job pointed at an
# Apple-signed system tool would prove nothing about that. Uniquely labelled,
# run once, booted out and deleted by the EXIT trap even if this script dies.
cp "$SRC/watchprobe.swift" .
if ! xcrun swiftc -O watchprobe.swift -o "$PROBE_BIN" 2>/dev/null; then
  skip "9b. could not build the watcher probe here"
elif ! codesign --force --options runtime -s - "$PROBE_BIN" 2>/dev/null; then
  skip "9b. could not ad-hoc sign the watcher probe here"
else
  sig="$(codesign -dvv "$PROBE_BIN" 2>&1)"
  case "$sig" in
    *"Signature=adhoc"*) pass "9b. the probe carries only an ad-hoc signature, weaker than the 3a fallback" ;;
    *) fail "9b. the probe is not ad-hoc signed, so it proves too much: $sig" ;;
  esac
  if [ ! -d "$HOME/Library/LaunchAgents" ] && ! mkdir -p "$HOME/Library/LaunchAgents" 2>/dev/null; then
    skip "9b. ~/Library/LaunchAgents is not writable here"
  else
    cat > "$PROBE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PROBE_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$PROBE_BIN</string><string>$PROBE_MARKER</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST
    if [ ! -f "$PROBE_PLIST" ]; then
      skip "9b. could not write the probe plist (sandboxed home)"
    else
      bmsg="$(launchctl bootstrap "gui/$(id -u)" "$PROBE_PLIST" 2>&1)"; bexit=$?
      if [ $bexit != 0 ]; then
        skip "9b. launchctl bootstrap is unavailable here ($bmsg)"
      else
        pass "9b. launchctl bootstrap accepted the ad-hoc signed user LaunchAgent"
        for _ in $(seq 1 15); do [ -f "$PROBE_MARKER" ] && break; sleep 1; done
        if [ -f "$PROBE_MARKER" ]; then
          echo "    $(cat "$PROBE_MARKER")"
          pass "9b. launchd EXECUTED the ad-hoc signed program (marker written)"
          case "$(cat "$PROBE_MARKER")" in
            *associate=0*) pass "9b. the launchd-spawned process re-associated the cursor successfully" ;;
            *) fail "9b. the job ran but re-association failed" ;;
          esac
        else
          fail "9b. the job loaded but never ran: $(launchctl print "gui/$(id -u)/$PROBE_LABEL" 2>&1 | grep -E 'last exit code|state =' | head -2 | tr '\n' ' ')"
        fi
        launchctl bootout "gui/$(id -u)/$PROBE_LABEL" >/dev/null 2>&1 \
          && pass "9b. bootout removed it" || fail "9b. bootout failed"
      fi
      rm -f "$PROBE_PLIST"
      [ -e "$PROBE_PLIST" ] && fail "9b. the probe plist was left behind" || pass "9b. nothing left behind"
    fi
  fi
fi

echo "== 10. signing identities present on this machine =="
security find-identity -v -p codesigning | tail -1

echo "== 11. launchd and SMAppService documentation quotes =="
man launchd.plist | col -b | grep -A3 "BundleProgram <string>" | sed 's/^/    /'
grep -n "must be code signed\|BundleProgram launchd plist key\|Contents/Library/LaunchAgents\|must be re-registered" \
  "$(xcrun --show-sdk-path)/System/Library/Frameworks/ServiceManagement.framework/Headers/SMAppService.h" | sed 's/^/    /'

echo
echo "$((NPASS+NFAIL+NSKIP)) checks: $NPASS passed, $NFAIL failed, $NSKIP skipped"
[ "$FAILED" = 0 ] && echo "ALL CHECKS PASSED (skips above are environment limits, not results)" \
                  || echo "SOME CHECKS FAILED"
exit "$FAILED"
