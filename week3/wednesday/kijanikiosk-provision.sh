#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# KijaniKiosk production provisioning script
# Encodes the Tuesday access model and hardening decisions so they apply
# automatically and idempotently to every provisioned Ubuntu server.
# Safe to run twice: every operation is guarded or declarative.
# ---------------------------------------------------------------------------

NODE_MAJOR_VERSION="24"
NGINX_VERSION="1.30.4-5"
APP_BASE="/opt/kijanikiosk"
export DEBIAN_FRONTEND=noninteractive


# ---------------------------------------------------------------------------
# Structured logging: consistent timestamp + level, warnings/errors to stderr
# ---------------------------------------------------------------------------
log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }


# ---------------------------------------------------------------------------
# Preconditions: refuse to run without root, or on a non-Ubuntu system
# ---------------------------------------------------------------------------
check_preconditions() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root (try: sudo bash $0)"
        exit 1
    fi

    if [ -r /etc/os-release ]; then
        . /etc/os-release
        if [ "${ID:-}" != "ubuntu" ]; then
            log_error "This script only supports Ubuntu (detected: ${ID:-unknown})"
            exit 1
        fi
    else
        log_error "Cannot read /etc/os-release; refusing to run on unknown system"
        exit 1
    fi

    log_info "Preconditions OK: running as root on Ubuntu ${VERSION_ID:-?}"
}


# ---------------------------------------------------------------------------
# Phase 1: Package Installation (pinned versions, held against drift)
# ---------------------------------------------------------------------------
provision_packages() {
    log_info "Updating package index and installing prerequisites"
    apt-get update -qq
    apt-get install -y --no-install-recommends curl gnupg acl ufw

    # NodeSource GPG key using the signed-by pattern. Overwriting the key file
    # is idempotent: gpg --dearmor -o REPLACES contents rather than appending,
    # so repeated runs converge to the same file.
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
    chmod 0644 /etc/apt/keyrings/nodesource.gpg

    # Repository entry referencing NODE_MAJOR_VERSION. > overwrites (idempotent).
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR_VERSION}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list

    log_info "Installing nginx=${NGINX_VERSION} and nodejs (node ${NODE_MAJOR_VERSION}.x)"
    apt-get update -qq
    apt-get install -y --no-install-recommends "nginx=${NGINX_VERSION}" nodejs

    # Hold both so later upgrades cannot move them off the pinned versions.
    apt-mark hold nginx nodejs

    local nginx_installed node_installed
    nginx_installed="$(nginx -v 2>&1)"   # nginx prints version to stderr
    node_installed="$(node --version)"
    log_info "Installed ${nginx_installed}, node ${node_installed}"
}


# ---------------------------------------------------------------------------
# Phase 2: Service Accounts and group (idempotent)
# ---------------------------------------------------------------------------
provision_service_accounts() {
    # Create the shared group only if absent
    if ! getent group kijanikiosk >/dev/null; then
        groupadd --system kijanikiosk
        log_info "Created group kijanikiosk"
    fi

    # Create each service account if absent, then add to the group
    for user in kk-api kk-payments kk-logs; do
        if ! getent passwd "$user" >/dev/null; then
            useradd --system --no-create-home --home-dir /nonexistent \
                --shell /usr/sbin/nologin --user-group \
                --comment "KijaniKiosk ${user} service account" "$user"
            log_info "Created service account $user"
        fi
        usermod -aG kijanikiosk "$user"   # idempotent: -a appends
    done

    # Add amina to the group only if her account already exists (do not create)
    if getent passwd amina >/dev/null; then
        usermod -aG kijanikiosk amina
        log_info "Added existing user amina to kijanikiosk"
    fi
}


# ---------------------------------------------------------------------------
# Phase 3: Directory Structure, ownership, modes, ACLs (Tuesday's access model)
# ---------------------------------------------------------------------------
provision_directories() {
    mkdir -p "$APP_BASE"/{api,payments,logs,config,scripts,shared/logs}

    # Ownership: each service owns its own dir; config/shared are root:kijanikiosk
    chown root:kijanikiosk         "$APP_BASE"
    chown kk-api:kk-api            "$APP_BASE/api"
    chown kk-payments:kk-payments "$APP_BASE/payments"
    chown kk-logs:kk-logs         "$APP_BASE/logs"
    chown root:kijanikiosk         "$APP_BASE/config"
    chown root:root                "$APP_BASE/scripts"
    chown root:kijanikiosk         "$APP_BASE/shared"
    chown kk-logs:kk-logs         "$APP_BASE/shared/logs"

    # Modes
    chmod 750  "$APP_BASE" "$APP_BASE"/{api,payments,logs,config} "$APP_BASE/shared" "$APP_BASE/scripts"
    # SGID (leading 2): new files in shared/logs inherit the kk-logs group
    chmod 2770 "$APP_BASE/shared/logs"

    # Access ACLs: kk-api writes logs, kk-payments reads them
    setfacl -m u:kk-api:rwx     "$APP_BASE/shared/logs"
    setfacl -m u:kk-payments:rx "$APP_BASE/shared/logs"

    # Default ACLs so files created inside inherit the same access
    setfacl -d -m u:kk-api:rwx     "$APP_BASE/shared/logs"
    setfacl -d -m u:kk-payments:rx "$APP_BASE/shared/logs"

    log_info "Directory tree, ownership, modes and ACLs applied"
}


