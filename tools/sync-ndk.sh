#!/usr/bin/env bash
# Re-resolve the pinned Android NDK, verify its recorded identity, and diff its
# own ABI table against the one this package ships.
#
#   tools/sync-ndk.sh              verify only; modifies nothing
#   tools/sync-ndk.sh --accept     re-record the hash after a human has read
#                                  the diff
#
# Why this exists: the ABI table in src/ndk.zig is a fact copied out of the
# NDK's own meta/abis.json. The NDK does not announce changes to that file, so
# nothing in the build graph invalidates a stale copy. A committed derived fact
# with no named enforcer is the illegitimate shape; this script is the enforcer.
# It is also the only thing standing between a silent NDK bump and a build that
# resolves sysroot paths which do not exist.
#
# WHAT IT DOES NOT CHECK, and who does. This script verifies the FACTS: the
# release, the revision, the archive digests, and that the ABI table this
# package ships matches the ABI table in the NDK it is pointed at. It does not
# verify that the tree it was pointed at is the one those bytes unpacked to --
# the 783 MB of sysroot binaries stay unbound to the archive, because binding
# them is `ndk-link-check`'s job and not this script's.
#
# That division is deliberate and it holds. Measured on a hand-made NDK whose
# metadata is copied verbatim from a real r29 and whose sysroot is an empty
# directory: this script passes it, and `ndk-link-check` refuses it with
# "'<sysroot>/usr/include/stdio.h' is not in this sysroot: FileNotFound".
# A forged NDK therefore has to satisfy two independent gates, and the one
# that actually uses the toolchain is the one that notices. Do not widen this
# script into a full-tree comparison to close the gap alone; that would put
# 783 MB of hashing in a gate that runs on every build, to defend against a
# threat the other gate already catches.
#
# It does NOT verify the libc paths file format in src/libc_file.zig. That is a
# Zig compiler fact, not an NDK fact, and it moves with the compiler rather than
# with Google. CHANGELOG.md p0004 says so in words as well, because "nothing
# enforces this" is itself a fact worth writing down.
#
# What is pinned, and how current it is. r29 is the first entry on Google's
# unsupported-downloads list: it is no longer a supported revision, though the
# URL still resolves and is still published, so the pin still works. The current
# LTS is r30 = 30.0.16248370 (2026-09-08), whose changelog is a clang bump, a
# simpleperf prebuilt refresh and a max-API of 37 -- no layout relocation, and no
# change to the ABI set or to any triple. The bump is expected to be cheap, and
# the one thing standing in front of it is the `min_os_version` handling below.
#
# Dependencies. Every external command this script runs is named here and
# checked below, in this order; nothing may be added without adding it here,
# because the guard has to run before the first of them:
#
#   bash dirname mktemp rm cp mv cat tr cut sort uname jq sed awk diff
#   sha256sum sha1sum wc unzip grep
#
# None of it is a GNU-only construct. The one rewrite sed could have owned goes
# through a temp file and a rename instead of `sed -i`, and the rest is POSIX
# spelling that BSD userland accepts unchanged.
#
# sha256sum and sha1sum are coreutils names. On a stock macOS box the names are
# `shasum -a 256` and `shasum -a 1`, so a host without coreutils on PATH is
# refused here, by name, rather than failing later with a raw command-not-found.
#
# Exit status: 0 when the NDK resolves and every check agrees; 1 when anything
# moved, when a fact could not be checked, or when the table extractor no longer
# understands src/ndk.zig. Never a silent pass.

set -euo pipefail

# Defined ahead of the guard because the guard is what names a missing tool, and
# a die() that cannot run names nothing. Both bodies are builtins only.
die() {
    printf 'sync-ndk: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: tools/sync-ndk.sh [--ndk <path>] [--zip <path>] [--accept]

  --ndk <path>   the unpacked NDK root to check. Either layout the library
                 recognises is accepted: the root itself, or the one a wrapper
                 keeps at <root>/libexec/android-sdk/ndk-bundle. Default: the
                 discovery order this package itself uses, $ANDROID_NDK_HOME,
                 $ANDROID_NDK_ROOT, $ANDROID_NDK.
  --zip <path>   the published NDK archive to hash. Default: $NDK_ZIP, then
                 <ndk>/../android-ndk-<release>-linux.zip, then a
                 /nix/store glob. The zip is what proves the release identity;
                 an unpacked tree proves only what its source.properties claims,
                 so the tree and the archive are required to agree before
                 anything is recorded.
  --accept       re-record release, revision, size and sha256 in
                 tools/ndk.sha256 once the ABI table agrees with the new NDK.
                 sha1 is written too, but it is Google's number rather than a
                 local one, so replacing it is a manual step. The file being
                 written is diffed first and then replaced by a single rename.
                 Review the diff first. Accepting does NOT update src/ndk.zig or
                 root.zig -- it cannot, and that work is yours.
EOF
}

# The guard runs before the first external command. ROOT is derived with dirname
# and WORK with mktemp, so a host missing either used to die with a bare
# "dirname: command not found" and exit 127, several lines above the one check
# whose entire job is to name the tool that is missing.
for tool in bash dirname mktemp rm cp mv cat tr cut sort uname jq sed awk \
    diff sha256sum sha1sum wc unzip grep; do
    command -v "$tool" >/dev/null 2>&1 ||
        die "$tool is required; this script cannot run without it"
done

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RECORD="$ROOT/tools/ndk.sha256"
TABLE="$ROOT/src/ndk.zig"

WORK=$(mktemp -d)

# The --accept rewrite stages its result beside the pin rather than inside
# $WORK, because a rename is atomic only within one filesystem and $WORK lives
# in TMPDIR. The same trap removes it, so an interrupted run leaves no
# half-written file sitting next to the pin.
RECORD_TMP=""
cleanup() {
    rm -rf "$WORK"
    if [ -n "$RECORD_TMP" ]; then
        rm -f "$RECORD_TMP"
    fi
    :
}
trap cleanup EXIT

NDK_ROOT=""
# $NDK_ZIP is read from the environment, which is what this script's usage text
# has always said it defaults to. An unconditional empty assignment made that a
# route the script did not offer: an exported NDK_ZIP was discarded here,
# before the search below could use it, and the usage text kept promising it.
# --zip still wins -- the argument loop assigns over this value.
NDK_ZIP=${NDK_ZIP:-}
ACCEPT=0

# One flag per path argument. `--ndk=` with nothing after it is a different
# request from "no --ndk at all", and the `[ -z "$NDK_ROOT" ]` tests below read
# them as the same one: an operator naming an empty path got a run that quietly
# verified a DIFFERENT NDK from the environment, and it exited 0.
NDK_ROOT_SET=0
NDK_ZIP_SET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --ndk)
            [ $# -ge 2 ] || die "--ndk needs a path"
            NDK_ROOT=$2
            NDK_ROOT_SET=1
            shift 2
            ;;
        --ndk=*)
            NDK_ROOT=${1#--ndk=}
            NDK_ROOT_SET=1
            shift
            ;;
        --zip)
            [ $# -ge 2 ] || die "--zip needs a path"
            NDK_ZIP=$2
            NDK_ZIP_SET=1
            shift 2
            ;;
        --zip=*)
            NDK_ZIP=${1#--zip=}
            NDK_ZIP_SET=1
            shift
            ;;
        --accept)
            ACCEPT=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
