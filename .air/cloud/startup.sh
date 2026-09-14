#!/usr/bin/env bash
# Environment startup script for the Air cloud development environment.
#
# rules_rs is a Bazel ruleset (Starlark only), so the environment needs exactly
# one thing to be useful: a working `bazel` that can build and test the root
# module. Everything else here is cache warming so that the snapshot taken after
# a successful warmup run makes the first real task fast.
#
# Runs in two modes, announced by AIR_STARTUP_MODE:
#   warmup - snapshot-baking run; do the expensive work and block on healthcheck
#   task   - real task run; install/configure only, then exit promptly
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BAZELISK_VERSION="v1.27.0"
LOCAL_BIN="$HOME/.local/bin"
ENV_FILE="$HOME/.air-cloud-env.sh"
AIR_BAZELRC="$HOME/.air-cloud.bazelrc"
MARKER="# added by rules_rs .air/cloud/startup.sh"

if [ "${AIR_STARTUP_MODE:-}" = warmup ]; then WARMUP=1; else WARMUP=; fi

log() { echo "[startup $(date -u +%H:%M:%S)] $*"; }

# --- bazelisk -----------------------------------------------------------------
# bazelisk reads .bazelversion (9.0.0) and fetches the matching Bazel release.
install_bazelisk() {
  if [ -x "$LOCAL_BIN/bazel" ] && "$LOCAL_BIN/bazel" version >/dev/null 2>&1; then
    log "bazelisk already installed at $LOCAL_BIN/bazel"
    return
  fi

  local arch
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) log "ERROR: unsupported architecture $(uname -m)"; return 1 ;;
  esac

  log "installing bazelisk $BAZELISK_VERSION (linux-$arch)"
  mkdir -p "$LOCAL_BIN"
  curl -fsSL --retry 5 --retry-all-errors \
    -o "$LOCAL_BIN/bazel.tmp" \
    "https://github.com/bazelbuild/bazelisk/releases/download/$BAZELISK_VERSION/bazelisk-linux-$arch"
  chmod +x "$LOCAL_BIN/bazel.tmp"
  mv "$LOCAL_BIN/bazel.tmp" "$LOCAL_BIN/bazel"
  log "bazelisk installed"
}

# --- shell environment --------------------------------------------------------
# The launch runs this script as a child process, so exports here die with it.
# Write them to a file and source that file from the login/interactive shells
# the agent and any tooling get.
configure_shell_env() {
  cat > "$ENV_FILE" <<'EOF'
# Sourced by ~/.profile and ~/.bashrc; managed by rules_rs .air/cloud/startup.sh.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH
EOF

  local source_line="[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\"  $MARKER"

  # A login shell reads only the first of these that exists.
  local profile=""
  for candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -f "$candidate" ]; then profile="$candidate"; break; fi
  done
  [ -n "$profile" ] || { profile="$HOME/.profile"; : > "$profile"; }

  for rc in "$profile" "$HOME/.bashrc"; do
    [ -f "$rc" ] || : > "$rc"
    if ! grep -qF "$MARKER" "$rc"; then
      printf '\n%s\n' "$source_line" >> "$rc"
      log "hooked $ENV_FILE into $rc"
    fi
  done

  # shellcheck disable=SC1090
  . "$ENV_FILE"
}

