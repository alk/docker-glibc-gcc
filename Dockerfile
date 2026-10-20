# Builds an x86_64 glibc gcc toolchain (C and C++) into /opt/glibc-gcc, with
# glibc from git master plus the patches in patches/.
#
#   ./fetch-sources.sh        # snapshots the tarballs below into sources/
#   docker build -t glibc-gcc .
#
# The build itself downloads nothing. binutils and glibc (on top of the
# kernel headers) don't depend on each other, so they are separate stages
# (BuildKit builds them in parallel); gcc is then built once, on top of
# both. See README for why that is enough here.

ARG BINUTILS_VERSION=2.47
ARG LINUX_VERSION=6.18.56
ARG GLIBC_COMMIT=b84c6a67f25ff501e6e833502937159f36d32d4f
ARG GCC_VERSION=16.2.0

# Debian stable, so the toolchain's own binaries (gcc, as, ld, ...) only need
# glibc 2.41 and can be copied out to most current distros (see README).
FROM debian:trixie AS base

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential xz-utils bzip2 rsync file gawk bison python3 && \
    rm -rf /var/lib/apt/lists/*

# The vendor field ("glibc") only matters in that it makes TARGET differ
# from the build triple, so gcc is built as a cross compiler (see README).
ENV PREFIX=/opt/glibc-gcc \
    TARGET=x86_64-glibc-linux-gnu \
    TOOLDIR=/opt/glibc-gcc/x86_64-glibc-linux-gnu \
    PATH=/opt/glibc-gcc/bin:$PATH

WORKDIR /build

# Local tarballs given to ADD are unpacked into the destination.

# --- binutils ---
FROM base AS binutils
ARG BINUTILS_VERSION
ADD sources/binutils-$BINUTILS_VERSION.tar.xz .
RUN mkdir obj && cd obj && \
    ../binutils-$BINUTILS_VERSION/configure \
      --target=$TARGET --prefix=$PREFIX \
      --disable-nls --disable-werror --disable-multilib --disable-gprofng && \
    make -j$(nproc) MAKEINFO=true && \
    make install MAKEINFO=true

# --- kernel headers ---
FROM base AS linux-headers
ARG LINUX_VERSION
ADD sources/linux-$LINUX_VERSION.tar.xz .
RUN make -C linux-$LINUX_VERSION ARCH=x86_64 INSTALL_HDR_PATH=$TOOLDIR headers_install

# --- glibc ---
# Built with Debian's gcc and binutils. Installed straight into gcc's
# tooldir, where it looks for target headers, crt files and libs by default.
# With a prefix other than /usr glibc puts everything (including ld.so) into
# $TOOLDIR/lib. lib64 is made a symlink to it so that gcc's libstdc++ and
# libgcc_s land there too and the loader finds them without rpath or
# ld.so.cache.
FROM base AS glibc
ARG GLIBC_COMMIT
COPY --from=linux-headers /opt/glibc-gcc /opt/glibc-gcc
ADD sources/glibc-$GLIBC_COMMIT.tar.gz .
COPY patches/*.patch patches/
RUN cd glibc-$GLIBC_COMMIT && \
    for p in ../patches/*.patch; do patch -p1 < $p || exit 1; done
# --host makes it a cross build: no ldconfig run and no install test (which
# would use Debian's gcc) at make install. Time zone data and the local time
# zone come from the host (glibc doesn't ship tzdata), see README.
RUN mkdir obj && cd obj && \
    printf '%s\n' 'zonedir = /usr/share/zoneinfo' 'localtime-file = /etc/localtime' > configparms && \
    ../glibc-$GLIBC_COMMIT/configure \
      --prefix=$TOOLDIR --host=$TARGET \
      --build=$(../glibc-$GLIBC_COMMIT/scripts/config.guess) \
      --with-headers=$TOOLDIR/include \
      --disable-werror --disable-nscd \
      CC=gcc CXX=g++ && \
    make -j$(nproc) MAKEINFO=: && \
    make install MAKEINFO=: && \
    ln -s lib $TOOLDIR/lib64 && \
    test -e $TOOLDIR/lib/ld-linux-x86-64.so.2

# --- gcc ---
FROM base AS gcc
ARG GCC_VERSION

COPY --from=binutils /opt/glibc-gcc /opt/glibc-gcc
COPY --from=glibc /opt/glibc-gcc /opt/glibc-gcc

# gcc (without a sysroot) inspects the target headers in sys-include: to
# detect the glibc version, to decide whether its limits.h chains to
# glibc's, and to run fixincludes. See README.
RUN ln -s include $TOOLDIR/sys-include

# gmp/mpfr/mpc/isl/gettext are built in-tree, so there are no host lib deps.
# With the tarballs already in place download_prerequisites doesn't download
# anything: it checks their sha512 sums, unpacks them and adds the symlinks.
ADD sources/gcc-$GCC_VERSION.tar.xz .
COPY sources/gmp-* sources/mpfr-* sources/mpc-* sources/isl-* sources/gettext-* gcc-$GCC_VERSION/
RUN cd gcc-$GCC_VERSION && ./contrib/download_prerequisites

# Make dynamically linked binaries use the loader inside /opt/glibc-gcc
# instead of the standard /lib64/ld-linux-x86-64.so.2.
RUN sed -i 's|^#define GLIBC_DYNAMIC_LINKER64 .*|#define GLIBC_DYNAMIC_LINKER64 "'$TOOLDIR'/lib/ld-linux-x86-64.so.2"|' \
      gcc-$GCC_VERSION/gcc/config/i386/linux64.h && \
    grep -F "\"$TOOLDIR/lib/ld-linux-x86-64.so.2\"" gcc-$GCC_VERSION/gcc/config/i386/linux64.h

RUN mkdir obj && cd obj && \
    ../gcc-$GCC_VERSION/configure \
      --target=$TARGET --prefix=$PREFIX --enable-languages=c,c++ \
      --disable-nls --disable-werror --disable-multilib --disable-bootstrap \
      --enable-shared --enable-threads=posix && \
    make -j$(nproc) MAKEINFO=true && \
    make install MAKEINFO=true && \
    rm -rf $PREFIX/share/info $PREFIX/share/man && \
    cd .. && rm -rf obj gcc-$GCC_VERSION

# --- smoke test ---
# ldd is glibc's, so it uses our loader; nothing may come from outside
# /opt/glibc-gcc.
COPY smoke-test.cc /tmp/t.cc
RUN $TARGET-g++ -O2 -static -o /tmp/t-static /tmp/t.cc && \
    file /tmp/t-static && /tmp/t-static && \
    $TARGET-g++ -O2 -o /tmp/t-dynamic /tmp/t.cc && \
    $TARGET-readelf -l /tmp/t-dynamic | grep -F "$TOOLDIR/lib/ld-linux-x86-64.so.2" && \
    $TOOLDIR/bin/ldd /tmp/t-dynamic && \
    ! $TOOLDIR/bin/ldd /tmp/t-dynamic | grep -v -e "=> $TOOLDIR/lib/" -e "^\s*$TOOLDIR/lib/ld-linux" -e linux-vdso && \
    /tmp/t-dynamic


FROM debian:trixie

COPY --from=gcc /opt/glibc-gcc /opt/glibc-gcc
ENV PATH=/opt/glibc-gcc/bin:$PATH
