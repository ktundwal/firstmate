#!/usr/bin/env bash
# Native socket paths must retain identity when crossing the MSYS boundary.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ ! -r "/proc/$$/winpid" ]; then
  echo "skip: native Windows path conversion required"
  exit 0
fi
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
out=$(fm_backend_herdr_canonical_socket_path 'Z:\fm-socket-test\herdr.sock') \
  || fail "native drive-letter socket was rejected"
[ "$out" = '/z/fm-socket-test/herdr.sock' ] || fail "native socket mapped to '$out'"
fm_backend_herdr_canonical_socket_path 'relative/socket' >/dev/null && fail "relative socket was accepted"
pass "Herdr canonicalizes native Windows socket identities and still refuses relative paths"