# --- bazel configuration ------------------------------------------------------
# Egress from this environment is HTTP(S)-proxy only. Bazel's gRPC clients do
# not honour HTTPS_PROXY, so the BuildBuddy remote cache / BES endpoints that
# test/.bazelrc points at are unreachable and a plain build there would fail on
# "Build Event Protocol upload failed". Neutralise those flags in the user
# bazelrc (which loses to explicit command line flags, so a task can opt back
# in) rather than touching the repository's own configuration.
configure_bazelrc() {
  cat > "$AIR_BAZELRC" <<'EOF'
# Managed by rules_rs .air/cloud/startup.sh -- do not edit by hand.
# gRPC endpoints are unreachable from this sandbox (HTTP(S)-proxy-only egress).
common --bes_backend=
common --bes_results_url=
common --remote_cache=
# Downloads go through an egress proxy that occasionally returns 5xx.
common --experimental_repository_downloader_retries=5
EOF

  local import_line="try-import $AIR_BAZELRC  $MARKER"
  local home_bazelrc="$HOME/.bazelrc"
  [ -f "$home_bazelrc" ] || : > "$home_bazelrc"
  if ! grep -qF "$MARKER" "$home_bazelrc"; then
    printf '%s\n' "$import_line" >> "$home_bazelrc"
    log "hooked $AIR_BAZELRC into $home_bazelrc"
  fi
}

# --- GNU patch ----------------------------------------------------------------
# crate_repository applies `patches` with `patch_tool = "patch"`, and several
# test/ workspaces (rav1e, ring, ...) rely on it, but the image ships no `patch`
# and there is no root to apt-get one. Download the .deb as an unprivileged user
# and unpack just the binary into ~/.local/bin.
install_patch() {
  if command -v patch >/dev/null 2>&1; then
    log "patch already available at $(command -v patch)"
    return 0
  fi

  log "installing GNU patch from the Ubuntu archive (userspace)"
  local work="$HOME/.cache/air-patch"
  rm -rf "$work"
  mkdir -p "$work/lists/partial" "$work/cache/archives/partial" "$work/debs"
  # apt drops privileges to _apt for downloads; it needs to write here.
  chmod -R 0777 "$work"

  cat > "$work/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu/ noble main
EOF

  local apt_opts=(
    -o "Dir::Etc::SourceList=$work/sources.list"
    -o "Dir::Etc::SourceParts=/dev/null"
    -o "Dir::State::Lists=$work/lists"
    -o "Dir::State::extended_states=$work/extended_states"
    -o "Dir::Cache=$work/cache"
    -o "Acquire::Languages=none"
    -o "APT::Get::List-Cleanup=false"
  )

  if ! apt-get "${apt_opts[@]}" -qq update; then
    log "WARNING: apt-get update failed; 'patch' stays unavailable and crate patching in test/ will fail"
    return 0
  fi
  if ! (cd "$work/debs" && apt-get "${apt_opts[@]}" -qq download patch); then
    log "WARNING: could not download the patch package; crate patching in test/ will fail"
    return 0
  fi

  local deb
  deb="$(find "$work/debs" -name 'patch_*.deb' -print -quit)"
  if [ -z "$deb" ]; then
    log "WARNING: no patch_*.deb was downloaded; crate patching in test/ will fail"
    return 0
  fi

  dpkg-deb -x "$deb" "$work/root"
  mkdir -p "$LOCAL_BIN"
  install -m 0755 "$work/root/usr/bin/patch" "$LOCAL_BIN/patch"
  log "installed $("$LOCAL_BIN/patch" --version | head -1) to $LOCAL_BIN/patch"
}

# --- git ----------------------------------------------------------------------
# This image has no ssh client (and no way to install one without root), so the
# `ssh://git@github.com/...` git dependency in test/git_crates/Cargo.toml cannot
# be fetched as written. Rewrite it to https, which goes through the egress
# proxy like every other download.
configure_git() {
  if ! git config --global --get-regexp 'url\..*\.insteadof' >/dev/null 2>&1; then
    git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
    log "configured git to rewrite ssh://git@github.com/ to https (no ssh client available)"
  fi
}

