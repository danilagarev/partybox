#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: scripts/build-android-release.sh test-release|store-aab BUILD_NUMBER [--universal]

test-release: optimized APKs per ABI, explicitly signed with the EXISTING debug key.
              --universal also builds a larger APK for every supported ABI.
store-aab:    store bundle; requires android/key.properties and an existing keystore.

Set FLUTTER_BIN, JAVA_HOME and ANDROID_HOME for your installed toolchain.
Artifacts: output/android/<mode>-<BUILD_NUMBER>/ (ignored by Git).
No key is created, no app identifier is changed, no artifact is uploaded.
HELP
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
if [[ $# -lt 2 || $# -gt 3 ]]; then usage >&2; exit 2; fi
mode=$1
build_number=$2
universal=${3:-}
if [[ ! $build_number =~ ^[1-9][0-9]*$ ]]; then
  echo 'BUILD_NUMBER must be a positive integer, greater than the installed version.' >&2
  exit 2
fi
if [[ ${#build_number} -gt 10 ]] || (( 10#$build_number > 2100000000 )); then
  echo 'BUILD_NUMBER must not exceed the Google Play limit of 2100000000.' >&2
  exit 2
fi
if [[ -n $universal && $universal != --universal ]]; then usage >&2; exit 2; fi
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
flutter_bin=${FLUTTER_BIN:-flutter}
artifact_dir="$repo_dir/output/android/$mode-$build_number"
case "$mode" in
  test-release)
    # Gradle uses this same debug key for ordinary Flutter debug builds. Refuse
    # to generate a new one: it would not update the tester's existing install.
    debug_store=${ANDROID_USER_HOME:-${HOME:?}/.android}/debug.keystore
    if [[ ! -f $debug_store ]]; then
      echo "Existing debug keystore not found: $debug_store" >&2
      echo 'Use the original test signing key; do not create a replacement.' >&2
      exit 1
    fi
    export ORG_GRADLE_PROJECT_partyboxTestSigning=true
    ;;
  store-aab)
    if [[ -n $universal ]]; then usage >&2; exit 2; fi
    if [[ ! -f "$repo_dir/apps/mobile/android/key.properties" ]]; then
      echo 'Store signing is missing: configure android/key.properties locally.' >&2
      exit 1
    fi
    export ORG_GRADLE_PROJECT_partyboxTestSigning=false
    ;;
  *) usage >&2; exit 2 ;;
esac
mkdir -p -- "$artifact_dir"
cd -- "$repo_dir/apps/mobile"
if [[ $mode == test-release ]]; then
  for abi in armeabi-v7a arm64-v8a x86_64; do
    case "$abi" in
      armeabi-v7a) platform=android-arm ;;
      arm64-v8a) platform=android-arm64 ;;
      x86_64) platform=android-x64 ;;
    esac
    # --split-per-abi adds 1000/2000/4000 to versionCode. A later universal
    # test APK would then be rejected as a downgrade. Single-target builds
    # keep one increasing versionCode across all downloadable test variants.
    ORG_GRADLE_PROJECT_partyboxTargetAbi="$abi" \
      "$flutter_bin" build apk --release --target-platform "$platform" \
      --build-number "$build_number" --split-debug-info="$artifact_dir/symbols"
    cp -- build/app/outputs/flutter-apk/app-release.apk \
      "$artifact_dir/partybox-$abi-test-release.apk"
  done
  if [[ $universal == --universal ]]; then
    "$flutter_bin" build apk --release --build-number "$build_number" \
      --split-debug-info="$artifact_dir/symbols"
    cp -- build/app/outputs/flutter-apk/app-release.apk \
      "$artifact_dir/partybox-universal-test-release.apk"
  fi
else
  "$flutter_bin" build appbundle --release --build-number "$build_number" \
    --split-debug-info="$artifact_dir/symbols"
  cp -- build/app/outputs/bundle/release/app-release.aab "$artifact_dir/partybox-store.aab"
fi
cd -- "$artifact_dir"
if [[ $mode == test-release ]]; then sha256sum -- ./*.apk > SHA256SUMS;
else sha256sum -- ./*.aab > SHA256SUMS; fi
ls -lh -- "$artifact_dir"