done

# Both spellings of both flags, so an empty operand is a refusal rather than a
# silent fall-through to the discovery order or to the /nix/store glob.
if [ "$NDK_ROOT_SET" -eq 1 ] && [ -z "$NDK_ROOT" ]; then
    die "--ndk was given with an empty value. Name the NDK root, or drop the flag and let the discovery order choose."
fi
if [ "$NDK_ZIP_SET" -eq 1 ] && [ -z "$NDK_ZIP" ]; then
    die "--zip was given with an empty value. Name the archive, or drop the flag and let the search below choose."
fi

[ -f "$RECORD" ] || die "missing $RECORD"
[ -f "$TABLE" ] || die "missing $TABLE; the ABI table this script diffs is not here"

# recorded <key> -> the value after "<key> = " in tools/ndk.sha256, or empty.
# awk rather than `sed | head`, because a short-lived head can hand sed a
# SIGPIPE and `set -o pipefail` would turn a successful read into a failure.
recorded() {
    awk -v k="$1" '
        index($0, k " = ") == 1 { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }
    ' "$RECORD"
}

PIN_RELEASE=$(recorded release)
PIN_REVISION=$(recorded revision)
PIN_SIZE=$(recorded size)
PIN_SHA=$(recorded sha256)
PIN_SHA1=$(recorded sha1)

# All five, because tools/ndk.sha256 promises them and CHANGELOG.md repeats
# them. `size` used to be optional: blanking or deleting its line took the
# check with it, silently, exit 0 -- so a fact the file recorded was not a fact
# the script required. A removed fact is a failure now, whichever one it is.
if [ -z "$PIN_RELEASE" ] || [ -z "$PIN_REVISION" ] || [ -z "$PIN_SIZE" ] ||
    [ -z "$PIN_SHA" ] || [ -z "$PIN_SHA1" ]; then
    printf 'sync-ndk: %s does not carry all five pinned facts.\n' "$RECORD" >&2
    for key in release revision size sha256 sha1; do
        if [ -z "$(recorded "$key")" ]; then
            printf '  missing: %s\n' "$key" >&2
        fi
    done
    printf '  Every one of the five is required. tools/ndk.sha256 records each\n' >&2
    printf '  of them as a fact an NDK bump has to revisit, so a missing one is\n' >&2
    printf '  a broken pin rather than an absent check.\n' >&2
    exit 1
fi

# --------------------------------------------------------------- host tag ---
#
# HostTag.directoryName, scraped out of src/ndk.zig the way the Abi accessors
# are scraped below: the on-disk spelling this script probes for has to be the
# one the library maps its tag to, and a second copy of that table here is a
# second thing to get wrong. Read before the tree is probed, because the probe
# is per host tag and the tag comes from this file.
awk '
    /^pub const HostTag = enum \{/ { in_host = 1; next }
    /^\};/                      { in_host = 0; next }
    in_host == 0                { next }
    /^[[:space:]]*pub fn directoryName\(/ { mode = 1; next }
    /^\}/                       { mode = 0; next }
    mode {
        arrow = index($0, "=>")
        if (arrow == 0) next
        head = substr($0, 1, arrow - 1)
        tail = substr($0, arrow + 2)
        # tail first: match() leaves the string it found in RSTART/RLENGTH,
        # and the head match below would overwrite it.
        if (!match(tail, /"[^"]*"/)) next
        value = substr(tail, RSTART + 1, RLENGTH - 2)
        first = match(head, /\.[A-Za-z_][A-Za-z0-9_]*/)
        if (first == 0) next
        tag = substr(head, first + 1)
        sub(/[^A-Za-z0-9_].*$/, "", tag)
        print tag "\t" value
    }
' "$TABLE" | LC_ALL=C sort >"$WORK/host-tags.tsv"

HOST_TAG_COUNT=$(wc -l <"$WORK/host-tags.tsv" | tr -d ' ')
if [ "$HOST_TAG_COUNT" -eq 0 ]; then
    die "scraped no host tag out of HostTag.directoryName in src/ndk.zig; the extractor no longer understands it"
fi

# The tag Ndk.hostTag() would return for the machine this script runs on. From
# uname rather than from a target triple: there is no Zig target here, and the
# host is the only fact a shell has. The OS/arch pairing is Ndk.hostTag()'s own
# table, so an OS or arch with no tag is refused in the same words the library
# refuses it in -- error.UnsupportedHost, which no -Dndk path can fix.
MACHINE_OS=$(uname -s)
MACHINE_ARCH=$(uname -m)
HOST_TAG=""
case "$MACHINE_OS" in
    Linux) HOST_TAG=linux_x86_64 ;;
    Darwin) HOST_TAG=darwin_x86_64 ;;
    MINGW* | MSYS* | CYGWIN*) HOST_TAG=windows_x86_64 ;;
esac

# `uname -m` on Apple Silicon reports arm64 natively and x86_64 under Rosetta.
# Both are the one macOS NDK package, so both are kept here.
case "$HOST_TAG:$MACHINE_ARCH" in
    linux_x86_64:x86_64 | darwin_x86_64:x86_64 | darwin_x86_64:arm64 | \
        darwin_x86_64:aarch64 | windows_x86_64:x86_64) ;;
    *) HOST_TAG="" ;;
esac

if [ -z "$HOST_TAG" ]; then
    printf 'sync-ndk: this machine has no Android NDK host tag.\n' >&2
    printf '  uname -s: %s\n' "$MACHINE_OS" >&2
    printf '  uname -m: %s\n' "$MACHINE_ARCH" >&2
    printf '  Ndk.hostTag() refuses this host with error.UnsupportedHost, which\n' >&2
    printf '  no --ndk path can fix. The tags this package serves:\n' >&2
    cut -f2 "$WORK/host-tags.tsv" | sed 's/^/    /' >&2
    exit 1
fi

HOST_DIR=$(awk -v t="$HOST_TAG" '$1 == t { print $2 }' "$WORK/host-tags.tsv")
if [ -z "$HOST_DIR" ]; then
    die "HostTag.directoryName in src/ndk.zig maps no tag to this machine ($HOST_TAG); it declares $HOST_TAG_COUNT tags and none of them is it"
fi

IDENTITY_OK=1
TABLE_OK=1

