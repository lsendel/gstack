#!/usr/bin/env bash
set -euo pipefail
payload=$(cd -- "$(dirname -- "$0")" && pwd)
work="${RUNNER_TEMP:?}/gstack-category-acceptance"
evidence="${RUNNER_TEMP}/gstack-category-evidence"
mkdir -p "$evidence"
exec > >(tee "$evidence/run.log") 2>&1
retain() {
  local status=$?
  trap - EXIT
  if test -d "$work/.context/free-test-logs"; then
    mkdir -p "$evidence/shards"
    find "$work/.context/free-test-logs" -maxdepth 1 -type f -name 'gstack-free-test-*.log' -exec cp -t "$evidence/shards/" {} + || status=1
  fi
  printf '%s\n' "$status" > "$evidence/overall-exit.txt"
  exit "$status"
}
trap retain EXIT
python3 "$payload/restore.py" "$work" | tee "$evidence/identity.json"
cp "$payload/manifest.json" "$evidence/payload-manifest.json"
printf '%s\n' "${GITHUB_SHA:?}" > "$evidence/workflow-sha.txt"
test "$(uname -s)" = Linux
test "$(uname -m)" = x86_64
test "$(id -u)" != 0
test "$(bun --version)" = 1.4.2
# Standard VM dependencies only. No sysctl, AppArmor, seccomp or host policy changes.
sudo apt-get update
sudo apt-get install -y --no-install-recommends fonts-noto-color-emoji xvfb xauth x11-utils poppler-utils zsh build-essential clang python3 python3-venv file unzip curl util-linux procps
accept_home="$HOME/gh-${GITHUB_RUN_ATTEMPT:?}"
mkdir -m 700 "$accept_home"
# An allowlist prevents runner tokens/configuration and CI's no-sandbox heuristic
# from reaching the free synthetic tests. HOME is a short private path outside /tmp
# so nested Chromium SingletonSocket paths stay well under the 108-byte AF_UNIX limit.
clean() {
  env -i HOME="$accept_home" ZDOTDIR="$accept_home" PATH="$PATH" LANG=C.UTF-8 \
    TMPDIR=/tmp TMP=/tmp TEMP=/tmp \
    PLAYWRIGHT_BROWSERS_PATH="$accept_home/.cache/ms-playwright" GSTACK_EXPECT_BINARIES=1 "$@"
}
cd "$work"
clean git config --global user.name 'Gstack Acceptance Fixture'
clean git config --global user.email acceptance@gstack.test
clean git config --global init.defaultBranch main
clean git config --global --add safe.directory '*'
clean bun --no-env-file --config=/dev/null install --frozen-lockfile
# System library installer is the pinned Playwright package, then browsers are
# downloaded into the isolated home. No repository secrets enter either child.
sudo env "PATH=$PATH" bun node_modules/playwright/cli.js install-deps chromium
clean bun node_modules/playwright/cli.js install chromium
python3 - <<'PY' > "$evidence/playwright-browsers.json"
import json, pathlib
data = json.loads(pathlib.Path("node_modules/playwright-core/browsers.json").read_text())
by_name = {entry["name"]: entry for entry in data["browsers"]}
chromium = by_name["chromium"]
headless = by_name["chromium-headless-shell"]
assert chromium["revision"] == headless["revision"], (chromium, headless)
assert chromium["browserVersion"] == headless["browserVersion"], (chromium, headless)
print(json.dumps({"chromium": chromium, "chromium-headless-shell": headless}, indent=2, sort_keys=True))
PY
chrome=$(clean bun -e 'import { chromium } from "playwright"; import { realpathSync } from "node:fs"; console.log(realpathSync(chromium.executablePath()))')
case "$chrome" in "$accept_home"/.cache/ms-playwright/chromium-*/chrome-linux*/chrome) ;; *) exit 1;; esac
chrome_dir="${chrome%/*}"
helper="$chrome_dir/chrome_sandbox"
installed="$chrome_dir/chrome-sandbox"
test -f "$helper" && test ! -L "$helper"
# Same bundled sandbox helper installation as the supported upstream CI lane.
sudo install -T -o root -g root -m 4755 "$helper" "$installed"
test "$(stat -c '%u:%a' "$installed")" = 0:4755
cmp -s "$helper" "$installed"
test "$("$installed" --get-api)" = 1
# Playwright's headless launch selects the paired chromium-headless-shell archive
# built from the exact same Chrome for Testing revision and browserVersion.
# Verify the shared release artifacts match before installing the SUID helper.
shell_dirs=("$accept_home"/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64)
test "${#shell_dirs[@]}" = 1
shell_dir="${shell_dirs[0]}"
test -f "$shell_dir/chrome-headless-shell"
for shared_file in ABOUT deb.deps rpm.deps icudtl.dat v8_context_snapshot.bin libEGL.so libGLESv2.so; do
  test -f "$chrome_dir/$shared_file"
  test -f "$shell_dir/$shared_file"
  cmp -s "$chrome_dir/$shared_file" "$shell_dir/$shared_file"
