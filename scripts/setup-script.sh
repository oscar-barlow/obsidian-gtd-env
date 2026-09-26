#!/usr/bin/env bash
#
# Environment SETUP SCRIPT for running Obsidian (desktop) headless in a Claude
# Code web environment, so Claude can drive the bundled CLI — including Dataview
# + Charts — over your synced vault for GTD weekly reviews.
#
# IMPORTANT — what runs where (this is why an earlier all-in-one script failed):
#   * Setup script (THIS file)  -> runs once at environment build, as root, and
#     is CACHED as a filesystem snapshot. Secrets are NOT in its environment, and
#     node here may be v20. So this file does ONLY secret-free, cacheable install.
#   * SessionStart hook -> runs `obsidian-up` (installed below) at the start of
#     every session, where the secrets, node v22, and the live proxy exist. That
#     is where login + vault sync + launch happen.
#
# Paste this into your environment's *Setup script* field. Put the SessionStart
# hook (.claude/settings.json + .claude/hooks/session-start.sh) in your repo.
#
# SECRETS (set as environment variables in the environment config; they surface
# at session runtime, which is exactly where obsidian-up uses them):
#   SECRET_EMAIL  SECRET_PASSWORD  SECRET_VAULT_ENCRYPTION_PASSWORD
#   OBSIDIAN_REMOTE_VAULT (optional, default "obsidian")  SECRET_MFA (optional)
#
set -euo pipefail

OBSIDIAN_VERSION="${OBSIDIAN_VERSION:-1.12.7}"
DATAVIEW_VERSION="${DATAVIEW_VERSION:-0.5.70}"
CHARTS_VERSION="${CHARTS_VERSION:-3.9.0}"

OBS_USER="obs"
OBS_HOME="/home/${OBS_USER}"
VAULT_DIR="${OBS_HOME}/vault"
PLUGIN_SRC="/opt/obsidian-plugins"   # cached plugin template, copied into vault at session time
REMOTE_VAULT="${OBSIDIAN_REMOTE_VAULT:-obsidian}"
DISPLAY_NUM=":99"

log() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------------------
log "1/7  System dependencies"
# xvfb: virtual display for the GUI + CLI client.
# libsecret-1-0 + gnome-keyring + dbus-x11: keytar backend for obsidian-headless.
# Some base images carry broken third-party PPAs (deadsnakes, ondrej/php) that
# 403 on noble and would abort `apt-get update`; drop them and don't be fatal.
sudo grep -rl 'ppa.launchpadcontent.net' /etc/apt/sources.list.d/ 2>/dev/null \
  | sudo xargs -r rm -f || true
sudo apt-get update -qq || true
sudo apt-get install -y -qq \
  xvfb libsecret-1-0 gnome-keyring dbus-x11 ca-certificates curl

# python-dateutil: RRULE expansion + tz handling for scripts/parse_ics.py (the
# weekly-review calendar check). Installed explicitly here rather than relying
# on it happening to already be on the base image.
pip3 install --quiet --break-system-packages python-dateutil 2>/dev/null \
  || pip3 install --quiet python-dateutil

# ---------------------------------------------------------------------------
log "2/7  Install Obsidian desktop (${OBSIDIAN_VERSION})"
ARCH="$(uname -m)"
if [ "${ARCH}" != "x86_64" ]; then
  echo "This script targets amd64; detected ${ARCH}. Adjust the asset below." >&2
  exit 1
fi
DEB="/tmp/obsidian_${OBSIDIAN_VERSION}_amd64.deb"
curl -sSL -o "${DEB}" \
  "https://github.com/obsidianmd/obsidian-releases/releases/download/v${OBSIDIAN_VERSION}/obsidian_${OBSIDIAN_VERSION}_amd64.deb"
sudo apt-get install -y -qq "${DEB}"
# The SUID sandbox helper doesn't work reliably in container runtimes (no
# user-namespace / setuid support), so the GUI is launched with --no-sandbox
# below. Keep the chmod as a fallback for any Electron codepath that probes the
# helper before seeing the flag.
sudo chmod 4755 /opt/Obsidian/chrome-sandbox

