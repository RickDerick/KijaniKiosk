#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# KijaniKiosk PRODUCTION FOUNDATION provisioning script  (Week 3 - Friday)
# Converges a dirty VM to the intended secure baseline, idempotently.
#
# --- Expected dirty conditions found in pre-provisioning audit ---
# The VM inherited a CLEANER state than the worst case, so controlled dirty
# state was injected to validate convergence. Conditions handled below:
#
#  1. kk-api  already exists (UID 997): Phase 2 getent guard detects & skips.
#  2. kk-payments already exists (UID 994): Phase 2 getent guard detects & skips.
#  3. kk-logs already exists (UID 993): Phase 2 getent guard detects & skips.
#  4. group kijanikiosk already exists (GID 969, members incl. amina):
#     Phase 2 getent guard detects & skips; membership re-asserted idempotently.
#  5. /opt/kijanikiosk/config was chmod 777 (INJECTED): Phase 3 resets to 750.
#  6. ufw carried a stale 'deny 3001' rule (INJECTED, simulating Thu remediation):
#     Phase 5 resets ufw to baseline and rebuilds from intent.
#  7. package hold on curl (INJECTED drift): Phase 1 removes the unintended hold,
#     keeps only nginx + nodejs held.
#  8. Only kk-api.service existed at an older/weaker spec; kk-payments and
#     kk-logs units absent: Phase 4 writes all three inline, overwriting kk-api.
#  9. Installed nginx (1.30.4-5) and node (v24.21.0) already match pins:
#     Phase 1 verifies match and skips reinstall, re-asserting holds.
# 10. Config lives under /opt (not /etc), so ProtectSystem=strict does NOT
#     block EnvironmentFile reads. No config move needed (Integration Challenge A).
# ===========================================================================

NODE_MAJOR_VERSION="24"
NGINX_VERSION="1.30.4-5"
APP_BASE="/opt/kijanikiosk"
MONITORING_CIDR="10.0.1.0/24"
export DEBIAN_FRONTEND=noninteractive


# --- Structured logging ----------------------------------------------------
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK]    $*"; }
warn()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" >&2; }
error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; exit 1; }


# --- Preconditions ---------------------------------------------------------
check_preconditions() {
    log "Phase 0: preconditions"
    if [ "$(id -u)" -ne 0 ]; then
        error "Must run as root (sudo bash $0)"
    fi
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        [ "${ID:-}" = "ubuntu" ] || error "Ubuntu only (found: ${ID:-unknown})"
    else
        error "Cannot read /etc/os-release"
    fi
    success "Running as root on Ubuntu ${VERSION_ID:-?}"
}


# ===========================================================================
# Phase 1: Packages (pinned, held; converge drift)
# ===========================================================================
provision_packages() {
    log "Phase 1: packages"
    apt-get update -qq || warn "apt-get update reported errors (unrelated third-party repos?) - continuing"
    apt-get install -y --no-install-recommends curl gnupg acl ufw jq

    # Remove any hold the script does not own (INJECTED: curl). Detect first.
    for pkg in $(apt-mark showhold); do
        if [ "$pkg" != "nginx" ] && [ "$pkg" != "nodejs" ]; then
            warn "Found unexpected hold on '$pkg' - removing (not managed here)"
            apt-mark unhold "$pkg" >/dev/null
        fi
    done

    # NodeSource key (overwrite = idempotent; --yes avoids the prompt).
    # Timeouts so a network blip fails fast instead of hanging the script.
    install -d -m 0755 /etc/apt/keyrings
    if curl -fsSL --connect-timeout 10 --max-time 30 \
         https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
         | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg; then
        chmod 0644 /etc/apt/keyrings/nodesource.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR_VERSION}.x nodistro main" \
          > /etc/apt/sources.list.d/nodesource.list
        apt-get update -qq || warn "apt-get update reported errors (unrelated repos?) - continuing"
    else
        warn "Could not fetch NodeSource key (network?). nodejs already installed & held, so continuing offline."
    fi

    # Challenge D: check installed vs pinned. Match -> skip. Differ -> fail loud.
    local nginx_now
    nginx_now="$(dpkg-query -W -f='${Version}' nginx 2>/dev/null || echo none)"
    if [ "$nginx_now" = "$NGINX_VERSION" ]; then
        success "nginx already at pinned ${NGINX_VERSION} - skipping install"
    elif [ "$nginx_now" = "none" ]; then
        log "nginx not installed - installing ${NGINX_VERSION}"
        apt-get install -y --no-install-recommends "nginx=${NGINX_VERSION}"
    else
        error "nginx installed=${nginx_now} != pinned=${NGINX_VERSION}. Manual review required (refusing silent downgrade)."
    fi

    if ! dpkg -l nodejs >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends nodejs
    else
        success "nodejs present ($(node --version)) - skipping install"
    fi

    apt-mark hold nginx nodejs >/dev/null
    success "Holds set: nginx nodejs ($(nginx -v 2>&1), node $(node --version))"
}


