#!/usr/bin/env bash
#
# Starts this library inside a release of its own — the one place its `@on_load`
# hook runs while the kernel is still starting.
#
# A release puts every module that carries an `@on_load` into its boot script, and
# `init` runs those hooks before the kernel goes on: a hook that cannot load a
# library there takes the whole VM with it, and a host's server starts and dies at
# once, leaving a log that says `on_load_function_failed` and a page nobody can
# reach. That is what 0.2.3 did to every host's release, on every platform, and it
# was found in a desktop bundle rather than here — because nothing in this
# repository had ever started the library the way a host does.
#
# Exits 0 only when the release is running and answers with the library's version.
set -euo pipefail
cd "$(dirname "$0")/.."

MIX_ENV=prod mix release --overwrite >/dev/null

release=_build/prod/rel/ex_mujoco
# A name and a cookie of its own: `rpc` starts a second VM that has to find the
# first one, and the default cookie of a CI runner is not a promise.
export RELEASE_DISTRIBUTION=sname
export RELEASE_NODE=ex_mujoco_boot
export RELEASE_COOKIE=ex_mujoco_boot

log="$(mktemp "${TMPDIR:-/tmp}/release-boot.XXXXXX")"
"$release/bin/ex_mujoco" start >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -f "$log"' EXIT

for _ in $(seq 1 60); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "the release died at boot, saying:" >&2
    cat "$log" >&2
    exit 1
  fi

  if version="$("$release/bin/ex_mujoco" rpc 'IO.puts(ExMujoco.version())' 2>/dev/null)"; then
    echo "the release is up and its library answers $(tr -d '\r' <<<"$version")"
    exit 0
  fi

  sleep 1
done

echo "the release is running but never answered" >&2
tail -20 "$log" >&2
exit 1
