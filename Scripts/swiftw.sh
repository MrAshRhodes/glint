#!/usr/bin/env bash
#
# swiftw.sh - a thin wrapper around `swift` that adapts to the host toolchain.
#
#   Full Xcode installed     -> plain `swift <args>`
#   Command Line Tools only  -> `swift build|run|test --build-system native <args>`
#                               (the default Swift Build engine needs Xcode), and
#                               `swift test` also gets the compiler, linker and rpath
#                               flags that let it find Swift Testing inside the CLT.
#
# Every other invocation (`swift package ...`, `swift Scripts/foo.swift`, `swift --version`)
# and every extra argument is passed through untouched.
#
# Environment:
#   SWIFTW_MODE           auto (default) | xcode | clt    Override toolchain detection.
#   SWIFTW_BUILD_SYSTEM   native | swiftbuild | ...       Always pass --build-system <value>
#                                                         to build/run/test.
#   SWIFTW_VERBOSE=1      Print the final command to stderr.

set -euo pipefail

mode="${SWIFTW_MODE:-auto}"
case "$mode" in
  auto)
    if xcodebuild -version >/dev/null 2>&1; then mode=xcode; else mode=clt; fi
    ;;
  xcode | clt) ;;
  *)
    echo "swiftw: invalid SWIFTW_MODE '$mode' (expected auto, xcode or clt)" >&2
    exit 2
    ;;
esac

sub="${1:-}"
extra=()

case "$sub" in
  build | run | test)
    build_system="${SWIFTW_BUILD_SYSTEM:-}"
    if [[ -z "$build_system" && "$mode" == clt ]]; then
      build_system=native
    fi
    if [[ -n "$build_system" ]]; then
      explicit=0
      for arg in "$@"; do
        case "$arg" in
          --build-system | --build-system=*) explicit=1 ;;
        esac
      done
      if ((!explicit)); then
        extra+=(--build-system "$build_system")
      fi
    fi

    if [[ "$sub" == test && "$mode" == clt ]]; then
      clt_root="$(xcode-select -p 2>/dev/null || true)"
      if [[ ! -d "$clt_root" ]]; then
        clt_root=/Library/Developer/CommandLineTools
      fi
      frameworks="$clt_root/Library/Developer/Frameworks"
      usr_lib="$clt_root/Library/Developer/usr/lib"
      extra+=(
        -Xswiftc -F -Xswiftc "$frameworks"
        -Xlinker -F -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$usr_lib"
      )
    fi
    ;;
esac

if (($# == 0)); then
  exec swift
fi

cmd=(swift "$sub" ${extra[@]+"${extra[@]}"} "${@:2}")

if [[ "${SWIFTW_VERBOSE:-0}" == 1 ]]; then
  printf 'swiftw (%s):' "$mode" >&2
  printf ' %q' "${cmd[@]}" >&2
  printf '\n' >&2
fi

exec "${cmd[@]}"