# ---------------------------------------------------------------- NDK root ---
#
# Same order, same variables, same precedence as the library's own discovery,
# and then the same two layouts, so a run of this script and a run of
# `zig build ndk-link-check` are talking about the same tree. Every path tried
# is named, in order, exactly as the NdkNotFound and describeProbeFailure
# messages do.
if [ -z "$NDK_ROOT" ]; then
    # The tried list is buffered, not printed as it goes, so a successful run
    # stays quiet. It is reported in full when nothing resolves, because the
    # whole cost of this design is an inherited variable beating a local
    # checkout and the reader has to be able to see which one won.
    declare -a TRIED=()
    FOUND=""
    for candidate in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK:-}"; do
        if [ -z "$candidate" ]; then
            TRIED+=("<unset>")
        elif [ -d "$candidate" ]; then
            TRIED+=("$candidate")
            FOUND=$candidate
            break
        elif [ -L "$candidate" ] && [ ! -e "$candidate" ]; then
            TRIED+=("$candidate   (a symlink that does not resolve)")
        else
            TRIED+=("$candidate   (not a directory)")
        fi
    done
    if [ -z "$FOUND" ]; then
        printf 'sync-ndk: no NDK root. Tried, in this order:\n' >&2
        printf '  1. %-20s %s\n' "--ndk <path>" "not supplied" >&2
        for index in 0 1 2; do
            case $index in
                0) varname=ANDROID_NDK_HOME ;;
                1) varname=ANDROID_NDK_ROOT ;;
                *) varname=ANDROID_NDK ;;
            esac
            printf '  %s. %-20s %s\n' "$((index + 2))" "$varname" \
                "$(printf '%s' "${TRIED[$index]}" | tr '\n' '|')" >&2
        done
        printf '  Give it an unpacked NDK two ways: --ndk <path>, or any of\n' >&2
        printf '  ANDROID_NDK_HOME / ANDROID_NDK_ROOT / ANDROID_NDK above.\n' >&2
        printf '  NDK_ZIP is not one of them: it names the published archive\n' >&2
        printf '  to hash against the pin, not the tree to probe.\n' >&2
        exit 1
    fi
    NDK_ROOT=$FOUND
    printf 'NDK root: %s (from discovery)\n' "$NDK_ROOT"
else
    [ -d "$NDK_ROOT" ] || die "$NDK_ROOT is not a directory"
    printf 'NDK root: %s\n' "$NDK_ROOT"
fi

# Where the archive search starts. Kept before the layout probe below, which
# may move NDK_ROOT one level down into a wrapper's libexec/android-sdk, and
# the zip a human downloaded sits beside the directory they pointed --ndk at.
NDK_SEARCH_ROOT=$NDK_ROOT

# ---------------------------------------------------- is this an NDK at all ---
#
# Ndk.open probes two layouts and refuses with error.NotAnNdk when neither
# holds; this probes the same two, for the same host tag, so a tree this script
# accepts is a tree the library accepts. Checking for source.properties alone
# accepted a directory holding nothing but that one file and meta/abis.json --
# which the library refuses, and which is what a half-unpacked tree and a
# wrapper's outer directory both look like. It also died naming the wrong reason
# for the layout nixpkgs' androidenv produces, which is "the layout a Nix user
# actually has" by src/ndk.zig's own description.
SYSROOT_REL="toolchains/llvm/prebuilt/$HOST_DIR/sysroot"
BUNDLE_REL="libexec/android-sdk/ndk-bundle"
PROBED_DIRECT="$NDK_ROOT/$SYSROOT_REL"
PROBED_BUNDLE="$NDK_ROOT/$BUNDLE_REL/$SYSROOT_REL"

if [ -d "$PROBED_DIRECT" ]; then
    NDK_SHAPE=direct
elif [ -d "$PROBED_BUNDLE" ]; then
    NDK_SHAPE=ndk_bundle
    NDK_ROOT="$NDK_ROOT/$BUNDLE_REL"
else
    printf 'sync-ndk: not an unpacked Android NDK root.\n' >&2
    printf '  pointed at: %s\n' "$NDK_ROOT" >&2
    printf '  neither probed path holds a sysroot for host tag %s (%s):\n' \
        "$HOST_TAG" "$HOST_DIR" >&2
    printf '    1. direct:      %s\n' "$PROBED_DIRECT" >&2
    printf '    2. ndk_bundle:  %s\n' "$PROBED_BUNDLE" >&2
    printf '  Those are the two layouts Ndk.Shape names, direct first, and the\n' >&2
    printf '  two Ndk.probeCandidates probes. An SDK root, an archive, or a\n' >&2
    printf '  wrapper directory is not either of them.\n' >&2
    exit 1
fi

# A directory called sysroot is not a sysroot. The probe above asks whether the
# path exists, so a stub holding two copied metadata files -- source.properties
# and meta/abis.json, both taken from a real NDK, and nothing else -- was
# accepted here and then had its ABI table diffed as if it were the NDK. A real
# sysroot carries what every path this package builds is built from: usr/include
# for the headers, usr/lib/<triple> for the libc.
SYSROOT="$NDK_ROOT/$SYSROOT_REL"
if [ ! -d "$SYSROOT/usr/include" ] && [ ! -d "$SYSROOT/usr/lib" ]; then
    printf 'sync-ndk: %s is not a sysroot.\n' "$SYSROOT" >&2
    printf '  It holds neither usr/include nor usr/lib, so it is a directory at\n' >&2
    printf '  the right path and nothing else -- which is exactly the shape a\n' >&2
    printf '  two-file stub copied out of a real NDK has, and the shape this\n' >&2
    printf '  script cannot tell from an NDK by reading metadata alone.\n' >&2
    exit 1
fi

# This is also the "is the host tag this machine resolves to actually in this
# NDK" check, which is the check that catches an NDK unpacked for another host:
# there is no sysroot for this machine to have found.
printf 'shape:     %s, NDK root %s\n' "$NDK_SHAPE" "$NDK_ROOT"

# ------------------------------------------------- which hosts this NDK ships ---
#
# CHANGELOG.md p0008 says the host-tag set cannot be checked from here, because
# "the manifest is not in the NDK tree and the script only reads files under the
# NDK root". That is true of Google's download manifest and false of the
# artefact that matters: toolchains/llvm/prebuilt/ holds exactly the host
# packages this archive was built to ship. r29 for linux-x86_64 holds one entry,
# linux-x86_64, and the script already holds its parent.
PREBUILT="$NDK_ROOT/toolchains/llvm/prebuilt"
[ -d "$PREBUILT" ] || die "$PREBUILT not found, so this tree carries no LLVM toolchain"

: >"$WORK/shipped-tags.tsv"
for entry in "$PREBUILT"/*; do
    [ -d "$entry" ] || continue
    printf '%s\n' "${entry##*/}" >>"$WORK/shipped-tags.tsv"
done
LC_ALL=C sort -o "$WORK/shipped-tags.tsv" "$WORK/shipped-tags.tsv"