# --- pre-commit ---------------------------------------------------------------
# CONTRIBUTING.md asks contributors to run pre-commit (buildifier formatting is
# enforced on CI), and .devcontainer does `pre-commit install` on start.
install_pre_commit() {
  if ! command -v pre-commit >/dev/null 2>&1; then
    log "installing pre-commit"
    pip3 install --user --break-system-packages --quiet pre-commit \
      || { log "WARNING: pre-commit install failed; formatting hooks unavailable"; return 0; }
  fi
  log "pre-commit $(pre-commit --version 2>/dev/null || echo '(version unknown)')"
  (cd "$REPO_ROOT" && pre-commit install) \
    || log "WARNING: 'pre-commit install' failed"
  if [ -n "$WARMUP" ]; then
    log "priming pre-commit hook environments (cached in ~/.cache/pre-commit)"
    (cd "$REPO_ROOT" && pre-commit install-hooks) \
      || log "WARNING: 'pre-commit install-hooks' failed; hooks will install on first use"
  fi
}

# --- cache warming ------------------------------------------------------------
# Fills ~/bazel_cache (disk cache), ~/bazel_repo_contents_cache and
# ~/.cache/bazel, all of which land in the snapshot.
warm_caches() {
  log "warming root module: bazel build //... (rust host tools, Go SDK, gazelle, buildifier)"
  if (cd "$REPO_ROOT" && bazel build //... 2>&1 | tail -20); then
    log "root module built"
  else
    log "WARNING: 'bazel build //...' failed during warmup; healthcheck will retry"
  fi

  # test/ is a separate Bazel module (listed in .bazelignore) that exercises
  # crate resolution end to end. Loading it downloads the crate archives for
  # every test workspace, which is the slow part of working in there. It cannot
  # complete fully: the git_crates workspace pulls a dependency over
  # ssh://git@github.com/... which needs an ssh client plus a key (CI supplies
  # SSH_PRIVATE_KEY), so this is best effort with --keep_going.
  log "warming test/ module crate downloads (best effort)"
  local test_log="$HOME/.cache/air-startup-test-module.log"
  if (cd "$REPO_ROOT/test" && bazel build --nobuild --keep_going //:all_builds > "$test_log" 2>&1); then
    log "test/ module loaded: every crate repository resolved"
  else
    log "NOTE: test/ module did not load completely; distinct errors follow ($test_log has the full output)"
    grep -E '^ERROR' "$test_log" | cut -c1-200 | sort -u | head -15 || true
  fi
  tail -6 "$test_log" || true
}

# --- healthcheck --------------------------------------------------------------
# Asserts the environment can actually do what a task on this repository needs:
# run the root module's Starlark unit tests with the pinned Bazel version.
# Keeps retrying (no internal deadline -- the launch applies its own) because
# the failures seen here are transient proxy 5xx on dependency downloads.
healthcheck() {
  local want attempt=0
  want="$(tr -d '[:space:]' < "$REPO_ROOT/.bazelversion")"

  while :; do
    attempt=$((attempt + 1))
    log "healthcheck attempt $attempt: bazel version"
    local have
    if have="$(cd "$REPO_ROOT" && bazel --version 2>/dev/null)" && [ "$have" = "bazel $want" ]; then
      log "healthcheck: $have (matches .bazelversion)"
      log "healthcheck attempt $attempt: bazel test //..."
      if (cd "$REPO_ROOT" && bazel test //... --test_output=errors 2>&1 | tail -25); then
        log "healthcheck PASSED: root module tests green"
        return 0
      fi
      log "healthcheck: 'bazel test //...' failed"
    else
      log "healthcheck: bazel version is '${have:-<none>}', want 'bazel $want'"
    fi
    log "healthcheck: not ready yet, retrying in 15s"
    sleep 15
  done
}

main() {
  log "mode=${AIR_STARTUP_MODE:-unset} repo=$REPO_ROOT"
  install_bazelisk
  configure_shell_env
  configure_bazelrc
  configure_git
  install_patch
  install_pre_commit

  if [ -n "$WARMUP" ]; then
    warm_caches
    healthcheck
  else
    log "task mode: skipping cache warming (served from the warmup snapshot)"
  fi
  log "startup complete"
}

main "$@"