# ---------------------------------------------------------------------------
log "3/7  Create '${OBS_USER}' user"
# NB: obsidian-headless is NOT installed here — it needs node >=22, but the build
# may run on v20, and nvm global packages are per-node-version. obsidian-up
# installs it at session time after selecting node 22.
id "${OBS_USER}" >/dev/null 2>&1 || sudo useradd -m -s /bin/bash "${OBS_USER}"

# `sudo -u obs` goes through a real PAM login session (pam_limits.so is active
# for sudo), and with no limits.conf entry for obs it fell back to the kernel's
# bare RLIMIT_NOFILE default: 1024 soft, even though the container's own hard
# cap (20000) was already there for root to use. Chromium/Electron's
# multi-process model (renderer + GPU + utility + zygote, each holding sockets,
# shared memory segments, ICU/V8 snapshot fds, LevelDB/IndexedDB file handles)
# eats into that fast; 1024 is tight enough to crash a real session. Confirmed
# live: obs was flipping between 1024 and 20000 depending on invocation path,
# and Obsidian was segfaulting (SIGSEGV / int3 trap, per dmesg) on repeated
# fresh launches under the low limit. Raise both soft and hard so any
# sudo -u obs / su - obs session gets full headroom, matching root.
echo "${OBS_USER} soft nofile 65536
${OBS_USER} hard nofile 65536" | sudo tee /etc/security/limits.d/obs-nofile.conf >/dev/null

# `Defaults env_reset` (stock /etc/sudoers) strips NODE_EXTRA_CA_CERTS /
# HTTPS_PROXY / etc. across every sudo boundary. That's silently fatal for
# anything in this script or in obsidian-up that shells out to `sudo` and then
# touches the network (e.g. obsidian-up's `npm install -g obsidian-headless`):
# without the proxy's CA, every registry request comes back
# SELF_SIGNED_CERT_IN_CHAIN, retries 3x, and falls back to a stale cache ~70s
# later — per package, compounding into a multi-minute stall across a real
# dependency tree. Keep the specific vars this environment already exports for
# every other process, so a sudo'd command sees the same network it would
# unprivileged.
echo 'Defaults env_keep += "NODE_EXTRA_CA_CERTS HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy SSL_CERT_FILE CURL_CA_BUNDLE"' \
  | sudo tee /etc/sudoers.d/90-env-keep-network >/dev/null
sudo chmod 440 /etc/sudoers.d/90-env-keep-network
sudo visudo -c

# ---------------------------------------------------------------------------
log "4/7  Cache Dataview + Charts plugin template"
sudo mkdir -p "${PLUGIN_SRC}/dataview" "${PLUGIN_SRC}/obsidian-charts"
fetch_plugin() { # repo  version  destdir
  for f in main.js manifest.json styles.css; do
    sudo curl -sSL -o "$3/$f" "https://github.com/$1/releases/download/$2/$f"
  done
}
fetch_plugin blacksmithgu/obsidian-dataview "${DATAVIEW_VERSION}" "${PLUGIN_SRC}/dataview"
fetch_plugin phibr0/obsidian-charts        "${CHARTS_VERSION}"   "${PLUGIN_SRC}/obsidian-charts"

# ---------------------------------------------------------------------------
log "5/7  Obsidian global config (enable CLI + register vault)"
VID="$(printf '%s' "${VAULT_DIR}" | md5sum | cut -c1-16)"
sudo -u "${OBS_USER}" mkdir -p "${OBS_HOME}/.config/obsidian"
printf '{"cli":true,"vaults":{"%s":{"path":"%s","ts":1700000000000,"open":true}}}\n' \
  "${VID}" "${VAULT_DIR}" \
  | sudo -u "${OBS_USER}" tee "${OBS_HOME}/.config/obsidian/obsidian.json" >/dev/null

# ---------------------------------------------------------------------------
log "6/7  Install 'obsidian-up' (session-time sync + launch) and 'obx' (client)"