# ===========================================================================
# Phase 2: Service accounts and group (idempotent, dirty-aware)
# ===========================================================================
provision_service_accounts() {
    log "Phase 2: service accounts"
    if getent group kijanikiosk >/dev/null; then
        success "group kijanikiosk exists (GID $(getent group kijanikiosk | cut -d: -f3))"
    else
        groupadd --system kijanikiosk
        success "created group kijanikiosk"
    fi

    for user in kk-api kk-payments kk-logs; do
        if getent passwd "$user" >/dev/null; then
            success "already exists: $user (UID $(id -u "$user"))"
        else
            useradd --system --no-create-home --home-dir /nonexistent \
                --shell /usr/sbin/nologin --user-group \
                --comment "KijaniKiosk ${user} service account" "$user"
            success "created service account $user"
        fi
        usermod -aG kijanikiosk "$user"
    done

    if getent passwd amina >/dev/null; then
        usermod -aG kijanikiosk amina
        success "ensured amina in kijanikiosk group"
    else
        warn "user amina absent - skipping (not created by this script)"
    fi
}


# ===========================================================================
# Phase 3: Directories, ownership, modes, ACLs (repair dirty perms)
# Integration Challenge B: /opt/kijanikiosk/health added to the access model.
# ===========================================================================
provision_directories() {
    log "Phase 3: directories, modes, ACLs"
    mkdir -p "$APP_BASE"/{api,payments,logs,config,scripts,shared/logs,health}

    chown root:kijanikiosk         "$APP_BASE"
    chown kk-api:kk-api            "$APP_BASE/api"
    chown kk-payments:kk-payments "$APP_BASE/payments"
    chown kk-logs:kk-logs         "$APP_BASE/logs"
    chown root:kijanikiosk         "$APP_BASE/config"
    chown root:root                "$APP_BASE/scripts"
    chown root:kijanikiosk         "$APP_BASE/shared"
    chown kk-logs:kk-logs         "$APP_BASE/shared/logs"
    # health: written by root (as kk-logs), read by the kijanikiosk group
    chown kk-logs:kijanikiosk     "$APP_BASE/health"

    # Modes - config reset from injected 777 back to 750
    chmod 750  "$APP_BASE" "$APP_BASE"/{api,payments,logs,config,scripts,shared}
    chmod 2770 "$APP_BASE/shared/logs"
    chmod 750  "$APP_BASE/health"
    success "reset /opt/kijanikiosk/config to 750 (was 777)"

    # Config env files must stay 640, group-readable (service accounts read them)
    if [ -f "$APP_BASE/config/db.env" ]; then
        chown root:kijanikiosk "$APP_BASE/config/db.env"
        chmod 640 "$APP_BASE/config/db.env"
    fi
    if [ -f "$APP_BASE/config/payments-api.env" ]; then
        chown root:kijanikiosk "$APP_BASE/config/payments-api.env"
        chmod 640 "$APP_BASE/config/payments-api.env"
    fi

    # ACLs on shared/logs (idempotent re-assert). Access + default.
    setfacl -m u:kk-api:rwx     "$APP_BASE/shared/logs"
    setfacl -m u:kk-payments:rx "$APP_BASE/shared/logs"
    setfacl -d -m u:kk-api:rwx     "$APP_BASE/shared/logs"
    setfacl -d -m u:kk-payments:rx "$APP_BASE/shared/logs"
    success "ACLs on shared/logs re-asserted (access + default)"
}