# No "and it holds no host package at all" branch here, because there is no
# state that reaches it: the sysroot probe above has already required
# toolchains/llvm/prebuilt/$HOST_DIR to exist, and none of the three directory
# names HostTag maps its tags to begins with a dot, so the glob always matches
# at least the machine's own host. The old zero test could only fire in a state
# the probe had already refused, so it read as a check and was not one.

# One direction: the NDK ships a host this package does not declare. Nothing
# scraped out of src/ndk.zig can see that, and it is the drift that leaves
# error.UnsupportedHost firing on an arm64 Linux host the day Google starts
# publishing linux-arm64 while HostTag stays at three entries.
UNDECLARED=$(awk -F'\t' 'NR == FNR { declared[$2] = 1; next } !($0 in declared)' \
    "$WORK/host-tags.tsv" "$WORK/shipped-tags.tsv")
if [ -n "$UNDECLARED" ]; then
    printf 'host tags CHANGED: this NDK ships a prebuilt toolchain for a host\n' >&2
    printf 'src/ndk.zig HostTag does not declare.\n' >&2
    printf '  under %s:\n' "$PREBUILT" >&2
    sed 's/^/    /' "$WORK/shipped-tags.tsv" >&2
    printf '  HostTag.directoryName declares:\n' >&2
    cut -f2 "$WORK/host-tags.tsv" | sed 's/^/    /' >&2
    printf '  shipped but not declared:\n' >&2
    printf '%s\n' "$UNDECLARED" | sed 's/^/    /' >&2
    printf '  Add the tag to HostTag in src/ndk.zig -- a tag that is missing\n' >&2
    printf '  there turns a real NDK into error.UnsupportedHost for its users.\n' >&2
    exit 1
fi

# The other direction is the probe above: this machine's own tag has to be
# present or there is nothing to diff. Both sets are printed so the shipped set
# is visible on every run rather than only when it is wrong.
shipped_list=$(awk '{ printf "%s%s", sep, $0; sep = ", " } END { print "" }' "$WORK/shipped-tags.tsv")
declared_list=$(awk -F'\t' '{ printf "%s%s", sep, $2; sep = ", " } END { print "" }' "$WORK/host-tags.tsv")
printf 'host tags:  NDK ships [%s]; HostTag declares [%s]; this machine is %s (%s)\n' \
    "$shipped_list" "$declared_list" "$HOST_TAG" "$HOST_DIR"

PROPS="$NDK_ROOT/source.properties"
[ -f "$PROPS" ] ||
    die "$PROPS not found; the sysroot is there but the NDK metadata beside it is not"

# --------------------------------------------------------------- revision ---
#
# The revision is what the NDK says about itself. Necessary, and not sufficient:
# a tree can carry any source.properties a packager wrote, which is why the
# archive hash below exists alongside it.
GOT_RELEASE=$(sed -n 's/^Pkg\.ReleaseName = //p' "$PROPS" | sed -n '$p')
GOT_REVISION=$(sed -n 's/^Pkg\.Revision = //p' "$PROPS" | sed -n '$p')

if [ -n "$GOT_RELEASE" ] && [ -n "$GOT_REVISION" ] &&
    [ "$GOT_RELEASE" = "$PIN_RELEASE" ] && [ "$GOT_REVISION" = "$PIN_REVISION" ]; then
    printf 'revision:  %s (%s) matches the pin\n' "$GOT_REVISION" "$GOT_RELEASE"
else
    printf 'revision CHANGED\n' >&2
    printf '  recorded: %s (%s)\n' "$PIN_REVISION" "$PIN_RELEASE" >&2
    printf '  found:    %s (%s)\n' "$GOT_REVISION" "$GOT_RELEASE" >&2
    IDENTITY_OK=0
fi

# -------------------------------------------------------------------- zip ---
#
# The archive hash is the release identity. Without it the revision line above
# is only a self-report, so a missing archive is a failure and never a skipped
# check.
if [ -z "$NDK_ZIP" ]; then
    # The glob is spelled as a quoted prefix, an unquoted star, and a quoted
    # pattern. `${PIN_RELEASE}` comes straight out of tools/ndk.sha256 and used
    # to be pasted into the pattern unquoted, where a space in the value
    # word-splits it; and a pattern that matches nothing is precisely the
    # "this check quietly checks nothing" failure the rest of this script
    # refuses to allow.
    for candidate in \
        "$NDK_SEARCH_ROOT/../android-ndk-${PIN_RELEASE}-linux.zip" \
        "/nix/store/"*"android-ndk-${PIN_RELEASE}-linux.zip"; do
        if [ -f "$candidate" ]; then
            NDK_ZIP=$candidate
            break
        fi
    done
fi

if [ -z "$NDK_ZIP" ] || [ ! -f "$NDK_ZIP" ]; then
    printf 'sync-ndk: release identity NOT verified: no NDK archive found.\n' >&2
    # An explicit --zip that names a directory is an error about THAT path, not
    # a search that came up empty. Listing the three defaults it never looked
    # at sent the reader looking for a download instead of reading the path they
    # typed.
    if [ "$NDK_ZIP_SET" -eq 1 ]; then
        if [ -d "$NDK_ZIP" ]; then
            printf '  --zip names a directory, not an archive: %s\n' "$NDK_ZIP" >&2
        else
            printf '  --zip names no readable file: %s\n' "$NDK_ZIP" >&2
        fi
    else
        printf '  Tried, in this order:\n' >&2
        printf '    1. --zip <path>\n' >&2
        printf '    2. %s\n' "$NDK_SEARCH_ROOT/../android-ndk-${PIN_RELEASE}-linux.zip" >&2
        printf '    3. /nix/store/*android-ndk-%s-linux.zip\n' "$PIN_RELEASE" >&2
    fi
    # The name the SEARCH builds is the pinned release's, so a tree from a
    # different release cannot have one under that name -- and that is the bump
    # this gate exists to police, not a missing download. Say which of the two
    # it is, because "no archive found" on its own sends the person doing the
    # bump looking for a download that was never wrong. (With --zip given, the
    # question was never a search, and the line above already answered it.)
    if [ "$GOT_RELEASE" != "$PIN_RELEASE" ]; then
        printf '  The tree at the NDK root reports %s (%s) and the pin records\n' "$GOT_RELEASE" "$GOT_REVISION" >&2
        printf '  %s (%s): the archive is named after the pinned release, so a\n' "$PIN_RELEASE" "$PIN_REVISION" >&2
        printf '  bumped tree has none under that name. Move the URL in\n' >&2
        printf '  .github/workflows/ci.yml and re-record this pin for it.\n' >&2
    else
        printf '  The tree at the NDK root reports %s (%s), the release this pin\n' "$GOT_RELEASE" "$GOT_REVISION" >&2
        printf '  records, so the archive is genuinely not beside it.\n' >&2
    fi
    printf '  An unpacked tree can assert its own revision; only the published\n' >&2
    printf '  archive proves which release that revision came from. Re-run with\n' >&2
    printf '  --zip <path-to-android-ndk-%s-linux.zip>.\n' "$PIN_RELEASE" >&2
    exit 1
