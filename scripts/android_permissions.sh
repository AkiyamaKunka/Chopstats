#!/usr/bin/env bash
# Prints the permissions an Android APK or app bundle asks for, one name a
# line, sorted and unique: the merged manifest Play reviews, libraries'
# permissions included. aapt2's full dump goes to stderr, for the log.
#
#   scripts/android_permissions.sh build/app/outputs/flutter-apk/app-release.apk
#   scripts/android_permissions.sh build/app/outputs/bundle/release/app-release.aab
#
# A bundle's manifest is the one Play receives, base/manifest/AndroidManifest.xml,
# in protobuf form: aapt2 reads it from a zip that holds it at the root next to
# the module's resources.pb, as it reads a proto-format APK. Needs the Android
# SDK's aapt2 (ANDROID_HOME or ANDROID_SDK_ROOT, as on GitHub's runners).
# Used by .github/workflows/mobile-build.yml (each APK against its allowlist)
# and release.yml (the Play bundle and the GitHub APK, docs/RELEASING.md § 6).
set -euo pipefail

# The names in an aapt2 `dump permissions` listing on stdin, one a line,
# sorted and unique. A permission is asked for as `uses-permission:
# name='…'`, or as `uses-permission-sdk-23: name='…'` for the form only
# Android 6 and later asks for (which a tools:node="remove" on
# <uses-permission> leaves in): both are listed, so neither form gets past
# a check. `permission:` (one the app declares) and `package:` are not
# requests. app/test/manifest_gate_test.dart runs this on a sample listing.
permission_names() {
  sed -nE "s/^uses-permission(-sdk-23)?: name='([^']*)'.*/\2/p" | LC_ALL=C sort -u
}

main() {
  file="${1:?usage: scripts/android_permissions.sh <app.apk|app.aab>}"
  [ -f "$file" ] || { echo "no such file: $file" >&2; exit 1; }

  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -z "$sdk" ] && [ -d "$HOME/Library/Android/sdk" ]; then
    sdk="$HOME/Library/Android/sdk" # Android Studio's default on a Mac
  fi
  tools="$(ls -d "$sdk"/build-tools/* 2>/dev/null | sort -V | tail -1)"
  aapt2="$tools/aapt2"
  [ -n "$tools" ] && [ -x "$aapt2" ] || {
    echo "aapt2 not found under ${sdk:-\$ANDROID_HOME}/build-tools" >&2
    exit 1
  }

  target="$file"
  case "$file" in
    *.aab)
      # Not local: the EXIT trap reads it after main has returned.
      work="$(mktemp -d "${TMPDIR:-/tmp}/aab-manifest.XXXXXX")"
      trap 'rm -rf "$work"' EXIT
      unzip -q "$file" base/manifest/AndroidManifest.xml base/resources.pb -d "$work"
      (
        cd "$work/base"
        cp manifest/AndroidManifest.xml AndroidManifest.xml
        zip -q ../manifest.apk AndroidManifest.xml resources.pb
      )
      target="$work/manifest.apk"
      ;;
  esac

  dump="$("$aapt2" dump permissions "$target")"
  echo "$dump" >&2
  permission_names <<<"$dump"
}

# Run, not sourced: sourcing it (the test) only defines permission_names.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
