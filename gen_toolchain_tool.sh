#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Samuel Hym, Tarides <samuel@tarides.com>

# Generate a wrapper for the C compiler, the linker and other binutils
# Usage: $0 <ARCH> <SHAREDIR> <TOOL>
# with:
#   ARCH: the target architecture (x86_64 or arm64)
#   SHAREDIR: the directory containing ocaml-unikraft-backend-*-* directories
#       with cflags, ldflags, etc. files

ARCH="$1"
SHAREDIR="$2"
TOOL="$3"

# Extract the backend in `ocaml-unikraft-backend-<backend>-<arch>`
extract_backend() {
  backend="${1%-*}"
  backend="${backend##*-}"
  printf %s "$backend"
}

gen_cc() {
  DEFAULT_UNIKRAFT_BACKEND="$(extract_backend \
    "$SHAREDIR"/ocaml-unikraft-backend-*-"$ARCH")"
  case "$DEFAULT_UNIKRAFT_BACKEND" in
    qemu|firecracker|xen)
      ;;
    *)
      DEFAULT_UNIKRAFT_BACKEND=nobackendfound
      ;;
  esac

  cat << EOF
#!/bin/sh

set -e

basedir="\`dirname "\$0"\`"
basedir="\`realpath "\$basedir/.."\`"
UKLIBDIR="\$basedir/lib/unikraft"

# Go through the argument list to know:
# - if we are compiling (by default, we assume that we are linking and use both
#   CFLAGS and LDFLAGS), by looking for an argument suggesting we are compiling
# - the Unikraft backend to use, removing it from the command line as we go
# - the target file (for post-processing steps)

compiling=
cxx=
backend=
flag=
TARGET=a.out
for arg do
  shift
  if test "\$flag" = z ; then
    flag=
    case "\$arg" in
      unikraft-backend=*)
        backend="\${arg#*=}"
        ;;
      *)
        set -- "\$@" -z "\$arg"
        ;;
    esac
    continue
  fi

  case "\$arg" in
    -[cSEM]|-MM)
      compiling="\$arg"
      flag=
      ;;
    -z)
      flag=z
      continue
      ;;
    -o)
      flag=o
      ;;
    -pthread)
      # This bare-metal aarch64-elf/x86_64-elf gcc has no -pthread driver flag
      # (recent gcc rejects it outright), and Unikraft's musl keeps pthread in
      # libc rather than a standalone libpthread. Translate the hosted-gcc
      # convention that OCaml's configure probes for: -pthread becomes the flag
      # musl needs (_REENTRANT), and -lpthread is dropped (see below).
      flag=
      set -- "\$@" -D_REENTRANT
      continue
      ;;
    -lpthread)
      flag=
      continue
      ;;
    -lstdc++|-lc++)
      # This freestanding musl target has no C++ runtime library. Dune links
      # -lstdc++ for any C++ foreign stub, but a unikernel's C++ objects must be
      # built runtime-free (no exceptions, RTTI, or STL) since none is present;
      # drop the flag rather than fail on the missing archive. C++ code that
      # does need a runtime still fails loudly, on its undefined symbols.
      flag=
      continue
      ;;
    *.cc|*.cpp|*.cxx|*.c++|*.C|-std=*++*|--std=*++*|-xc++|-x=c++)
      # A C++ compile: a C++ source, a C++ standard, or an explicit -x c++. The
      # backend cflags below are the C dialect's (-std=gnu11, -Wno-int-conversion
      # and friends), which gcc rejects for C++ with a warning per flag; the
      # flags are dropped for C++ further down. Keep the argument itself.
      cxx=1
      ;;
    *)
      if [ "\$flag" = o ]; then TARGET="\$arg"; fi
      flag=
      ;;
  esac
  set -- "\$@" "\$arg"
done

case "\${backend:-$DEFAULT_UNIKRAFT_BACKEND}" in
EOF

  for b in "$SHAREDIR"/ocaml-unikraft-backend-*-"$ARCH"; do
    if [ -d "$b" ]; then
      cc="`cat "$b"/cc`"
      includedir="`"$cc" -print-file-name=include`"
      printf '  '
      extract_backend "$b"
      printf ')\n    LIBDIR="$basedir/lib/%s"\n' "${b##*/}"
      printf '    set -- \\\n      -D __Unikraft__ \\\n'
      cat "$b"/cflags
      # Access the compiler base headers, such as x86intrin.h, if needed
      printf '      -isystem %s \\\n' "${includedir@Q}"
      printf '      -static \\\n'
      printf '      "$@" \\\n'
      # Disable warnings due to musl code
      printf '      -D _REDIR_TIME64=0 -Wno-undef -Wno-strict-prototypes\n'
      printf '    if [ -z "$compiling" ]; then\n    set -- \\\n'
      cat "$b"/ldflags
      printf '      ;\n    fi\n'

      # Drop the C-dialect flags for a C++ compile. The backend cflags above are
      # the C dialect's; gcc warns once per flag when they reach a C++ front end
      # ("valid for C/ObjC but not for C++"), a wall of noise on every build that
      # compiles a C++ stub. They are already inert for C++ -- the compile's own
      # -std=c++NN, appended after them, wins -- so filtering them changes
      # nothing but the noise. Rebuild the argument list rather than editing it
      # in place, so an argument that contains spaces (a path) survives. A C
      # compile never sets cxx, so its argument list is untouched.
      printf '    if [ -n "$cxx" ]; then\n'
      printf '      __ukn=$#\n'
      printf '      while [ "$__ukn" -gt 0 ]; do\n'
      printf '        __ukn=$((__ukn-1)); __uka="$1"; shift\n'
      printf '        case "$__uka" in\n'
      printf '          -Wno-int-conversion|-Wno-incompatible-pointer-types|-Wno-strict-prototypes|-std=gnu11|--std=gnu11|-std=c11|--std=c11) ;;\n'
      printf '          *) set -- "$@" "$__uka" ;;\n'
      printf '        esac\n'
      printf '      done\n'
      printf '    fi\n'

      # Call to the compiler and post-processing
      # Post-processing is performed only if the `-z` option is given explicitly
      # Call to the compiler is duplicated to `set -x` just before the actual
      # invocations
      printf '    if [ -z "$compiling" -a -n "$backend" ]; then\n'
      printf '      [ -n "${__V}" ] && set -x\n'
      printf '      %s "$@"\n' "$cc"
      cat "$b"/poststeps
      printf '    else\n'
      printf '    [ -n "${__V}" ] && set -x\n'
      printf '      %s "$@"\n' "$cc"
      printf '    fi\n    ;;\n'
    fi
  done

  cat << EOF
  *)
    if [ -n "\$backend" ]; then
      echo 'fatal error: backend "'"\$backend"'"not found' >&2
    else
      echo 'fatal error: no backend found' >&2
    fi
    exit 1
    ;;
esac
EOF
}

cat1() {
  cat "$1"
}

cat_config_file() {
  cat1 "$SHAREDIR"/ocaml-unikraft-backend-*-"$ARCH"/"$1"
}

# Should we use cc for as?
gen_tool() {
  TOOL="$1"
  PREFIX="`cat_config_file toolprefix`"
  if command -v -- "$PREFIX$TOOL" > /dev/null; then
    TOOL="$PREFIX$TOOL"
  fi

  cat << EOF
#!/bin/sh
exec $TOOL "\$@"
EOF
}

case "$TOOL" in
  cc|gcc)
    gen_cc
    ;;
  *)
    gen_tool "$TOOL"
    ;;
esac
