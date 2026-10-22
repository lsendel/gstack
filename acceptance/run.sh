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
accept_home="$HOME/gstack-category-home-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
mkdir -m 700 "$accept_home"
mkdir -p -m 700 "$work/.context/acceptance-tmp"
# An allowlist prevents runner tokens/configuration and CI's no-sandbox heuristic
# from reaching the free synthetic tests. HOME is private and outside /tmp.
clean() {
  env -i HOME="$accept_home" ZDOTDIR="$accept_home" PATH="$PATH" LANG=C.UTF-8 \
    TMPDIR="$work/.context/acceptance-tmp" TMP="$work/.context/acceptance-tmp" TEMP="$work/.context/acceptance-tmp" \
    PLAYWRIGHT_BROWSERS_PATH="$accept_home/.cache/ms-playwright" GSTACK_EXPECT_BINARIES=1 "$@"
}
cd "$work"
clean git config --global user.name 'Gstack Acceptance Fixture'
clean git config --global user.email acceptance@gstack.test
clean git config --global init.defaultBranch main
clean bun --no-env-file --config=/dev/null install --frozen-lockfile
# System library installer is the pinned Playwright package, then browsers are
# downloaded into the isolated home. No repository secrets enter either child.
sudo env "PATH=$PATH" bun node_modules/playwright/cli.js install-deps chromium
clean bun node_modules/playwright/cli.js install chromium
chrome=$(clean bun -e 'import { chromium } from "playwright"; import { realpathSync } from "node:fs"; console.log(realpathSync(chromium.executablePath()))')
case "$chrome" in "$accept_home"/.cache/ms-playwright/chromium-*/chrome-linux*/chrome) ;; *) exit 1;; esac
helper="${chrome%/*}/chrome_sandbox"
installed="${chrome%/*}/chrome-sandbox"
test -f "$helper" && test ! -L "$helper"
# Same bundled sandbox helper installation as the supported upstream CI lane.
sudo install -T -o root -g root -m 4755 "$helper" "$installed"
test "$(stat -c '%u:%a' "$installed")" = 0:4755
cmp -s "$helper" "$installed"
clean bun --no-env-file --config=/dev/null run gen:skill-docs --host all
clean bun --no-env-file --config=/dev/null run vendor:xterm
clean bash browse/scripts/build-node-server.sh
clean bun --no-env-file --config=/dev/null run build:gates
clean bun --no-env-file --config=/dev/null run build:cso
git status --short > "$evidence/post-setup-status.txt"
sha256sum browse/dist/browse make-pdf/dist/pdf lib/diagram-render/dist/diagram-render.html lib/diagram-render/dist/BUILD_INFO.json bin/gstack-cso-core bin/gstack-cso-launcher bin/gstack-cso-watchdog > "$evidence/build-sha256.txt"
clean bash bin/gstack-wtree > "$evidence/tested-working-tree.txt"
test -s "$evidence/tested-working-tree.txt"
clean xvfb-run -a bun --no-env-file --config=/dev/null "$payload/browser-preflight.ts"
clean bun --no-env-file --config=/dev/null run typecheck
clean bun --no-env-file --config=/dev/null run typecheck:test
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
git diff --stat > "$evidence/post-test-diff.txt"
exit "$result"