fi

printf 'zip:       %s\n' "$NDK_ZIP"

GOT_SIZE=$(wc -c <"$NDK_ZIP" | tr -d ' ')
# `<file`, not `<$file`: coreutils prefixes the digest with a backslash when the
# name it prints needs escaping -- a newline or a backslash in the path -- so the
# argv form yields `\4abbbcdc...` and a bit-identical archive reads as CHANGED on
# both digests. With stdin there is no name to escape and the output is
# `<digest>  -`, which is what `cut -d' ' -f1` expects.
GOT_SHA=$(sha256sum <"$NDK_ZIP" | cut -d' ' -f1)
GOT_SHA1=$(sha1sum <"$NDK_ZIP" | cut -d' ' -f1)

if [ "$GOT_SHA" = "$PIN_SHA" ]; then
    printf 'sha256:    matches the pin (computed here; Google publishes no SHA-256)\n'
else
    printf 'sha256 CHANGED\n' >&2
    printf '  recorded: %s\n' "$PIN_SHA" >&2
    printf '  fetched:  %s\n' "$GOT_SHA" >&2
    IDENTITY_OK=0
fi

# The one digest in this file that is actually from the publisher. Google's NDK
# metadata (repository2-3.xml, and the unsupported-downloads wiki) carries SHA-1
# and nothing else -- a case-insensitive search for "sha256" across that XML
# returns zero hits -- so the SHA-256 above is a locally computed value and is
# labelled as one. This is the check against the publisher's own number, and it
# needs no network: the digest is recorded here, in the pin, and compared
# locally. Nothing in this script fetches anything.
if [ "$GOT_SHA1" = "$PIN_SHA1" ]; then
    printf 'sha1:      %s matches the publisher digest in the pin\n' "$GOT_SHA1"
else
    printf 'sha1 CHANGED\n' >&2
    printf '  recorded: %s (from Google repository2-3.xml)\n' "$PIN_SHA1" >&2
    printf '  fetched:  %s\n' "$GOT_SHA1" >&2
    printf '  This is the only digest here that the publisher itself states.\n' >&2
    IDENTITY_OK=0
fi

if [ "$GOT_SIZE" != "$PIN_SIZE" ]; then
    printf 'size CHANGED\n' >&2
    printf '  recorded: %s\n' "$PIN_SIZE" >&2
    printf '  fetched:  %s\n' "$GOT_SIZE" >&2
    IDENTITY_OK=0
fi

# -------------------------------------------------------- tree to archive ---
#
# A hash pins bytes. Nothing inside those bytes says which tree was unpacked out
# of them, so `--ndk <tree A> --zip <archive B>` hashed B, diffed A's metadata,
# and printed one coherent "pin holds" for two different NDKs. The halves have
# to be the same release, so read the archive's own source.properties and
# require both facts to agree with the tree's.
#
# The extraction is the one .github/workflows/ci.yml already does at its
# provision step -- `unzip -p <zip> '*/source.properties'` rather than trusting
# the archive's file name -- and `sort -u` is here for the reason it is there:
# an archive holding two source.properties that disagree has no single tree to
# compare against, and "several answers" is a failure, not a value to pick from.
ARCHIVE_PROPS="$WORK/archive-source.properties"
if ! unzip -p "$NDK_ZIP" '*/source.properties' >"$ARCHIVE_PROPS" 2>"$WORK/unzip.err"; then
    printf 'sync-ndk: the archive carries no source.properties, so the tree it\n' >&2
    printf 'came from cannot be tied to it. Archive: %s\n' "$NDK_ZIP" >&2
    cat "$WORK/unzip.err" >&2
    exit 1
fi
[ -s "$ARCHIVE_PROPS" ] ||
    die "$NDK_ZIP extracts an empty source.properties; it is not an NDK archive at all"

ARCHIVE_RELEASE=$(sed -n 's/^Pkg\.ReleaseName[[:space:]]*=[[:space:]]*//p' "$ARCHIVE_PROPS" | LC_ALL=C sort -u)
ARCHIVE_REVISION=$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$ARCHIVE_PROPS" | LC_ALL=C sort -u)

# $( ) has already dropped the trailing newline, so a second distinct value is
# an embedded newline and an absent one is empty. Either way there is no single
# answer, and an answer that is missing is not an answer that agrees.
ARCHIVE_RELEASE_LINES=$(printf '%s\n' "$ARCHIVE_RELEASE" | wc -l | tr -d ' ')
ARCHIVE_REVISION_LINES=$(printf '%s\n' "$ARCHIVE_REVISION" | wc -l | tr -d ' ')
if [ -z "$ARCHIVE_RELEASE" ] || [ -z "$ARCHIVE_REVISION" ] ||
    [ "$ARCHIVE_RELEASE_LINES" -ne 1 ] || [ "$ARCHIVE_REVISION_LINES" -ne 1 ]; then
    printf 'sync-ndk: the archive does not carry exactly one identity to compare.\n' >&2
    printf '  archive: %s\n' "$NDK_ZIP" >&2
    printf '  Pkg.ReleaseName: %s\n' "$(printf '%s' "$ARCHIVE_RELEASE" | tr '\n' '|')" >&2
    printf '  Pkg.Revision:    %s\n' "$(printf '%s' "$ARCHIVE_REVISION" | tr '\n' '|')" >&2
    printf '  Each must appear in exactly one copy inside the archive.\n' >&2
    exit 1
fi

if [ "$GOT_RELEASE" = "$ARCHIVE_RELEASE" ] && [ "$GOT_REVISION" = "$ARCHIVE_REVISION" ]; then
    printf 'tie:       tree and archive agree on %s (%s)\n' "$GOT_RELEASE" "$GOT_REVISION"
else
    printf 'tree/archive TIE BROKEN: this tree did not come out of this archive.\n' >&2
    printf '  %-9s %-16s %-16s %s\n' fact tree archive pin >&2
    printf '  %-9s %-16s %-16s %s\n' release \
        "$GOT_RELEASE" "$ARCHIVE_RELEASE" "$PIN_RELEASE" >&2
    printf '  %-9s %-16s %-16s %s\n' revision \
        "$GOT_REVISION" "$ARCHIVE_REVISION" "$PIN_REVISION" >&2
    printf '  tree:    %s\n' "$NDK_ROOT" >&2
    printf '  archive: %s\n' "$NDK_ZIP" >&2
    printf '  The pin in tools/ndk.sha256 covers the archive. A tree that\n' >&2
    printf '  disagrees with it is a different NDK, and --accept is refused\n' >&2
    printf '  here on purpose: accepting would record one tree self-report\n' >&2
    printf '  beside the other hash, and no check here could see that after.\n' >&2
    exit 1
