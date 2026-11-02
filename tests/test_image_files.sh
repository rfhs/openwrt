#!/bin/sh
# Checks that an openwrt image has this checkout's files/: the same contents,
# modes and symlinks, without starting it.
#   ./tests/test_image_files.sh rfhs/openwrt:4.6.4.1
set -eu

missing_tools=""
for tool in cmp dirname docker find mktemp readlink rm sed stat tar; do
  command -v "${tool}" > /dev/null 2>&1 || missing_tools="${missing_tools} ${tool}"
done
if [ -n "${missing_tools}" ]; then
  printf '%s: required commands not found:%s\n' "${0##*/}" "${missing_tools}" >&2
  exit 1
fi
if [ "$#" -ne 1 ]; then
  printf 'usage: %s image\n' "${0}" >&2
  exit 2
fi
files="$(dirname "${0}")/../files"

work="$(mktemp -d)"
c=""
trap 'if [ -n "${c}" ]; then docker rm "${c}" > /dev/null; fi; rm -rf "${work}"' EXIT
c="$(docker create "${1}")"

failed=0
fail() {
  printf 'FAIL: %s\n' "${1}"
  failed=1
}
find "${files}" ! -type d | sed "s#^${files}/##" > "${work}/list"
while read -r f; do
  rm -rf "${work}/got"
  mkdir "${work}/got"
  if ! docker cp "${c}:/${f}" - 2> /dev/null | tar -xpf - -C "${work}/got" 2> /dev/null; then
    fail "${f} isn't in ${1}"
    continue
  fi
  got="${work}/got/${f##*/}"
  if [ -L "${files}/${f}" ]; then
    if [ "$(readlink "${got}")" != "$(readlink "${files}/${f}")" ]; then
      fail "${f} isn't the same symlink"
      continue
    fi
  elif [ -L "${got}" ] || ! cmp -s "${got}" "${files}/${f}"; then
    fail "${f} differs"
    continue
  elif [ "$(stat -c %a "${got}")" != "$(stat -c %a "${files}/${f}")" ]; then
    fail "${f} has mode $(stat -c %a "${got}"), not $(stat -c %a "${files}/${f}")"
    continue
  fi
  printf 'PASS: %s\n' "${f}"
done < "${work}/list"
exit "${failed}"