# ===========================================================================
# Phase 4: systemd units for ALL THREE services, written inline.
# kk-api, kk-logs  -> target < 3.5 ;  kk-payments -> target < 2.5
# ===========================================================================
provision_systemd_units() {
    log "Phase 4: systemd units (three, inline)"

    # ---- kk-api.service ----
    cat > /etc/systemd/system/kk-api.service << 'EOF'
[Unit]
Description=KijaniKiosk API service
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=kk-api
Group=kk-api
WorkingDirectory=/opt/kijanikiosk/api
EnvironmentFile=/opt/kijanikiosk/config/db.env
ExecStart=/usr/bin/node /opt/kijanikiosk/api/server.js
Restart=on-failure
RestartSec=5

# Hardening (target < 3.5)
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/kijanikiosk/shared/logs
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native
AmbientCapabilities=
UMask=0077
RemoveIPC=true

[Install]
WantedBy=multi-user.target
EOF

    # ---- kk-logs.service (has ExecReload so logrotate postrotate can signal) ----
    cat > /etc/systemd/system/kk-logs.service << 'EOF'
[Unit]
Description=KijaniKiosk log aggregator service
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=kk-logs
Group=kk-logs
WorkingDirectory=/opt/kijanikiosk/logs
EnvironmentFile=/opt/kijanikiosk/config/db.env
ExecStart=/usr/bin/node /opt/kijanikiosk/logs/aggregator.js
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5

# Hardening (target < 3.5)
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/kijanikiosk/shared/logs
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native
AmbientCapabilities=
UMask=0077
RemoveIPC=true

[Install]
WantedBy=multi-user.target
EOF

    # ---- kk-payments.service (target < 2.5 : maximal hardening) ----
    cat > /etc/systemd/system/kk-payments.service << 'EOF'
[Unit]
Description=KijaniKiosk payments service
After=kk-api.service
Wants=kk-api.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=kk-payments
Group=kk-payments
WorkingDirectory=/opt/kijanikiosk/payments
EnvironmentFile=/opt/kijanikiosk/config/payments-api.env
ExecStart=/usr/bin/node /opt/kijanikiosk/payments/processor.js
Restart=on-failure
RestartSec=5

# --- Hardening (target < 2.5) ---
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectProc=invisible
ProcSubset=pid
ReadWritePaths=/opt/kijanikiosk/shared/logs
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077
KeyringMode=private
RemoveIPC=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable kk-api.service kk-logs.service kk-payments.service >/dev/null 2>&1
    success "three units written and enabled (not started - no app code yet)"
}


# ===========================================================================
# Phase 5: Firewall - reset to baseline, rebuild from intent, comment each rule
# ===========================================================================
provision_firewall() {
    log "Phase 5: firewall (reset + intent)"
    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    ufw allow 22/tcp comment 'SSH admin access'
    ufw allow 80/tcp comment 'HTTP public web'
    # Loopback 3001 BEFORE the deny, so nginx proxying works (order matters)
    ufw allow from 127.0.0.1 to any port 3001 proto tcp comment 'payments via loopback for nginx proxy'
    # Monitoring subnet may reach the payments health endpoint
    ufw allow from "$MONITORING_CIDR" to any port 3001 proto tcp comment 'payments health check from monitoring subnet'
    # Everyone else denied on 3001 (internal service port)
    ufw deny 3001/tcp comment 'payments port - deny external, internal only'

    ufw --force enable >/dev/null
    success "ufw rebuilt: 22, 80, 3001(loopback+monitoring allow / external deny)"
}


# ===========================================================================
# Phase 7: Journal persistence + logrotate  (Phase 6 is verification, last)
# ===========================================================================
provision_logging() {
    log "Phase 7: journal persistence + logrotate"

    # Persistent journal capped at 500M
    install -d -m 2755 /var/log/journal
    if ! grep -q '^Storage=persistent' /etc/systemd/journald.conf; then
        sed -i 's/^#\?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf
    fi
    if ! grep -q '^SystemMaxUse=500M' /etc/systemd/journald.conf; then
        sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
    fi
    systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
    systemctl restart systemd-journald
    success "journal persistent, capped 500M"

    # logrotate config for all three services' shared logs.
    # create 640 kk-logs kijanikiosk => new file owned kk-logs:kijanikiosk.
    # Default ACLs on shared/logs propagate the kk-api rwx / kk-payments r-x.
    cat > /etc/logrotate.d/kijanikiosk << 'EOF'
/opt/kijanikiosk/shared/logs/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su kk-logs kijanikiosk
    create 640 kk-logs kijanikiosk
}
EOF
    # Verify the config parses
    if logrotate --debug /etc/logrotate.d/kijanikiosk >/dev/null 2>&1; then
        success "logrotate config valid (--debug passed)"
    else
        error "logrotate --debug failed on /etc/logrotate.d/kijanikiosk"
    fi
}


# ===========================================================================
# Phase 8: Monitoring health checks -> structured JSON
# Integration Challenge B: file owned kk-logs:kijanikiosk, 640, group-readable.
# ===========================================================================
provision_health() {
    log "Phase 8: health checks"
    mkdir -p "$APP_BASE/health"
    chown kk-logs:kijanikiosk "$APP_BASE/health"
    chmod 750 "$APP_BASE/health"

    local api_status payments_status logs_status
    api_status=$(timeout 2 bash -c "echo >/dev/tcp/localhost/3000" 2>/dev/null && echo '"ok"' || echo '"down"')
    payments_status=$(timeout 2 bash -c "echo >/dev/tcp/localhost/3001" 2>/dev/null && echo '"ok"' || echo '"down"')
    logs_status=$(timeout 2 bash -c "echo >/dev/tcp/localhost/3002" 2>/dev/null && echo '"ok"' || echo '"down"')

    printf '{"timestamp":"%s","kk-api":%s,"kk-payments":%s,"kk-logs":%s}\n' \
        "$(date -Is)" "$api_status" "$payments_status" "$logs_status" \
        > "$APP_BASE/health/last-provision.json"

    chown kk-logs:kijanikiosk "$APP_BASE/health/last-provision.json"
    chmod 640 "$APP_BASE/health/last-provision.json"
    success "health JSON written (services likely down - expected, no app code)"
}