fi

# The same tie, for the file every diff below is computed from. The archive's
# own meta/abis.json sits inside the very zip whose digest was just verified and
# was never read: source.properties is a self-report, and comparing two
# self-reports binds the tree's NAME to the archive, not the tree's CONTENTS.
# So a tree whose abis.json was edited -- llvm_triple retargeted, bitness
# rewritten, an ABI deleted -- still agreed with the archive on everything the
# old tie looked at, and the diff below then reported it as NDK drift against
# metadata the digests cover. Both sides are canonicalised with `jq -S .` so the
# comparison is of the JSON, not of its formatting or key order.
ARCHIVE_ABIS_RAW="$WORK/archive-abis.json.raw"
if ! unzip -p "$NDK_ZIP" '*/meta/abis.json' >"$ARCHIVE_ABIS_RAW" 2>"$WORK/unzip-abis.err"; then
    printf 'sync-ndk: the archive carries no meta/abis.json, so the table this\n' >&2
    printf 'script is about to diff cannot be tied to the bytes its digests\n' >&2
    printf 'cover. Archive: %s\n' "$NDK_ZIP" >&2
    cat "$WORK/unzip-abis.err" >&2
    exit 1
fi
ARCHIVE_ABIS="$WORK/archive-abis.json"
if ! jq -S . "$ARCHIVE_ABIS_RAW" >"$ARCHIVE_ABIS" 2>"$WORK/jq-archive.err"; then
    printf 'sync-ndk: the archive carries a meta/abis.json jq cannot parse.\n' >&2
    printf '  archive: %s\n' "$NDK_ZIP" >&2
    sed 's/^/  /' "$WORK/jq-archive.err" >&2
    exit 1
fi
ARCHIVE_ABIS_COPIES=$(jq -s 'length' "$ARCHIVE_ABIS_RAW")
if [ "$ARCHIVE_ABIS_COPIES" -ne 1 ]; then
    die "$NDK_ZIP holds $ARCHIVE_ABIS_COPIES copies of meta/abis.json; there is no single table to tie the tree to"
fi
TREE_ABIS="$WORK/tree-abis.json"
if ! jq -S . "$NDK_ROOT/meta/abis.json" >"$TREE_ABIS" 2>"$WORK/jq-tree.err"; then
    printf 'sync-ndk: %s is not JSON this script can parse.\n' "$NDK_ROOT/meta/abis.json" >&2
    sed 's/^/  /' "$WORK/jq-tree.err" >&2
    exit 1
fi
if diff -q "$TREE_ABIS" "$ARCHIVE_ABIS" >/dev/null 2>&1; then
    printf 'abi tie:   tree and archive carry the same meta/abis.json\n'
else
    printf 'tree/archive ABI TIE BROKEN: this tree did not come out of this archive.\n' >&2
    printf '  tree:    %s\n' "$NDK_ROOT/meta/abis.json" >&2
    printf '  archive: %s\n' "$NDK_ZIP" >&2
    printf '  archive is on the left, tree on the right. This is not NDK drift:\n' >&2
    printf '  the digests above cover the archive, and the table this script\n' >&2
    printf '  diffs src/ndk.zig against is the archive'"'"'s, not the tree'"'"'s.\n' >&2
    diff -u "$ARCHIVE_ABIS" "$TREE_ABIS" >&2 || true
    exit 1
fi

# --------------------------------------------------------------- ABI table ---
#
# Expected, straight from the NDK. Columns are <tag> <abi name> <triple> <min
# api>, where <tag> is the Zig identifier the enum spells and <abi name> is the
# meta/abis.json key the NDK spells; keeping both means the diff reports a
# renamed ABI as well as a retargeted triple.
ABIS="$NDK_ROOT/meta/abis.json"
[ -f "$ABIS" ] ||
    die "$ABIS not found; r29 and later ship it, and without it there is nothing to diff"

# `min_os_version` is a field that can disappear, and Google may yet delete it:
# an unguarded extractor reads an absent key as the string "null" and reports
# all five floors as changed when the NDK did nothing but drop it. That false
# alarm is the one direction that teaches people to ignore this script, so
# absence has to be handled -- but as a decision somebody recorded, never as a
# consequence of the file under test. This key can be deleted from a tree's
# meta/abis.json, and the probe used to ask `any(.[]; has(...))`: deleting it
# turned the floor check off and the run stayed green, so src/ndk.zig's
# 21/21/21/35/21 stopped being enforced with nothing said. The shape of the
# whole file decides, in three states:
#
#   all five carry it   the floor is compared, as before
#   none carries it     not compared, and only because someone recorded that
#                       decision: `# min_os_version: absent` in the pin file
#   some carry it       refused: a partial table has no floor to compare and no
#                       honest reading of "not cross-checked"
#
# jq's parse error is reported here, by name, before any conclusion is drawn
# from a file it could not read. The old probe swallowed it into the
# "declares no min_os_version" branch, printed that claim about a file that did
# not parse, and then died on jq's own exit code 5 -- a status this script's
# header does not document and no wrapper testing `== 1` expects.
if ! jq -e 'type == "object" and length > 0 and all(.[]; type == "object" and has("triple"))' \
    "$ABIS" >/dev/null 2>"$WORK/jq-shape.err"; then
    printf 'sync-ndk: %s is not a meta/abis.json this script understands.\n' "$ABIS" >&2
    printf 'Each ABI entry must be an object carrying a "triple". jq said:\n' >&2
    sed 's/^/  /' "$WORK/jq-shape.err" >&2
    exit 1
fi

if jq -e 'all(.[]; has("min_os_version"))' "$ABIS" >/dev/null 2>&1; then
    MIN_OS_PRESENT=1
    COLUMNS_DESC="<tag> <abi name> <triple> <min api>"
elif jq -e 'any(.[]; has("min_os_version"))' "$ABIS" >/dev/null 2>&1; then
    printf 'sync-ndk: %s carries min_os_version on some ABIs and not others.\n' "$ABIS" >&2
    printf 'A partial floor table has no value to compare and no honest reading\n' >&2
    printf 'of "not cross-checked", so it is refused rather than half applied.\n' >&2
    printf '  with the key:    %s\n' \
        "$(jq -r 'to_entries[] | select(.value | has("min_os_version")) | .key' "$ABIS" | LC_ALL=C sort | tr '\n' ' ')" >&2
    printf '  without the key: %s\n' \
        "$(jq -r 'to_entries[] | select(.value | has("min_os_version") | not) | .key' "$ABIS" | LC_ALL=C sort | tr '\n' ' ')" >&2
    exit 1
