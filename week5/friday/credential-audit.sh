#!/usr/bin/env bash
# =============================================================================
# KijaniKiosk payments – credential audit (Week 5 Friday, Requirement 5)
#
# Five checks across the three surfaces the brief names – Jenkinsfile, git
# history and build logs – plus the archived artifacts and the Jenkins
# credential store.
#
# Secrets are typed at a hidden prompt, held only in memory, and searched for
# in both literal and base64 form (masking only hides the literal form).
# The script never prints a secret, only whether it was found.
#
# Usage:  ./credential-audit.sh 2>&1 | tee credential-audit.txt
# =============================================================================
set -uo pipefail

PAYMENTS_REPO="${PAYMENTS_REPO:-$HOME/DevOPs15/kijanikiosk-payments}"
JOB_DIR="/var/lib/jenkins/jobs/kijanikiosk-payments"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/kijanikiosk}"
API_IP="${API_IP:-$(multipass info kijanikiosk-api | awk '/IPv4/ {print $2; exit}')}"

FAILURES=0
pass() { echo "  RESULT: PASS - $*"; }
fail() { echo "  RESULT: FAIL - $*"; FAILURES=$((FAILURES + 1)); }

# --- Secrets to search for (hidden input, never echoed) ----------------------
read -rsp "Nexus password for jenkins-ci: " CI_PASS; echo >&2
read -rsp "Nexus password for admin:      " ADMIN_PASS; echo >&2

# Every form a secret could leak in: literal passwords, and the base64
# "user:password" tokens that npm's _auth setting uses.
PATTERNS=$(mktemp)
WORK=$(mktemp -d)
trap 'rm -rf "$PATTERNS" "$WORK"' EXIT
{
  printf '%s\n' "$CI_PASS" "$ADMIN_PASS"
  printf '%s' "jenkins-ci:$CI_PASS" | base64 -w0; echo
  printf '%s' "admin:$ADMIN_PASS"   | base64 -w0; echo
} > "$PATTERNS"
unset CI_PASS ADMIN_PASS

# Generic patterns that should never appear with a real value after them
GENERIC='(_auth|_authToken)=[A-Za-z0-9+/=]{8,}|password[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'$]+'

echo "============================================================="
echo " KijaniKiosk credential audit - $(date '+%Y-%m-%d %H:%M %Z')"
echo " Repository: $PAYMENTS_REPO  (HEAD $(git -C "$PAYMENTS_REPO" rev-parse --short HEAD))"
echo " Jenkins:    $API_IP:$JOB_DIR"
echo " Secrets searched: 2 passwords + 2 base64 user:password tokens"
echo "============================================================="

# --- Check 1: final Jenkinsfile ----------------------------------------------
echo
echo "[1/5] Jenkinsfile (final committed version) contains no credential values"
JF="$PAYMENTS_REPO/Jenkinsfile"
if grep -qFf "$PATTERNS" "$JF" || grep -qE "$GENERIC" "$JF"; then
  fail "credential material found in Jenkinsfile"
else
  pass "no password, token or _auth value in Jenkinsfile"
fi
echo "  Credential references (IDs only, safe to commit):"
grep -n "credentialsId" "$JF" | sed 's/^/    /'

# --- Check 2: entire git history ---------------------------------------------
echo
echo "[2/5] Git history (every commit, every branch) contains no credential values"
# Third-party code (node_modules) is excluded: it is never committed here, and its
# documentation examples would only create false positives.
git -C "$PAYMENTS_REPO" log --all -p -- . ':(exclude)node_modules' > "$WORK/history.txt"
echo "  Commits scanned: $(git -C "$PAYMENTS_REPO" rev-list --all | wc -l)"
if grep -qFf "$PATTERNS" "$WORK/history.txt" || grep -qE "$GENERIC" "$WORK/history.txt"; then
  fail "credential material found in git history (diff line numbers below; values not shown)"
  { grep -nFf "$PATTERNS" "$WORK/history.txt"; grep -nE "$GENERIC" "$WORK/history.txt"; } | cut -d: -f1 | sed 's/^/    history line /' | head -10
else
  pass "no secret in any commit diff"
fi
if git -C "$PAYMENTS_REPO" log --all --name-only --format= | grep -qx '.npmrc'; then
  fail ".npmrc was committed at some point"
else
  pass ".npmrc has never been committed"
fi

# --- Fetch Jenkins build records once (logs + archived artifacts) ------------
ssh -i "$SSH_KEY" "ubuntu@$API_IP" "sudo tar -C '$JOB_DIR' -cz builds" \
  | tar -C "$WORK" -xz
BUILD_COUNT=$(find "$WORK/builds" -maxdepth 1 -mindepth 1 -type d | wc -l)

# --- Check 3: every build log --------------------------------------------------
echo
echo "[3/5] Build logs (all $BUILD_COUNT retained builds) contain no credential values"
LOGS=$(find "$WORK/builds" -name log -type f)
if echo "$LOGS" | xargs grep -lFf "$PATTERNS" 2>/dev/null | grep -q .; then
  fail "credential material found in a build log"
else
  pass "no password or base64 token in any build log"
fi
if echo "$LOGS" | xargs grep -lE "$GENERIC" 2>/dev/null | grep -q .; then
  fail "an _auth/_authToken value appears in a build log"
else
  pass "no _auth/_authToken value in any build log"
fi
MASKED=$(echo "$LOGS" | xargs grep -l "Masking supported pattern matches" 2>/dev/null | wc -l)
echo "  Builds where Jenkins confirmed credential masking was active: $MASKED"

# --- Check 4: archived artifacts ---------------------------------------------
echo
echo "[4/5] Archived artifacts contain no .npmrc and no credential values"
if find "$WORK/builds" -path '*/archive/*' -name '.npmrc' | grep -q .; then
  fail ".npmrc found in archived artifacts"
else
  pass "no .npmrc in any archived artifact"
fi
if find "$WORK/builds" -path '*/archive/*' -type f -print0 \
     | xargs -0 -r grep -lFf "$PATTERNS" 2>/dev/null | grep -q .; then
  fail "credential material found in archived artifacts"
else
  pass "no secret inside any archived file"
fi

# --- Check 5: Jenkins credential store ---------------------------------------
echo
echo "[5/5] Jenkins credential store holds the Nexus password encrypted, not in plain text"
ssh -i "$SSH_KEY" "ubuntu@$API_IP" "sudo cat /var/lib/jenkins/credentials.xml" > "$WORK/credentials.xml"
if grep -qFf "$PATTERNS" "$WORK/credentials.xml"; then
  fail "a password is stored in plain text in credentials.xml"
else
  pass "no plain-text password in credentials.xml"
fi
ENCRYPTED=$(grep -cE '<password>\{[A-Za-z0-9+/=]+\}</password>' "$WORK/credentials.xml")
echo "  Encrypted password entries in the store: $ENCRYPTED"
grep -o '<id>[^<]*</id>' "$WORK/credentials.xml" | sed 's/^/    credential /'

echo
echo "============================================================="
if [ "$FAILURES" -eq 0 ]; then
  echo " AUDIT PASSED: 0 findings across all five checks"
else
  echo " AUDIT FAILED: $FAILURES finding(s) - see FAIL lines above"
fi
echo "============================================================="
exit "$FAILURES"
