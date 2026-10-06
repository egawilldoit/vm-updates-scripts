#!/usr/bin/env bash
# =============================================================================
# update — the single update authority for this host.
#
# Design contract (do not regress these):
#   * ONE update authority per tool. No cron, timer or helper may mutate a
#     managed tool outside this script.
#   * Native tool updaters do the updating. This script owns interruption,
#     verification and cleanup only. No custom state backups.
#   * Explicit workload interruption: when the user runs an update, active
#     work for that tool may be interrupted. It is never interrupted by
#     anything else.
#   * Verification must be able to detect version drift on its own.
#   * Independent components never gate each other.
#   * `--verify` performs ZERO mutation.
#   * `--dry-run` performs ZERO mutation and prints the exact plan.
#
# Exit codes
#   0  success
#   1  at least one selected component FAILED
#   2  usage error
#   3  lock contention (another update owns the global lock)
#   4  preflight refusal — nothing was mutated
#   5  interrupted — state may be mid-flight
# =============================================================================

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="update"
readonly SCRIPT_VERSION="2.1.0"

# --- Identity / environment ----------------------------------------------------
export HOME="${HOME:-/home/ubuntu}"
export USER="${USER:-ubuntu}"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# Only make PATH mutations visible to children when they are already valid.
if [[ -d "$HOME/.nvm/versions/node" ]]; then
    for _nd in "$HOME"/.nvm/versions/node/*/bin; do
        [[ -d "$_nd" ]] && PATH="$_nd:$PATH"
    done
fi
export PATH

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

# --- State locations ----------------------------------------------------------
readonly STATE_ROOT="$HOME/.local/state/tool-updates"
readonly GLOBAL_LOCK="$STATE_ROOT/update.lock"
readonly LOG_DIR="$STATE_ROOT/logs/update"
readonly LOG_KEEP=20
ACTIVE_LOG=""

# --- Tool locations (discovered, not assumed) ---------------------------------
CODEX_BIN="$(command -v codex 2>/dev/null || true)"
OPENCODE_BIN="$(command -v opencode 2>/dev/null || true)"
HERMES_BIN="$(command -v hermes 2>/dev/null || true)"
T3_BIN="$(command -v t3 2>/dev/null || true)"

readonly CODEX_HOME="$HOME/.codex"
readonly CODEX_PACKAGES="$CODEX_HOME/packages"
readonly CODEX_STANDALONE="$CODEX_PACKAGES/standalone"
readonly CODEX_DAEMON_PKG="$CODEX_PACKAGES/app-server-daemon"
readonly CODEX_CONTROL_DIR="$CODEX_HOME/app-server-control"
readonly CODEX_DAEMON_STATE="$CODEX_HOME/app-server-daemon"
readonly CODEX_DAEMON_PID="$CODEX_DAEMON_STATE/daemon.pid"
readonly CODEX_APP_SERVER_PID="$CODEX_DAEMON_STATE/app-server.pid"
readonly CODEX_DAEMON_UPDATER_PID="$CODEX_DAEMON_STATE/daemon-updater.pid"

readonly T3_HOME="$HOME/.t3"
readonly T3_RUNTIME="$T3_HOME/runtime"
readonly T3_VERSIONS="$T3_RUNTIME/versions"
readonly T3_SERVICE_STATE="$T3_RUNTIME/service-state.json"
readonly T3_UNIT="t3code.service"
readonly T3_HEALTH_URL="http://127.0.0.1:3773/"

readonly HERMES_UNITS=(hermes-gateway.service hermes-serve.service)

# --- Runtime flags ------------------------------------------------------------
DO_CODEX=0
DO_OPENCODE=0
DO_HERMES=0
DO_T3=0
DO_VERIFY=0
DO_CHECK=0
FORCE_UPDATE=0
DRY_RUN=0
declare -A PRECHECK=() PRECHECK_DETAIL=()

# --- Result tracking ----------------------------------------------------------
declare -A RESULT=()          # component -> PASS|FAIL|SKIPPED|DISABLED|NOT_CONFIGURED
declare -A RESULT_DETAIL=()   # component -> human readable detail
declare -A UPDATE_RC=()       # component -> raw rc of its native updater
UPDATE_FAILURES=0

# --- Interruption / restoration bookkeeping ------------------------------------
T3_STOPPED_BY_US=0
IN_MUTATION=0
LOG_FH_OPEN=0
LOCK_HELD=0
OBS_LOCK_BUSY=0
RESTART_T3_REASON=""
DAEMON_PKG_STATUS=""
DAEMON_PKG_DETAIL=""
DAEMON_PKG_CAPABILITY=""
# Explicit capability state for the daemon PACKAGE update. Exactly one of
# SUPPORTED or NOT_APPLICABLE, decided BEFORE the command would be invoked, so
# an unsupported lifecycle is never called and never claimed to have succeeded.
# NOT_APPLICABLE is a normal outcome, not a failure.
DAEMON_PACKAGE_UPDATE="NOT_APPLICABLE"

# T3_STOP_PLANNED is set in dry-run to describe a stop that WOULD happen.
# T3_STOPPED_BY_US is reserved for a stop that actually succeeded. Keeping them
# apart is what stops a dry-run from claiming it will restore a service it
# never stopped.
T3_STOP_PLANNED=0

# OpenCode V2 lifecycle identity. The PID and its start time -- not a URL that
# answers -- are authoritative for whether the service really cycled.
OPENCODE_BEFORE_PID=""
OPENCODE_BEFORE_START=""
OPENCODE_BEFORE_VERSION=""
OPENCODE_BEFORE_EXE=""
OPENCODE_SERVICE_WAS_RUNNING=0
OPENCODE_AFTER_PID=""
OPENCODE_AFTER_START=""
OPENCODE_AFTER_EXE=""
OPENCODE_AFTER_VERSION=""
OPENCODE_SERVICE_URL_BEFORE=""
# PIDs this run intends to shut down; the pre-update proof checks each is gone.
OPENCODE_TARGET_PIDS=""

declare -a RESTORE_FAILURES=()

# Codex background-state bookkeeping. A stopped app-server is a real outage of
# the SSH control surface, so it must be restored even on an abort -- and never
# left down silently.
CODEX_RESTORE_NEEDED=0
CODEX_APP_BEFORE_PID=""
CODEX_APP_BEFORE_START=""
CODEX_APP_BEFORE_EXE=""
CODEX_APP_BEFORE_SOCKET=""
CODEX_UPDATER_BEFORE_PID=""
CODEX_UPDATER_WAS_ACTIVE=0
CODEX_RELEASE_BEFORE=""
CODEX_VERSION_BEFORE=""
CODEX_UPDATER_LOOP_AFTER="n/a"

# Update outcome, restore outcome and verification outcome are tracked
# separately so a failed update can never be reported as a failed restore, or a
# successful restore as a successful update.
UPDATE_RESULT="NOT RUN"
RESTORE_RESULT="NOT ATTEMPTED"
VERIFY_RESULT="NOT RUN"

# =============================================================================
# Output helpers
# =============================================================================

C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m';   C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
fi

log()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$C_YEL" "$C_RESET" "$*"; }
err()  { printf '  %sERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
section() { printf '\n%s=== %s ===%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# Redact anything that looks like a secret before it reaches a log or terminal.
scrub() { sed -E 's/((token|secret|password|api[_-]?key|authorization)[=: ]+)[^ ]+/\1<REDACTED>/Ig'; }

# Dry-run action prefixes (Phase 13 contract)
a_stop()    { printf '  %sWOULD STOP%s    %s\n'    "$C_CYN" "$C_RESET" "$*"; }
a_update()  { printf '  %sWOULD UPDATE%s  %s\n'    "$C_CYN" "$C_RESET" "$*"; }
a_restart() { printf '  %sWOULD RESTART%s %s\n'    "$C_CYN" "$C_RESET" "$*"; }
a_verify()  { printf '  %sWOULD VERIFY%s  %s\n'    "$C_CYN" "$C_RESET" "$*"; }
a_clean()   { printf '  %sWOULD CLEAN%s   %s\n'    "$C_CYN" "$C_RESET" "$*"; }

note_dry() { [[ $DRY_RUN -eq 1 ]] && log "  ${C_YEL}[dry-run]${C_RESET} no changes were made"; return 0; }

record() { # record <component> <status> <detail>
    RESULT["$1"]="$2"
    RESULT_DETAIL["$1"]="$3"
    case "$2" in
        FAIL)           UPDATE_FAILURES=$((UPDATE_FAILURES + 1)) ;;
        SKIPPED)        : ;;
        PASS|DISABLED|NOT_CONFIGURED) : ;;
    esac
}

status_line() { # status_line <component> <status> [detail]
    local comp="$1" st="$2" detail="${3:-}" color=""
    case "$st" in
        PASS)           color="$C_GRN" ;;
        FAIL)           color="$C_RED" ;;
        SKIPPED)        color="$C_YEL" ;;
        DISABLED)       color="$C_DIM" ;;
        NOT_CONFIGURED) color="$C_DIM" ;;
        *)              color="" ;;
    esac
    printf '  %-10s %s%-15s%s %s\n' "$comp" "$color" "$st" "$C_RESET" "$detail"
}

usage() {
    cat <<'EOF'
Usage:
  update --all [--dry-run]
  update --codex [--dry-run]
  update --opencode [--dry-run]
  update --hermes [--dry-run]
  update --t3 [--dry-run]
  update --verify
  update --check
  update --force --all

Options:
  --codex       Update Codex
  --opencode    Update OpenCode V2
  --hermes      Update Hermes
  --t3          Update T3 nightly
  --all         Update Codex, OpenCode V2, Hermes, and T3
  --verify      Read-only stack verification
  --check       Read-only update availability report
  --force       Run native updater even when proven current
  --dry-run     Show exactly what would happen without changing anything
  -h, --help    Show help

Notes:
  * update is the only authority that may change a managed tool version.
  * --verify performs zero mutation: no updates, no restarts, no backups,
    no log files, no lock file creation.
  * --dry-run performs zero mutation and prints the exact plan.
  * Component failures are independent; one failure does not prevent the
    other selected components from being attempted.
EOF
}

# =============================================================================
# /proc helpers — pure reads, no mutation
# =============================================================================

proc_exists() { [[ -d "/proc/$1" ]]; }

# A process can exit between enumerating /proc and reading it. That is normal
# on Linux and must never produce a diagnostic. Note the redirection order:
# `2>/dev/null` must come BEFORE `< file`, otherwise bash reports the failed
# open before stderr is redirected. Use a subshell so a vanished pid yields
# exactly empty output and a 0 status.
proc_cmdline() { ( tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline" ) 2>/dev/null | sed 's/ *$//'; }
proc_exe()     { ( readlink -f "/proc/$1/exe" ) 2>/dev/null || true; }
proc_ppid()    { ( awk '/^PPid:/{print $2}' 2>/dev/null < "/proc/$1/status" ) 2>/dev/null || echo 0; }
proc_cgroup()  { ( sed -n 's#^[0-9]*::##p' 2>/dev/null < "/proc/$1/cgroup" ) 2>/dev/null | head -n1 || true; }

# Field 22 of /proc/<pid>/stat is the process start time, in clock ticks since
# boot. comm (field 2) is parenthesised and may itself contain spaces and
# parentheses, so everything up to the LAST ')' is discarded before splitting.
# After that, field N lives at index N-2 because fields 1 and 2 are gone, so
# starttime is index 20. Empty output means the process is gone, which callers
# treat as "cannot prove", never as an error.
proc_starttime() {
    ( awk '{
        n = index($0, ")")
        if (n) { split(substr($0, n + 1), a, " "); print a[20] }
    }' 2>/dev/null < "/proc/$1/stat" ) 2>/dev/null
}

proc_pids() { # proc_pids <grep-pattern>  -> pids whose cmdline matches
    local pat="$1" pid cmd
    for pid in /proc/[0-9]*; do
        pid="${pid#/proc/}"
        cmd="$(proc_cmdline "$pid" 2>/dev/null || true)"
        [[ -n "$cmd" ]] || continue
        [[ "$cmd" == *"$pat"* ]] && printf '%s\n' "$pid"
    done
}

is_descendant_of() { # is_descendant_of <pid> <ancestor>
    local pid="$1" anc="$2" guard=0
    while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]]; do
        [[ "$pid" == "$anc" ]] && return 0
        pid="$(proc_ppid "$pid")"
        guard=$((guard + 1))
        [[ $guard -gt 64 ]] && break
    done
    [[ "$anc" == "1" ]] && [[ "$pid" == "1" ]] && return 0
    return 1
}

in_t3_cgroup() { # in_t3_cgroup <pid>
    local cg; cg="$(proc_cgroup "$1")"
    [[ "$cg" == *"$T3_UNIT"* ]]
}

t3_main_pid() {
    systemctl --user show "$T3_UNIT" -p MainPID --value 2>/dev/null || echo 0
}

t3_active() {
    [[ "$(systemctl --user is-active "$T3_UNIT" 2>/dev/null || true)" == "active" ]]
}

# Some managed units are user units (t3code) and some are system units
# (hermes-gateway, hermes-serve). Probe both scopes rather than assuming.
# LoadState is "not-found" rather than "loaded" when a unit is absent from a
# scope, so match "loaded" exactly and treat anything else as absent.
# Returns the systemctl scope FLAG ("--user" or "--system"), or "" if absent.
unit_scope() { # unit_scope <name> -> "--user" | "--system" | ""
    local ls
    ls="$(systemctl --user show "$1" -p LoadState --value 2>/dev/null || true)"
    if [[ "$ls" == "loaded" ]]; then printf -- '--user'; return 0; fi
    ls="$(systemctl --system show "$1" -p LoadState --value 2>/dev/null || true)"
    if [[ "$ls" == "loaded" ]]; then printf -- '--system'; return 0; fi
    printf ''
    return 0
}

unit_label() { # human scope word for messages
    local sc; sc="$(unit_scope "$1")"
    case "$sc" in
        --user)   printf 'user' ;;
        --system) printf 'system' ;;
        *)        printf 'absent' ;;
    esac
}

unit_enabled() { # unit_enabled <name>
    local sc; sc="$(unit_scope "$1")"
    [[ -n "$sc" ]] || return 1
    [[ "$(systemctl "$sc" is-enabled "$1" 2>/dev/null || true)" == "enabled" ]]
}

unit_active() { # unit_active <name>
    local sc; sc="$(unit_scope "$1")"
    [[ -n "$sc" ]] || return 1
    [[ "$(systemctl "$sc" is-active "$1" 2>/dev/null || true)" == "active" ]]
}

unit_mainpid() { # unit_mainpid <name>
    local sc; sc="$(unit_scope "$1")"
    [[ -n "$sc" ]] || { echo 0; return 0; }
    systemctl "$sc" show "$1" -p MainPID --value 2>/dev/null || echo 0
}

# Start a unit in whichever scope owns it.
unit_start() { # unit_start <name>
    local sc; sc="$(unit_scope "$1")"
    [[ -n "$sc" ]] || return 1
    systemctl "$sc" start "$1" 2>/dev/null
}

# =============================================================================
# T3 helpers
# =============================================================================

t3_cli_version() {
    local v
    v="$("$T3_BIN" --version 2>/dev/null || true)"
    printf '%s' "${v#t3 v}" | awk '{print $1}'
}

t3_launcher_target() { readlink -f "$HOME/.local/bin/t3" 2>/dev/null || echo ""; }

t3_launcher_version() {
    local t; t="$(t3_launcher_target)"
    [[ -n "$t" ]] || { echo ""; return 0; }
    # .../versions/<ver>/t3
    printf '%s' "$t" | sed -n 's#.*/versions/\([^/]*\)/.*#\1#p'
}

t3_state_version() {
    [[ -f "$T3_SERVICE_STATE" ]] || { echo ""; return 0; }
    sed -n 's/.*"activeVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$T3_SERVICE_STATE" | head -n1
}

t3_execstart_path() {
    systemctl --user show "$T3_UNIT" -p ExecStart --value 2>/dev/null \
        | sed -n 's/^[^p]*path=\([^ ;]*\).*/\1/p' | head -n1
}

t3_execstart_version() {
    local p; p="$(t3_execstart_path)"
    [[ -n "$p" ]] || { echo ""; return 0; }
    printf '%s' "$p" | sed -n 's#.*/versions/\([^/]*\)/.*#\1#p'
}