# Build-time constants baked in; runtime values (SECRET_*, NODE_EXTRA_CA_CERTS,
# HTTPS_PROXY) are referenced live and must NOT be expanded now -> quoted heredoc.
sudo tee /usr/local/bin/obsidian-up >/dev/null <<EOF
#!/usr/bin/env bash
OBS_USER="${OBS_USER}"; VAULT_DIR="${VAULT_DIR}"; PLUGIN_SRC="${PLUGIN_SRC}"
REMOTE_VAULT="${REMOTE_VAULT}"; DISPLAY_NUM="${DISPLAY_NUM}"
EOF
sudo tee -a /usr/local/bin/obsidian-up >/dev/null <<'EOF'
# Not `set -e`: a sync hiccup must not abort session startup.
set -uo pipefail
SOCK="/home/${OBS_USER}/.obsidian-cli.sock"

# obsidian-headless needs node >=22. Select it via nvm if the default is older.
if command -v node >/dev/null && [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  for d in "${NVM_DIR:-}" "$HOME/.nvm" /usr/local/nvm /root/.nvm /opt/nvm; do
    [ -n "$d" ] && [ -s "$d/nvm.sh" ] && . "$d/nvm.sh" && nvm use 22 >/dev/null 2>&1 && break
  done
fi
command -v ob >/dev/null 2>&1 || npm install -g obsidian-headless >/dev/null 2>&1 || true

# Vault sync — needs the session secrets + live proxy (both inherited here). The
# proxy CA (NODE_EXTRA_CA_CERTS) and HTTPS_PROXY are already in this env, so the
# ob Node process picks them up automatically. Secrets pass as single argv
# elements (safe for special characters — no shell re-parsing).
if [ -z "${SECRET_EMAIL:-}" ]; then
  echo "obsidian-up: SECRET_EMAIL not set in this session; skipping vault sync." >&2
else
  export VAULT_DIR REMOTE_VAULT
  dbus-run-session -- bash -c '
    echo "" | gnome-keyring-daemon --unlock >/dev/null 2>&1 || true
    MFA_ARG=(); [ -n "${SECRET_MFA:-}" ] && MFA_ARG=(--mfa "$SECRET_MFA")
    ob login --email "$SECRET_EMAIL" --password "$SECRET_PASSWORD" "${MFA_ARG[@]}"
    ob sync-setup --vault "$REMOTE_VAULT" --path "$VAULT_DIR" \
                  --password "$SECRET_VAULT_ENCRYPTION_PASSWORD" 2>/dev/null || true
    # Silence per-file progress (thousands of lines -> ~264KB) that would otherwise
    # flood the SessionStart hook and bloat the context window. Keep stderr for errors.
    ob sync --path "$VAULT_DIR" >/dev/null
  ' || echo "obsidian-up: vault sync failed (see above)." >&2
fi

# Ensure the CLI-enable flag + vault registration exist. This is normally
# written once at build time (step 5/7 below) and never touched again — but if
# it's ever lost (a bad crash, or a profile-cache clear that goes too far, as
# happened live once during testing) every future eval fails with "Command
# line interface is not enabled", and obsidian-up had no way to notice or
# recover. Recreate it idempotently on every run, same as community-plugins.json
# just below.
VID="$(printf '%s' "${VAULT_DIR}" | md5sum | cut -c1-16)"
sudo -u "${OBS_USER}" mkdir -p "/home/${OBS_USER}/.config/obsidian"
printf '{"cli":true,"vaults":{"%s":{"path":"%s","ts":1700000000000,"open":true}}}\n' \
  "${VID}" "${VAULT_DIR}" \
  | sudo -u "${OBS_USER}" tee "/home/${OBS_USER}/.config/obsidian/obsidian.json" >/dev/null

# Ensure the vault dir + plugins exist and are owned by obs.
sudo mkdir -p "${VAULT_DIR}/.obsidian/plugins"
for p in dataview obsidian-charts; do
  if [ ! -f "${VAULT_DIR}/.obsidian/plugins/${p}/main.js" ] && [ -d "${PLUGIN_SRC}/${p}" ]; then
    sudo cp -r "${PLUGIN_SRC}/${p}" "${VAULT_DIR}/.obsidian/plugins/"
  fi
done
echo '["dataview","obsidian-charts"]' \
  | sudo tee "${VAULT_DIR}/.obsidian/community-plugins.json" >/dev/null
sudo chown -R "${OBS_USER}:${OBS_USER}" "${VAULT_DIR}"

# Launch a persistent virtual display + the GUI (the CLI socket server), as
# obs, retrying the whole launch up to 3 times. This matters: a launch
# attempt can leave a socket file behind (bind() succeeded) without the app
# ever becoming responsive (crashed or stuck very early in startup, before
# logging anything) — confirmed live, repeatedly. Left alone, that stale
# socket makes every later `obx` call either hang or (worse) make the
# `obsidian` CLI binary conclude no instance is running and silently spawn a
# SECOND competing Electron instance as a side effect of what should have
# been a thin client call. Detect "socket exists but never answers" and
# actually clean up and retry, rather than trusting `-S "${SOCK}"` alone.
#
# `setsid` is load-bearing: this runs from a SessionStart hook, and when the
# hook finishes the harness tears down its whole process group. `nohup` only
# blocks SIGHUP, so without a fresh session/process group both Xvfb and the
# GUI die moments after the hook reports success.
#
# `ulimit -n` here is belt-and-braces on top of the /etc/security/limits.d
# entry set up in the setup script: raise obs's *soft* fd limit to whatever
# its hard cap allows right before exec'ing into Xvfb/Obsidian, so a launch
# path that for any reason skips the full PAM login stack still gets
# headroom.
#
# 640x480 (a change made alongside the sandbox/GPU flags below) is reverted
# back to 1280x800: it wasn't motivated by the GPU rationale (24-bit color
# was the actual concern, not smallness) and an unusually small viewport is
# itself a plausible source of Skia/Chromium rendering edge cases — not
# proven, but free to remove now that the flags below address the GPU path
# properly.
#
# `timeout` on every single CLI round trip: a bare call has no way to fail —
# it just hangs the whole session-start hook. `timeout` turns a stuck call
# into "this attempt didn't land," which the readiness probe and the
# plugin-enable loop below just try again.
obx() { timeout 15 sudo -u "${OBS_USER}" -- env DISPLAY="${DISPLAY_NUM}" obsidian "$@" 2>/dev/null; }

launched=""
for attempt in 1 2 3; do
  # Only a genuinely fresh launch (no Xvfb, no socket) gets its Chromium cache
  # cleared first -- vault content and plugin config live under ${VAULT_DIR},
  # not here, so this only ever throws away disposable browser-engine state;
  # but after an ungraceful crash that state can be left corrupt, and a
  # corrupted Cache/Code Cache/GPUCache/LevelDB dir causing every subsequent
  # relaunch to crash again on the same corrupt read is a well-known Electron
  # failure mode.
  if ! pgrep -f "Xvfb ${DISPLAY_NUM}" >/dev/null && [ ! -S "${SOCK}" ]; then
    sudo rm -rf "/home/${OBS_USER}/.config/obsidian/Cache" \
                "/home/${OBS_USER}/.config/obsidian/Code Cache" \
                "/home/${OBS_USER}/.config/obsidian/GPUCache" \
                "/home/${OBS_USER}/.config/obsidian/DawnGraphiteCache" \
                "/home/${OBS_USER}/.config/obsidian/DawnWebGPUCache" \
                "/home/${OBS_USER}/.config/obsidian/blob_storage" \
                "/home/${OBS_USER}/.config/obsidian/Crashpad" 2>/dev/null || true
  fi

  if ! pgrep -f "Xvfb ${DISPLAY_NUM}" >/dev/null; then
    sudo -u "${OBS_USER}" setsid nohup Xvfb "${DISPLAY_NUM}" -screen 0 1280x800x24 \
      -nolisten tcp \
      >/tmp/xvfb.log 2>&1 </dev/null &
    sleep 1
  fi
  if [ ! -S "${SOCK}" ]; then
    sudo -u "${OBS_USER}" -- env DISPLAY="${DISPLAY_NUM}" setsid nohup bash -c '
      ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
      exec /opt/Obsidian/obsidian \
        --no-sandbox \
        --disable-gpu \
        --disable-software-rasterizer \
        --disable-dev-shm-usage \
        --disable-renderer-backgrounding \
        --disable-background-timer-throttling \
        --disable-backgrounding-occluded-windows \
        --disable-hang-monitor
    ' >"/home/${OBS_USER}/gui.log" 2>&1 </dev/null &
    for _ in $(seq 1 90); do [ -S "${SOCK}" ] && break; sleep 0.5; done
  fi

  if [ ! -S "${SOCK}" ]; then
    echo "obsidian-up: attempt ${attempt}/3: CLI socket never appeared." >&2
    continue
  fi

  # The socket file can exist before Obsidian is actually accepting CLI
  # connections (bind() vs. ready-to-serve is a real race on a cold,
  # first-time launch with a lot to index) -- confirm it's truly answering.
  ready=""
  for _ in $(seq 1 20); do
    case "$(obx eval code='1+1')" in *2*) ready=1; break ;; esac
    sleep 1
  done

  if [ -n "${ready}" ]; then
    launched=1
    break
  fi

  echo "obsidian-up: attempt ${attempt}/3: socket appeared but never answered (crashed or stuck during startup) -- cleaning up and retrying." >&2
  sudo pkill -9 -f "/opt/Obsidian/obsidian" 2>/dev/null || true
  sudo rm -f "${SOCK}"
  sleep 2
