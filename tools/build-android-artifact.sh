#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build a Rusty V8 Android source artifact from the current repo checkout.

Usage:
  tools/build-android-artifact.sh [--ref <branch|tag|sha>] [--jobs <n>]

Environment overrides:
  RUST_TOOLCHAIN       Rust toolchain version to install/use. Default: 1.91.0
  TARGET_TRIPLE        Cargo target triple. Default: aarch64-linux-android
  ANDROID_API          Android API level used in the linker path. Default: 24
  NDK_VERSION          Android NDK version to download if missing. Default: r26c
  NDK_DIR              NDK install directory. Default: $HOME/.cache/android-ndk-r26c
  CACHE_DIR            sccache directory. Default: $HOME/.cache/rusty_v8/sccache
  SCCACHE_CACHE_SIZE   sccache size budget. Default: 250G
  LIBCLANG_PATH        libclang directory. Default: llvm-config --libdir or /usr/lib/llvm/lib
  SKIP_FETCH           Set to 1 to skip git fetch before checking out --ref

Artifacts:
  target/librusty_v8_release_<target>.a.gz
  target/src_binding_release_<target>.rs
EOF
}

REF=""
JOBS="${JOBS:-88}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      REF="${2:?missing value for --ref}"
      shift 2
      ;;
    --jobs)
      JOBS="${2:?missing value for --jobs}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 1
  fi
}

default_libclang_path() {
  if command -v llvm-config >/dev/null 2>&1; then
    llvm-config --libdir
  else
    printf '%s\n' /usr/lib/llvm/lib
  fi
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-1.91.0}"
TARGET_TRIPLE="${TARGET_TRIPLE:-aarch64-linux-android}"
ANDROID_API="${ANDROID_API:-24}"
NDK_VERSION="${NDK_VERSION:-r26c}"
NDK_DIR="${NDK_DIR:-$HOME/.cache/android-ndk-${NDK_VERSION}}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/rusty_v8/sccache}"
SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-250G}"
LIBCLANG_PATH="${LIBCLANG_PATH:-$(default_libclang_path)}"

require_cmd git
require_cmd curl
require_cmd unzip
require_cmd python3
require_cmd rustup
require_cmd cargo
require_cmd sccache

mkdir -p "$CACHE_DIR"
mkdir -p "$(dirname "$NDK_DIR")"

if [[ -n "$REF" ]]; then
  if [[ "${SKIP_FETCH:-0}" != "1" ]]; then
    git fetch --tags origin
  fi
  git checkout "$REF"
fi

git submodule update --init --recursive

rustup toolchain install "$RUST_TOOLCHAIN"
rustup target add --toolchain "$RUST_TOOLCHAIN" "$TARGET_TRIPLE"

if [[ ! -d "$NDK_DIR" ]]; then
  archive="$(dirname "$NDK_DIR")/android-ndk-${NDK_VERSION}-linux.zip"
  curl -L -o "$archive" \
    "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip"
  unzip -q "$archive" -d "$(dirname "$NDK_DIR")"
  rm -f "$archive"
fi

mkdir -p third_party
rm -rf third_party/android_ndk
ln -sfn "$NDK_DIR" third_party/android_ndk

linker="$ROOT_DIR/third_party/android_ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/${TARGET_TRIPLE}${ANDROID_API}-clang++"
if [[ ! -x "$linker" ]]; then
  echo "android linker not found: $linker" >&2
  exit 1
fi

export RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN"
export V8_FROM_SOURCE=1
export LIBCLANG_PATH
export ANDROID_NDK_HOME="$ROOT_DIR/third_party/android_ndk"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$linker"
export SCCACHE=sccache
export SCCACHE_DIR="$CACHE_DIR"
export SCCACHE_CACHE_SIZE
export SCCACHE_IDLE_TIMEOUT=0
export NUM_JOBS="$JOBS"
export CARGO_BUILD_JOBS="$JOBS"

sccache --start-server || true

cargo build -vv --locked --target "$TARGET_TRIPLE" --release

archive_path="target/librusty_v8_release_${TARGET_TRIPLE}.a.gz"
binding_path="target/src_binding_release_${TARGET_TRIPLE}.rs"

gzip -9c "target/${TARGET_TRIPLE}/release/gn_out/obj/librusty_v8.a" > "$archive_path"
cp "target/${TARGET_TRIPLE}/release/gn_out/src_binding.rs" "$binding_path"

echo "artifact: $archive_path"
echo "binding:  $binding_path"