t3_mainpid_exe() {
    local pid; pid="$(t3_main_pid)"
    [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" != "0" ]] || { echo ""; return 0; }
    proc_exe "$pid"
}

t3_mainpid_version() {
    local p; p="$(t3_mainpid_exe)"
    [[ -n "$p" ]] || { echo ""; return 0; }
    printf '%s' "$p" | sed -n 's#.*/versions/\([^/]*\)/.*#\1#p'
}

t3_serve_pid() {
    # Prefer descendants of the T3 main PID whose exe is under versions/.
    local main p exe
    main="$(t3_main_pid)"
    [[ "$main" =~ ^[0-9]+$ && "$main" != "0" ]] || { echo ""; return 0; }
    for p in /proc/[0-9]*; do
        p="${p#/proc/}"
        proc_exists "$p" || continue
        is_descendant_of "$p" "$main" || continue
        exe="$(proc_exe "$p")"
        [[ "$exe" == "$T3_VERSIONS/"*/t3 ]] || continue
        printf '%s\n' "$p"; return 0
    done
    echo ""
}

t3_serve_version() {
    local p; p="$(t3_serve_pid)"
    [[ -n "$p" ]] || { echo ""; return 0; }
    local exe; exe="$(proc_exe "$p")"
    printf '%s' "$exe" | sed -n 's#.*/versions/\([^/]*\)/.*#\1#p'
}

t3_pending_update() { # echoes pending|failed|none
    local d="$T3_HOME/userdata" f
    for f in "$d"/.update-pending "$d"/pending-update "$d"/.t3-update-pending; do
        [[ -e "$f" ]] && { echo "pending"; return 0; }
    done
    for f in "$d"/.update-failed "$d"/update-failed; do
        [[ -e "$f" ]] && { echo "failed"; return 0; }
    done
    echo "none"
}

# Count likely interruptible work inside t3code.service without exposing argv.
# Membership comes from cgroup data or ancestry under MainPID; no process is signalled.
t3_workload_counts() {
    local root="${PROC_ROOT:-/proc}" pid main cg cmd cmd0 op=0 build=0 shells=0 other=0
    main="$(t3_main_pid)"
    for p in "$root"/[0-9]*; do
        [[ -d "$p" ]] || continue
        pid="${p##*/}"
        cg="$(sed -n 's#^[0-9]*::##p' "$p/cgroup" 2>/dev/null | head -n1 || true)"
        if [[ "$cg" != *"$T3_UNIT"* ]] && ! { [[ "$main" =~ ^[0-9]+$ && "$main" != 0 ]] && is_descendant_of "$pid" "$main"; }; then
            continue
        fi
        cmd="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)"
        cmd0="${cmd%% *}"; cmd0="${cmd0##*/}"
        case "$cmd" in
            *opencode*) op=$((op+1)) ;;
            *)
                case "$cmd0" in npm|pnpm|yarn|node|vite|webpack) build=$((build+1)) ;;
                    bash|sh|zsh|fish|terminal) shells=$((shells+1)) ;;
                    *) case "$cmd" in *test*|*build*) build=$((build+1)) ;; *) other=$((other+1)) ;; esac ;;
                esac ;;
        esac
    done
    printf 'OpenCode: %d\nnpm/pnpm/test/build: %d\nterminals/shells: %d\nother: %d\n' "$op" "$build" "$shells" "$other"
}

warn_t3_workloads() {
    printf 'T3 update will restart t3code.service. Active child workloads that may be interrupted:\n'
    t3_workload_counts | sed 's/^/  /'
}

t3_http_health() {
    local code
    code="$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "$T3_HEALTH_URL" 2>/dev/null || echo 000)"
    printf '%s' "$code"
}

# Stop T3 only if this script needs it. Records prior state for restoration.
t3_stop_for() { # t3_stop_for <reason>
    local reason="$1"
    t3_active || { info "t3code.service not active; nothing to stop"; return 0; }
    if [[ $DRY_RUN -eq 1 ]]; then
        # Nothing is actually stopped in a dry run, so T3_STOPPED_BY_US stays 0
        # and t3_restore_if_stopped will do nothing. This flag exists only so
        # the plan can state the intent without implying a real stop happened.
        a_stop "t3code.service (reason: $reason)"
        T3_STOP_PLANNED=1
        info "dry-run: T3 stop is planned but was NOT performed; T3_STOPPED_BY_US stays 0"
        return 0
    fi
    info "Stopping t3code.service (reason: $reason)"
    RESTART_T3_REASON="$reason"
    systemctl --user stop "$T3_UNIT" 2>/dev/null || true
    local i
    for i in $(seq 1 30); do
        t3_active || break
        sleep 1
    done
    if t3_active; then
        warn "t3code.service did not stop within 30s"
        return 1
    fi
    # Only now, after the stop actually succeeded.
    T3_STOPPED_BY_US=1
    return 0
}

# Restart T3 only if this script stopped it. Never reports success on failure.
t3_restore_if_stopped() {
    # Real restore happens only when a stop actually succeeded.
    [[ $T3_STOPPED_BY_US -eq 1 ]] || return 0
    if [[ $DRY_RUN -eq 1 ]]; then
        if [[ $T3_STOP_PLANNED -eq 1 ]]; then
            a_restart "t3code.service (restore: was active before this run)"
        else
            a_restart "t3code.service (restore)"
        fi
        T3_STOPPED_BY_US=0
        return 0
    fi
    info "Restarting t3code.service (was active; stopped because: ${RESTART_T3_REASON:-unknown})"
    if ! systemctl --user start "$T3_UNIT" 2>/dev/null; then
        RESTORE_FAILURES+=("t3code.service failed to start")
        return 1
    fi
    local i
    for i in $(seq 1 60); do
        [[ "$(t3_http_health)" == "200" ]] && {
            info "t3code.service restored and healthy (HTTP 200)"
            T3_STOPPED_BY_US=0
            return 0
        }
        sleep 1
    done
    RESTORE_FAILURES+=("t3code.service did not reach HTTP 200 within 60s")
    return 1
}

# =============================================================================
# Codex helpers
# =============================================================================

codex_cli_version() { "$CODEX_BIN" --version 2>/dev/null | head -n1 | awk '{print $NF}'; }

codex_daemon_json() { timeout 30 "$CODEX_BIN" app-server daemon version 2>/dev/null || true; }

codex_daemon_status() {
    codex_daemon_json | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# Run `codex app-server daemon <sub>` and classify the SEMANTIC result, not
# just the shell exit code.
#
# Several daemon subcommands exit 0 while reporting a machine-readable
# `status` that is not success. `daemon update` returns
#   {"status":"unsupported", ...}
# with exit 0 when the running app-server was not started from a managed
# daemon package. Treating exit 0 as success would report a no-op as done.
#
# Echoes "<status>|<message>". `unsupported` is a normal, explainable condition
# on this host (the app-server predates daemon management), so it is reported
# as NOT_CONFIGURED rather than a hard failure -- but never as success.
codex_daemon_subcommand() { # <subcommand> [args...]
    local sub="$1"; shift
    local out rc status msg
    # `daemon start` spawns the app-server and its updater loop as detached
    # long-lived children of THIS process. Bash descriptors opened with `exec N>`
    # are inherited by every descendant, so without `9>&-` the restored daemons
    # would hold the global updater flock forever and no future update could
    # ever acquire the lock. Close the lock fd for this call and its children.
    out="$(timeout 60 "$CODEX_BIN" app-server daemon "$sub" "$@" 2>&1 9>&-)" && rc=0 || rc=$?
    status="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$out" | head -n1)"
    msg="$(sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$out" | head -n1)"
    [[ -n "$status" ]] || status="exit$rc"
    [[ -n "$msg" ]] || msg="$(tr '\n' ' ' <<<"$out" | cut -c1-160)"
    printf '%s|%s|%s' "$status" "$msg" "$rc"
}

