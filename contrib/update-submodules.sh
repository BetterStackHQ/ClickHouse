#!/bin/sh

set -e

WORKDIR=$(dirname "$0")
WORKDIR=$(readlink -f "${WORKDIR}")

"$WORKDIR/sparse-checkout/setup-sparse-checkout.sh"
git submodule init
git submodule sync
git config --file .gitmodules --get-regexp .*path | sed 's/[^ ]* //' | xargs -I _ --max-procs 64 git submodule update --depth=1 --single-branch _