done

[ -n "${launched}" ] || { echo "obsidian-up: Obsidian never became responsive after 3 launch attempts. See /home/${OBS_USER}/gui.log." >&2; exit 1; }

# Restricted Mode + plugin enable, all inside one retry loop rather than fired
# once each. Each piece has its own reason to need a retry: the first-run
# "trust author" modal (harmless no-op once already dismissed, so safe every
# iteration) blocks setEnable(); how long the plugin system takes to come up
# after that varies with cold-start/indexing load, and on a genuine
# first-sync cold boot it has been observed to fail outright (session-start
# hook logged "GUI is up but these plugins did not load: dataview
# obsidian-charts", confirmed from this session's own hook output).
loaded=""
for _ in $(seq 1 30); do
  obx eval code='(()=>{const b=[...document.querySelectorAll(".modal button")].find(x=>x.innerText.includes("Trust author"));if(b)b.click();return !!b})()' >/dev/null
  obx eval code='app.plugins.setEnable(true)' >/dev/null
  obx eval code='app.plugins.enablePlugin("dataview")' >/dev/null
  obx eval code='app.plugins.enablePlugin("obsidian-charts")' >/dev/null
  # The CLI prints its own startup banner on stdout and prefixes real results
  # with "=> ", so a dead renderer yields a line that still reads like success
  # ("Obsidian ready. Loaded: <timestamp> Loaded main app package ..."). Grep
  # for the plugin ids instead; without Dataview the session can't query live
  # state.
  loaded="$(obx eval "code=Object.keys(app.plugins.plugins).join(',')")"
  missing=""
  for p in dataview obsidian-charts; do
    case "${loaded}" in *"${p}"*) ;; *) missing="${missing} ${p}";; esac
  done
  [ -z "${missing}" ] && break
  sleep 1
done

if [ -n "${missing}" ]; then
  echo "obsidian-up: GUI is up but these plugins did not load:${missing}" >&2
  echo "obsidian-up: see /home/${OBS_USER}/gui.log" >&2
  exit 1
fi
echo "Obsidian ready. Plugins loaded: dataview, obsidian-charts"
EOF
sudo chmod +x /usr/local/bin/obsidian-up

# obx: CLI client wrapper for use during the session (named to avoid clashing
# with obsidian-headless's own `ob`).
sudo tee /usr/local/bin/obx >/dev/null <<EOF
#!/usr/bin/env bash
# Examples:
#   obx files
#   obx read file="Some Project"
#   obx eval code='app.plugins.plugins.dataview.api.pages().where(p=>p.status=="active").length'
exec sudo -u ${OBS_USER} -- env DISPLAY=${DISPLAY_NUM} obsidian "\$@"
EOF
sudo chmod +x /usr/local/bin/obx

log "Setup complete (secret-free). The SessionStart hook runs 'obsidian-up' each session."