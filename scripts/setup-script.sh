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
log "1/6  System dependencies"
# xvfb: virtual display for the GUI + CLI client.
# libsecret-1-0 + gnome-keyring + dbus-x11: keytar backend for obsidian-headless.
# Some base images carry broken third-party PPAs (deadsnakes, ondrej/php) that
# 403 on noble and would abort `apt-get update`; drop them and don't be fatal.
sudo grep -rl 'ppa.launchpadcontent.net' /etc/apt/sources.list.d/ 2>/dev/null \
  | sudo xargs -r rm -f || true
sudo apt-get update -qq || true
sudo apt-get install -y -qq \
  xvfb libsecret-1-0 gnome-keyring dbus-x11 ca-certificates curl

# ---------------------------------------------------------------------------
log "2/6  Install Obsidian desktop (${OBSIDIAN_VERSION})"
ARCH="$(uname -m)"
if [ "${ARCH}" != "x86_64" ]; then
  echo "This script targets amd64; detected ${ARCH}. Adjust the asset below." >&2
  exit 1
fi
DEB="/tmp/obsidian_${OBSIDIAN_VERSION}_amd64.deb"
curl -sSL -o "${DEB}" \
  "https://github.com/obsidianmd/obsidian-releases/releases/download/v${OBSIDIAN_VERSION}/obsidian_${OBSIDIAN_VERSION}_amd64.deb"
sudo apt-get install -y -qq "${DEB}"
# Electron won't run as root without --no-sandbox; run it as a non-root user
# with a working SUID sandbox helper instead.
sudo chmod 4755 /opt/Obsidian/chrome-sandbox

# ---------------------------------------------------------------------------
log "3/6  Create '${OBS_USER}' user"
# NB: obsidian-headless is NOT installed here — it needs node >=22, but the build
# may run on v20, and nvm global packages are per-node-version. obsidian-up
# installs it at session time after selecting node 22.
id "${OBS_USER}" >/dev/null 2>&1 || sudo useradd -m -s /bin/bash "${OBS_USER}"

# ---------------------------------------------------------------------------
log "4/6  Cache Dataview + Charts plugin template"
sudo mkdir -p "${PLUGIN_SRC}/dataview" "${PLUGIN_SRC}/obsidian-charts"
fetch_plugin() { # repo  version  destdir
  for f in main.js manifest.json styles.css; do
    sudo curl -sSL -o "$3/$f" "https://github.com/$1/releases/download/$2/$f"
  done
}
fetch_plugin blacksmithgu/obsidian-dataview "${DATAVIEW_VERSION}" "${PLUGIN_SRC}/dataview"
fetch_plugin phibr0/obsidian-charts        "${CHARTS_VERSION}"   "${PLUGIN_SRC}/obsidian-charts"

# ---------------------------------------------------------------------------
log "5/6  Obsidian global config (enable CLI + register vault)"
VID="$(printf '%s' "${VAULT_DIR}" | md5sum | cut -c1-16)"
sudo -u "${OBS_USER}" mkdir -p "${OBS_HOME}/.config/obsidian"
printf '{"cli":true,"vaults":{"%s":{"path":"%s","ts":1700000000000,"open":true}}}\n' \
  "${VID}" "${VAULT_DIR}" \
  | sudo -u "${OBS_USER}" tee "${OBS_HOME}/.config/obsidian/obsidian.json" >/dev/null

# ---------------------------------------------------------------------------
log "6/6  Install 'obsidian-up' (session-time sync + launch) and 'obx' (client)"

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

# Launch a persistent virtual display + the GUI (the CLI socket server), as obs.
if ! pgrep -f "Xvfb ${DISPLAY_NUM}" >/dev/null; then
  sudo -u "${OBS_USER}" nohup Xvfb "${DISPLAY_NUM}" -screen 0 1280x800x24 \
    >/tmp/xvfb.log 2>&1 &
  sleep 1
fi
if [ ! -S "${SOCK}" ]; then
  sudo -u "${OBS_USER}" -- env DISPLAY="${DISPLAY_NUM}" nohup \
    /opt/Obsidian/obsidian --disable-gpu --disable-dev-shm-usage \
    >"/home/${OBS_USER}/gui.log" 2>&1 &
  for _ in $(seq 1 90); do [ -S "${SOCK}" ] && break; sleep 0.5; done
fi
[ -S "${SOCK}" ] || { echo "obsidian-up: CLI socket never appeared." >&2; exit 1; }

# Restricted Mode off (idempotent) + ensure plugins loaded.
obx() { sudo -u "${OBS_USER}" -- env DISPLAY="${DISPLAY_NUM}" obsidian "$@" 2>/dev/null; }
# One round-trip to the renderer instead of three.
obx eval "code=app.plugins.setEnable(true);app.plugins.enablePlugin('dataview');app.plugins.enablePlugin('obsidian-charts')" >/dev/null
echo "Obsidian ready. Loaded: $(obx eval "code=Object.keys(app.plugins.plugins).join(',')")"
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