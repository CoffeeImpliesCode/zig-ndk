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
# It does NOT verify the libc paths file format in src/libc_file.zig. That is a
# Zig compiler fact, not an NDK fact, and it moves with the compiler rather than
# with Google. CHANGELOG.md p0004 says so in words as well, because "nothing
# enforces this" is itself a fact worth writing down.
#
# Dependencies: bash, jq, sed, awk, diff, sha256sum, wc.
#
# Exit status: 0 when the NDK resolves and every check agrees; 1 when anything
# moved, when a fact could not be checked, or when the table extractor no longer
# understands src/ndk.zig. Never a silent pass.

set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RECORD="$ROOT/tools/ndk.sha256"
TABLE="$ROOT/src/ndk.zig"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

die() {
    printf 'sync-ndk: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: tools/sync-ndk.sh [--ndk <path>] [--zip <path>] [--accept]

  --ndk <path>   the unpacked NDK root to check. Default: the discovery order
                 this package itself uses, $ANDROID_NDK_HOME,
                 $ANDROID_NDK_ROOT, $ANDROID_NDK.
  --zip <path>   the published NDK archive to hash. Default: $NDK_ZIP, then
                 <ndk>/../android-ndk-<release>-linux.zip, then a
                 /nix/store glob. The zip is what proves the release identity;
                 an unpacked tree proves only what its source.properties claims.
  --accept       re-record release, revision, size and sha256 in
                 tools/ndk.sha256 once the ABI table agrees with the new NDK.
                 Review the diff first. Accepting does NOT update src/ndk.zig or
                 root.zig -- it cannot, and that work is yours.
EOF
}

