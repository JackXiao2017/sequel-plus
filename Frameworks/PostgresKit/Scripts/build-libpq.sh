#!/bin/bash

#
#  build-libpq.sh
#  PostgresKit
#
#  Originally created by Stuart Connolly (stuconnolly.com) on August 1, 2012.
#  Rewritten for arm64 / PostgreSQL 18.
#
#  Builds static arm64 libpq (plus libpgcommon and libpgport) from the PostgreSQL source
#  and installs them into Frameworks/PostgresKit/Libs/libpq. All building happens in a
#  temporary directory; only the output libs and headers are written to the repository.
#
#  Built against the OpenSSL 4 headers from Homebrew (openssl@4); the final link uses the
#  static libssl.a/libcrypto.a already bundled in SPMySQLFramework.
#
#  Usage: build-libpq.sh        (no arguments; requires network access)

set -euo pipefail

PG_VERSION='18.6'
PG_SHA256='555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f'
PG_URL="https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2"

OPENSSL_PREFIX='/opt/homebrew/opt/openssl@4'
MIN_OS_X_VERSION='12.0'
ARCH_FLAGS="-arch arm64 -mmacosx-version-min=${MIN_OS_X_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/Libs"
BUNDLED_SSL_DIR="$(cd "${SCRIPT_DIR}/../../SPMySQLFramework/MySQL Client Libraries/lib" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "${OPENSSL_PREFIX}/include/openssl" ] || die "OpenSSL headers not found at ${OPENSSL_PREFIX}/include"

# The bundled static OpenSSL must be arm64 and the same major version as the headers.
for LIB in libssl.a libcrypto.a; do
	[ "$(lipo -archs "${BUNDLED_SSL_DIR}/${LIB}")" = 'arm64' ] || die "${LIB} is not arm64-only"
done
HDR_MAJOR=$(sed -n 's/^# *define OPENSSL_VERSION_MAJOR *\([0-9]*\).*/\1/p' "${OPENSSL_PREFIX}/include/openssl/opensslv.h" | head -1)
LIB_MAJOR=$(strings "${BUNDLED_SSL_DIR}/libcrypto.a" | sed -n 's/^OpenSSL \([0-9]*\)\..*/\1/p' | head -1)
[ -n "${HDR_MAJOR}" ] && [ "${HDR_MAJOR}" = "${LIB_MAJOR}" ] || die "OpenSSL major mismatch: headers=${HDR_MAJOR} bundled lib=${LIB_MAJOR}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/build-libpq.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
JOBS=$(sysctl -n hw.ncpu)

echo "==> Downloading PostgreSQL ${PG_VERSION}"
curl -fsSL -o "${WORK}/pg.tar.bz2" "${PG_URL}"
echo "${PG_SHA256}  ${WORK}/pg.tar.bz2" | shasum -a 256 -c - >/dev/null || die 'PostgreSQL tarball checksum mismatch'
tar -xjf "${WORK}/pg.tar.bz2" -C "${WORK}"
PG_SRC="${WORK}/postgresql-${PG_VERSION}"

echo "==> Configuring PostgreSQL"
(
	cd "${PG_SRC}"
	CFLAGS="${ARCH_FLAGS}" ./configure \
		--with-ssl=openssl --without-icu --without-readline --without-gssapi --without-zlib \
		--with-includes="${OPENSSL_PREFIX}/include" --with-libs="${OPENSSL_PREFIX}/lib" >"${WORK}/configure.log" 2>&1 \
		|| { tail -30 "${WORK}/configure.log"; exit 1; }
)

echo '==> Building src/port, src/common, src/interfaces/libpq'
for DIR in src/port src/common src/interfaces/libpq; do
	make -C "${PG_SRC}/${DIR}" -j"${JOBS}" >>"${WORK}/make.log" 2>&1 || { tail -30 "${WORK}/make.log"; die "build failed in ${DIR}"; }
done

mkdir -p "${LIBS_DIR}/libpq/lib" "${LIBS_DIR}/libpq/include"
cp "${PG_SRC}/src/interfaces/libpq/libpq.a" "${PG_SRC}/src/common/libpgcommon.a" "${PG_SRC}/src/port/libpgport.a" "${LIBS_DIR}/libpq/lib/"
# (pg_config_ext.h was removed from PostgreSQL in v16; not needed.)
cp "${PG_SRC}/src/interfaces/libpq/libpq-fe.h" "${PG_SRC}/src/include/postgres_ext.h" "${LIBS_DIR}/libpq/include/"

echo "==> Done. Output in ${LIBS_DIR}/libpq"