codex_daemon_managed_path() {
    codex_daemon_json | sed -n 's/.*"managedCodexPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

codex_daemon_version() {
    codex_daemon_json | sed -n 's/.*"managedCodexVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# Current release token of one managed package tree, e.g.
# standalone -> "0.160.0-aarch64-unknown-linux-musl". Prints nothing when the
# tree is missing or its `current` symlink is dangling.
codex_release_of_tree() { # codex_release_of_tree <tree-dir>
    readlink -f "$1/current" 2>/dev/null | sed -n 's#.*/releases/\([^/]*\)$#\1#p'
}

codex_current_release() { codex_release_of_tree "$CODEX_STANDALONE"; }
codex_daemon_pkg_release() { codex_release_of_tree "$CODEX_DAEMON_PKG"; }

# Is this absolute executable path the CURRENT release of the package tree it
# belongs to? Prints nothing and returns 1 when the path is outside the managed
# trees, so callers can tell "not managed by codex" from "stale release".
#
# Both trees are considered. The app-server may legitimately run from
# packages/app-server-daemon while the CLI runs from packages/standalone; a
# check that only looked at standalone would either miss real staleness or
# invent it.
codex_exe_on_current_release() { # <abs-exe>
    local exe="$1" tree rel cur
    case "$exe" in
        "$CODEX_STANDALONE"/releases/*)               tree="$CODEX_STANDALONE" ;;
        "$CODEX_DAEMON_PKG"/releases/*)               tree="$CODEX_DAEMON_PKG" ;;
        *) return 1 ;;
    esac
    rel="$(sed -n 's#^.*/releases/\([^/]*\)/.*#\1#p' <<<"$exe")"
    [[ -n "$rel" ]] || return 1
    cur="$(codex_release_of_tree "$tree")"
    [[ -n "$cur" ]] || return 1     # cannot judge -> do not call it stale
    [[ "$rel" == "$cur" ]]
}

# The authoritative signal: which PID owns the unix socket that
# app-server-control.sock resolves to.
#
# This never consults a pid file, on purpose. On this host the app-server is
# booted by the SSH remote payload (CODEX_REMOTE_PAYLOAD runs
# `nohup codex ... app-server --listen unix://`) and is therefore never
# registered in daemon.pid at all. Socket ownership is the only fact that
# cannot be forged by a stale file.
codex_control_socket() {
    readlink -f "$CODEX_CONTROL_DIR/app-server-control.sock" 2>/dev/null || true
}

codex_daemon_socket_owner() {
    local sock pid
    sock="$(codex_control_socket)"
    [[ -n "$sock" ]] || { echo ""; return 0; }
    pid="$(ss -xlpn 2>/dev/null | grep -F -- "$sock" \
        | grep -o 'pid=[0-9]\+' | head -n1 | cut -d= -f2)"
    if [[ -n "$pid" ]] && proc_exists "$pid"; then printf '%s\n' "$pid"; else echo ""; fi
}

# PID of the `codex app-server daemon pid-update-loop` process.
#
# Validated two ways on purpose: against daemon-updater.pid, which Codex
# maintains for this exact process, AND against the process's own argv. A pid
# file alone is not enough -- pids are recycled and the file survives a crash.
codex_daemon_updater_pid() {
    local recorded pid
    recorded="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' \
        "$CODEX_DAEMON_UPDATER_PID" 2>/dev/null | head -n1)"
    if [[ -n "$recorded" ]] && proc_exists "$recorded" \
       && [[ "$(proc_cmdline "$recorded")" == *pid-update-loop* ]]; then
        printf '%s\n' "$recorded"; return 0
    fi
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        if [[ "$(proc_cmdline "$pid")" == *pid-update-loop* ]]; then
            printf '%s\n' "$pid"; return 0
        fi
    done < <(codex_processes)
    return 0
}

codex_processes() { # every pid that is a Codex process, by exe or by argv
    local pid exe cmd base
    for pid in /proc/[0-9]*; do
        pid="${pid#/proc/}"
        proc_exists "$pid" || continue
        exe="$(proc_exe "$pid")"
        cmd="$(proc_cmdline "$pid")"
        base="${exe##*/}"
        if [[ "$exe" == "$CODEX_PACKAGES/"* ]] \
           || [[ "$base" == codex || "$base" == codex-code-mode-host ]] \
           || [[ "$cmd" == codex\ * || "${cmd%% *}" == codex ]]; then
            printf '%s\n' "$pid"
        fi
    done
}

# Classify a codex pid. Prints "<pid>\t<class>\t<stale>\t<summary>"
#
# The class names are the contract used by the rest of the script:
#   managed-app-server  owns app-server-control.sock (authoritative)
#   daemon-updater      codex app-server daemon pid-update-loop
#   code-mode-host      the code-mode host, in-process or as its own binary
#   proxy               codex app-server proxy
#   t3-owned            inside the T3 unit's cgroup or process tree
#   app-server-unmanaged  an app-server that is not the socket owner
#   unknown-codex       anything else that is still a codex process
#
# A process may vanish between enumerating /proc and reading it. Every helper
# above tolerates that, so classification returns a best-effort row rather than
# failing: an unreadable pid is reported as unknown-codex with an empty summary.
codex_classify() { # codex_classify <pid>
    local pid="$1" cmd exe cg main owner
    cmd="$(proc_cmdline "$pid")"
    exe="$(proc_exe "$pid")"
    cg="$(proc_cgroup "$pid")"
    main="$(t3_main_pid)"
    owner="$(codex_daemon_socket_owner)"

    # Stale means "provably on a non-current release of a managed tree". A path
    # outside those trees is NOT stale; it is simply not comparable.
    local stale="no"
    if [[ -n "$exe" ]] \
       && [[ "$exe" == "$CODEX_STANDALONE"/releases/* || "$exe" == "$CODEX_DAEMON_PKG"/releases/* ]] \
       && ! codex_exe_on_current_release "$exe"; then
        stale="yes"
    fi

    local class
    if [[ "$cg" == *"$T3_UNIT"* ]] \
       || { [[ "$main" =~ ^[0-9]+$ ]] && [[ "$main" != "0" ]] && is_descendant_of "$pid" "$main"; }; then
        class="t3-owned"
    elif [[ "$cmd" == *"pid-update-loop"* ]]; then
        class="daemon-updater"
    elif [[ -n "$owner" && "$pid" == "$owner" ]]; then
        class="managed-app-server"
    elif [[ "$cmd" == *"app-server proxy"* ]]; then
        class="proxy"
    elif [[ "$cmd" == *code-mode-host* || "${exe##*/}" == *code-mode-host* ]]; then
        class="code-mode-host"
    elif [[ "$cmd" == *"app-server"* ]]; then
        class="app-server-unmanaged"
    else
        class="unknown-codex"
    fi

    printf '%s\t%s\t%s\t%s\n' "$pid" "$class" "$stale" "$(printf '%s' "$cmd" | cut -c1-110)"
}

codex_stale_processes() { # "<pid>/<class>" per process on a non-current release
    local pid exe row
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        exe="$(proc_exe "$pid")"
        [[ -n "$exe" ]] || continue
        [[ "$exe" == "$CODEX_STANDALONE"/releases/* || "$exe" == "$CODEX_DAEMON_PKG"/releases/* ]] || continue
        codex_exe_on_current_release "$exe" && continue
        # Field 2 of the classify row is the class; field 1 is the pid again.
        row="$(codex_classify "$pid")"
        printf '%s/%s\n' "$pid" "$(cut -f2 <<<"$row")"
    done < <(codex_processes)
}

codex_pids_of_class() { # codex_pids_of_class <class> [class...]
    local want pid class
    while read -r pid class; do
        [[ -n "$pid" && -n "$class" ]] || continue
        for want in "$@"; do
            if [[ "$class" == "$want" ]]; then printf '%s\n' "$pid"; break; fi
        done
    done < <(codex_processes | while read -r p; do codex_classify "$p"; done | cut -f1,2)
}

# Is there a live Codex app-server that this updater is responsible for?
#
# The answer is the control-socket owner, never the presence of daemon.pid.
#
# REGRESSION (2026-10-04): this used to require daemon.pid or app-server.pid.
# Neither file exists on this host, so it returned false, the run printed "the
# app-server is NOT daemon-managed" and then SKIPPED stopping the process it had
# just discovered -- leaving the pre-update app-server alive across
# `codex update`. Socket ownership is authoritative; pid files are not.
codex_daemon_is_managed() {
    [[ -n "$(codex_daemon_socket_owner)" ]]
}

# A daemon *package* pid file is a separate, narrower question: it decides
# whether `codex app-server daemon update` has any package to operate on.
# Its absence does NOT make the app-server unmanaged, and does NOT make it
# safe to leave running.
codex_daemon_has_pidfile() {
    [[ -e "$CODEX_DAEMON_PID" || -e "$CODEX_APP_SERVER_PID" ]]
}

codex_daemon_pkg_selected() {
    [[ -e "$CODEX_DAEMON_PKG/current" ]]
}

# Capability detection for the daemon package update.
#
# Prints "<SUPPORTED|NOT_APPLICABLE>|<reason>". NOT_APPLICABLE is a normal,
# explainable outcome on this host and is never a failure -- but it is also
# never reported as success.
codex_daemon_update_capability() {
    if ! codex_daemon_has_pidfile; then
        printf 'NOT_APPLICABLE|no daemon.pid and no app-server.pid: the app-server is not registered as a daemon package\n'
        return 0
    fi
    if ! codex_daemon_pkg_selected; then
        printf 'NOT_APPLICABLE|no daemon package selected under packages/app-server-daemon\n'
        return 0
    fi
    printf 'SUPPORTED|daemon package is selected and the app-server is pid-managed\n'
}

# Phase 3: stop the process that can RECREATE the app-server.
#
# `codex app-server daemon pid-update-loop` is the only long-lived Codex process
# on this host with the power to bring the app-server back, and Codex exposes no
# supported command to stop just that loop. So the PID is validated twice --
# against daemon-updater.pid and against its own argv -- and only then targeted.
# Nothing else is signalled here.
stop_codex_updater_loop() { # stop_codex_updater_loop <pid>
    local pid="$1" i
    [[ -n "$pid" ]] || return 0
    proc_exists "$pid" || return 0

    if [[ "$(proc_cmdline "$pid")" != *pid-update-loop* ]]; then
        err "refusing to stop PID $pid: argv does not say pid-update-loop"
        return 1
    fi
    [[ "$(proc_exe "$pid")" == "$CODEX_PACKAGES/"* ]] || {
        err "refusing to stop PID $pid: executable is not a managed codex package"
        return 1
    }

    if [[ $DRY_RUN -eq 1 ]]; then
        a_stop "maintainer/updater PID $pid (pid-update-loop; SIGTERM then SIGKILL)"
        return 0
    fi

    info "Stopping Codex maintainer first: pid-update-loop PID $pid"
    terminate_pids "codex-updater-loop" "$pid" || {
        err "maintainer PID $pid would not stop; the app-server could be recreated at any moment"
        return 1
    }
    for i in $(seq 1 5); do
        proc_exists "$pid" || break
        sleep 1
    done
    if proc_exists "$pid"; then
        err "maintainer PID $pid survived; aborting before any app-server is touched"
        return 1
    fi
    info "maintainer PID $pid is gone; nothing can recreate the app-server now"
    return 0
}

# Phase 4: stop the socket-owning app-server by PID and PROVE it is gone.
#
# `codex app-server daemon stop` is never the mechanism here: on this host the
# app-server is not registered in daemon.pid, so the command has nothing to
# address. The PID is re-validated against its own argv immediately before
# signalling so a recycled pid cannot be hit.
stop_codex_app_server() { # stop_codex_app_server <pid>
    local pid="$1" i cmd owner
    [[ -n "$pid" ]] || return 0

    if [[ $DRY_RUN -eq 1 ]]; then
        a_stop "managed app-server PID $pid (SIGTERM -> SIGKILL if needed)"
        return 0
    fi

    if ! proc_exists "$pid"; then
        info "managed app-server PID $pid is already gone"
        return 0
    fi
    cmd="$(proc_cmdline "$pid")"
    if [[ "$cmd" != *app-server* ]]; then
        err "refusing to stop PID $pid: argv is not a codex app-server ($cmd)"
        return 1
    fi

    info "Stopping managed app-server PID $pid (app-server-control.sock owner)"
    kill -TERM "$pid" 2>/dev/null || true

    for i in $(seq 1 20); do
        proc_exists "$pid" || break
        sleep 1
    done

    if proc_exists "$pid"; then
        if [[ "$(codex_daemon_socket_owner)" == "$pid" ]]; then
            warn "PID $pid still owns the control socket after SIGTERM"
        fi
        warn "app-server PID $pid ignored SIGTERM for 20s; SIGKILL to that PID only"
        kill -KILL "$pid" 2>/dev/null || true
        for i in $(seq 1 10); do
            proc_exists "$pid" || break
            sleep 1
        done
    fi

    if proc_exists "$pid"; then
        err "app-server PID $pid survived SIGKILL"
        return 1
    fi

    owner="$(codex_daemon_socket_owner)"
    if [[ -z "$owner" ]]; then
        info "control socket released: no owner (old app-server PID $pid is gone)"
    elif [[ "$owner" == "$pid" ]]; then
        err "control socket is still owned by PID $pid after it was killed"
        return 1
    else
        info "control socket released: now owned by a different PID ($owner)"
    fi
    return 0
}

# Stop the Codex background lifecycle in the only safe order: the maintainer
# first, then the app-server it would otherwise recreate. Both steps are
# verified, and either one failing aborts before the native updater runs.
stop_codex_daemon() { # stop_codex_daemon <updater_loop_pid> <app_server_pid>
    local updater_loop="$1" app_server="$2"

    if [[ -n "$updater_loop" ]] && proc_exists "$updater_loop"; then
        info "note: daemon updater loop (PID $updater_loop) is active and may respawn the app-server"
    fi

    stop_codex_updater_loop "$updater_loop" || return 1
    stop_codex_app_server  "$app_server"     || return 1
    return 0
}

# Terminate ONLY the PIDs handed to us. Never pattern-kills a whole family.
# Returns 0 only when every target is observably gone.
terminate_pids() { # terminate_pids <label> <pid...>
    local label="$1"; shift
    local pid waited remaining
    for pid in "$@"; do
        [[ -n "$pid" ]] || continue
        proc_exists "$pid" || continue
        if [[ $DRY_RUN -eq 1 ]]; then
            a_stop "$label PID $pid (SIGTERM -> SIGKILL if needed)"
        else
            info "  SIGTERM $label PID $pid"
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    [[ $DRY_RUN -eq 1 ]] && return 0

    waited=0
    while [[ $waited -lt 20 ]]; do
        remaining=0
        for pid in "$@"; do
            if [[ -n "$pid" ]] && proc_exists "$pid"; then remaining=1; fi
        done
        [[ $remaining -eq 0 ]] && return 0
        sleep 1; waited=$((waited + 1))
    done

    # Escalate only for the targeted leftovers.
    for pid in "$@"; do
        [[ -n "$pid" ]] || continue
        proc_exists "$pid" || continue
        warn "  SIGKILL $label PID $pid (refused graceful shutdown)"
        kill -KILL "$pid" 2>/dev/null || true
    done

    # A second bounded wait, then an honest verdict. Never claim success while
    # a targeted pid is still alive.
    waited=0
    while [[ $waited -lt 10 ]]; do
        remaining=0
        for pid in "$@"; do
            if [[ -n "$pid" ]] && proc_exists "$pid"; then remaining=1; fi
        done
        [[ $remaining -eq 0 ]] && return 0
        sleep 1; waited=$((waited + 1))
    done
    for pid in "$@"; do
        if [[ -n "$pid" ]] && proc_exists "$pid"; then
            err "$label PID $pid survived SIGKILL"
        fi
    done
    return 1
}

# Phase 5 gate. The native updater must not start while any pre-update Codex
# workload is still alive on the pre-update release.
#
# Two independent conditions, because either one alone is satisfiable by a
# process the other ignores:
#   * the exact old managed app-server PID must be gone;
#   * no surviving codex process may still be running out of the pre-update
#     release directory.
codex_pre_update_proof() { # codex_pre_update_proof <old_app_pid> <before_release>
    local old_pid="$1" rel="$2" pid exe bad=0

    if [[ -n "$old_pid" ]] && proc_exists "$old_pid"; then
        err "old managed app-server PID $old_pid is still alive; refusing to run the native updater"
        bad=1
    fi
    if [[ -n "$old_pid" ]] && [[ "$(codex_daemon_socket_owner)" == "$old_pid" ]]; then
        err "old app-server PID $old_pid still owns the control socket; refusing to run the native updater"
        bad=1
    fi

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$pid" == "$old_pid" ]] && continue
        exe="$(proc_exe "$pid")"
        [[ -n "$exe" ]] || continue
        if [[ -n "$rel" && "$exe" == */releases/$rel/* ]]; then
            err "PID $pid still runs the pre-update release $rel; refusing to run the native updater"
            bad=1
        fi
    done < <(codex_processes)

    [[ $bad -eq 0 ]] || return 1
    info "pre-update proof: no Codex workload survives on release ${rel:-unknown}"
    return 0
}

# Phase 7: recreate the background Codex state with the supported lifecycle
# command, then prove a genuinely fresh process exists.
#
# `codex app-server daemon start` is used because it is the documented way to
# obtain a managed app-server on this build. It is only called when one was
# actually running beforehand, so nothing is started that was not already part
# of the host's background state.
codex_restore_background() { # codex_restore_background
    local res status msg rc i owner loop

    if [[ $DRY_RUN -eq 1 ]]; then
        a_restart "Codex background app-server mechanism (codex app-server daemon start)"
        return 0
    fi

    info "Restoring Codex background app-server (codex app-server daemon start)"
    res="$(codex_daemon_subcommand start)"
    status="${res%%|*}"; res="${res#*|}"
    msg="${res%%|*}";     rc="${res##*|}"
    info "  daemon start: status=$status rc=$rc"
    if [[ -n "$msg" && "$msg" != "$status" ]]; then info "  $msg"; fi

    owner=""
    for i in $(seq 1 60); do
        owner="$(codex_daemon_socket_owner)"
        [[ -n "$owner" ]] && break
        sleep 1
    done
    if [[ -z "$owner" ]]; then
        RESTORE_FAILURES+=("app-server daemon start failed: no control-socket owner appeared (status=$status rc=$rc)")
        return 1
    fi
    info "  fresh app-server socket owner: PID $owner"

    # The updater loop was part of the background state before this run, so it
    # must come back too. Recorded honestly either way.
    if [[ $CODEX_UPDATER_WAS_ACTIVE -eq 1 ]]; then
        loop="$(codex_daemon_updater_pid)"
        if [[ -n "$loop" ]]; then
            CODEX_UPDATER_LOOP_AFTER="restored (PID $loop)"
            info "  daemon updater loop restored: PID $loop"
        else
            CODEX_UPDATER_LOOP_AFTER="not-restored"
            warn "  daemon updater loop was active before but is not running now"
            RESTORE_FAILURES+=("daemon updater loop (pid-update-loop) was not restarted")
        fi
    else
        CODEX_UPDATER_LOOP_AFTER="was-not-active"
    fi
    return 0
}

# Phase 7 + 8: prove the replacement app-server is fresh and that nothing is
# left behind on the pre-update release.
#
# A same-version update cannot prove freshness by comparing version strings, so
# identity is compared structurally instead: PID, /proc start time, and the
# executable the process actually runs.
codex_verify_fresh_app_server() { # <before_pid> <before_start> <before_release> <before_version>
    local bpid="$1" bstart="$2" brel="$3" bver="$4"
    local owner start exe cur aver stale fails=""

    owner="$(codex_daemon_socket_owner)"
    if [[ -z "$owner" ]]; then
        err "no app-server control-socket owner after the update"
        return 1
    fi
    cur="$(codex_current_release)"
    aver="$(codex_cli_version)"
    info "after: cli ${aver:-?}, app-server PID $owner (was ${bpid:-none}), release ${cur:-?}"

    # The old process must not have survived.
    if [[ -n "$bpid" ]] && proc_exists "$bpid"; then
        err "old app-server PID $bpid survived the update"
        fails="old-pid-alive"
    fi

    # The socket owner must be a different process instance.
    if [[ -n "$bpid" && "$owner" == "$bpid" ]]; then
        start="$(proc_starttime "$owner")"
        if [[ -n "$bstart" && -n "$start" && "$start" == "$bstart" ]]; then
            err "socket owner is still the pre-update PID $bpid with the same start time; no fresh process was created"
            fails="no-fresh-process"
        fi
    fi

    exe="$(proc_exe "$owner")"
    if [[ -n "$exe" ]]; then
        info "  fresh app-server executable: $exe"
        if [[ "$exe" != "$CODEX_PACKAGES/"* ]]; then
            warn "  fresh app-server runs outside the managed package tree"
        elif ! codex_exe_on_current_release "$exe"; then
            err "fresh app-server PID $owner runs a non-current release: $exe"
            fails="stale-exe"
        fi
    else
        err "could not read /proc/$owner/exe for the fresh app-server"
        fails="unreadable-exe"
    fi

    # Structural freshness: the replacement must be younger than the old one.
    if [[ -n "$bstart" ]]; then
        start="$(proc_starttime "$owner")"
        if [[ -n "$start" && "$start" =~ ^[0-9]+$ && "$bstart" =~ ^[0-9]+$ ]]; then
            if [[ "$start" -le "$bstart" ]]; then
                err "fresh app-server start time $start is not newer than the pre-update $bstart"
                fails="not-newer"
            else
                info "  fresh app-server start time $start > pre-update $bstart"
            fi
        fi
    fi

    # The control socket must actually answer.
    if [[ "$(codex_daemon_status)" != "running" ]]; then
        err "control socket has an owner but 'daemon version' does not report running"
        fails="socket-unresponsive"
    else
        info "  control socket responds (daemon version: running)"
    fi

    # Phase 8 stale-release invariant.
    if [[ -n "$brel" && -n "$cur" && "$brel" != "$cur" ]]; then
        stale="$(codex_stale_processes || true)"
        if [[ -n "$stale" ]]; then
            err "release changed ($brel -> $cur) but process(es) still run the old release: $(tr '\n' ' ' <<<"$stale")"
            fails="stale-release"
        else
            info "  release changed ($brel -> $cur); zero processes remain on $brel"
        fi
    elif [[ -n "$bver" && -n "$aver" && "$bver" != "$aver" ]]; then
        stale="$(codex_stale_processes || true)"
        if [[ -n "$stale" ]]; then
            err "version changed ($bver -> $aver) but stale process(es) remain: $(tr '\n' ' ' <<<"$stale")"
            fails="stale-release"
        fi
    else
        # Same-version update: version comparison proves nothing, so the fresh
        # instance checks above carry the proof. Say so explicitly.
        info "  same-version update (${bver:-?} -> ${aver:-?}); freshness proved by PID/start-time, not by version"
        stale="$(codex_stale_processes || true)"
        if [[ -n "$stale" ]]; then
            err "stale process(es) remain even though the version is unchanged: $(tr '\n' ' ' <<<"$stale")"
            fails="stale-release"
        fi
    fi

    [[ -z "$fails" ]] || { err "fresh app-server proof failed: $fails"; return 1; }
    return 0
}

# =============================================================================
# OpenCode V2 helpers
# =============================================================================

opencode_version() {
    # Emits the bare version, e.g. "2.0.22" from "opencode v2.0.22".
    "$OPENCODE_BIN" --version 2>/dev/null \
        | sed -n 's/^opencode v\{0,1\}\([0-9][^ ]*\).*/\1/p' | head -n1
}

opencode_install_root() {
    local real; real="$(readlink -f "$OPENCODE_BIN" 2>/dev/null || true)"
    [[ -n "$real" ]] || { echo ""; return 0; }
    printf '%s' "$real" | sed -n 's#\(.*/lib/node_modules/@opencode/cli\).*#\1#p'
}

opencode_background_service_url() {
    timeout 20 "$OPENCODE_BIN" service status 2>/dev/null | head -n1 || true
}

opencode_service_running() {
    [[ -n "$(opencode_background_service_url)" ]]
}

# ---------------------------------------------------------------------------
# OpenCode V2 identity helpers
#
# A URL that answers is NOT proof of identity: it says nothing about WHICH
# process is serving, or whether that process is from the current build. The
# service PID and its start time are authoritative for lifecycle freshness.
# Every /proc read here tolerates a process vanishing mid-scan silently.
# ---------------------------------------------------------------------------

# The background-service process: `opencode ... serve --service`.
opencode_service_pid() {
    local pid cmd
    for pid in /proc/[0-9]*; do
        pid="${pid#/proc/}"
        proc_exists "$pid" || continue
        cmd="$(proc_cmdline "$pid")"
        [[ "$cmd" == *opencode* && "$cmd" == *serve* && "$cmd" == *--service* ]] && { printf '%s\n' "$pid"; return 0; }
    done
    echo ""
}

# All background-service PIDs (there should normally be at most one).
opencode_service_pids() {
    local pid cmd
    for pid in /proc/[0-9]*; do
        pid="${pid#/proc/}"
        proc_exists "$pid" || continue
        cmd="$(proc_cmdline "$pid")"
        [[ "$cmd" == *opencode* && "$cmd" == *serve* && "$cmd" == *--service* ]] && printf '%s\n' "$pid"
    done
    return 0
}

# PIDs owned by t3code.service (cgroup membership or descent from T3 MainPID).
opencode_t3_owned_pids() {
    local pid exe cmd main
    main="$(t3_main_pid)"
    for pid in /proc/[0-9]*; do
        pid="${pid#/proc/}"
        proc_exists "$pid" || continue
        exe="$(proc_exe "$pid")"
        cmd="$(proc_cmdline "$pid")"
        if [[ "$exe" == *"/@opencode/cli/"* ]] || [[ "$cmd" == opencode\ * ]] || [[ "${cmd%% *}" == opencode* ]]; then
            if [[ "$(proc_cgroup "$pid")" == *"$T3_UNIT"* ]] \
               || { [[ "$main" =~ ^[0-9]+$ ]] && [[ "$main" != "0" ]] && is_descendant_of "$pid" "$main"; }; then
                printf '%s\n' "$pid"
            fi
        fi
    done
    return 0
}

# True when a process PID exists AND still looks like the OpenCode service.
opencode_pid_is_service() { # <pid>
    local cmd
    [[ -n "${1:-}" ]] || return 1
    proc_exists "$1" || return 1
    cmd="$(proc_cmdline "$1")"
    [[ "$cmd" == *opencode* && "$cmd" == *serve* && "$cmd" == *--service* ]]
}

# Stop the official background service and PROVE the old PID is gone.
# Escalates to a targeted SIGTERM then SIGKILL on that ONE pid.
# Returns 0 only when the old service process no longer exists.
opencode_stop_service() { # <old_pid> <old_start>
    local old_pid="$1" old_start="$2" i res status msg rc

    [[ -n "$old_pid" ]] || { info "no background service was running; nothing to stop"; return 0; }
    proc_exists "$old_pid" || { info "background service PID $old_pid already gone"; return 0; }

    info "Stopping OpenCode background service (official: opencode service stop)"
    res="$(opencode_official service stop)"
    status="${res%%|*}"; res="${res#*|}"
    msg="${res%%|*}";     rc="${res##*|}"
    info "  service stop: status=$status rc=$rc"
    [[ -n "$msg" && "$msg" != "$status" ]] && info "  $msg"

    for (( i = 1; i <= 30; i++ )); do
        proc_exists "$old_pid" || break
        sleep 1
    done
    if ! proc_exists "$old_pid"; then
        info "  official stop removed service PID $old_pid"
        return 0
    fi

    # The command claimed success but the process survived. Signal THAT pid only.
    warn "official stop left PID $old_pid alive; sending SIGTERM to that PID only"
    if ! terminate_pids "opencode-service" "$old_pid"; then
        err "service PID $old_pid would not stop; refusing to run 'opencode upgrade'"
        return 1
    fi
    for (( i = 1; i <= 20; i++ )); do
        proc_exists "$old_pid" || break
        sleep 1
    done
    if proc_exists "$old_pid"; then
        err "service PID $old_pid survived SIGTERM/SIGKILL; refusing to run 'opencode upgrade'"
        return 1
    fi
    info "  service PID $old_pid terminated by signal"
    return 0
}

# Run an official opencode subcommand and classify the outcome.
opencode_official() { # <subcommand> [args...]
    local sub="$1"; shift
    local out rc
    # Close the mutation lock before the command is spawned. In particular,
    # `service start` may detach a daemon which must not prolong our lock.
    out="$(timeout 120 "$OPENCODE_BIN" "$sub" "$@" 9>&- 2>&1)" && rc=0 || rc=$?
    local status="ok"
    [[ $rc -eq 0 ]] || status="error"
    printf '%s|%s|%s' "$status" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)" "$rc"
}

# Refuse to run 'opencode upgrade' while any pre-update workload survives.
opencode_pre_update_proof() { # <old_pid> <old_start>
    local old_pid="$1" old_start="$2" pid bad=0

    if [[ -n "$old_pid" ]] && proc_exists "$old_pid"; then
        err "old OpenCode service PID $old_pid is still alive; refusing to run 'opencode upgrade'"
        bad=1
    fi
    if [[ -n "$old_pid" ]] && opencode_pid_is_service "$old_pid"; then
        err "old OpenCode PID $old_pid is still the service; refusing to run 'opencode upgrade'"
        bad=1
    fi
    # No background service may still be running from the pre-update build.
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        err "OpenCode background service PID $pid still running; refusing to run 'opencode upgrade'"
        bad=1
    done < <(opencode_service_pids)

    # No process that this run intended to shut down may have survived.
    local p
    for p in ${OPENCODE_TARGET_PIDS:-}; do
        [[ -n "$p" ]] || continue
        if proc_exists "$p"; then
            err "target OpenCode PID $p survived the stop phase; refusing to run 'opencode upgrade'"
            bad=1
        fi
    done

    [[ $bad -eq 0 ]] || return 1
    info "pre-update proof: no OpenCode workload survives (old PID ${old_pid:-none}, start ${old_start:-?})"
    return 0
}

# Restore the background service only if it was running before this run.
opencode_restore_service() { # <was_running>
    local was="$1" i res status msg rc
    if [[ "$was" -ne 1 ]]; then
        info "background service was not running before this run; not starting it"
        return 0
    fi
    info "Restoring OpenCode background service (official: opencode service start)"
    res="$(opencode_official service start)"
    status="${res%%|*}"; res="${res#*|}"
    msg="${res%%|*}";     rc="${res##*|}"
    info "  service start: status=$status rc=$rc"
    [[ -n "$msg" && "$msg" != "$status" ]] && info "  $msg"

    for (( i = 1; i <= 60; i++ )); do
        [[ -n "$(opencode_service_pid)" ]] && break
        sleep 1
    done
    OPENCODE_AFTER_PID="$(opencode_service_pid)"
    if [[ -z "$OPENCODE_AFTER_PID" ]]; then
        RESTORE_FAILURES+=("opencode service start produced no service process (status=$status rc=$rc)")
        return 1
    fi
    info "  fresh service PID: $OPENCODE_AFTER_PID"
    return 0
}

# Prove the service REALLY cycled. For a same-version upgrade, PID and start
# time are the only available evidence that anything happened.
opencode_verify_fresh_service() { # <before_pid> <before_start> <before_version>
    local b_pid="$1" b_start="$2" b_ver="$3"
    local problems=()

    if [[ $OPENCODE_SERVICE_WAS_RUNNING -ne 1 ]]; then
        info "freshness not applicable: no service was running before this run"
        return 0
    fi

    OPENCODE_AFTER_PID="$(opencode_service_pid)"
    if [[ -z "$OPENCODE_AFTER_PID" ]]; then
        problems+=("no OpenCode service process exists after the update")
    fi
    OPENCODE_AFTER_START=""
    [[ -n "$OPENCODE_AFTER_PID" ]] && OPENCODE_AFTER_START="$(proc_starttime "$OPENCODE_AFTER_PID")"
    OPENCODE_AFTER_EXE=""
    [[ -n "$OPENCODE_AFTER_PID" ]] && OPENCODE_AFTER_EXE="$(proc_exe "$OPENCODE_AFTER_PID")"
    OPENCODE_AFTER_VERSION="$(opencode_version)"

    if [[ -n "$OPENCODE_AFTER_PID" ]]; then
        if [[ -n "$b_pid" && "$OPENCODE_AFTER_PID" == "$b_pid" ]]; then
            # A recycled PID is only acceptable with different identity/time.
            if [[ -n "$b_start" && -n "$OPENCODE_AFTER_START" && "$OPENCODE_AFTER_START" == "$b_start" ]]; then
                problems+=("service PID $OPENCODE_AFTER_PID is unchanged and has the same start time: the service did not cycle")
            fi
        fi
    fi

    if [[ -n "$b_start" && -n "$OPENCODE_AFTER_START" && -n "$OPENCODE_AFTER_PID" ]]; then
        if [[ "$OPENCODE_AFTER_START" -le "$b_start" ]]; then
            problems+=("fresh service start time $OPENCODE_AFTER_START is not newer than $b_start")
        fi
    fi

    local root
    root="$(opencode_install_root)"
    if [[ -z "$root" ]]; then
        problems+=("install root could not be resolved; the service build cannot be verified")
    elif [[ -n "$OPENCODE_AFTER_EXE" ]]; then
        [[ "$OPENCODE_AFTER_EXE" == "$root/"* ]] || \
            problems+=("service exe $OPENCODE_AFTER_EXE is not under the installed root $root")
    fi

    local stale
    stale="$(opencode_stale_processes || true)"
    if [[ -n "$stale" ]]; then
        problems+=("stale-build OpenCode process(es): $(printf '%s' "$stale" | tr '\n' ' ')")
    fi

    if [[ ${#problems[@]} -gt 0 ]]; then
        printf '%s' "${problems[*]}"
        return 1
    fi

    if [[ "$OPENCODE_AFTER_VERSION" == "$b_ver" ]]; then
        info "freshness: same-version upgrade ($b_ver -> $OPENCODE_AFTER_VERSION); proved by PID $b_pid -> $OPENCODE_AFTER_PID and start time $b_start -> $OPENCODE_AFTER_START"
    else
        info "freshness: $b_ver -> $OPENCODE_AFTER_VERSION; PID $b_pid -> $OPENCODE_AFTER_PID"
    fi
    return 0
}

# All opencode processes, classified
opencode_processes() {
    local pid exe cmd cg main class
    main="$(t3_main_pid)"
    for pid in /proc/[0-9]*; do
        pid="${pid#/proc/}"
        proc_exists "$pid" || continue
        exe="$(proc_exe "$pid")"
        cmd="$(proc_cmdline "$pid")"
        if [[ "$exe" == *"/@opencode/cli/"* ]] || [[ "$cmd" == opencode\ * ]] || [[ "${cmd%% *}" == opencode* ]]; then
            if [[ "$(proc_cgroup "$pid")" == *"$T3_UNIT"* ]] \
               || { [[ "$main" =~ ^[0-9]+$ ]] && [[ "$main" != "0" ]] && is_descendant_of "$pid" "$main"; }; then
                class="t3-owned"
            elif [[ "$cmd" == *serve* && "$cmd" == *--service* ]]; then
                class="background-service"
            elif [[ "$cmd" == *serve* ]]; then
                class="server"
            else
                class="other"
            fi
            printf '%s\t%s\t%s\n' "$pid" "$class" "$(printf '%s' "$cmd" | cut -c1-110)"
        fi
    done
}

opencode_stale_processes() {
    # Any opencode process whose exe is not the currently installed one.
    local root pid exe
    root="$(opencode_install_root)"
    # An unresolvable install root means the build cannot be identified. Emit a
    # marker so callers fail closed instead of treating "unknown" as "clean".
    [[ -n "$root" ]] || { printf 'UNRESOLVED_INSTALL_ROOT\n'; return 0; }
    opencode_processes | while IFS=$'\t' read -r pid _ _; do
        exe="$(proc_exe "$pid")"
        [[ -n "$exe" ]] || continue
        [[ "$exe" == "$root/"* ]] || printf '%s\n' "$pid"
    done
}

# =============================================================================
# Hermes helpers
# =============================================================================

hermes_version() { "$HERMES_BIN" --version 2>/dev/null | sed -n 's/^Hermes Agent \([^ ]*\).*/\1/p' | head -n1; }

hermes_home() { printf '%s' "${HERMES_HOME:-$HOME/.hermes}"; }

hermes_git_sha() { git -C "$(hermes_home)/hermes-agent" rev-parse HEAD 2>/dev/null || echo ""; }

hermes_pids_for_unit() { # hermes_pids_for_unit <unit>
    local main; main="$(unit_mainpid "$1")"
    [[ "$main" =~ ^[0-9]+$ ]] && [[ "$main" != "0" ]] && printf '%s\n' "$main"
    return 0
}

# =============================================================================
# Locking — one global mutation lock
# =============================================================================

acquire_lock() {
    mkdir -p "$STATE_ROOT" 2>/dev/null || true
    # Sanity check: flock must actually be usable before we claim a lock.
    if ! command -v flock >/dev/null 2>&1; then
        err "flock is not available; refusing to run without mutual exclusion"
        exit 3
    fi
    exec 9>"$GLOBAL_LOCK" || { err "cannot open lock $GLOBAL_LOCK"; exit 3; }
    if ! flock -n 9; then
        err "another update is running and owns $GLOBAL_LOCK"
        if [[ -r "$STATE_ROOT/update.lock.holder" ]]; then
            err "holder:"
            sed 's/^/    /' "$STATE_ROOT/update.lock.holder" >&2 || true
        fi
        err "No changes were made. Wait for it to finish, then retry."
        exit 3
    fi
    LOCK_HELD=1
    # Identify the holder for humans. Written to a sidecar, never to the lock
    # file itself, so we cannot truncate another updater's record.
    printf 'pid=%s\nstarted=%s\ncmd=%s\n' \
        "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${UPDATE_ARGV:-<unknown>}" \
        > "$STATE_ROOT/update.lock.holder" 2>/dev/null || true
    return 0
}

# Dry-run and --check never create a lock file or holder record. If one already
# exists, make a best-effort read-only shared-lock observation in a short-lived
# subshell. A concurrent mutation may start immediately afterwards, so this
# remains an observational snapshot rather than a transaction.
acquire_observation_lock() {
    [[ -e "$GLOBAL_LOCK" ]] || return 0
    if ! ( exec 8<"$GLOBAL_LOCK" && flock -s -n 8 ); then
        OBS_LOCK_BUSY=1
        warn "mutation lock is busy; continuing with an observational snapshot that may become stale"
    fi
    return 0
}

# =============================================================================
# Traps / restoration
# =============================================================================

on_exit() {
    local rc=$?
    if [[ $LOG_FH_OPEN -eq 1 ]]; then
        printf '=== update finished rc=%s at %s ===\n' \
            "$rc" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    fi
    if [[ $LOCK_HELD -eq 1 ]]; then
        rm -f "$STATE_ROOT/update.lock.holder" 2>/dev/null || true
    fi
    exit "$rc"
}

on_signal() {
    printf '\n[INTERRUPTED] received a termination signal.\n' >&2

    # Codex first: a stopped app-server is an outage of the SSH control surface,
    # so it is restored before anything else and independently of T3.
    if [[ $IN_MUTATION -eq 1 && $DRY_RUN -eq 0 && $CODEX_RESTORE_NEEDED -eq 1 ]]; then
        printf '[INTERRUPTED] this run had stopped the Codex app-server (was PID %s); attempting to restore it...\n' \
            "${CODEX_APP_BEFORE_PID:-unknown}" >&2
        if codex_restore_background >/dev/null 2>&1; then
            CODEX_RESTORE_NEEDED=0
            printf '[INTERRUPTED] Codex app-server restore requested.\n' >&2
        else
            printf '[INTERRUPTED] Codex app-server could NOT be restored. Check it manually.\n' >&2
        fi
    fi

    if [[ $IN_MUTATION -eq 1 && $T3_STOPPED_BY_US -eq 1 && $DRY_RUN -eq 0 ]]; then
        printf '[INTERRUPTED] this run had stopped t3code.service; attempting to restore it...\n' >&2
        if systemctl --user start "$T3_UNIT" 2>/dev/null; then
            printf '[INTERRUPTED] t3code.service restore requested.\n' >&2
        else
            printf '[INTERRUPTED] t3code.service could NOT be restored. Check it manually.\n' >&2
        fi
    fi
    printf '[INTERRUPTED] state may be mid-flight. Run "update --verify" before trusting the stack.\n' >&2
    exit 5
}

install_traps() {
    trap on_exit EXIT
    trap on_signal INT TERM
}

# Mutation runs only. --verify and --dry-run write nothing.
#
# REGRESSION NOTE (2026-10-04): this function previously did
#     exec > >(tee -a "$logf" | scrub >&3)
#     exec 3>&-
# It ran this instead:
#       exec > >(tee -a "$logf" | scrub >&3)
#       exec 3>&-
# FD 3 was never opened, so `scrub >&3` failed with "Bad file descriptor",
# which killed the pipeline and made every later printf fail with
# "write error: Broken pipe" -- including the EXIT trap. It also had the
# scrub on the wrong side of tee, so the log received RAW unredacted output.
# Both are fixed below. Do not reintroduce a custom file descriptor here.
# test-update.sh section 15 covers this and extracts the exec line below.
start_logging() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    mkdir -p "$LOG_DIR" 2>/dev/null || return 0
    local logf
    logf="$LOG_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-$$.log"
    : >"$logf" 2>/dev/null || return 0
    chmod 600 "$logf" 2>/dev/null || true

    # scrub runs BEFORE tee, so what lands in the log is already redacted.
    # No custom file descriptor is involved.
    #
    #   stdout+stderr -> scrub -> tee -> terminal
    #                                       -> log
    exec > >(scrub | tee -a "$logf") 2>&1
    LOG_FH_OPEN=1
    ACTIVE_LOG="$logf"

    printf '=== update run %s pid=%s log=%s ===\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$$" "$logf"
    return 0
}

prune_update_logs() {
    [[ $DRY_RUN -eq 0 && $DO_VERIFY -eq 0 && $DO_CHECK -eq 0 ]] || return 0
    [[ -d "$LOG_DIR" && ! -L "$LOG_DIR" ]] || return 0
    local rows=() i name path
    mapfile -t rows < <(find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.log' -printf '%T@ %f\n' 2>/dev/null | sort -rn)
    for ((i=LOG_KEEP; i<${#rows[@]}; i++)); do
        name="${rows[$i]#* }"
        [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+\.log$ ]] || continue
        path="$LOG_DIR/$name"
        [[ "$path" == "$ACTIVE_LOG" ]] && continue
        if ! rm -- "$path" 2>/dev/null; then warn "could not prune old updater log: $name"; fi
    done
}

# =============================================================================
# VERIFY — read-only, zero mutation
# =============================================================================

# Availability is deliberately conservative: only OpenCode has a bounded,
# read-only lookup against the npm registry channel used by its native upgrade.
precheck_tool() { # precheck_tool <codex|opencode|hermes|t3>
    local tool="$1" installed latest root pid exe
    [[ -n "${PRECHECK[$tool]:-}" ]] && return 0
    case "$tool" in
        codex) [[ -z "$CODEX_BIN" ]] && { PRECHECK[$tool]=NOT_CONFIGURED; PRECHECK_DETAIL[$tool]="not installed"; return; }
            PRECHECK[$tool]=UNKNOWN; PRECHECK_DETAIL[$tool]="no safe read-only authoritative latest check; native reconciliation required" ;;
        hermes) [[ -z "$HERMES_BIN" ]] && { PRECHECK[$tool]=NOT_CONFIGURED; PRECHECK_DETAIL[$tool]="not installed"; return; }
            PRECHECK[$tool]=UNKNOWN; PRECHECK_DETAIL[$tool]="native check may mutate checkout metadata; latest ref unavailable safely" ;;
        t3) [[ -z "$T3_BIN" ]] && { PRECHECK[$tool]=NOT_CONFIGURED; PRECHECK_DETAIL[$tool]="not installed"; return; }
            PRECHECK[$tool]=UNKNOWN; PRECHECK_DETAIL[$tool]="nightly latest ref unavailable safely; reconciliation required" ;;
        opencode)
            [[ -z "$OPENCODE_BIN" ]] && { PRECHECK[$tool]=NOT_CONFIGURED; PRECHECK_DETAIL[$tool]="not installed"; return; }
            installed="$(opencode_version)"
            if [[ -z "$installed" ]]; then PRECHECK[$tool]=UNKNOWN; PRECHECK_DETAIL[$tool]="installed version unreadable"; return; fi
            latest="$(timeout 8 curl -fsS --max-time 7 'https://registry.npmjs.org/%40opencode%2Fcli/latest' 2>/dev/null | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)"
            if [[ -z "$latest" ]]; then PRECHECK[$tool]=UNKNOWN; PRECHECK_DETAIL[$tool]="npm registry latest lookup unavailable; installed v$installed"; return; fi
            root="$(opencode_install_root 2>/dev/null || true)"
            while read -r pid; do
                [[ -n "$pid" ]] || continue
                exe="$(proc_exe "$pid")"
                if [[ -z "$root" || "$exe" != "$root"/* ]]; then
                    PRECHECK[$tool]=UNKNOWN; PRECHECK_DETAIL[$tool]="running service PID $pid is outside the current installation"; return
                fi
            done < <(opencode_service_pids)
            if [[ "$installed" != "$latest" ]]; then
                PRECHECK[$tool]=UPDATE_AVAILABLE; PRECHECK_DETAIL[$tool]="v$installed -> v$latest"
            elif opencode_verify_local_health; then
                PRECHECK[$tool]=CURRENT; PRECHECK_DETAIL[$tool]="v$installed; local verification healthy"
            else
                PRECHECK[$tool]=UNKNOWN; PRECHECK_DETAIL[$tool]="v$installed; local service verification is not healthy"
            fi
            ;;
    esac
}

opencode_verify_local_health() {
    local stale
    stale="$(opencode_stale_processes)"
    [[ -z "$stale" ]]
}

precheck_selected() {
    [[ $DO_CODEX -eq 1 ]] && precheck_tool codex
    [[ $DO_OPENCODE -eq 1 ]] && precheck_tool opencode
    [[ $DO_HERMES -eq 1 ]] && precheck_tool hermes
    [[ $DO_T3 -eq 1 ]] && precheck_tool t3
    if [[ $OBS_LOCK_BUSY -eq 1 ]]; then
        local t
        for t in codex opencode hermes t3; do
            [[ -n "${PRECHECK[$t]:-}" && "${PRECHECK[$t]}" == CURRENT ]] || continue
            PRECHECK[$t]=UNKNOWN
            PRECHECK_DETAIL[$t]="mutation lock is busy; current state cannot be accepted"
        done
    fi
}

print_check() {
    local t s d rc=0
    printf 'UPDATE AVAILABILITY\n'
    for t in codex opencode hermes t3; do
        precheck_tool "$t"
        if [[ $OBS_LOCK_BUSY -eq 1 && "${PRECHECK[$t]}" == CURRENT ]]; then
            PRECHECK[$t]=UNKNOWN
            PRECHECK_DETAIL[$t]="mutation lock is busy; current state cannot be accepted"
        fi
        s="${PRECHECK[$t]}"; d="${PRECHECK_DETAIL[$t]}"
        printf '%-10s %-18s %s\n' "$t" "$s" "$d"
        [[ "$s" == UNKNOWN ]] && continue
        [[ "$s" == NOT_CONFIGURED ]] && continue
    done
    return "$rc"
}

# Surface the daemon-package outcome in the final result so an "unsupported"
# or "skipped" step can never be mistaken for a completed update.
codex_result_detail() { # <base detail>
    local base="$1" extra=""
    if [[ "$DAEMON_PACKAGE_UPDATE" != "SUPPORTED" ]]; then
        extra="; daemon package update: ${DAEMON_PACKAGE_UPDATE}"
    fi
    if [[ "$DAEMON_PKG_STATUS" != "updated" && -n "$DAEMON_PKG_STATUS" && "$DAEMON_PKG_STATUS" != "NOT_APPLICABLE" ]]; then
        extra+=" (${DAEMON_PKG_STATUS}: ${DAEMON_PKG_DETAIL})"
    fi
    printf '%s%s' "$base" "$extra"
}

verify_codex() {
    local v st dver cur
    if [[ -z "$CODEX_BIN" ]]; then
        RESULT[codex]="NOT_CONFIGURED"; RESULT_DETAIL[codex]="codex not on PATH"
        status_line codex NOT_CONFIGURED "codex not on PATH"
        return 0
    fi
    v="$(codex_cli_version)"
    if [[ -z "$v" ]]; then
        RESULT[codex]="FAIL"; RESULT_DETAIL[codex]="installed but --version returned nothing"
        status_line codex FAIL "installed but --version returned nothing"
        return 0
    fi

    local details=("cli $v")

    st="$(codex_daemon_status)"
    dver="$(codex_daemon_version)"
    cur="$(codex_current_release)"

    case "$st" in
        running) details+=("daemon running ${dver:-?} on release ${cur:-?}") ;;
        stopped) details+=("daemon not running (accepted: not configured to run)") ;;
        "")      details+=("daemon status UNKNOWN") ;;
        *)       details+=("daemon ${st}") ;;
    esac

    # A process executing a release other than the current one is real drift.
    local stale
    stale="$(codex_stale_processes || true)"
    if [[ -n "$stale" ]]; then
        local n detail
        n="$(printf '%s\n' "$stale" | wc -l | tr -d ' ')"
        detail="${details[*]}; $n process(es) on a non-current release: $(printf '%s' "$stale" | tr '\n' ' ')"
        RESULT[codex]="FAIL"; RESULT_DETAIL[codex]="$detail"
        status_line codex FAIL "$detail"
        return 0
    fi

    local d="${details[*]}"
    RESULT[codex]="PASS"; RESULT_DETAIL[codex]="$d"
    status_line codex PASS "$d"
}

verify_opencode() {
    local v
    if [[ -z "$OPENCODE_BIN" ]]; then
        RESULT[opencode]="NOT_CONFIGURED"; RESULT_DETAIL[opencode]="opencode not on PATH"
        status_line opencode NOT_CONFIGURED "opencode not on PATH"
        return 0
    fi
    v="$(opencode_version)"
    if [[ -z "$v" ]]; then
        RESULT[opencode]="FAIL"; RESULT_DETAIL[opencode]="installed but --version returned nothing"
        status_line opencode FAIL "installed but --version returned nothing"
        return 0
    fi

    local url svc
    url="$(opencode_background_service_url || true)"
    svc="no background service"
    [[ -n "$url" ]] && svc="service ${url}"

    local stale
    stale="$(opencode_stale_processes || true)"
    if [[ -n "$stale" ]]; then
        local n detail
        n="$(printf '%s\n' "$stale" | wc -l | tr -d ' ')"
        detail="v$v; $n process(es) not on the installed build: $(printf '%s' "$stale" | tr '\n' ' ')"
        RESULT[opencode]="FAIL"; RESULT_DETAIL[opencode]="$detail"
        status_line opencode FAIL "$detail"
        return 0
    fi

    local d="v$v; $svc"
    RESULT[opencode]="PASS"; RESULT_DETAIL[opencode]="$d"
    status_line opencode PASS "$d"
}

verify_hermes() {
    local v
    if [[ -z "$HERMES_BIN" ]]; then
        RESULT[hermes]="NOT_CONFIGURED"; RESULT_DETAIL[hermes]="hermes not on PATH"
        status_line hermes NOT_CONFIGURED "hermes not on PATH"
        return 0
    fi
    v="$(hermes_version)"
    if [[ -z "$v" ]]; then
        RESULT[hermes]="FAIL"; RESULT_DETAIL[hermes]="installed but --version returned nothing"
        status_line hermes FAIL "installed but --version returned nothing"
        return 0
    fi

    local problems=() notes=()
    local u
    for u in "${HERMES_UNITS[@]}"; do
        local sc; sc="$(unit_label "$u")"
        if [[ "$sc" == "absent" ]]; then
            notes+=("${u%%.service} not installed")
            continue
        fi
        if unit_active "$u"; then
            local pid; pid="$(unit_mainpid "$u")"
            local where="${sc}:${pid:-?}"
            if unit_enabled "$u"; then notes+=("${u%%.service} active+enabled $where")
            else notes+=("${u%%.service} active(not-enabled) $where"); fi
        else
            problems+=("${u%%.service} not active (${sc} unit)")
        fi
    done

    local d="cli $v; ${notes[*]:-no units}"
    if [[ ${#problems[@]} -gt 0 ]]; then
        d+="; PROBLEM: ${problems[*]}"
        RESULT[hermes]="FAIL"; RESULT_DETAIL[hermes]="$d"
        status_line hermes FAIL "$d"
    else
        RESULT[hermes]="PASS"; RESULT_DETAIL[hermes]="$d"
        status_line hermes PASS "$d"
    fi
}

verify_t3() {
    if [[ -z "$T3_BIN" ]]; then
        RESULT[t3]="NOT_CONFIGURED"; RESULT_DETAIL[t3]="t3 not on PATH"
        status_line t3 NOT_CONFIGURED "t3 not on PATH"
        return 0
    fi
    local cli launcher state execstart mainpid serve http pending
    cli="$(t3_cli_version)"
    launcher="$(t3_launcher_version)"
    state="$(t3_state_version)"
    execstart="$(t3_execstart_version)"
    mainpid="$(t3_mainpid_version)"
    serve="$(t3_serve_version)"
    http="$(t3_http_health)"
    pending="$(t3_pending_update)"

    if [[ -z "$cli" ]]; then
        RESULT[t3]="FAIL"; RESULT_DETAIL[t3]="t3 installed but --version returned nothing"
        status_line t3 FAIL "installed but --version returned nothing"
        return 0
    fi

    local mismatches=()
    local v
    for v in "$launcher" "$state" "$execstart" "$mainpid" "$serve"; do
        [[ -z "$v" ]] && continue
        [[ "$v" == "$cli" ]] || mismatches+=("$v")
    done

    local detail="cli=$cli launcher=${launcher:-?} state=${state:-?} execstart=${execstart:-?} mainpid=${mainpid:-?} serve=${serve:-?} http=$http"

    if ! t3_active; then
        detail="${T3_UNIT} not active; $detail"
        RESULT[t3]="FAIL"; RESULT_DETAIL[t3]="$detail"
        status_line t3 FAIL "$detail"
        return 0
    fi
    if [[ "$http" != "200" ]]; then
        detail="HTTP $http (expected 200); $detail"
        RESULT[t3]="FAIL"; RESULT_DETAIL[t3]="$detail"
        status_line t3 FAIL "$detail"
        return 0
    fi
    if [[ "$pending" != "none" ]]; then
        detail="pending update state: $pending; $detail"
        RESULT[t3]="FAIL"; RESULT_DETAIL[t3]="$detail"
        status_line t3 FAIL "$detail"
        return 0
    fi
    if [[ ${#mismatches[@]} -gt 0 ]]; then
        detail="version drift — not matching cli $cli: ${mismatches[*]}; $detail"
        RESULT[t3]="FAIL"; RESULT_DETAIL[t3]="$detail"
        status_line t3 FAIL "$detail"
        return 0
    fi
    RESULT[t3]="PASS"; RESULT_DETAIL[t3]="$detail"
    status_line t3 PASS "$detail"
}

do_verify() {
    # Best-effort shared lock WITHOUT creating or modifying the lock file.
    # If the lock file does not exist yet, verify proceeds unserialised.
    local locked=0
    if [[ -e "$GLOBAL_LOCK" ]]; then
        exec 8<"$GLOBAL_LOCK" 2>/dev/null && flock -s -n 8 && locked=1 || true
    fi

    printf '%sSTACK VERIFICATION%s (read-only)  %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$C_RESET"

    verify_codex
    verify_opencode
    verify_hermes
    verify_t3

    section "RESULT"
    local fails=0
    for c in codex opencode hermes t3; do
        [[ "${RESULT[$c]:-}" == "FAIL" ]] && fails=$((fails + 1))
    done

    if [[ $fails -eq 0 ]]; then
        printf '  %sSTACK HEALTHY%s — all configured components PASS\n' "$C_GRN" "$C_RESET"
    else
        printf '  %sSTACK UNHEALTHY%s — %d component check group(s) FAIL\n' "$C_RED" "$C_RESET" "$fails"
    fi
    printf '  %sNo changes were made.%s\n' "$C_DIM" "$C_RESET"

    [[ $locked -eq 1 ]] && exec 8>&- 2>/dev/null || true
    [[ $fails -eq 0 ]] && return 0 || return 1
}

# =============================================================================
# CODEX update
# =============================================================================

do_codex_update() {
    section "CODEX"
    if [[ $DRY_RUN -eq 0 && $FORCE_UPDATE -eq 0 ]]; then
        precheck_tool codex
        if [[ "${PRECHECK[codex]}" == CURRENT ]]; then
            record codex PASS "already current: ${PRECHECK_DETAIL[codex]}"
            status_line codex PASS "already current: ${PRECHECK_DETAIL[codex]}"
            return 0
        fi
    fi
    if [[ -z "$CODEX_BIN" ]]; then
        record codex SKIPPED "codex not installed on PATH"
        status_line codex SKIPPED "not installed on PATH"
        return 0
    fi

    # ---- BEFORE snapshot ------------------------------------------------------
    # Recorded before any mutation so the post-update proof has something real
    # to compare against.
    CODEX_VERSION_BEFORE="$(codex_cli_version)"
    CODEX_RELEASE_BEFORE="$(codex_current_release)"
    CODEX_APP_BEFORE_PID="$(codex_daemon_socket_owner)"
    CODEX_APP_BEFORE_SOCKET="$(codex_control_socket)"
    CODEX_APP_BEFORE_EXE=""
    CODEX_APP_BEFORE_START=""
    if [[ -n "$CODEX_APP_BEFORE_PID" ]]; then
        CODEX_APP_BEFORE_EXE="$(proc_exe "$CODEX_APP_BEFORE_PID")"
        CODEX_APP_BEFORE_START="$(proc_starttime "$CODEX_APP_BEFORE_PID")"
    fi
    CODEX_UPDATER_BEFORE_PID="$(codex_daemon_updater_pid)"
    CODEX_UPDATER_WAS_ACTIVE=0
    if [[ -n "$CODEX_UPDATER_BEFORE_PID" ]] && proc_exists "$CODEX_UPDATER_BEFORE_PID"; then
        CODEX_UPDATER_WAS_ACTIVE=1
    fi
    local daemon_was; daemon_was="$(codex_daemon_status)"
    # Authoritative ownership: a live control-socket owner means managed,
    # regardless of whether any daemon.pid exists.
    local ownership="none running"
    if codex_daemon_is_managed; then
        ownership="managed (control-socket owner; no daemon.pid required)"
    fi

    # Capability detection decides whether the daemon PACKAGE update applies at
    # all, so an unsupported lifecycle is never invoked in the first place.
    local cap cap_reason=""
    cap="$(codex_daemon_update_capability)"
    DAEMON_PKG_CAPABILITY="${cap%%|*}"
    DAEMON_PACKAGE_UPDATE="${cap%%|*}"
    cap_reason="${cap#*|}"

    printf '  %sCODEX BEFORE%s\n' "$C_BOLD" "$C_RESET"
    info "cli version: ${CODEX_VERSION_BEFORE:-?} (release ${CODEX_RELEASE_BEFORE:-?})"
    info "daemon status: ${daemon_was:-unknown}; ownership: ${ownership}"
    if [[ -n "$CODEX_APP_BEFORE_PID" ]]; then
        info "app-server socket owner: PID $CODEX_APP_BEFORE_PID (start ${CODEX_APP_BEFORE_START:-?})"
        info "socket: ${CODEX_APP_BEFORE_SOCKET:-unknown}"
        info "exe: ${CODEX_APP_BEFORE_EXE:-unknown}"
    else
        info "app-server socket owner: none"
    fi
    if [[ $CODEX_UPDATER_WAS_ACTIVE -eq 1 ]]; then
        info "updater loop: PID $CODEX_UPDATER_BEFORE_PID (pid-update-loop; can recreate the app-server)"
    else
        info "updater loop: none active"
    fi
    info "daemon package update capability: ${DAEMON_PKG_CAPABILITY} (${cap_reason})"

    # ---- Discovery / classification -------------------------------------------
    section "CODEX processes"
    local -a targets=()
    local -a t3_owned=() cmh=() pxy=()
    local count=0
    while IFS=$'\t' read -r pid class stale summary; do
        [[ -n "$pid" ]] || continue
        local stale_tag=""
        [[ "$stale" == "yes" ]] && stale_tag=" ${C_RED}STALE-RELEASE${C_RESET}"
        printf '  %-8s %-20s%s %s\n' "$pid" "$class" "$stale_tag" "$summary"
        count=$((count + 1))
        case "$class" in
            managed-app-server|daemon-updater) : ;;   # handled by the stop phase
            code-mode-host) cmh+=("$pid") ;;
            proxy)          pxy+=("$pid") ;;
            t3-owned)       t3_owned+=("$pid") ;;
            *)              targets+=("$pid") ;;
        esac
    done < <(codex_processes | while read -r p; do codex_classify "$p"; done)

    [[ $count -eq 0 ]] && info "no codex processes found"

    # ---- DRY RUN --------------------------------------------------------------
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  %sSTOP PLAN%s\n' "$C_CYN" "$C_RESET"
        if [[ $CODEX_UPDATER_WAS_ACTIVE -eq 1 ]]; then
            a_stop "maintainer/updater PID $CODEX_UPDATER_BEFORE_PID (first: it would recreate the app-server)"
        else
            a_stop "maintainer/updater: none active"
        fi
        if [[ -n "$CODEX_APP_BEFORE_PID" ]]; then
            a_stop "managed app-server PID $CODEX_APP_BEFORE_PID (SIGTERM, then SIGKILL that PID only)"
        else
            a_stop "managed app-server: none running"
        fi
        if [[ ${#cmh[@]} -gt 0 ]]; then
            a_stop "code-mode-host PIDs: ${cmh[*]}"
        else
            a_stop "code-mode-host: none running"
        fi
        if [[ ${#pxy[@]} -gt 0 ]]; then
            a_stop "proxy PIDs: ${pxy[*]}"
        else
            a_stop "proxy: none running"
        fi
        if [[ ${#t3_owned[@]} -gt 0 ]]; then
            a_stop "t3code.service first (owns ${#t3_owned[@]} Codex process(es)), then restore it"
        else
            a_stop "t3code.service: not needed (it owns no Codex child)"
        fi

        printf '  %sPRE-UPDATE GATES%s\n' "$C_CYN" "$C_RESET"
        if [[ -n "$CODEX_APP_BEFORE_PID" ]]; then
            a_verify "old managed app-server PID $CODEX_APP_BEFORE_PID is gone before the native update"
        else
            a_verify "no managed app-server to stop"
        fi
        a_verify "no surviving Codex process on the pre-update release (${CODEX_RELEASE_BEFORE:-?})"

        printf '  %sUPDATE PLAN%s\n' "$C_CYN" "$C_RESET"
        a_update "codex update"
        if [[ "$DAEMON_PKG_CAPABILITY" == "SUPPORTED" ]]; then
            a_update "codex app-server daemon update  (capability: SUPPORTED)"
        else
            info "daemon update — SKIPPED: ${DAEMON_PKG_CAPABILITY} (${cap_reason})"
        fi
        # Always stated, on either branch: the app-server is stopped by its own
        # PID. `daemon stop` is never the mechanism, because it can only report
        # on a pid-file-managed app-server and cannot prove the socket was freed.
        if [[ "$DAEMON_PKG_CAPABILITY" == "SUPPORTED" ]]; then
            info "note: 'daemon stop' is not the stop mechanism; the app-server is signalled by its own PID so the socket release can be proven before the update"
        else
            info "note: 'daemon stop/update' is not the stop mechanism on this host; the app-server is not daemon-managed (no daemon.pid / app-server.pid), so it is stopped by its own PID"
        fi

        printf '  %sRESTORE PLAN%s\n' "$C_CYN" "$C_RESET"
        if [[ -n "$CODEX_APP_BEFORE_PID" ]]; then
            a_restart "Codex background app-server mechanism (codex app-server daemon start)"
            if [[ $CODEX_UPDATER_WAS_ACTIVE -eq 1 ]]; then
                a_restart "daemon updater loop (was PID $CODEX_UPDATER_BEFORE_PID)"
            fi
        else
            a_restart "nothing: no app-server was running before this run"
        fi
        a_restart "t3code.service: only if this run stopped it"

        printf '  %sPOST-UPDATE GATES%s\n' "$C_CYN" "$C_RESET"
        a_verify "fresh app-server PID (must differ from ${CODEX_APP_BEFORE_PID:-none})"
        a_verify "fresh control-socket owner exists and responds"
        a_verify "fresh app-server executable is the current release"
        a_verify "fresh process start time newer than ${CODEX_APP_BEFORE_START:-n/a}"
        a_verify "no stale-release Codex processes"

        record codex PASS "dry-run"
        status_line codex PASS "dry-run: would update ${CODEX_VERSION_BEFORE:-?} -> ?"
        note_dry
        return 0
    fi

    # ---- T3, only when it genuinely owns Codex children ----------------------
    if [[ ${#t3_owned[@]} -gt 0 ]]; then
        t3_stop_for "T3 owns ${#t3_owned[@]} Codex process(es): ${t3_owned[*]}" || true
    else
        info "T3 owns no Codex child; t3code.service left running"
    fi

    # ---- PHASE 3 + 4: maintainer first, then the socket-owning app-server ----
    IN_MUTATION=1
    CODEX_RESTORE_NEEDED=0

    if ! stop_codex_daemon "$CODEX_UPDATER_BEFORE_PID" "$CODEX_APP_BEFORE_PID"; then
        RESTORE_FAILURES+=("Codex stop phase failed before the native update")
        RESTORE_RESULT="FAILED (stop phase aborted before 'codex update')"
        VERIFY_RESULT="NOT RUN (aborted before the native update)"
        UPDATE_RESULT="FAILED (pre-update stop phase)"
        if [[ -n "$CODEX_APP_BEFORE_PID" ]]; then
            CODEX_RESTORE_NEEDED=1
            codex_restore_background || true
            CODEX_RESTORE_NEEDED=0
        fi
        t3_restore_if_stopped || true
        UPDATE_RC[codex]=1
        record codex FAIL "pre-update stop phase failed; 'codex update' was NOT run"
        status_line codex FAIL "pre-update stop phase failed; native update skipped"
        IN_MUTATION=0
        return 0
    fi

    if [[ -n "$CODEX_APP_BEFORE_PID" ]]; then
        CODEX_RESTORE_NEEDED=1
    fi

    # ---- PHASE 5: prove the stop actually took effect ------------------------
    if ! codex_pre_update_proof "$CODEX_APP_BEFORE_PID" "$CODEX_RELEASE_BEFORE"; then
        RESTORE_FAILURES+=("pre-update proof failed: old Codex workloads survived")
        RESTORE_RESULT="FAILED (pre-update proof failed)"
        VERIFY_RESULT="NOT RUN (aborted before the native update)"
        UPDATE_RESULT="FAILED (old app-server survived)"
        if [[ $CODEX_RESTORE_NEEDED -eq 1 ]]; then
            codex_restore_background || true
            CODEX_RESTORE_NEEDED=0
        fi
        t3_restore_if_stopped || true
        UPDATE_RC[codex]=1
        record codex FAIL "old Codex workloads survived the stop phase; native update skipped"
        status_line codex FAIL "old Codex workloads survived; native update skipped"
        IN_MUTATION=0
        return 0
    fi

    # ---- PHASE 6: native update ----------------------------------------------
    local rc=0
    info "Running: codex update"
    # 9>&-: the native updater shells out to an installer that may background
    # work. It must not inherit the global lock fd, or a leftover child would
    # keep the flock held after this run exits.
    if ! "$CODEX_BIN" update 2>&1 9>&- | sed 's/^/    /' 9>&-; then
        rc=1
    fi

    if [[ $rc -ne 0 ]]; then
        UPDATE_RESULT="FAILED (native 'codex update' rc=$rc)"
        UPDATE_RC[codex]=$rc
        RESTORE_RESULT="ATTEMPTED after the failed update"
        if [[ $CODEX_RESTORE_NEEDED -eq 1 ]]; then
            codex_restore_background || true
            CODEX_RESTORE_NEEDED=0
        fi
        t3_restore_if_stopped || true
        VERIFY_RESULT="$(codex_verify_after_failure)"
        record codex FAIL "native 'codex update' failed (rc=$rc)"
        status_line codex FAIL "native 'codex update' failed (rc=$rc)"
        IN_MUTATION=0
        return 0
    fi

    # Daemon PACKAGE update. Only invoked when capability detection says it
    # applies; and when it is invoked, the machine-readable status decides the
    # verdict rather than the shell exit code, because the command exits 0
    # even while reporting {"status":"unsupported"}.
    DAEMON_PKG_STATUS=""
    DAEMON_PKG_DETAIL=""
    if [[ "$DAEMON_PKG_CAPABILITY" == "SUPPORTED" ]]; then
        local dres dstatus dmsg drc
        dres="$(codex_daemon_subcommand update)"
        dstatus="${dres%%|*}"; dres="${dres#*|}"
        dmsg="${dres%%|*}";   drc="${dres##*|}"
        info "daemon package update: status=$dstatus rc=$drc"
        if [[ -n "$dmsg" ]]; then info "  $dmsg"; fi
        case "$dstatus" in
            unsupported)
                DAEMON_PKG_STATUS="unsupported"
                DAEMON_PACKAGE_UPDATE="NOT_APPLICABLE"
                DAEMON_PKG_DETAIL="$dmsg"
                warn "daemon package update reported unsupported: $dmsg"
                ;;
            ok|updated|up-to-date|upToDate|noUpdate|alreadyUpToDate|success)
                # noUpdate is a benign outcome: the managed package is already
                # current. It is success, not failure. (Observed on this host,
                # where the daemon updater had nothing to do.)
                DAEMON_PKG_STATUS="updated"
                DAEMON_PKG_DETAIL="status=$dstatus"
                ;;
            *)
                DAEMON_PKG_STATUS="failed"
                DAEMON_PKG_DETAIL="status=$dstatus rc=$drc: $dmsg"
                rc=1
                ;;
        esac
    else
        DAEMON_PKG_STATUS="NOT_APPLICABLE"
        DAEMON_PACKAGE_UPDATE="NOT_APPLICABLE"
        DAEMON_PKG_DETAIL="${cap_reason:-not applicable}"
        info "skipping 'codex app-server daemon update': ${DAEMON_PKG_DETAIL}"
    fi

    UPDATE_RC[codex]=$rc
    if [[ $rc -ne 0 ]]; then
        UPDATE_RESULT="FAILED (daemon package update)"
        # The app-server was already stopped, so it MUST be restored even
        # though the update failed. Leaving the control surface down because a
        # secondary step failed would be worse than the failure itself.
        RESTORE_RESULT="ATTEMPTED after the failed update"
        if [[ $CODEX_RESTORE_NEEDED -eq 1 ]]; then
            codex_restore_background || true
            CODEX_RESTORE_NEEDED=0
        fi
        t3_restore_if_stopped || true
        VERIFY_RESULT="$(codex_verify_after_failure)"
        record codex FAIL "daemon package update failed: ${DAEMON_PKG_DETAIL}"
        status_line codex FAIL "daemon package update failed: ${DAEMON_PKG_DETAIL}"
        IN_MUTATION=0
        return 0
    fi

    # ---- PHASE 7: restore the background Codex state -------------------------
    if [[ $CODEX_RESTORE_NEEDED -eq 1 ]]; then
        if codex_restore_background; then
            RESTORE_RESULT="PASS (background app-server restored as PID $(codex_daemon_socket_owner); updater loop: ${CODEX_UPDATER_LOOP_AFTER})"
        else
            RESTORE_RESULT="INCOMPLETE (see RESTORE RESULT above)"
        fi
        CODEX_RESTORE_NEEDED=0
    else
        RESTORE_RESULT="NOT NEEDED (no background app-server was running before this run)"
        info "no background app-server was stopped by this run; nothing to restore"
    fi

    t3_restore_if_stopped || true

    # ---- PHASE 7 + 8: prove the replacement is genuinely fresh ---------------
    local fresh_rc=0
    if [[ -n "$CODEX_APP_BEFORE_PID" ]]; then
        if codex_verify_fresh_app_server \
                "$CODEX_APP_BEFORE_PID" "$CODEX_APP_BEFORE_START" \
                "$CODEX_RELEASE_BEFORE" "$CODEX_VERSION_BEFORE"; then
            VERIFY_RESULT="PASS (fresh app-server proved by PID, start time and release)"
        else
            fresh_rc=1
            VERIFY_RESULT="FAILED (fresh app-server proof did not hold)"
        fi
    else
        VERIFY_RESULT="PASS (no app-server existed before; none required)"
    fi

    verify_codex
    local st="${RESULT[codex]:-FAIL}" after_ver
    after_ver="$(codex_cli_version)"
    UPDATE_RESULT="SUCCESS (codex update rc=0)"
    if [[ "$st" == "PASS" && $fresh_rc -eq 0 ]]; then
        local d; d="$(codex_result_detail "cli ${CODEX_VERSION_BEFORE} -> ${after_ver}; app-server ${CODEX_APP_BEFORE_PID} -> $(codex_daemon_socket_owner)")"
        record codex PASS "$d"
        status_line codex PASS "$d"
    else
        local d2; d2="$(codex_result_detail "${RESULT_DETAIL[codex]:-post-update verification failed}; updater loop: ${CODEX_UPDATER_LOOP_AFTER}")"
        UPDATE_RESULT="FAILED (post-update verification)"
        record codex FAIL "$d2"
        status_line codex FAIL "$d2"
    fi
    IN_MUTATION=0
    return 0
}

# Verify the stack after an aborted or failed Codex update, reported as a
# distinct outcome from the update failure itself.
codex_verify_after_failure() {
    verify_codex
    if [[ "${RESULT[codex]:-FAIL}" == "PASS" ]]; then
        printf 'PASS (stack recovered despite the failure)'
    else
        printf 'FAILED (%s)' "${RESULT_DETAIL[codex]:-codex did not verify}"
    fi
}

# =============================================================================
# OPENCODE V2 update
# =============================================================================

do_opencode_update() {
    section "OPENCODE V2"
    if [[ $DRY_RUN -eq 0 && $FORCE_UPDATE -eq 0 ]]; then
        precheck_tool opencode
        if [[ "${PRECHECK[opencode]}" == CURRENT ]]; then
            record opencode PASS "already current: ${PRECHECK_DETAIL[opencode]}"
            status_line opencode PASS "already current: ${PRECHECK_DETAIL[opencode]}"
            return 0
        fi
    fi
    if [[ -z "$OPENCODE_BIN" ]]; then
        record opencode SKIPPED "opencode not installed on PATH"
        status_line opencode SKIPPED "not installed on PATH"
        return 0
    fi

    # ---- BEFORE snapshot ------------------------------------------------------
    # The PID and its start time are authoritative. A responding URL is only a
    # hint: it says nothing about which process serves, or from which build.
    OPENCODE_BEFORE_VERSION="$(opencode_version)"
    OPENCODE_BEFORE_PID="$(opencode_service_pid)"
    OPENCODE_BEFORE_EXE=""
    OPENCODE_BEFORE_START=""
    if [[ -n "$OPENCODE_BEFORE_PID" ]]; then
        OPENCODE_BEFORE_EXE="$(proc_exe "$OPENCODE_BEFORE_PID")"
        OPENCODE_BEFORE_START="$(proc_starttime "$OPENCODE_BEFORE_PID")"
        OPENCODE_SERVICE_WAS_RUNNING=1
    fi
    OPENCODE_SERVICE_URL_BEFORE="$(opencode_background_service_url || true)"
    # Recorded for the report only. Never used to decide identity or freshness:
    # a responding URL does not identify which process serves.
    info "service endpoint (informational): ${OPENCODE_SERVICE_URL_BEFORE:-none}"

    local root; root="$(opencode_install_root)"
    local t3_children; t3_children="$(opencode_t3_owned_pids || true)"
    local t3_count=0
    [[ -n "$t3_children" ]] && t3_count="$(printf '%s\n' "$t3_children" | grep -c . || true)"

    printf '  %sOPENCODE BEFORE%s\n' "$C_BOLD" "$C_RESET"
    info "before: v${OPENCODE_BEFORE_VERSION:-?}"
    info "executable: $(readlink -f "$OPENCODE_BIN")"
    info "install root: ${root:-unknown}"
    if [[ $OPENCODE_SERVICE_WAS_RUNNING -eq 1 ]]; then
        info "background service PID: $OPENCODE_BEFORE_PID"
        info "service start time: ${OPENCODE_BEFORE_START:-?}"
        info "service exe: ${OPENCODE_BEFORE_EXE:-unknown}"
    else
        info "background service PID: none (service not running)"
    fi
    if [[ "$t3_count" -gt 0 ]]; then
        info "T3 owns $t3_count OpenCode process(es): $(printf '%s' "$t3_children" | tr '\n' ' ')"
    else
        info "T3 owns no OpenCode child; t3code.service will remain running"
    fi

    # ---- Discovery / classification -------------------------------------------
    section "OPENCODE processes"
    local -a targets=()
    while IFS=$'\t' read -r pid class summary; do
        [[ -n "$pid" ]] || continue
        printf '  %-8s %-20s %s\n' "$pid" "$class" "$summary"
        case "$class" in
            background-service) : ;;   # handled by the official command
            t3-owned) : ;;             # disappears when T3 is stopped
            *) targets+=("$pid") ;;
        esac
    done < <(opencode_processes)

    OPENCODE_TARGET_PIDS="${OPENCODE_BEFORE_PID} ${targets[*]}"

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  %sSTOP PLAN%s\n' "$C_BOLD" "$C_RESET"
        if [[ "$t3_count" -gt 0 ]]; then
            a_stop "t3code.service first (owns $t3_count OpenCode process(es)), then restore it"
        else
            a_stop "t3code.service: not needed (it owns no OpenCode child)"
        fi
        if [[ $OPENCODE_SERVICE_WAS_RUNNING -eq 1 ]]; then
            a_stop "OpenCode background service PID $OPENCODE_BEFORE_PID via 'opencode service stop'"
            a_stop "  (if that PID survives: SIGTERM, then SIGKILL that PID only)"
        else
            a_stop "OpenCode background service: not running, nothing to stop"
        fi
        [[ ${#targets[@]} -gt 0 ]] && a_stop "targeted OpenCode PIDs: ${targets[*]}"

        printf '  %sPRE-UPDATE GATES%s\n' "$C_BOLD" "$C_RESET"
        a_verify "old OpenCode PID $OPENCODE_BEFORE_PID is gone"
        a_verify "no pre-update OpenCode workload remains"

        printf '  %sUPDATE PLAN%s\n' "$C_BOLD" "$C_RESET"
        a_update "opencode upgrade"

        printf '  %sRESTORE PLAN%s\n' "$C_BOLD" "$C_RESET"
        if [[ $OPENCODE_SERVICE_WAS_RUNNING -eq 1 ]]; then
            a_restart "OpenCode background service (was running, PID $OPENCODE_BEFORE_PID)"
        else
            a_restart "OpenCode background service: not started (it was not running before)"
        fi
        if [[ "$t3_count" -gt 0 ]]; then
            a_restart "t3code.service (only if this run stopped it)"
        else
            a_restart "t3code.service: untouched (T3 owns no OpenCode child)"
        fi

        printf '  %sPOST-UPDATE GATES%s\n' "$C_BOLD" "$C_RESET"
        a_verify "fresh service PID differs from $OPENCODE_BEFORE_PID"
        a_verify "fresh process start time is newer than ${OPENCODE_BEFORE_START:-?}"
        a_verify "service executable is the currently installed OpenCode V2 build"
        a_verify "no stale-build OpenCode processes"

        record opencode PASS "dry-run"
        status_line opencode PASS "dry-run: would upgrade v${OPENCODE_BEFORE_VERSION:-?}"
        note_dry
        return 0
    fi

    # ---- Stop phase -----------------------------------------------------------
    # T3 is stopped ONLY when it actually owns an OpenCode child. With zero
    # owned children T3 is never touched and T3_STOPPED_BY_US stays 0.
    if [[ "$t3_count" -gt 0 ]]; then
        t3_stop_for "T3 owns $t3_count OpenCode process(es): $(printf '%s' "$t3_children" | tr '\n' ' ')" || true
        sleep 2
    else
        info "T3 owns no OpenCode child; t3code.service left running"
    fi

    if ! opencode_stop_service "$OPENCODE_BEFORE_PID" "$OPENCODE_BEFORE_START"; then
        record opencode FAIL "background service PID ${OPENCODE_BEFORE_PID:-?} could not be stopped; 'opencode upgrade' was not run"
        status_line opencode FAIL "service PID ${OPENCODE_BEFORE_PID:-?} would not stop; upgrade not attempted"
        t3_restore_if_stopped || true
        return 0
    fi

    if [[ ${#targets[@]} -gt 0 ]]; then
        terminate_pids "opencode" "${targets[@]}" || true
    fi

    # ---- Pre-update proof -----------------------------------------------------
    if ! opencode_pre_update_proof "$OPENCODE_BEFORE_PID" "$OPENCODE_BEFORE_START"; then
        record opencode FAIL "pre-update proof failed; 'opencode upgrade' was not run"
        status_line opencode FAIL "pre-update proof failed; upgrade not attempted"
        opencode_restore_service "$OPENCODE_SERVICE_WAS_RUNNING" || true
        t3_restore_if_stopped || true
        return 0
    fi

    # ---- Native update --------------------------------------------------------
    IN_MUTATION=1
    local rc=0
    info "Running: opencode upgrade"
    if ! "$OPENCODE_BIN" upgrade 9>&- 2>&1 | sed 's/^/    /'; then
        rc=1
    fi
    UPDATE_RC[opencode]=$rc
    if [[ $rc -ne 0 ]]; then
        record opencode FAIL "native 'opencode upgrade' failed (rc=$rc)"
        status_line opencode FAIL "native 'opencode upgrade' failed (rc=$rc)"
        opencode_restore_service "$OPENCODE_SERVICE_WAS_RUNNING" || true
        t3_restore_if_stopped || true
        IN_MUTATION=0
        return 0
    fi

    # ---- Restore --------------------------------------------------------------
    opencode_restore_service "$OPENCODE_SERVICE_WAS_RUNNING" || true

    # ---- Freshness + verification ---------------------------------------------
    # Run once and keep the verdict: the function returns the failure text on
    # stdout, so calling it twice would race the state it just measured.
    local fresh_detail="" fresh_rc=0
    fresh_detail="$(opencode_verify_fresh_service "$OPENCODE_BEFORE_PID" "$OPENCODE_BEFORE_START" "$OPENCODE_BEFORE_VERSION")" || fresh_rc=1

    t3_restore_if_stopped || true

    verify_opencode
    local st="${RESULT[opencode]:-FAIL}"
    if [[ $fresh_rc -ne 0 ]]; then
        record opencode FAIL "freshness proof failed: $fresh_detail"
        status_line opencode FAIL "freshness proof failed: $fresh_detail"
    elif [[ $st == "PASS" ]]; then
        record opencode PASS "upgraded: ${OPENCODE_BEFORE_VERSION} -> $(opencode_version); service PID ${OPENCODE_BEFORE_PID:-none} -> ${OPENCODE_AFTER_PID:-none}"
        status_line opencode PASS "upgraded: ${OPENCODE_BEFORE_VERSION} -> $(opencode_version); service PID ${OPENCODE_BEFORE_PID:-none} -> ${OPENCODE_AFTER_PID:-none}"
    else
        record opencode FAIL "${RESULT_DETAIL[opencode]}"
        status_line opencode FAIL "${RESULT_DETAIL[opencode]}"
    fi
    IN_MUTATION=0
    return 0
}

# =============================================================================
# HERMES update
# =============================================================================

do_hermes_update() {
    section "HERMES"
    if [[ $DRY_RUN -eq 0 && $FORCE_UPDATE -eq 0 ]]; then
        precheck_tool hermes
        if [[ "${PRECHECK[hermes]}" == CURRENT ]]; then
            record hermes PASS "already current: ${PRECHECK_DETAIL[hermes]}"
            status_line hermes PASS "already current: ${PRECHECK_DETAIL[hermes]}"
            return 0
        fi
    fi
    if [[ -z "$HERMES_BIN" ]]; then
        record hermes SKIPPED "hermes not installed on PATH"
        status_line hermes SKIPPED "not installed on PATH"
        return 0
    fi

    local before; before="$(hermes_version)"
    local before_sha; before_sha="$(hermes_git_sha)"
    info "before: ${before:-?} (git ${before_sha:-?})"

    section "HERMES services"
    local -a was_active=()
    local u
    for u in "${HERMES_UNITS[@]}"; do
        local sc; sc="$(unit_label "$u")"
        if [[ "$sc" == "absent" ]]; then info "${u}: not installed"
        elif unit_active "$u"; then
            was_active+=("$u")
            info "${u}: active (${sc} scope, MainPID $(unit_mainpid "$u"))"
        else
            info "${u}: inactive (${sc} scope)"
        fi
    done
    info "note: the pm2 web UI is informational only; it is never started by update."

    if [[ $DRY_RUN -eq 1 ]]; then
        a_update "hermes update --yes --no-backup"
        [[ ${#was_active[@]} -gt 0 ]] && a_restart "${was_active[*]} (restore: were active)"
        a_verify "hermes --version + unit active/enabled"
        record hermes PASS "dry-run"
        status_line hermes PASS "dry-run: would update ${before:-?}"
        note_dry
        return 0
    fi

    IN_MUTATION=1
    local rc=0
    info "Running: hermes update --yes --no-backup   (--no-backup: no custom state backup)"
    if ! "$HERMES_BIN" update --yes --no-backup 9>&- 2>&1 | sed 's/^/    /'; then
        rc=1
    fi
    UPDATE_RC[hermes]=$rc
    if [[ $rc -ne 0 ]]; then
        record hermes FAIL "native 'hermes update' failed (rc=$rc)"
        status_line hermes FAIL "native 'hermes update' failed (rc=$rc)"
        for u in "${was_active[@]}"; do
            unit_start "$u" || RESTORE_FAILURES+=("$u failed to start")
        done
        IN_MUTATION=0
        return 0
    fi

    # Restore only units that were active before this run.
    for u in "${was_active[@]}"; do
        unit_active "$u" || unit_start "$u" || RESTORE_FAILURES+=("$u failed to start")
    done

    verify_hermes
    local st="${RESULT[hermes]:-FAIL}"
    if [[ $st == "PASS" ]]; then
        record hermes PASS "updated: ${before} -> $(hermes_version)"
        status_line hermes PASS "updated: ${before} -> $(hermes_version)"
    else
        record hermes FAIL "${RESULT_DETAIL[hermes]}"
        status_line hermes FAIL "${RESULT_DETAIL[hermes]}"
    fi
    IN_MUTATION=0
    return 0
}

# =============================================================================
# T3 update
# =============================================================================

do_t3_update() {
    section "T3"
    if [[ -z "$T3_BIN" ]]; then
        record t3 SKIPPED "t3 not installed on PATH"
        status_line t3 SKIPPED "not installed on PATH"
        return 0
    fi

    section "T3 BEFORE state"
    local b_cli b_launcher b_state b_exec b_main b_serve b_http b_pending
    b_cli="$(t3_cli_version)";         b_launcher="$(t3_launcher_version)"
    b_state="$(t3_state_version)";      b_exec="$(t3_execstart_version)"
    b_main="$(t3_mainpid_version)";     b_serve="$(t3_serve_version)"
    b_http="$(t3_http_health)";         b_pending="$(t3_pending_update)"
    info "cli=$b_cli launcher=${b_launcher:-?} state=${b_state:-?} execstart=${b_exec:-?} mainpid=${b_main:-?} serve=${b_serve:-?} http=$b_http pending=$b_pending"

    local before_drift=0
    local v
    for v in "$b_launcher" "$b_state" "$b_exec" "$b_main" "$b_serve"; do
        [[ -z "$v" ]] && continue
        [[ "$v" == "$b_cli" ]] || before_drift=1
    done
    if [[ $before_drift -eq 1 ]]; then
        info "${C_YEL}PRE-EXISTING DRIFT detected${C_RESET} — the official updater is expected to reconcile all surfaces."
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        a_update "t3 update --channel nightly --yes"
        info "  (t3 update performs its own service reconciliation and restart; --yes is required non-interactively)"
        a_verify "cli == launcher == state == ExecStart == MainPID == t3 serve; unit active; HTTP 200; no pending update"
        a_clean "obsolete T3 runtimes (keep active + one previous), only if verification passed"
        record t3 PASS "dry-run"
        status_line t3 PASS "dry-run: would update from $b_cli"
        note_dry
        return 0
    fi

    IN_MUTATION=1
    local rc=0
    warn_t3_workloads
    info "Running: t3 update --channel nightly --yes"
    if ! "$T3_BIN" update --channel nightly --yes 9>&- 2>&1 | sed 's/^/    /'; then
        rc=1
    fi
    UPDATE_RC[t3]=$rc
    if [[ $rc -ne 0 ]]; then
        record t3 FAIL "native 't3 update' failed (rc=$rc)"
        status_line t3 FAIL "native 't3 update' failed (rc=$rc)"
        t3_active || systemctl --user start "$T3_UNIT" 2>/dev/null || \
            RESTORE_FAILURES+=("t3code.service failed to start after failed update")
        IN_MUTATION=0
        return 0
    fi

    # Bounded wait for service convergence
    local i code
    for (( i = 1; i <= 90; i++ )); do
        code="$(t3_http_health)"
        [[ "$code" == "200" ]] && break
        sleep 2
    done

    section "T3 AFTER state"
    local a_cli a_launcher a_state a_exec a_main a_serve a_http
    a_cli="$(t3_cli_version)";         a_launcher="$(t3_launcher_version)"
    a_state="$(t3_state_version)";      a_exec="$(t3_execstart_version)"
    a_main="$(t3_mainpid_version)";     a_serve="$(t3_serve_version)"
    a_http="$(t3_http_health)"
    info "cli=$a_cli launcher=${a_launcher:-?} state=${a_state:-?} execstart=${a_exec:-?} mainpid=${a_main:-?} serve=${a_serve:-?} http=$a_http"

    local problems=()
    unit_active "$T3_UNIT" || problems+=("t3code.service not active")
    [[ "$a_http" == "200" ]] || problems+=("HTTP $a_http")
    [[ "$(t3_pending_update)" == "none" ]] || problems+=("pending update: $(t3_pending_update)")
    local w
    for w in "$a_launcher" "$a_state" "$a_exec" "$a_main" "$a_serve"; do
        [[ -z "$w" ]] && continue
        [[ "$w" == "$a_cli" ]] || problems+=("surface $w != cli $a_cli")
    done

    if [[ ${#problems[@]} -gt 0 ]]; then
        local detail; detail="$(IFS='; '; echo "${problems[*]}")"
        record t3 FAIL "post-update verification failed: $detail"
        status_line t3 FAIL "post-update verification failed: $detail"
    else
        record t3 PASS "updated and fully aligned at $a_cli"
        status_line t3 PASS "updated and fully aligned at $a_cli"
    fi
    IN_MUTATION=0
    return 0
}

# =============================================================================
# Cleanup — only after a VERIFIED update; never deletes user data
# =============================================================================

# Is any running process executing this path?
path_in_use_by_process() { # path_in_use_by_process <dir>
    local dir="$1" pid exe
    for pid in /proc/[0-9]*; do
        pid="${pid#/proc/}"
        proc_exists "$pid" || continue
        exe="$(proc_exe "$pid")"
        [[ -n "$exe" && "$exe" == "$dir"/* ]] && return 0
    done
    return 1
}

cleanup_t3_runtimes() {
    local active
    active="$(t3_state_version)"
    if [[ -z "$active" ]]; then
        info "cleanup: active T3 version unknown; refusing to remove any runtime"
        return 0
    fi
    [[ -d "$T3_VERSIONS" ]] || return 0

    local all=()
    local d
    for d in "$T3_VERSIONS"/*/; do
        [[ -d "$d" ]] || continue
        all+=("$(basename "$d")")
    done

    # Every non-active runtime, newest first. The first entry is always the
    # rollback candidate and is never removed.
    local sorted
    sorted="$(printf '%s\n' "${all[@]}" | grep -Fvx "$active" | sort -Vr || true)"
    [[ -n "$sorted" ]] || { info "cleanup: nothing to prune"; return 0; }

    local first=1 ver dir
    while read -r ver; do
        [[ -n "$ver" ]] || continue
        dir="$T3_VERSIONS/$ver"

        # Retain exactly one immediately-previous runtime as the rollback target.
        if [[ $first -eq 1 ]]; then
            first=0
            info "cleanup: keeping $ver as the rollback candidate"
            continue
        fi

        # Never remove anything a running process is executing.
        if path_in_use_by_process "$dir"; then
            info "cleanup: KEEP $ver (a running process is executing it)"
            continue
        fi

        if [[ $DRY_RUN -eq 1 ]]; then
            a_clean "T3 runtime $ver (active=$active kept, newest other kept as rollback)"
        else
            info "cleanup: removing obsolete T3 runtime $ver"
            rm -rf -- "$dir"
        fi
    done <<< "$sorted"
    return 0
}

cleanup_codex_releases() {
    local cur; cur="$(codex_current_release)"
    [[ -n "$cur" ]] || return 0
    [[ -d "$CODEX_STANDALONE/releases" ]] || return 0

    # Never delete the current release, never delete a release a process is
    # executing, and always keep exactly one previous release for rollback.
    local -a others=()
    local d
    for d in "$CODEX_STANDALONE/releases"/*/; do
        [[ -d "$d" ]] || continue
        d="$(basename "$d")"
        [[ "$d" == "$cur" ]] && continue
        others+=("$d")
    done
    [[ ${#others[@]} -eq 0 ]] && return 0

    local sorted
    sorted="$(printf '%s\n' "${others[@]}" | sort -Vr)"

    local first=1 pid ver dir busy
    while read -r ver; do
        [[ -n "$ver" ]] || continue
        dir="$CODEX_STANDALONE/releases/$ver"
        [[ "$dir" == "$CODEX_STANDALONE/releases/$cur" ]] && continue
        if [[ $first -eq 1 ]]; then
            first=0
            info "cleanup: keeping previous Codex release $ver (rollback candidate)"
            continue
        fi
        busy=0
        for pid in /proc/[0-9]*; do
            pid="${pid#/proc/}"
            proc_exists "$pid" || continue
            [[ "$(proc_exe "$pid")" == "$dir"/* ]] && { busy=1; break; }
        done
        if [[ $busy -eq 1 ]]; then
            info "cleanup: KEEP $ver (a running process is executing it)"
            continue
        fi
        if [[ $DRY_RUN -eq 1 ]]; then
            a_clean "Codex release $ver (current=$cur)"
        else
            info "cleanup: removing unused Codex release $ver"
            rm -rf -- "$dir"
        fi
    done <<< "$sorted"
}

# =============================================================================
# Reporting
# =============================================================================

# =============================================================================
# Reporting
# =============================================================================

print_summary() {
    # In dry-run, RESULT already holds per-component plan outcomes. The
    # verification pass at the end of main() overwrites RESULT, so save the
    # plan results first and restore them for an honest dry-run summary.
    if [[ $DRY_RUN -eq 1 ]]; then
        local p
        declare -A PLAN_RESULT=() PLAN_DETAIL=()
        for p in "${!RESULT[@]}"; do
            PLAN_RESULT[$p]="${RESULT[$p]}"
            PLAN_DETAIL[$p]="${RESULT_DETAIL[$p]}"
        done
        RESULT=()
        RESULT_DETAIL=()
        for p in "${!PLAN_RESULT[@]}"; do
            RESULT[$p]="${PLAN_RESULT[$p]}"
            RESULT_DETAIL[$p]="${PLAN_DETAIL[$p]}"
        done
    fi

    section "SUMMARY"
    local c
    local -a order=(codex opencode hermes t3)
    for c in "${order[@]}"; do
        [[ -n "${RESULT[$c]:-}" ]] || continue
        status_line "$c" "${RESULT[$c]}" "${RESULT_DETAIL[$c]}"
    done

    section "RESTORE RESULT"
    if [[ ${#RESTORE_FAILURES[@]} -gt 0 ]]; then
        printf '  %sRESTORE INCOMPLETE%s\n' "$C_RED" "$C_RESET"
        local f; for f in "${RESTORE_FAILURES[@]}"; do printf '    - %s\n' "$f"; done
    else
        printf '  %sall services restored to their pre-run state%s\n' "$C_GRN" "$C_RESET"
    fi
    case "$RESTORE_RESULT" in
        FAILED*|INCOMPLETE*)
            printf '  restore outcome: %s%s%s\n' "$C_RED" "$RESTORE_RESULT" "$C_RESET" ;;
        *)
            printf '  restore outcome: %s\n' "$RESTORE_RESULT" ;;
    esac

    section "VERIFICATION RESULT"
    case "$VERIFY_RESULT" in
        PASS*)   printf '  %s%s%s\n' "$C_GRN" "$VERIFY_RESULT" "$C_RESET" ;;
        NOT\ RUN*) printf '  %s\n' "$VERIFY_RESULT" ;;
        *)       printf '  %s%s%s\n' "$C_RED" "$VERIFY_RESULT" "$C_RESET" ;;
    esac

    section "RESULT"
    local fail=0 skipped=0
    for c in "${order[@]}"; do
        case "${RESULT[$c]:-}" in
            FAIL)    fail=$((fail + 1)) ;;
            SKIPPED) skipped=$((skipped + 1)) ;;
        esac
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  %sDRY RUN COMPLETE%s — nothing was changed.\n' "$C_CYN" "$C_RESET"
        printf '  The plan above is what a real run would do.\n'
        return 0
    fi

    case "$UPDATE_RESULT" in
        FAILED*)  printf '  update outcome: %s%s%s\n' "$C_RED" "$UPDATE_RESULT" "$C_RESET" ;;
        SUCCESS*) printf '  update outcome: %s%s%s\n' "$C_GRN" "$UPDATE_RESULT" "$C_RESET" ;;
        *)        printf '  update outcome: %s\n' "$UPDATE_RESULT" ;;
    esac

    # Native-updater exit codes are surfaced separately from verification so a
    # caller can tell "the updater failed" from "the stack is unhealthy".
    local any_rc=0 c2
    for c2 in "${order[@]}"; do
        if [[ -n "${UPDATE_RC[$c2]:-}" ]]; then
            any_rc=1
            info "native updater rc: ${c2}=${UPDATE_RC[$c2]}"
        fi
    done
    [[ $any_rc -eq 0 ]] && info "all native updaters exited 0"

    # A component can verify as PASS while the update itself failed, or while
    # restoration or post-update verification failed. None of those is a
    # SUCCESS, whatever the per-component verdicts say.
    local blocked=0
    case "$UPDATE_RESULT"  in FAILED*) blocked=1 ;; esac
    case "$RESTORE_RESULT" in FAILED*|INCOMPLETE*) blocked=1 ;; esac
    case "$VERIFY_RESULT"  in FAILED*|NOT\ RUN*) blocked=1 ;; esac

    if [[ $fail -gt 0 ]]; then
        printf '  %sUPDATE RESULT: FAILED%s — %d component(s) failed\n' "$C_RED" "$C_RESET" "$fail"
        return 1
    fi
    if [[ $blocked -eq 1 ]]; then
        printf '  %sUPDATE RESULT: FAILED%s — components verified, but update/restore/verification reported a failure\n' \
            "$C_RED" "$C_RESET"
        return 1
    fi
    if [[ $skipped -gt 0 ]]; then
        printf '  %sUPDATE RESULT: COMPLETE WITH SKIPS%s — 0 failed, %d skipped\n' "$C_YEL" "$C_RESET" "$skipped"
        return 0
    fi
    # A run that could not put everything back is never a SUCCESS, even when
    # every component verified. Restoration is part of the contract.
    if [[ ${#RESTORE_FAILURES[@]} -gt 0 ]]; then
        printf '  %sUPDATE RESULT: FAILED%s — %d restore failure(s); see RESTORE RESULT\n' \
            "$C_RED" "$C_RESET" "${#RESTORE_FAILURES[@]}"
        return 1
    fi
    printf '  %sUPDATE RESULT: SUCCESS%s — all selected components completed and verified\n' "$C_GRN" "$C_RESET"
    return 0
}

# =============================================================================
# Argument parsing
# =============================================================================

parse_args() {
    local a
    for a in "$@"; do
        case "$a" in
            --codex)   DO_CODEX=1 ;;
            --opencode) DO_OPENCODE=1 ;;
            --hermes)  DO_HERMES=1 ;;
            --t3)      DO_T3=1 ;;
            --all)     DO_CODEX=1; DO_OPENCODE=1; DO_HERMES=1; DO_T3=1 ;;
            --verify)  DO_VERIFY=1 ;;
            --check)   DO_CHECK=1 ;;
            --force)   FORCE_UPDATE=1 ;;
            --dry-run) DRY_RUN=1 ;;
            -h|--help) usage; exit 0 ;;
            *)
                printf 'ERROR: unknown option: %s\n\n' "$a" >&2
                usage >&2
                exit 2
                ;;
        esac
    done

    if [[ $DO_VERIFY -eq 1 ]]; then
        if [[ $DO_CODEX -eq 1 || $DO_OPENCODE -eq 1 || $DO_HERMES -eq 1 || $DO_T3 -eq 1 || $FORCE_UPDATE -eq 1 || $DO_CHECK -eq 1 ]]; then
            printf 'ERROR: --verify cannot be combined with an update flag.\n' >&2
            printf '       Use "update --verify" alone, or "update --all".\n' >&2
            exit 2
        fi
        if [[ $DRY_RUN -eq 1 ]]; then
            printf 'ERROR: --verify is already read-only; --dry-run has no meaning with it.\n' >&2
            exit 2
        fi
        return 0
    fi

    if [[ $DO_CHECK -eq 1 ]]; then
        if [[ $DO_CODEX -eq 1 || $DO_OPENCODE -eq 1 || $DO_HERMES -eq 1 || $DO_T3 -eq 1 || $DO_VERIFY -eq 1 || $DRY_RUN -eq 1 || $FORCE_UPDATE -eq 1 ]]; then
            printf 'ERROR: --check must be used alone.\n' >&2; exit 2
        fi
        return 0
    fi

    if [[ $FORCE_UPDATE -eq 1 && $DO_CODEX -eq 0 && $DO_OPENCODE -eq 0 && $DO_HERMES -eq 0 && $DO_T3 -eq 0 ]]; then
        printf 'ERROR: --force requires an update selection.\n' >&2; exit 2
    fi

    if [[ $DO_CODEX -eq 0 && $DO_OPENCODE -eq 0 && $DO_HERMES -eq 0 && $DO_T3 -eq 0 ]]; then
        usage >&2
        exit 2
    fi
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    # Read-only invocations must not preserve a caller's mutation-lock fd.
    if [[ $DO_VERIFY -eq 1 || $DRY_RUN -eq 1 ]]; then
        exec 9>&-
    fi

    if [[ $DO_VERIFY -eq 1 ]]; then
        do_verify || exit 1
        exit 0
    fi

    if [[ $DO_CHECK -eq 1 ]]; then
        exec 9>&-
        acquire_observation_lock
        print_check
        exit 0
    fi

    if [[ $DRY_RUN -eq 0 && $FORCE_UPDATE -eq 0 ]]; then
        acquire_observation_lock
        precheck_selected
        local all_current=1 t
        for t in codex opencode hermes t3; do
            case "$t" in
                codex) [[ $DO_CODEX -eq 1 ]] || continue ;;
                opencode) [[ $DO_OPENCODE -eq 1 ]] || continue ;;
                hermes) [[ $DO_HERMES -eq 1 ]] || continue ;;
                t3) [[ $DO_T3 -eq 1 ]] || continue ;;
            esac
            [[ "${PRECHECK[$t]}" == CURRENT ]] || all_current=0
        done
        if [[ $all_current -eq 1 ]]; then
            for t in codex opencode hermes t3; do
                [[ -n "${PRECHECK[$t]:-}" ]] || continue
                record "$t" PASS "already current: ${PRECHECK_DETAIL[$t]}"
                status_line "$t" PASS "already current: ${PRECHECK_DETAIL[$t]}"
            done
            printf 'No native updater was needed; all selected tools are proven current.\n'
            exit 0
        fi
    fi

    UPDATE_ARGV="$*"
    if [[ $DRY_RUN -eq 1 ]]; then
        acquire_observation_lock
    else
        acquire_lock
    fi
    install_traps
    start_logging

    local run_id
    run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"

    printf '%s%s%s %s v%s%s\n' "$C_BOLD" "$SCRIPT_NAME" "$C_RESET" "v$SCRIPT_VERSION" "" "$C_RESET"
    printf '%srun %s%s\n' "$C_DIM" "$run_id" "$C_RESET"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s*** DRY RUN — no changes will be made ***%s\n' "$C_YEL" "$C_RESET"
    fi

    local selected=()
    [[ $DO_CODEX -eq 1    ]] && selected+=("codex")
    [[ $DO_OPENCODE -eq 1 ]] && selected+=("opencode")
    [[ $DO_HERMES -eq 1   ]] && selected+=("hermes")
    [[ $DO_T3 -eq 1       ]] && selected+=("t3")
    info "selected: ${selected[*]}"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "lock: observational only; snapshot may become stale if an updater starts concurrently"
    else
        info "lock: $GLOBAL_LOCK (held exclusively)"
    fi

    # Order is fixed and independent of argv: T3 runs LAST, because the Codex
    # and OpenCode workflows may need to stop T3 to release provider children.
    # Each component records its own result; a failure never skips the next.
    [[ $DO_CODEX -eq 1    ]] && do_codex_update    || true
    [[ $DO_OPENCODE -eq 1 ]] && do_opencode_update || true
    [[ $DO_HERMES -eq 1   ]] && do_hermes_update   || true
    [[ $DO_T3 -eq 1       ]] && do_t3_update       || true

    # Cleanup runs only after a component verified a successful update, and
    # only against a component that was actually selected in this run.
    section "CLEANUP"
    if [[ $DRY_RUN -eq 1 ]]; then
        [[ $DO_T3 -eq 1 ]] && a_clean "obsolete T3 runtimes (keep active + one previous)"
        [[ $DO_CODEX -eq 1 ]] && a_clean "unused Codex releases (keep current + one previous)"
        info "no files were removed"
    elif [[ $DO_T3 -eq 1 && "${RESULT[t3]:-}" == "PASS" && "${UPDATE_RC[t3]:-}" == "0" ]]; then
        cleanup_t3_runtimes
    else
        info "skipped T3 runtime cleanup: T3 was not selected, or its update did not verify"
    fi
    if [[ $DRY_RUN -eq 0 ]]; then
        if [[ $DO_CODEX -eq 1 && "${RESULT[codex]:-}" == "PASS" && "${UPDATE_RC[codex]:-}" == "0" ]]; then
            cleanup_codex_releases
        else
            info "skipped Codex release cleanup: Codex was not selected, or its update did not verify"
        fi
    fi

    section "FULL STACK VERIFICATION"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "skipped: --dry-run performs no verification that could touch state"
        info "run 'update --verify' for a read-only health report"
    else
        verify_codex
        verify_opencode
        verify_hermes
        verify_t3
    fi

    prune_update_logs

    print_summary || exit 1
    exit 0
}

main "$@"
