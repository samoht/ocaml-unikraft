#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Samuel Hym, Tarides <samuel@tarides.com>

# Unikraft says in various places it requires bash, so we can follow suit, to
# use its powerful ${v//"$var"/...} substitution

# extract_postprocessing <unikraftdir> <builddir> <targetradix> <targetsuffix>
#     [<fullconfig> <toolprefixfile>]

UNIKRAFTDIR="${1%/}"
REALUNIKRAFTDIR="$(realpath "$UNIKRAFTDIR")"
BUILDDIR="${2%/}"
REALBUILDDIR="$(realpath "$BUILDDIR")"
TARGETRDX="$3"
PATHTARGET="$BUILDDIR/$TARGETRDX"
REALPATHTARGET="$REALBUILDDIR/$TARGETRDX"
TARGETSUFFIX="$(< "$4")"
FULLCONFIG="${5:-}"
TOOLPREFIX=
[ -n "${6:-}" ] && TOOLPREFIX="$(< "$6")"

IFS='\n'

process() {
  while read line; do
    case "$line" in
      "sh "*.cmd|"/bin/sh "*.cmd|"bash "*.cmd|*"/bash "*.cmd)
        # Process the content of the .cmd file
        process < "${line#* }"
        ;;
      *)
        line="${line//"$PATHTARGET"/\"\$\{TARGET\}\"}"
        line="${line//"$REALPATHTARGET"/\"\$\{TARGET\}\"}"
        line="${line//"$TARGETRDX"/\"\$\{TARGET\}\"}"
        line="${line//"$BUILDDIR"/\"\$\{LIBDIR\}\"}"
        line="${line//"$REALBUILDDIR"/\"\$\{LIBDIR\}\"}"
        line="${line//"$UNIKRAFTDIR"/\"\$\{UKLIBDIR\}\"}"
        line="${line//"$REALUNIKRAFTDIR"/\"\$\{UKLIBDIR\}\"}"
        echo "      $line"
        ;;
    esac
  done
}

echo '      mv "$TARGET" "$TARGET".'"$TARGETSUFFIX"

# A static-PIE image (OPTIMIZE_PIE) self-relocates through the .uk_reloc table
# that mkukreloc.py distills from the link's dynamic relocations. Unikraft runs
# that step inside the rule producing the debug image, so the verbose replay
# the post-processing steps are learned from never re-runs it; inject it here,
# on the freshly linked image, ahead of the learned strip/bootinfo/binary
# steps. A failure must abort the build: an image whose table stayed empty
# boots at the wrong addresses instead of failing loudly.
if [ -n "$FULLCONFIG" ] && grep -q '^CONFIG_OPTIMIZE_PIE=y' "$FULLCONFIG"; then
  printf '      READELF=%sreadelf NM=%snm "${UKLIBDIR}"/support/scripts/mkukreloc.py "$TARGET".%s || exit 1\n' \
    "$TOOLPREFIX" "$TOOLPREFIX" "$TARGETSUFFIX"
  printf '      %sobjcopy --update-section .uk_reloc="$TARGET".%s.uk_reloc.bin "$TARGET".%s || exit 1\n' \
    "$TOOLPREFIX" "$TARGETSUFFIX" "$TARGETSUFFIX"
fi

process
