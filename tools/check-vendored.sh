#!/usr/bin/env bash
# The vendored-payload drift gate, without touching the checkout.
#
# devtools:check-vendored runs `vendir sync` in place and then asks git
# for a diff, so an edit nobody staged is overwritten before anything
# looks at it, and the gate reports a clean payload. This syncs a fresh
# copy from the committed vendir.yml and vendir.lock.yml into a scratch
# directory instead, and compares it with the working tree. Any edit,
# deletion, or extra file in a vendored directory fails, and stays where
# it was for someone to look at.
set -euo pipefail

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

cp vendir.yml vendir.lock.yml "$scratch/"
vendir=$(command -v vendir)
# An inherited GIT_DIR would point vendir's throwaway clone at this
# repository, as devtools' own task notes.
(cd "$scratch" && env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE \
  -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY "$vendir" sync --locked >/dev/null)

rc=0
for dir in .config/mise/conf.d .devtools; do
  if [[ ! -d $scratch/$dir ]]; then
    echo "vendir produced no $dir, so the drift check compared nothing" >&2
    exit 1
  fi
  if ! diff -r "$scratch/$dir" "$dir"; then
    rc=1
  fi
done

if [[ $rc -ne 0 ]]; then
  echo "the vendored payload differs from what vendir.lock.yml pins; revert the edits above, or move the pin with devtools:update-pins" >&2
  exit 1
fi
echo "vendored payload matches what vendir.lock.yml pins"
