# devenv for the zig-ndk integration library.
#
# The library itself is pure Zig and needs only a 0.16.0 compiler. The NDK is
# the one heavy input, and it is fetched here rather than taken from nixpkgs'
# `androidndkPkgs_*` for two reasons, both found by execution on this host:
#
#   * `pkgs.androidndkPkgs_29` cannot even be evaluated on a linux build host.
#     It composes a package set whose *target* must be an Android triple, and
#     fails with "Android NDK doesn't support targetting x86_64-unknown-linux-gnu".
#   * The route that does evaluate, `androidenv.composeAndroidPackages`, lands
#     the NDK under an unfree licence gate, so it also needs `allowUnfree`.
#     This devenv's module system has no `allowUnfree` option to set.
#
# Fetching Google's own zip by pinned hash sidesteps both, and puts the pin
# where a reviewer can read it. The same four facts are recorded for
# `tools/sync-ndk.sh` to re-check in tools/ndk.sha256.
#
# A private global cache keeps this project off the shared ~/.cache/zig lock
# graph. Builds there convoy behind whichever process is wedged, and one stuck
# zls build-runner holds a manifest flock for hours.
{ pkgs, config, ... }:

let
  # Changing either of these is a compiler-record change: re-run `nix build`
  # and the cross-ABI and link gates.
  ndkUrl = "https://dl.google.com/android/repository/android-ndk-r29-linux.zip";
  ndkHash = "sha256-Sru83IQvPUh5IG6WldUnCWA+Ut1o08H/8Es7Xnowjs8=";

  # `fetchurl`, not `fetchzip`: `fetchzip` hashes the UNPACKED tree, so the
  # value below (a plain SHA-256 of the published zip, the same one recorded in
  # tools/ndk.sha256) is rejected with
  #   specified: sha256-Sru83IQvPUh5IG6WldUnCWA+Ut1o08H/8Es7Xnowjs8=
  #   got:      sha256-DNmViXMysUrXpD7iLhfCmIXMiRs9asaRS2eL7vEWcB0=
  # and the whole shell fails to realise. `fetchurl` hashes the downloaded file
  # itself, which is what tools/ndk.sha256 and `tools/sync-ndk.sh` verify.
  ndkZip = pkgs.fetchurl {
    url = ndkUrl;
    hash = ndkHash;
  };

  # The zip holds a single top-level `android-ndk-r29/`, and the sysroot this
  # package compiles against is at
  #   <out>/toolchains/llvm/prebuilt/<host-tag>/sysroot
  ndk = pkgs.runCommand "android-ndk-r29" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    mkdir -p extracted
    unzip -q ${ndkZip} -d extracted
    mv extracted/*/ $out
    chmod -R u+w $out
    # The NDK's own build scripts exec bit, which the zip preserves but
    # runCommand's restrictive umask can drop.
    chmod +x $out/ndk-build $out/ndk-gdb $out/ndk-lldb $out/ndk-stack \
             $out/ndk-which $out/wrap.sh 2>/dev/null || true
  '';
in
{
  # Everything is nested under an explicit `config` because `config` is in
  # scope: devenv rejects the shorthand top-level form in that case, with
  # "unsupported attribute ... caused by introducing a top-level `config`".
  config = {
    packages = with pkgs; [
      zig_0_16
      ndk
      binutils
      # `llvmPackages_latest` and `llvmPackages_latest.bintools` are attribute
      # sets, not derivations; devenv's `packages` option rejects both with
      # "not of type `package`". `binutils` alone is the LLVM tool this project
      # needs, to read the ELF headers of what the link gate produces.
      cmake
      ninja
      pkg-config
      gh
      jq
      unzip
    ];

    env = {
      # Absolute, not relative. A relative value resolves against whatever
      # directory a `zig` invocation happens to run in, so `zig build` from a
      # subdirectory lands back in the shared ~/.cache/zig lock graph — the
      # exact convoy the private cache exists to avoid. CI sets the same
      # directory in absolute form.
      ZIG_GLOBAL_CACHE_DIR = "${builtins.toString ./.}/.zig-global-cache";

      # NDK discovery reads ANDROID_NDK_HOME first, then ANDROID_NDK_ROOT, then
      # ANDROID_NDK. Pointing the first here means a bare `zig build` finds a
      # sysroot without extra flags. Note the value is the NDK root itself, so
      # discovery takes its direct shape rather than the nixpkgs
      # `libexec/android-sdk/ndk-bundle` one.
      ANDROID_NDK_HOME = "${ndk}";
    };

    enterShell = ''
      echo "zig-ndk devenv ready"
      echo "  zig:              $(zig version 2>/dev/null || echo missing)"
      echo "  ANDROID_NDK_HOME: $ANDROID_NDK_HOME"
      echo "  test:             zig build test"
      echo "  check:            zig build check"
      echo "  cross:            zig build ndk-abi-check"
      echo "  link:             zig build ndk-link-check"
    '';

    scripts.test.exec = "zig build test";
    scripts.check.exec = "zig build check";
    scripts.cross.exec = "zig build ndk-abi-check";
    scripts.link.exec = "zig build ndk-link-check";
    # The gate, not a tree walk: build.zig's `fmt-check` uses an explicit
    # path allowlist, so `zig fmt --check .` here can trip on files the gate
    # deliberately ignores and can disagree with the command CI runs.
    scripts.fmt.exec = "zig build fmt-check";
  };
}
