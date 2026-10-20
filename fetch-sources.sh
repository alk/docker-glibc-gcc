#!/bin/sh
# Snapshots the source tarballs the Dockerfile builds from into sources/, so
# that the docker build itself downloads nothing. Versions are the ARG
# defaults in the Dockerfile. Files already present are kept, so after a
# version bump this only fetches what's new.
set -eu
cd "$(dirname "$0")"

version() { sed -n "s/^ARG $1=//p" Dockerfile; }
BINUTILS_VERSION=$(version BINUTILS_VERSION)
LINUX_VERSION=$(version LINUX_VERSION)
GLIBC_COMMIT=$(version GLIBC_COMMIT)
GCC_VERSION=$(version GCC_VERSION)

mkdir -p sources
cd sources

# wcurl doesn't skip existing files (it saves a numbered copy instead), so
# only pass it the missing ones.
fetch() {
  urls=
  for url; do
    [ -e "${url##*/}" ] || urls="$urls $url"
  done
  [ -z "$urls" ] || wcurl --curl-options=--remove-on-error $urls
}

fetch \
  https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_VERSION.tar.xz \
  https://cdn.kernel.org/pub/linux/kernel/v${LINUX_VERSION%%.*}.x/linux-$LINUX_VERSION.tar.xz \
  https://ftp.gnu.org/gnu/gcc/gcc-$GCC_VERSION/gcc-$GCC_VERSION.tar.xz

# glibc is a git snapshot (the patches in ../patches are against master, not
# a release). sourceware doesn't serve snapshot tarballs, but it does let us
# fetch a single commit. git archive + gzip -n gives the same bytes every
# time.
glibc=glibc-$GLIBC_COMMIT.tar.gz
if [ ! -e $glibc ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  git init -q --bare "$tmp"
  git -C "$tmp" fetch -q --depth 1 https://sourceware.org/git/glibc.git $GLIBC_COMMIT
  git -C "$tmp" archive --prefix=glibc-$GLIBC_COMMIT/ $GLIBC_COMMIT | gzip -n > $glibc.tmp
  mv $glibc.tmp $glibc
fi

# gcc's in-tree prerequisites (gmp, mpfr, mpc, isl, gettext), at the versions
# this gcc release pins in contrib/download_prerequisites (which checks them
# against contrib/prerequisites.sha512 during the docker build).
fetch $(tar -xJOf gcc-$GCC_VERSION.tar.xz gcc-$GCC_VERSION/contrib/download_prerequisites |
          sed -n "s#^[a-z]*='\([^']*\.tar\.[a-z0-9]*\)'\$#https://gcc.gnu.org/pub/gcc/infrastructure/\1#p")