NDK_ROOT=""
NDK_ZIP=""
ACCEPT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --ndk)
            [ $# -ge 2 ] || die "--ndk needs a path"
            NDK_ROOT=$2
            shift 2
            ;;
        --ndk=*)
            NDK_ROOT=${1#--ndk=}
            shift
            ;;
        --zip)
            [ $# -ge 2 ] || die "--zip needs a path"
            NDK_ZIP=$2
            shift 2
            ;;
        --zip=*)
            NDK_ZIP=${1#--zip=}
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

for tool in jq sed awk diff sha256sum wc; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

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

if [ -z "$PIN_RELEASE" ] || [ -z "$PIN_REVISION" ] || [ -z "$PIN_SHA" ]; then
    die "$RECORD does not carry release, revision and sha256"
fi

IDENTITY_OK=1
TABLE_OK=1

# ---------------------------------------------------------------- NDK root ---
#
# Same order, same variables, same precedence as the library's own discovery, so
# a run of this script and a run of `zig build ndk-link-check` are talking about
# the same tree. Every path tried is named, in order, exactly as the
# NdkNotFound message does.
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
            printf '  %s. %-20s %s\n' "$((index + 2))" "$varname" "${TRIED[$index]}" >&2
        done
        exit 1
    fi
    NDK_ROOT=$FOUND
    printf 'NDK root: %s (from discovery)\n' "$NDK_ROOT"
else
    [ -d "$NDK_ROOT" ] || die "$NDK_ROOT is not a directory"
    printf 'NDK root: %s\n' "$NDK_ROOT"
fi

PROPS="$NDK_ROOT/source.properties"
[ -f "$PROPS" ] || die "$PROPS not found; that is not an unpacked NDK root"

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
    for candidate in \
        "$NDK_ROOT/../android-ndk-${PIN_RELEASE}-linux.zip" \
        /nix/store/*android-ndk-${PIN_RELEASE}-linux.zip; do
        if [ -f "$candidate" ]; then
            NDK_ZIP=$candidate
            break
        fi
    done
fi

if [ -z "$NDK_ZIP" ] || [ ! -f "$NDK_ZIP" ]; then
    printf 'sync-ndk: release identity NOT verified: no NDK archive found.\n' >&2
    printf '  Tried, in this order:\n' >&2
    printf '    1. --zip <path>\n' >&2
    printf '    2. %s\n' "$NDK_ROOT/../android-ndk-${PIN_RELEASE}-linux.zip" >&2
    printf '    3. /nix/store/*android-ndk-%s-linux.zip\n' "$PIN_RELEASE" >&2
    printf '  An unpacked tree can assert its own revision; only the published\n' >&2
    printf '  archive proves which release that revision came from. Re-run with\n' >&2
    printf '  --zip <path-to-android-ndk-%s-linux.zip>.\n' "$PIN_RELEASE" >&2
    exit 1
fi

printf 'zip:       %s\n' "$NDK_ZIP"

GOT_SIZE=$(wc -c <"$NDK_ZIP" | tr -d ' ')
GOT_SHA=$(sha256sum "$NDK_ZIP" | cut -d' ' -f1)

if [ "$GOT_SHA" = "$PIN_SHA" ]; then
    printf 'sha256:    matches the pin\n'
else
    printf 'sha256 CHANGED\n' >&2
    printf '  recorded: %s\n' "$PIN_SHA" >&2
    printf '  fetched:  %s\n' "$GOT_SHA" >&2
    IDENTITY_OK=0
fi

if [ -n "$PIN_SIZE" ] && [ "$GOT_SIZE" != "$PIN_SIZE" ]; then
    printf 'size CHANGED\n' >&2
    printf '  recorded: %s\n' "$PIN_SIZE" >&2
    printf '  fetched:  %s\n' "$GOT_SIZE" >&2
    IDENTITY_OK=0
fi

# --------------------------------------------------------------- ABI table ---
#
# Expected, straight from the NDK. Columns are <tag> <abi dir> <triple> <min
# api>, where <tag> is the Zig identifier the enum spells and <abi dir> is the
# directory name the NDK spells; keeping both means the diff reports a renamed
# directory as well as a retargeted triple.
ABIS="$NDK_ROOT/meta/abis.json"
[ -f "$ABIS" ] ||
    die "$ABIS not found; r29 and later ship it, and without it there is nothing to diff"

jq -r 'to_entries[]
    | [ (.key | gsub("-"; "_")), .key, .value.triple, (.value.min_os_version | tostring) ]
    | @tsv' "$ABIS" | LC_ALL=C sort >"$WORK/expected.tsv"

# Actual, scraped from the three accessors in src/ndk.zig. This is text
# extraction rather than a compiler run, so it depends on the shape of those
# three functions: each is a `pub fn <name>(` line ending at the next line that
# starts in column zero. A reshape of them is a change this script must be
# taught, and the count check below is what says so out loud.
awk -v tagfile="$WORK/declared.tsv" '
    # Scoped to the Abi enum on purpose: HostTag.directoryName has the same
    # name and would otherwise contribute host tags to the ABI table.
    /^pub const Abi = enum \{/  { in_abi = 1; next }
    /^\};/                     { in_abi = 0; next }
    in_abi == 0                { next }
    /^[[:space:]]*\/\//        { next }
    /^[[:space:]]*pub fn directoryName\(/ { mode = "dir";  next }
    /^[[:space:]]*pub fn triple\(/        { mode = "trip"; next }
    /^[[:space:]]*pub fn minApiLevel\(/   { mode = "min";  next }
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
            if (mode == "dir")  dir[tag]  = value
            if (mode == "trip") trip[tag] = value
            if (mode == "min")  min[tag]  = value
        }
    }
    END {
        for (tag in seen) printf "%s\t%s\t%s\t%s\n", tag, dir[tag], trip[tag], min[tag]
        for (declared_tag in declared) print declared_tag > tagfile
        close(tagfile)
    }
' "$TABLE" | LC_ALL=C sort >"$WORK/actual.tsv"

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
    printf '  columns are <tag> <abi dir> <triple> <min api>:\n' >&2
    diff -u "$WORK/expected.tsv" "$WORK/actual.tsv" >&2 || true
    TABLE_OK=0
elif ! diff -u "$WORK/expected.tsv" "$WORK/actual.tsv" >"$WORK/abi.diff"; then
    printf 'ABI table CHANGED against meta/abis.json\n' >&2
    cat "$WORK/abi.diff" >&2
    TABLE_OK=0
else
    printf 'abi table: %s ABIs in src/ndk.zig match meta/abis.json exactly\n' "$ACTUAL_COUNT"
fi

# The enum's tag list and the tags its accessors cover have to be the same set.
# Without this, a tag deleted from the enum but left behind in all three
# switch arms still scrapes clean, still matches the NDK, and no longer
# compiles -- the one mutation the content diff above cannot see.
LC_ALL=C sort -u "$WORK/declared.tsv" >"$WORK/declared-sorted.tsv"
cut -f1 "$WORK/actual.tsv" >"$WORK/actual-tags.tsv"
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
    for key in release revision size sha256; do
        case $key in
            release) value=$GOT_RELEASE ;;
            revision) value=$GOT_REVISION ;;
            size) value=$GOT_SIZE ;;
            sha256) value=$GOT_SHA ;;
        esac
        sed -i "s|^$key = .*$|$key = $value|" "$RECORD"
    done
    printf '\naccepted. %s now records:\n' "$RECORD"
    printf '  release  %s\n  revision %s\n  size     %s\n  sha256   %s\n' \
        "$GOT_RELEASE" "$GOT_REVISION" "$GOT_SIZE" "$GOT_SHA"
    printf '\nThe ABI table already matched this NDK. Add an entry to CHANGELOG.md\n'
    printf 'saying what moved, and re-run this script with no flags to confirm.\n'
    exit 0
fi

if [ "$IDENTITY_OK" -ne 1 ]; then
    printf '\nsync-ndk: the pin in tools/ndk.sha256 no longer describes this NDK.\n' >&2
    printf 'The ABI table still matches, so this is an identity change only.\n' >&2
    printf 'Nothing was modified. Re-run with --accept to re-record it, and record\n' >&2
    printf 'in CHANGELOG.md what changed about the release.\n' >&2
    exit 1
fi

if [ "$ACCEPT" -eq 1 ]; then
    printf '\nnothing moved; tools/ndk.sha256 already records %s\n' "$PIN_SHA"
    printf -- '--accept had nothing to write.\n'
    exit 0
fi

printf '\nsync-ndk: pin holds. release %s, revision %s, sha256 %s.\n' \
    "$PIN_RELEASE" "$PIN_REVISION" "$PIN_SHA"
printf 'Nothing was modified. Use --accept only after reviewing a real change.\n'
exit 0