else
    if ! grep -q '^# min_os_version: absent' "$RECORD"; then
        printf 'sync-ndk: %s declares no min_os_version on any ABI, so the per-ABI\n' "$ABIS" >&2
        printf 'floor cannot be cross-checked -- and this run refuses to decide that\n' >&2
        printf 'for itself. Deleting one JSON key used to switch this check off in\n' >&2
        printf 'silence; it is now a decision someone has to record in %s:\n' "$RECORD" >&2
        printf '  # min_os_version: absent\n' >&2
        printf 'Add that line, say why in CHANGELOG.md, and run this again.\n' >&2
        exit 1
    fi
    MIN_OS_PRESENT=0
    COLUMNS_DESC="<tag> <abi name> <triple>"
fi

if [ "$MIN_OS_PRESENT" -eq 1 ]; then
    jq -r 'to_entries[]
        | [ (.key | gsub("-"; "_")), .key, .value.triple, (.value.min_os_version | tostring) ]
        | @tsv' "$ABIS" | LC_ALL=C sort >"$WORK/expected.tsv"
else
    jq -r 'to_entries[]
        | [ (.key | gsub("-"; "_")), .key, .value.triple ]
        | @tsv' "$ABIS" | LC_ALL=C sort >"$WORK/expected.tsv"
    printf 'min api:    this NDK declares no min_os_version on any ABI; the per-ABI floor is NOT cross-checked, as recorded in %s\n' "$RECORD"
fi

