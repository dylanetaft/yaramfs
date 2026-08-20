#!/bin/sh
set -e

# Always run from the repo root so hook paths (hooks/shared/...) resolve.
cd "$(dirname "$0")" || exit 1

. hooks/shared/head.sh
for_each_hook prepare