done
shell_helper="$shell_dir/chrome-sandbox"
sudo install -T -o root -g root -m 4755 "$helper" "$shell_helper"
test "$(stat -c '%u:%a' "$shell_helper")" = 0:4755
cmp -s "$helper" "$shell_helper"
test "$("$shell_helper" --get-api)" = 1
sha256sum "$helper" "$installed" "$shell_helper" > "$evidence/sandbox-helpers-sha256.txt"
clean bun --no-env-file --config=/dev/null run gen:skill-docs --host all
clean bun --no-env-file --config=/dev/null run vendor:xterm
clean bash browse/scripts/build-node-server.sh
clean bun --no-env-file --config=/dev/null run build:gates
clean bun --no-env-file --config=/dev/null run build:cso
if command -v swiftc >/dev/null 2>&1; then
  swift_warm=$(mktemp -d /tmp/sw-XXXXXX)
  cat <<'SWIFT' > "$swift_warm/Core.swift"
public final class WarmCore { public init() {} }
SWIFT
  cat <<'SWIFT' > "$swift_warm/App.swift"
import Foundation
import Observation
import WarmCore
@Observable final class WarmState { var x: Int = 0 }
SWIFT
  clean swiftc -emit-module -parse-as-library -module-name WarmCore "$swift_warm/Core.swift" -emit-module-path "$swift_warm/WarmCore.swiftmodule"
  clean swiftc -typecheck -D DEBUG -I "$swift_warm" "$swift_warm/App.swift"
  rm -rf "$swift_warm"
fi
git status --short > "$evidence/post-setup-status.txt"
git diff --binary > "$evidence/post-setup.diff"
sha256sum browse/dist/browse make-pdf/dist/pdf lib/diagram-render/dist/diagram-render.html lib/diagram-render/dist/BUILD_INFO.json bin/gstack-cso-core bin/gstack-cso-launcher bin/gstack-cso-watchdog > "$evidence/build-sha256.txt"
clean bash bin/gstack-wtree > "$evidence/tested-working-tree.txt"
test -s "$evidence/tested-working-tree.txt"
clean env GSTACK_PREFLIGHT_EVIDENCE="$evidence/browser-preflight.json" xvfb-run -a bun --no-env-file --config=/dev/null "$payload/browser-preflight.ts"
test -s "$evidence/browser-preflight.json"
clean bun --no-env-file --config=/dev/null run typecheck
clean bun --no-env-file --config=/dev/null run typecheck:test
clean bun --no-env-file --config=/dev/null run format:cso:check
clean env GSTACK_FREE_SEED_BASE=514fbfdc9799376edfd2536f60659501a48ead64 bun --no-env-file --config=/dev/null test test/free-seed-ratchet.test.ts
docker --host unix:///var/run/docker.sock info >/dev/null
clean env GSTACK_CSO_DOCKER_TESTS=1 DOCKER_HOST=unix:///var/run/docker.sock bun --no-env-file --config=/dev/null test --max-concurrency 1 test/cso-docker-integration.test.ts 2>&1 | tee "$evidence/cso-docker-integration.log"
# No quick mode, file filter, retry downgrade, timeout override or skip override.
set +e
clean xvfb-run -a bun --no-env-file --config=/dev/null run test
result=$?
set -e
printf '%s\n' "$result" > "$evidence/acceptance-exit.txt"
clean bash bin/gstack-wtree > "$evidence/final-working-tree.txt"
cmp "$evidence/tested-working-tree.txt" "$evidence/final-working-tree.txt"
sha256sum -c "$evidence/build-sha256.txt"
test "$(git rev-parse HEAD)" = 5ace6cf535399dc706241fac4b938319c43c54d0
test "$(git rev-parse 'HEAD^{tree}')" = 5bad460e6481dd8ece05e1c1ba46e45df83d2d25
git status --short > "$evidence/post-test-status.txt"
cmp "$evidence/post-setup-status.txt" "$evidence/post-test-status.txt"
git diff --binary > "$evidence/post-test.diff"
cmp "$evidence/post-setup.diff" "$evidence/post-test.diff"
git diff --stat -- . ':!lib/diagram-render/dist/BUILD_INFO.json' ':!lib/diagram-render/dist/diagram-render.html' > "$evidence/post-test-diff.txt"
test ! -s "$evidence/post-test-diff.txt"
exit "$result"