# Actual, scraped from the three accessors in src/ndk.zig. This is text
# extraction rather than a compiler run, so it depends on the shape of those
# three functions: each is a `pub fn <name>(` line ending at the next line that
# starts in column zero. A reshape of them is a change this script must be
# taught, and the count check below is what says so out loud.
awk -v tagfile="$WORK/declared.tsv" -v blindfile="$WORK/blind.txt" '
    # Scoped to the Abi enum on purpose. HostTag.directoryName is a DIFFERENT
    # function under a different name now — `Abi.directoryName` was renamed to
    # `Abi.name`, because an ABI name is a meta/abis.json key and not a path
    # component of sysroot/usr/lib, which is namespaced by triple. The scoping
    # below is what would catch a future `name` accessor appearing on another
    # type in the same file and contributing rows to the ABI table.
    /^pub const Abi = enum \{/  { in_abi = 1; next }
    /^\};/                     { in_abi = 0; next }
    in_abi == 0                { next }
    /^[[:space:]]*\/\//        { next }
    /^[[:space:]]*pub fn name\(/             { mode = "name";  next }
    /^[[:space:]]*pub fn triple\(/           { mode = "trip"; next }
    /^[[:space:]]*pub fn minApiLevel\(/      { mode = "min";  next }
    /^\}/                      { mode = "";      next }
    # The tag list of the enum itself. It is compared against the tags the
    # three accessors cover, because a tag deleted from the enum while its
    # switch arms stayed behind still scrapes clean and no longer compiles.
    mode == "" && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*,?[[:space:]]*$/ {
        declared_tag = $0
        sub(/^[[:space:]]*/, "", declared_tag)
        sub(/,?[[:space:]]*$/, "", declared_tag)
        if (declared_tag != "") declared[declared_tag] = 1
        next
    }
    mode != "" {
        arrow = index($0, "=>")
        if (arrow == 0) next
        head = substr($0, 1, arrow - 1)
        tail = substr($0, arrow + 2)
        # A grouped arm such as `.x86, .x86_64 => 21` is one line and two
        # tags, so the whole list between the first `.tag` and the arrow is
        # taken, not just the first name on it.
        first = match(head, /\.[A-Za-z_][A-Za-z0-9_]*/)
        if (first == 0) next
        ntags = split(substr(head, first), tags, ",")
        if (match(tail, /"[^"]*"/)) {
            value = substr(tail, RSTART + 1, RLENGTH - 2)
        } else if (match(tail, /[0-9]+/)) {
            value = substr(tail, RSTART, RLENGTH)
        } else {
            next
        }
        for (i = 1; i <= ntags; i++) {
            tag = tags[i]
            sub(/^[[:space:]]*[.]/, "", tag)
            sub(/[[:space:]]*$/, "", tag)
            if (tag == "") continue
            seen[tag] = 1
            if (mode == "name") name[tag] = value
            if (mode == "trip") trip[tag] = value
            if (mode == "min")  min[tag]  = value
        }
    }
    END {
        for (tag in seen) {
            # A row that scraped nothing is not a row the diff can read. The
            # counts still match, so a renamed accessor came out as a blank
            # column and was then reported as NDK drift for an edit made in
            # this repository. Named here instead, before anything is compared.
            if (name[tag] == "" || trip[tag] == "" || min[tag] == "") print tag > blindfile
            printf "%s\t%s\t%s\t%s\n", tag, name[tag], trip[tag], min[tag]
        }
        for (declared_tag in declared) print declared_tag > tagfile
        close(tagfile)
        close(blindfile)
    }
' "$TABLE" | LC_ALL=C sort >"$WORK/actual.tsv"

if [ -s "$WORK/blind.txt" ]; then
    printf 'sync-ndk: the extractor matched an ABI with an empty column in\n' >&2
    printf 'src/ndk.zig, so a diff below would report NDK drift for a rename made\n' >&2
    printf 'in this repository. Nothing was compared against the NDK.\n' >&2
    printf '  blind on: %s\n' "$(tr '\n' ' ' <"$WORK/blind.txt")" >&2
    exit 1
fi

# The other side of the same probe: with no floor to compare, the scraped floor
# column is dropped rather than diffed against nothing.
ACTUAL_FILE="$WORK/actual.tsv"
if [ "$MIN_OS_PRESENT" -eq 0 ]; then
    cut -f1-3 "$ACTUAL_FILE" >"$WORK/actual-no-min.tsv"
    ACTUAL_FILE="$WORK/actual-no-min.tsv"
fi

EXPECTED_COUNT=$(wc -l <"$WORK/expected.tsv" | tr -d ' ')
ACTUAL_COUNT=$(wc -l <"$WORK/actual.tsv" | tr -d ' ')

# A sweep that matched nothing and a sweep that matched everything look identical
# from here, so the counts are checked before the contents and a zero is a
# failure rather than an empty diff.
if [ "$EXPECTED_COUNT" -eq 0 ]; then
    die "parsed zero ABIs out of $ABIS; the NDK changed its own metadata format"
fi

if [ "$ACTUAL_COUNT" -ne "$EXPECTED_COUNT" ]; then
    printf 'ABI table CHANGED, or the extractor no longer understands src/ndk.zig\n' >&2
    printf '  meta/abis.json declares %s ABIs\n' "$EXPECTED_COUNT" >&2
    printf '  the three accessors yielded %s arms\n' "$ACTUAL_COUNT" >&2
    printf '  columns are %s:\n' "$COLUMNS_DESC" >&2
    diff -u "$WORK/expected.tsv" "$ACTUAL_FILE" >&2 || true
    TABLE_OK=0
elif ! diff -u "$WORK/expected.tsv" "$ACTUAL_FILE" >"$WORK/abi.diff"; then
    printf 'ABI table CHANGED against meta/abis.json\n' >&2
    cat "$WORK/abi.diff" >&2
    TABLE_OK=0
else
    # "exactly" is a claim about every compared column, so it is only said when
    # the per-ABI floor was one of them.
    if [ "$MIN_OS_PRESENT" -eq 1 ]; then
        printf 'abi table: %s ABIs in src/ndk.zig match meta/abis.json exactly\n' "$ACTUAL_COUNT"
    else
        printf 'abi table: %s ABIs in src/ndk.zig match meta/abis.json on tag, name and triple\n' "$ACTUAL_COUNT"
    fi
fi

# The enum's tag list and the tags its accessors cover have to be the same set.
# Without this, a tag deleted from the enum but left behind in all three
# switch arms still scrapes clean, still matches the NDK, and no longer
# compiles -- the one mutation the content diff above cannot see.
LC_ALL=C sort -u "$WORK/declared.tsv" >"$WORK/declared-sorted.tsv"
cut -f1 "$ACTUAL_FILE" >"$WORK/actual-tags.tsv"
if ! diff -u "$WORK/declared-sorted.tsv" "$WORK/actual-tags.tsv" >"$WORK/tags.diff"; then
    printf 'the Abi enum and its three accessors disagree about which ABIs exist\n' >&2
    cat "$WORK/tags.diff" >&2
    printf '  left: tags the enum declares   right: tags the accessors map\n' >&2
    TABLE_OK=0
else
    printf 'abi enum: %s declared tags, %s mapped tags\n' \
        "$(wc -l <"$WORK/declared-sorted.tsv" | tr -d ' ')" \
        "$(wc -l <"$WORK/actual-tags.tsv" | tr -d ' ')"
fi

# ----------------------------------------------------------------- summary ---

if [ "$TABLE_OK" -ne 1 ]; then
    printf '\nsync-ndk: refusing to record anything. The archive may or may not have\n' >&2
    printf 'moved, but src/ndk.zig does not yet describe this NDK, and a hash that\n' >&2
    printf 'promises a table the tree does not contain is worse than a stale one.\n' >&2
    printf '\n' >&2
    printf 'Update the Abi table in src/ndk.zig and the two comptime pins in\n' >&2
    printf 'root.zig by hand, then run this script again.\n' >&2
    exit 1
fi

if [ "$ACCEPT" -eq 1 ] && [ "$IDENTITY_OK" -ne 1 ]; then
    # One awk pass writes four facts into a staging file beside the pin, and one
    # rename puts it in place.
    #
    # `sed -i` would have been shorter and is not portable: BSD sed requires an
    # argument to -i and errors without one, so --accept was broken on
    # darwin_x86_64, a host this package claims. Four of them were also four
    # chances to be interrupted between edits, which leaves release and revision
    # new and sha256 stale -- the worst state a pin can be in, because nothing
    # in the file looks wrong and the next run reports a tree that matches the
    # archive's bytes and not this file.
    #
    # The staging file is a copy of the original rather than a fresh create, so
    # the rename lands with the permissions the file already had.
    RECORD_TMP="$RECORD.sync-ndk.tmp"
    cp "$RECORD" "$RECORD_TMP"
    awk -v release="$GOT_RELEASE" -v revision="$GOT_REVISION" \
        -v size="$GOT_SIZE" -v sha256="$GOT_SHA" '
        /^release = /  { print "release = " release;  next }
        /^revision = / { print "revision = " revision; next }
        /^size = /     { print "size = " size;      next }
        /^sha256 = /   { print "sha256 = " sha256;  next }
        { print }
    ' "$RECORD" >"$RECORD_TMP"

    # Show what is about to be written, before it is written. The ABI diff
    # printed earlier in this run is a diff of src/ndk.zig, which is a different
    # file from the one being changed; --accept is the only path in this script
    # that modifies anything, so the diff a maintainer authorises has to be this
    # one. The usage text says "review the diff first" and used to print the
    # other file's.
    if diff -u "$RECORD" "$RECORD_TMP" >"$WORK/record.diff"; then
        printf '\nsync-ndk: --accept has nothing to write.\n' >&2
        printf 'Every fact it does write in %s already equals what this NDK\n' "$RECORD" >&2
        printf 'resolves to, which is what the checks above say rather than a\n' >&2
        printf 'contradiction of them. The one that can still differ is sha1:\n' >&2
        printf 'it is not written here at all, because it is the publisher value\n' >&2
        printf 'and not one this machine computes. If it moved, replace that line\n' >&2
        printf 'by hand from repository2-3.xml. Nothing was modified.\n' >&2
        exit 1
    fi
    printf '\nabout to write %s. Left is on disk now, right is what this NDK\n' "$RECORD"
    printf 'resolves to. The ABI diff printed earlier is src/ndk.zig, not this file.\n'
    cat "$WORK/record.diff"

    mv -f "$RECORD_TMP" "$RECORD"
    RECORD_TMP=""

    printf '\naccepted. %s now records:\n' "$RECORD"
    printf '  release  %s\n  revision %s\n  size     %s\n  sha256   %s\n' \
        "$GOT_RELEASE" "$GOT_REVISION" "$GOT_SIZE" "$GOT_SHA"
    printf '\nsha1 was NOT written, and that is deliberate: this script does not\n'
    printf 'fetch it, so any value it computed would be its own number wearing\n'
    printf 'Google'"'"'s label. The line is left as recorded -- compare it with the\n'
    printf 'digest in repository2-3.xml and replace it by hand if it moved.\n'
    printf '\nThe ABI table already matched this NDK. Add an entry to CHANGELOG.md\n'
    printf 'saying what moved, and re-run this script with no flags to confirm.\n'
    exit 0
fi

if [ "$IDENTITY_OK" -ne 1 ]; then
    printf '\nsync-ndk: the pin in tools/ndk.sha256 no longer describes this NDK.\n' >&2
    printf 'The ABI table still matches, so this is an identity change only.\n' >&2
    printf 'Nothing was modified. Re-run with --accept to re-record it, and record\n' >&2
    printf 'in CHANGELOG.md what changed about the release. sha1 is the one\n' >&2
    printf 'value that came from the publisher; replace it from repository2-3.xml.\n' >&2
    exit 1
fi

if [ "$ACCEPT" -eq 1 ]; then
    printf '\nnothing moved; tools/ndk.sha256 already records %s\n' "$PIN_SHA"
    printf -- '--accept had nothing to write.\n'
    exit 0
fi

printf '\nsync-ndk: pin holds. release %s, revision %s, sha256 %s, sha1 %s.\n' \
    "$PIN_RELEASE" "$PIN_REVISION" "$PIN_SHA" "$PIN_SHA1"
printf 'Nothing was modified. Use --accept only after reviewing a real change.\n'
exit 0