#!/bin/bash
# pins.sh - manage the artifact pin manifest in lib.sh.
#
# The manifest ships with sha256 values of "TBD" because a hash you have not
# actually computed is worse than no hash at all - it looks like verification
# while verifying nothing. This script computes the real ones.
#
# DO THIS ON A TRUSTED NETWORK, during a rehearsal, not on engagement day:
#   bash pins.sh --show      # what is pinned and what is not
#   bash pins.sh --record    # download everything, print the real sha256 lines
#   bash pins.sh --write     # same, but edit lib.sh in place (backup kept)
#   bash pins.sh --verify    # re-download and compare against the manifest
#
# --verify is the drift check: run it the week before the event. A mismatch on
# something we pinned means upstream moved a release asset under us; a mismatch
# on something marked 'latest'/'master' is expected and is the argument for
# pinning it.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh" || { echo "cannot source lib.sh"; exit 1; }

MODE=${1:---show}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

names=$(printf '%s\n' "${!PIN_URL[@]}" | sort)

case $MODE in
--show)
    printf '%-18s %-24s %s\n' "ARTIFACT" "VERSION" "SHA256"
    printf '%-18s %-24s %s\n' "--------" "-------" "------"
    for n in $names; do
        printf '%-18s %-24s %s\n' "$n" "${PIN_VER[$n]}" "${PIN_SHA[$n]}"
    done
    echo
    unpinned=0; unverified=0
    for n in $names; do
        case "${PIN_VER[$n]}" in latest|master|main) unpinned=$((unpinned+1)) ;; esac
        [ "${PIN_SHA[$n]}" = "TBD" ] && unverified=$((unverified+1))
    done
    print_status "$unpinned of $(echo "$names" | wc -w) artifacts track a moving target"
    print_status "$unverified of $(echo "$names" | wc -w) artifacts have no verified sha256"
    ;;

--record|--write)
    print_status "Downloading every manifest artifact to compute real hashes..."
    OUT="$TMP/lines"; : > "$OUT"
    fail=0
    for n in $names; do
        if curl -fsSL --retry 3 --connect-timeout 15 "${PIN_URL[$n]}" -o "$TMP/$n"; then
            sha=$(sha256sum "$TMP/$n" | cut -d' ' -f1)
            printf 'PIN_SHA[%s]="%s"\n' "$n" "$sha" >> "$OUT"
            print_success "$n  ${sha:0:16}...  ($(stat -c %s "$TMP/$n") bytes)"
        else
            print_error "$n  DOWNLOAD FAILED - leaving as TBD"
            fail=$((fail+1))
        fi
    done
    echo
    if [ "$MODE" = "--record" ]; then
        print_status "Paste these into lib.sh (or re-run with --write):"
        echo; cat "$OUT"
    else
        cp "lib.sh" "lib.sh.pins-bak-$(date +%s)"
        while IFS= read -r line; do
            key=${line%%]*}; key=${key#PIN_SHA[}
            # Replace only the sha for this key, leave URL/VER untouched.
            sed -i "s|^PIN_SHA\[$key\]=.*|$line|" "$SCRIPT_DIR/lib.sh"
        done < "$OUT"
        print_success "lib.sh updated (backup: lib.sh.pins-bak-*)"
        print_warning "Commit this. A pinned hash only helps if everyone builds from it."
    fi
    [ "$fail" -gt 0 ] && print_warning "$fail artifact(s) could not be downloaded"
    ;;

--verify)
    print_status "Re-downloading and comparing against the manifest..."
    drift=0; skipped=0
    for n in $names; do
        if [ "${PIN_SHA[$n]}" = "TBD" ]; then
            print_warning "$n has no recorded hash - skipped (version: ${PIN_VER[$n]})"
            skipped=$((skipped+1)); continue
        fi
        if ! curl -fsSL --retry 3 --connect-timeout 15 "${PIN_URL[$n]}" -o "$TMP/$n"; then
            print_error "$n download failed"; drift=$((drift+1)); continue
        fi
        sha=$(sha256sum "$TMP/$n" | cut -d' ' -f1)
        if [ "$sha" = "${PIN_SHA[$n]}" ]; then
            print_success "$n unchanged"
        else
            print_error "$n CHANGED since it was pinned"
            print_error "   manifest: ${PIN_SHA[$n]}"
            print_error "   upstream: $sha"
            drift=$((drift+1))
        fi
    done
    echo
    if [ "$drift" -eq 0 ]; then
        print_success "No drift on any pinned artifact ($skipped unpinned, skipped)"
    else
        print_error "$drift artifact(s) drifted - investigate before the event"
        exit 1
    fi
    ;;

-h|--help) sed -n '2,20p' "$0" ;;
*) print_error "unknown mode: $MODE (try --help)"; exit 1 ;;
esac
