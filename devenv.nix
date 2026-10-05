# devenv for the zig-ndk integration library.
#
# The library itself is pure Zig and needs only a 0.16.0 compiler. The rest of
# the package set exists so an NDK is reachable on this host without an Android
# Studio install: `androidndkPkgs_*` from nixpkgs is the supported route, and
# `ANDROID_NDK_HOME` is pointed at it below.
#
# A private global cache keeps this project off the shared ~/.cache/zig lock
# graph. Builds there convoy behind whichever process is wedged, and one stuck
# zls build-runner holds a manifest flock for hours.
{ pkgs, lib, ... }:

let
  # The NDK revision this package is developed and gated against. Changing it
  # is a compiler-record change: re-run `nix build` and the cross-target check.
  ndkPkgs = pkgs.androidndkPkgs_28;
in
{
  packages = with pkgs; [
    zig_0_16
    ndkPkgs.binaries
    jdk17
    binutils
    llvmPackages_latest
    cmake
    ninja
    pkg-config
    git
    gh
    jq
  ];

  env.ZIG_GLOBAL_CACHE_DIR = ".zig-global-cache";

  # NDK discovery reads ANDROID_NDK_HOME first, then ANDROID_NDK_ROOT, then
  # ANDROID_NDK. Point the first at the nixpkgs-provided NDK so a bare
  # `zig build` finds a sysroot without extra flags.
  env.ANDROID_NDK_HOME = "${ndkPkgs.binaries}";
  env.ANDROID_PLATFORM_VERSION = "android-28";

  enterShell = ''
    echo "zig-ndk devenv ready"
    echo "  zig:            $(zig version 2>/dev/null || echo missing)"
    echo "  ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
    echo "  gate:           zig build"
    echo "  check:          zig build check"
    echo "  test:           zig build test"
    echo "  cross:          zig build ndk-abi-check"
  '';

  scripts.gate.exec = "zig build";
  scripts.check.exec = "zig build check";
  scripts.test.exec = "zig build test";
  scripts.cross.exec = "zig build ndk-abi-check";
  scripts.fmt.exec = "zig fmt --check .";
}