# ---------------------------------------------------------------------------
# Phase 4: Production-grade systemd unit file
# cat > file << 'EOF' overwrites every run (idempotent); quoted 'EOF' keeps
# the heredoc literal so nothing is shell-expanded.
# ---------------------------------------------------------------------------
provision_systemd_units() {
    cat > /etc/systemd/system/kk-api.service << 'EOF'
[Unit]
Description=KijaniKiosk API service
After=network.target

[Service]
Type=simple
User=kk-api
Group=kk-api
WorkingDirectory=/opt/kijanikiosk/api
EnvironmentFile=/opt/kijanikiosk/config/db.env
ExecStart=/usr/bin/node /opt/kijanikiosk/api/server.js

# Restart policy with burst limiting: restart on failure, but give up if the
# service crash-loops more than 5 times in 60 seconds.
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/kijanikiosk/shared/logs

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    # Enable for boot but DO NOT start: application code is not deployed yet.
    systemctl enable kk-api.service
    log_info "kk-api.service written and enabled (not started)"
}


# ---------------------------------------------------------------------------
# Phase 5: Firewall - allow only SSH (22) and HTTP (80), deny everything else
# ---------------------------------------------------------------------------
provision_firewall() {
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH first so enabling the firewall cannot lock us out
    ufw allow 22/tcp
    ufw allow 80/tcp

    ufw --force enable   # --force skips the interactive prompt
    log_info "ufw configured: allow 22/tcp and 80/tcp, deny all other incoming"
}


# ---------------------------------------------------------------------------
# Phase 6: Verification - failed counter, exit non-zero if anything fails
# ---------------------------------------------------------------------------
verify_provisioning() {
    local failed=0

    # Service accounts exist
    for user in kk-api kk-payments kk-logs; do
        if getent passwd "$user" >/dev/null; then
            echo "[OK]   user $user exists"
        else
            echo "[FAIL] user $user missing"; failed=$((failed + 1))
        fi
    done

    # Directories exist
    for dir in api payments logs config scripts shared/logs; do
        if [ -d "$APP_BASE/$dir" ]; then
            echo "[OK]   directory $APP_BASE/$dir exists"
        else
            echo "[FAIL] directory $APP_BASE/$dir missing"; failed=$((failed + 1))
        fi
    done

    # SUID scan: there must be NO SUID files in the app tree
    if [ -z "$(find "$APP_BASE" -perm /4000 -type f 2>/dev/null)" ]; then
        echo "[OK]   no SUID files in $APP_BASE"
    else
        echo "[FAIL] SUID files found in $APP_BASE"; failed=$((failed + 1))
    fi

    # Version holds active
    for pkg in nginx nodejs; do
        if apt-mark showhold | grep -qx "$pkg"; then
            echo "[OK]   $pkg is held"
        else
            echo "[FAIL] $pkg is not held"; failed=$((failed + 1))
        fi
    done

    # systemd hardening directives present
    for directive in NoNewPrivileges PrivateTmp ProtectSystem; do
        if grep -q "^${directive}=" /etc/systemd/system/kk-api.service 2>/dev/null; then
            echo "[OK]   unit has $directive"
        else
            echo "[FAIL] unit missing $directive"; failed=$((failed + 1))
        fi
    done

    # kk-api.service enabled
    if systemctl is-enabled kk-api.service >/dev/null 2>&1; then
        echo "[OK]   kk-api.service is enabled"
    else
        echo "[FAIL] kk-api.service is not enabled"; failed=$((failed + 1))
    fi

    # ufw active and allowing only the intended ports
    if ufw status | grep -q "Status: active"; then
        echo "[OK]   ufw is active"
    else
        echo "[FAIL] ufw is not active"; failed=$((failed + 1))
    fi
    for port in 22 80; do
        if ufw status | grep -q "^${port}/tcp"; then
            echo "[OK]   ufw allows ${port}/tcp"
        else
            echo "[FAIL] ufw does not allow ${port}/tcp"; failed=$((failed + 1))
        fi
    done

    if [ "$failed" -ne 0 ]; then
        log_error "Verification FAILED: $failed check(s) did not pass"
        return 1
    fi
    log_info "Verification passed: all checks OK"
    return 0
}


# ---------------------------------------------------------------------------
# Run phases in dependency order
# ---------------------------------------------------------------------------
check_preconditions
provision_packages
provision_service_accounts
provision_directories
provision_systemd_units
provision_firewall
verify_provisioning