# ===========================================================================
# Phase 6: Verification (runs LAST). failed counter; exit non-zero on any fail.
# ===========================================================================
verify_provisioning() {
    log "Phase 6: verification"
    local failed=0

    for user in kk-api kk-payments kk-logs; do
        if getent passwd "$user" >/dev/null; then success "user $user exists"
        else echo "[FAIL] user $user missing"; failed=$((failed+1)); fi
    done

    for dir in api payments logs config scripts shared/logs health; do
        if [ -d "$APP_BASE/$dir" ]; then success "dir $dir exists"
        else echo "[FAIL] dir $dir missing"; failed=$((failed+1)); fi
    done

    if [ -z "$(find "$APP_BASE" -perm /4000 -type f 2>/dev/null)" ]; then
        success "no SUID files in tree"
    else echo "[FAIL] SUID files present"; failed=$((failed+1)); fi

    if [ "$(stat -c '%a' "$APP_BASE/config")" = "750" ]; then
        success "config mode is 750 (repaired)"
    else echo "[FAIL] config mode not 750"; failed=$((failed+1)); fi

    for pkg in nginx nodejs; do
        if apt-mark showhold | grep -qx "$pkg"; then success "$pkg held"
        else echo "[FAIL] $pkg not held"; failed=$((failed+1)); fi
    done
    if apt-mark showhold | grep -qx curl; then
        echo "[FAIL] curl still held (should have been removed)"; failed=$((failed+1))
    else success "curl hold removed"; fi

    for unit in kk-api kk-payments kk-logs; do
        if systemctl is-enabled "${unit}.service" >/dev/null 2>&1; then
            success "${unit}.service enabled"
        else echo "[FAIL] ${unit}.service not enabled"; failed=$((failed+1)); fi
    done

    if grep -q "^After=kk-api.service" /etc/systemd/system/kk-payments.service \
       && grep -q "^Wants=kk-api.service" /etc/systemd/system/kk-payments.service; then
        success "kk-payments depends on kk-api (After+Wants)"
    else echo "[FAIL] kk-payments missing After/Wants kk-api"; failed=$((failed+1)); fi

    # Firewall: one assertion per rule
    local ufwstat; ufwstat=$(ufw status)
    echo "$ufwstat" | grep -q "22/tcp.*ALLOW" && success "ufw: SSH 22 allowed" || { echo "[FAIL] ufw 22 missing"; failed=$((failed+1)); }
    echo "$ufwstat" | grep -q "80/tcp.*ALLOW" && success "ufw: HTTP 80 allowed" || { echo "[FAIL] ufw 80 missing"; failed=$((failed+1)); }
    echo "$ufwstat" | grep -q "3001.*DENY"     && success "ufw: 3001 external deny present" || { echo "[FAIL] ufw 3001 deny missing"; failed=$((failed+1)); }
    if echo "$ufwstat" | grep -E "3001" | grep -q "ALLOW"; then success "ufw: 3001 loopback/monitoring allow present"; else echo "[FAIL] ufw 3001 allow missing"; failed=$((failed+1)); fi

    # journal persistence
    if [ -d /var/log/journal ] && grep -q '^Storage=persistent' /etc/systemd/journald.conf; then
        success "journal persistent"
    else echo "[FAIL] journal not persistent"; failed=$((failed+1)); fi

    # logrotate valid
    if logrotate --debug /etc/logrotate.d/kijanikiosk >/dev/null 2>&1; then
        success "logrotate config valid"
    else echo "[FAIL] logrotate invalid"; failed=$((failed+1)); fi

    # health JSON exists and is group-readable
    if [ -f "$APP_BASE/health/last-provision.json" ]; then
        success "health JSON present"
    else echo "[FAIL] health JSON missing"; failed=$((failed+1)); fi

    echo "-----------------------------------------------------------"
    if [ "$failed" -ne 0 ]; then
        error "VERIFICATION FAILED: $failed check(s) did not pass"
    fi
    success "ALL VERIFICATION CHECKS PASSED"
}


# ===========================================================================
# Run all phases in dependency order
# ===========================================================================
check_preconditions
provision_packages
provision_service_accounts
provision_directories
provision_systemd_units
provision_firewall
provision_logging
provision_health
verify_provisioning
