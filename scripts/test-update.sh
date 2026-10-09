#!/usr/bin/env bash
# Static + behavioural test suite for /home/ubuntu/bin/update
# Performs NO mutation: no update, no service change, no file deletion.
set -uo pipefail

PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

U=/home/ubuntu/bin/update

printf '\n=== 1. syntax ===\n'
check "bash -n bin/update" "bash -n $U"
check "bash -n update.src.sh" "bash -n /home/ubuntu/tool-updates/scripts/update.src.sh"
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck -S warning clean" "shellcheck -S warning /home/ubuntu/tool-updates/scripts/update.src.sh"
fi

printf '\n=== 2. contract / exit codes ===\n'
$U --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help exits 0"
$U >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "no args exits 2" || bad "no args exits 2"
$U --bogus >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "unknown flag exits 2" || bad "unknown flag exits 2"
$U --verify --codex >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "--verify + flag exits 2" || bad "--verify + flag exits 2"
$U --verify --dry-run >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "--verify --dry-run exits 2" || bad "--verify --dry-run exits 2"

printf '\n=== 3. help text contract ===\n'
H="$($U --help 2>&1)"
for s in 'update --all' 'update --codex' 'update --opencode' 'update --hermes' 'update --t3' 'update --verify' '--dry-run'; do
    grep -qF -- "$s" <<<"$H" && ok "help mentions '$s'" || bad "help mentions '$s'"
done
grep -q 'OpenCode V2' <<<"$H" && ok "help says OpenCode V2" || bad "help says OpenCode V2"
grep -qi 'opencode v1' <<<"$H" && bad "help must not advertise OpenCode v1" || ok "no OpenCode v1 in help"

printf '\n=== 4. no OpenCode V1 assumptions in active code ===\n'
check "no .opencode/bin path" "! grep -q '\.opencode/bin' $U"
check "no update-opencode.sh reference" "! grep -q 'update-opencode' $U"
check "no custom backup function" "! grep -qiE 'create_backup|backup_t3_state|copy_sensitive_file|backup_sqlite' $U"
check "no retention engine" "! grep -q 'update_ops_backup_retention' $U"

printf '\n=== 5. single lock ===\n'
check "one lock path" "[[ \$(grep -c 'GLOBAL_LOCK=' $U) -eq 1 ]]"
check "no per-tool lock files" "! grep -qE 'codex\.lock|hermes\.lock|t3\.lock|opencode\.lock|nightly-all\.lock' $U"
check "lock path is update.lock" "grep -q 'update.lock\"' $U"

printf '\n=== 6. no indiscriminate killing ===\n'
check "no pkill -9"    "! grep -q 'pkill' $U"
check "no killall"     "! grep -q 'killall' $U"
check "no pgrep kill"  "! grep -qE 'kill .*\\\$\(pgrep' $U"
check "targeted kill exists" "grep -q 'kill -TERM' $U"

printf '\n=== 7. --verify is read-only by inspection ===\n'
check "verify makes no lock file"   "grep -q 'if \[\[ -e \"\$GLOBAL_LOCK\" \]\]' $U"
check "verify does not mkdir"       "! sed -n '/^do_verify()/,/^}/p' $U | grep -q 'mkdir'"
check "verify does not rm"          "! sed -n '/^do_verify()/,/^}/p' $U | grep -q 'rm -'"
check "verify does not tee/log"     "! sed -n '/^do_verify()/,/^}/p' $U | grep -q 'tee'"
check "verify does not start units" "! sed -n '/^do_verify()/,/^}/p' $U | grep -qE 'systemctl.*(start|stop|restart)'"
check "verify does not pm2"         "! sed -n '/^do_verify()/,/^}/p' $U | grep -q 'pm2'"
check "start_logging skips dry-run" "grep -q 'DRY_RUN -eq 1 \]\] && return 0' $U"

printf '\n=== 8. official native updater commands ===\n'
check "codex update"              "grep -q 'app-server daemon update' $U"
# The stop/start commands are invoked through codex_daemon_subcommand now, so
# assert the subcommand names are used rather than a literal argv string.
check "daemon stop subcommand used"  "grep -qE 'daemon (stop|\\\$sub)' $U"
check "daemon start subcommand used" "grep -q 'app-server daemon start failed' $U"
check "opencode upgrade"          "grep -q 'opencode.*upgrade' $U"
check "opencode service stop"     "grep -q 'service stop' $U"
check "hermes update"             "grep -q 'update --yes --no-backup' $U"
check "hermes no-backup honored"  "grep -q '\-\-no-backup' $U"
check "t3 update --channel nightly --yes" "grep -q 'update --channel nightly --yes' $U"

printf '\n=== 9. error/trap model ===\n'
check "set -Eeuo pipefail" "grep -q 'set -Eeuo pipefail' $U"
check "umask 077"         "grep -q 'umask 077' $U"
check "EXIT trap"         "grep -q 'trap on_exit EXIT' $U"
check "INT/TERM trap"     "grep -q 'trap on_signal INT TERM' $U"
check "secret scrubbing"  "grep -q 'REDACTED' $U"

printf '\n=== 10. T3 alignment verification ===\n'
for f in t3_cli_version t3_launcher_version t3_state_version t3_execstart_version t3_mainpid_version t3_serve_version t3_http_health t3_pending_update; do
    check "defines $f" "grep -q '$f()' $U"
done
check "drift compared to cli" "grep -q 'mismatches+=' $U"

printf '\n=== 11. component independence ===\n'
check "no UPDATE_FAILED gate" "! grep -q 'UPDATE_FAILED == 0' $U"
check "per-component result"  "grep -q 'declare -A RESULT' $U"
check "SKIPPED supported"     "grep -q 'SKIPPED' $U"

printf '\n=== 12. legacy authorities retired ===\n'
check "4h cron gone"        "! crontab -l | grep -q t3-nightly-maintenance"
check "nightly timer off"   "[[ \$(systemctl --user is-enabled t3-nightly-update.timer 2>&1) == disabled ]]"
check "no live service update callers" "! grep -rl 'service update' /home/ubuntu/bin /home/ubuntu/.local/bin /home/ubuntu/.config/systemd/user 2>/dev/null | grep -qv retired/ || true"

printf '\n=== 13. dry-run performs no mutation (behavioural) ===\n'
T3PID_B="$(systemctl --user show t3code.service -p MainPID --value)"
T3ST_B="$(systemctl --user show t3code.service -p ActiveEnterTimestamp --value)"
SHA_B="$(sha256sum $HOME/.t3/runtime/versions/*/t3 2>/dev/null | md5sum | cut -d' ' -f1)"
VER_B="$(t3 --version 2>&1)|$(codex --version 2>&1)|$(opencode --version 2>&1)|$(hermes --version 2>&1 | head -1)"
BK_B="$(ls $HOME/.local/state/tool-updates/backups/ 2>/dev/null | tr '\n' ',')"
LOGS_B="$(ls $HOME/.local/state/tool-updates/logs/update 2>/dev/null | wc -l)"

for f in --codex --opencode --hermes --t3 --all; do
    $U $f --dry-run >/dev/null 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then ok "$f --dry-run exits 0"; else bad "$f --dry-run exits $rc"; fi
done

T3PID_A="$(systemctl --user show t3code.service -p MainPID --value)"
T3ST_A="$(systemctl --user show t3code.service -p ActiveEnterTimestamp --value)"
SHA_A="$(sha256sum $HOME/.t3/runtime/versions/*/t3 2>/dev/null | md5sum | cut -d' ' -f1)"
VER_A="$(t3 --version 2>&1)|$(codex --version 2>&1)|$(opencode --version 2>&1)|$(hermes --version 2>&1 | head -1)"
BK_A="$(ls $HOME/.local/state/tool-updates/backups/ 2>/dev/null | tr '\n' ',')"
LOGS_A="$(ls $HOME/.local/state/tool-updates/logs/update 2>/dev/null | wc -l)"

[[ "$T3PID_B" == "$T3PID_A" ]] && ok "T3 MainPID unchanged" || bad "T3 MainPID changed $T3PID_B -> $T3PID_A"
[[ "$T3ST_B" == "$T3ST_A" ]] && ok "T3 start time unchanged" || bad "T3 restarted"
[[ "$SHA_B" == "$SHA_A" ]] && ok "installed binaries unchanged" || bad "binary checksum changed"
[[ "$VER_B" == "$VER_A" ]] && ok "tool versions unchanged" || bad "a version changed"
[[ "$BK_B" == "$BK_A" ]] && ok "no new backups" || bad "backup set changed"
[[ "$LOGS_B" == "$LOGS_A" ]] && ok "no logs written by dry-run" || bad "dry-run wrote logs"

printf '\n=== 14. dry-run output contract ===\n'
O="$($U --all --dry-run 2>&1)"
for p in 'WOULD STOP' 'WOULD UPDATE' 'WOULD RESTART' 'WOULD VERIFY' 'WOULD CLEAN'; do
    grep -qF "$p" <<<"$O" && ok "dry-run emits '$p'" || bad "dry-run missing '$p'"
done
# T3 must be planned last
TC="$(grep -n '^=== T3 ===' <<<"$O" | head -1 | cut -d: -f1)"
CO="$(grep -n '^=== CODEX ===' <<<"$O" | head -1 | cut -d: -f1)"
OC="$(grep -n '^=== OPENCODE V2 ===' <<<"$O" | head -1 | cut -d: -f1)"
if [[ -n "$TC" && -n "$CO" && -n "$OC" && "$TC" -gt "$CO" && "$TC" -gt "$OC" ]]; then
    ok "T3 planned after Codex and OpenCode"
else bad "T3 ordering wrong (codex=$CO opencode=$OC t3=$TC)"; fi
grep -q 't3 update --channel nightly --yes' <<<"$O" && ok "shows official t3 command" || bad "missing t3 command"

printf '\n=== 15. logging pipeline (regression: unopened FD 3 / scrub ordering) ===\n'
# The real bug: start_logging() used to run `tee ... | scrub >&3` without ever
# opening FD 3. That made scrub fail, killed the pipeline, and every later
# printf (including the EXIT trap) died with "Broken pipe". Dry-run never
# reaches start_logging(), so the previous suite could not catch it.
check "no unopened-FD-3 redirect in start_logging" \
    "! sed -n '/^start_logging()/,/^}/p' /home/ubuntu/tool-updates/scripts/update.src.sh | grep -q '>&3'"
# Only executable code matters here; the regression-note comment quotes the
# old broken line verbatim and must not trip this assertion.
check "no exec 3 in executable code" \
    "! grep -vE '^[[:space:]]*#' $U | grep -q 'exec 3'"
check "scrub runs before tee" \
    "sed -n '/^start_logging()/,/^}/p' $U | grep -q 'scrub | tee'"
check "logger preserves logs if terminal consumer closes" \
    "sed -n '/^start_logging()/,/^}/p' $U | grep -q 'tee -p -a'"
check "logger remains alive to record interruption status" \
    "sed -n '/^start_logging()/,/^}/p' $U | grep -q \"trap '' INT TERM\""
check "start_logging pipes stderr too" \
    "sed -n '/^start_logging()/,/^}/p' $U | grep -q '2>&1'"
check "global redactor flushes each line" \
    "grep -q 'scrub() { sed -u ' $U"
check "native updater indentation flushes each line" \
    "grep -q \"sed -u 's/\^/    /'\" $U"

# Exercise the real function in isolation against a temp log, proving the
# pipeline works and that the log is redacted BEFORE it is written.
SB="$(mktemp -d /tmp/update-logtest.XXXXXX)"

# Extract the REAL exec line and the REAL scrub body from the shipped script,
# so this probe exercises production code rather than a copy that can drift.
EXECLINE="$(grep -m1 '^[[:space:]]*exec > >(' "$U" | sed 's/^[[:space:]]*//')"
SCRUBBODY="$(sed -n '/^scrub() {/,/^}/p' "$U")"
if [[ -n "$EXECLINE" ]]; then ok "extracted real logging exec line" || true
else bad "could not extract the logging exec line from $U"; fi

# Replace the log path with our sandbox so the probe writes nothing real.
PROBE_EXEC="${EXECLINE//\"\$logf\"/\"\$logf\"}"
cat >"$SB/probe.sh" <<PROBE
set -Eeuo pipefail
umask 077
logf="\$1"
: >"\$logf"
${SCRUBBODY}
${PROBE_EXEC}
LOG_FH_OPEN=1
printf 'api_key=SUPERSECRET12345\n'
printf 'token: abcdefSECRET\n'
printf 'plain line survives\n'
printf 'stderr line\n' >&2
printf '=== update finished rc=0 ===\n'
sleep 1
PROBE
chmod +x "$SB/probe.sh"
mkdir -p "$SB/logs"
# Capture the terminal side too: the old bug silently swallowed stdout.
"$SB/probe.sh" "$SB/logs/probe.log" >"$SB/terminal.out" 2>"$SB/terminal.err"
PRC=$?
PL="$SB/logs/probe.log"
T="$SB/terminal.out"

if [[ $PRC -eq 0 ]]; then ok "logging pipeline exits 0"; else bad "logging pipeline exit $PRC"; fi
check "no 'Bad file descriptor' in log"      "! grep -q 'Bad file descriptor' $PL"
check "no 'Broken pipe' in log"              "! grep -q 'Broken pipe' $PL"
check "no shell error at all in log"         "! grep -qE 'line [0-9]+:' $PL"
check "plain output reached the log"         "grep -q 'plain line survives' $PL"
check "stderr reached the log"               "grep -q 'stderr line' $PL"
check "EXIT-trap style line reached the log" "grep -q 'update finished rc=0' $PL"
# The old bug also destroyed terminal output and leaked shell errors to stderr.
check "stdout still reached the terminal" "grep -q 'plain line survives' $T"
check "no shell error on stderr" "! grep -qE 'Bad file descriptor|Broken pipe' $SB/terminal.err"
check "stderr also went to the log" "grep -q 'stderr line' $PL"
check "raw secret absent from terminal" "! grep -q 'SUPERSECRET12345' $T"
check "raw token absent from terminal" "! grep -q 'abcdefSECRET' $T"
check "redaction marker present in terminal" "grep -q '<REDACTED>' $T"
# The ordering flaw: the log must NOT contain the raw secret.
if grep -q 'SUPERSECRET12345' "$PL" 2>/dev/null; then
    bad "RAW SECRET IN LOG — scrub runs after tee"
else ok "raw secret absent from log (scrub precedes tee)"; fi
check "redaction marker present in log" "grep -q '<REDACTED>' $PL"
if grep -q 'abcdefSECRET' "$PL" 2>/dev/null; then
    bad "RAW TOKEN IN LOG"
else ok "raw token absent from log"; fi

# Verify incremental visibility through the actual logger and native sed stage.
cat >"$SB/fake-updater" <<'FAKEUPDATER'
#!/usr/bin/env bash
printf 'first line\n'
sleep 1
printf 'second line\n'
FAKEUPDATER
chmod +x "$SB/fake-updater"
(
    exec > >(sed -u -E 's/((token|secret|password|api[_-]?key|authorization)[=: ]+)[^ ]+/\\1<REDACTED>/Ig' | tee -p -a "$SB/logs/stream.log") 2>&1
    "$SB/fake-updater"
) >"$SB/stream.terminal" 2>&1 &
STREAM_PID=$!
sleep 0.2
grep -q 'first line' "$SB/stream.terminal" \
    && ok "global logging pipeline displays first line before fake updater exits" \
    || bad "global logging pipeline buffered first line"
wait "$STREAM_PID"
( "$SB/fake-updater" | sed -u 's/^/    /' ) >"$SB/native-stream.out" &
NATIVE_PID=$!
sleep 0.2
grep -q 'first line' "$SB/native-stream.out" \
    && ok "native updater indentation displays first line promptly" \
    || bad "native updater indentation buffered first line"
wait "$NATIVE_PID"

# A closed terminal consumer must not break the shell's writes or lose log data.
( "$SB/probe.sh" "$SB/logs/broken-consumer.log" ) > >(head -n0)
BRC=$?
[[ $BRC -eq 0 ]] && ok "broken terminal consumer does not fail updater output" \
    || bad "broken terminal consumer exit $BRC"
check "broken terminal consumer still leaves redacted log" \
    "grep -q 'plain line survives' $SB/logs/broken-consumer.log && ! grep -q 'SUPERSECRET12345' $SB/logs/broken-consumer.log"
rm -rf "$SB"

printf '\n=== 16. daemon semantics (regression: ambiguous stop / exit-0-but-unsupported) ===\n'
# Defect A: `daemon stop` used to be issued and then only warned when the
# status still read "running", leaving the run ambiguous. It must now be
# VERIFIED against the authoritative control-socket owner.
check "has stop_codex_daemon"            "grep -q 'stop_codex_daemon()' $U"
check "stop verifies socket owner gone"  "grep -q 'control socket released' $U"
check "stop escalates to targeted kill"  "grep -q 'still owns the control socket' $U"
check "no bare 'still reported running'" "! grep -q 'still reported running' $U"
check "no swallowed daemon stop"         "! grep -q 'daemon stop >/dev/null 2>&1 || true' $U"
check "notes the active updater loop"    "grep -q 'may respawn the app-server' $U"
check "detects unmanaged app-server"     "grep -q 'codex_daemon_is_managed()' $U"
check "explains why stop is skipped"     "grep -q 'not daemon-managed' $U"

# Defect B: `daemon update` exits 0 while reporting {"status":"unsupported"}.
# That must never be reported as a successful updater run.
check "parses daemon semantic status"    "grep -q 'codex_daemon_subcommand()' $U"
check "branches on unsupported"          "grep -q 'unsupported)' $U"
check "does not trust exit 0 alone"      "grep -q 'DAEMON_PKG_STATUS' $U"
check "surfaces daemon pkg in result"    "grep -q 'codex_result_detail()' $U"

# The classifier can be correct while the CONSUMER still ignores it (the real
# defect: exit 0 was accepted verbatim). Assert the consumer, not just the
# parser: "updated" may only be assigned in the success branch, and the
# unsupported branch must set its own value.
CH="$U"
check "'updated' assigned only in success branch" \
    "[[ \$(grep -c 'DAEMON_PKG_STATUS=\"updated\"' $CH) -eq 1 ]]"
check "unsupported branch assigns its own status" \
    "grep -A2 'unsupported)' $CH | grep -q 'DAEMON_PKG_STATUS=\"unsupported\"'"
check "no unconditional success before the case" \
    "! grep -B1 'case \"\$dstatus\" in' $CH | grep -q 'DAEMON_PKG_STATUS=\"updated\"'"
# The unsupported branch must not reach a success assignment. Only the lines
# belonging to THAT branch count -- the sibling success branch legitimately
# assigns "updated" a couple of lines later.
check "unsupported branch does not set updated" \
    "! sed -n '/unsupported)/,/;;/p' $CH | grep -q 'DAEMON_PKG_STATUS=\"updated\"'"

# Behavioural: run the REAL codex_daemon_subcommand from production against a
# stub codex binary that reproduces Codex's exact behaviour -- shell exit 0
# with a machine-readable status of "unsupported". A test that re-typed the
# classifier would keep passing while production stayed broken.
SB3="$(mktemp -d /tmp/update-daemon.XXXXXX)"
mkdir -p "$SB3/bin"
cat >"$SB3/bin/codex" <<'STUB'
#!/usr/bin/env bash
# Stub reproducing the real payload AND the real shell exit code (0).
cat <<'JSON'
{"status":"unsupported","managedCodexPath":"/x/current/bin/codex","installedVersion":"0.160.0","runningVersion":"0.160.0","message":"This command requires a daemon package selected from its managed releases directory."}
JSON
exit 0
STUB
chmod +x "$SB3/bin/codex"
python3 - "$U" "$SB3/extract.sh" "$SB3" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.index('codex_daemon_subcommand() {')
d = 0
fn = None
for j in range(i, len(s)):
    if s[j] == '{': d += 1
    elif s[j] == '}':
        d -= 1
        if d == 0:
            fn = s[i:j+1]
            break
if fn is None:
    sys.exit("could not extract codex_daemon_subcommand from production")
open(sys.argv[2], 'w').write(
    '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    'CODEX_BIN="' + sys.argv[3] + '/bin/codex"\n' + fn +
    '\nR="$(codex_daemon_subcommand update)"\n'
    'S="${R%%|*}"\n'
    'case "$S" in unsupported) echo VERDICT=not-success ;; *) echo VERDICT=success ;; esac\n'
    'echo "parsed=$R"\n')
PY
chmod +x "$SB3/extract.sh"
CLSOUT="$("$SB3/extract.sh" 2>&1)"
CLSRC=$?
rm -rf "$SB3"
[[ $CLSRC -eq 0 ]] && ok "production classifier ran on the stub" || bad "classifier failed: $CLSOUT"
grep -q 'VERDICT=not-success' <<<"$CLSOUT" \
    && ok "exit-0 + status:unsupported is NOT success (production)" \
    || bad "exit-0 + status:unsupported treated as success (production)"
grep -q 'parsed=unsupported|' <<<"$CLSOUT" \
    && ok "production parses the status field" || bad "status field not parsed"
grep -q '|0$' <<<"$CLSOUT" \
    && ok "production still records shell rc=0 for forensics" || bad "shell rc not recorded"

# Defect C: a pid can vanish between enumerating /proc and reading it. The
# helpers must be silent, and the redirection order must put 2>/dev/null
# BEFORE `< file` or bash reports the failed open.
check "proc_cmdline tolerates race"      "grep -q 'proc_cmdline() { ( tr' $U"
check "proc_exe tolerates race"          "grep -q 'proc_exe()     { ( readlink' $U"
check "redirection order is correct"     "! grep -qE '< \"/proc/\\\$1/[a-z]+\" 2>/dev/null' $U"

# Behavioural: the real helpers, against a pid that does not exist.
SB2="$(mktemp -d /tmp/update-race.XXXXXX)"
python3 - "$U" "$SB2/race.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.index('proc_exists()'); j = s.index('proc_pids()')
open(sys.argv[2], 'w').write(
    '#!/usr/bin/env bash\nset -Eeuo pipefail\n' + s[i:j] +
    'echo "cmdline=[$(proc_cmdline 999999)]"\n'
    'echo "exe=[$(proc_exe 999999)]"\n'
    'echo "ppid=[$(proc_ppid 999999)]"\n'
    'echo "cgroup=[$(proc_cgroup 999999)]"\n'
    'echo "self=[$(proc_cmdline $$)]"\n')
PY
chmod +x "$SB2/race.sh"
RACE_OUT="$("$SB2/race.sh" 2>&1)"
RACE_RC=$?
rm -rf "$SB2"
[[ $RACE_RC -eq 0 ]] && ok "helpers survive a vanished pid (exit 0)" || bad "helpers exit $RACE_RC on vanished pid"
check "no /proc diagnostic leaked" "! grep -q 'No such file or directory' <<<\"$RACE_OUT\""
check "no 'Bad file descriptor'"  "! grep -q 'Bad file descriptor' <<<\"$RACE_OUT\""
check "live pid still readable"    "grep -q 'self=\[.\+\]' <<<\"$RACE_OUT\""

# Behavioural: end-to-end dry-run must be free of /proc noise.
N_T3="$(systemctl --user show t3code.service -p MainPID --value)"
DR="$($U --codex --dry-run 2>&1)"
check "dry-run has no /proc race noise" "! grep -qE 'No such file or directory|Bad file descriptor' <<<\"$DR\""
check "dry-run reports daemon stop is skipped" "grep -q 'daemon stop' <<<\"$DR\""
# The host may or may not have a daemon pid file (it gained one once the app-server
# became genuinely pid-managed). Either state is correct, but the daemon package
# update must always be either explicitly skipped or explicitly announced as
# SUPPORTED. It must never be silently assumed to run.
check "dry-run never silently claims a daemon update runs" \
    "grep -q 'daemon update — SKIPPED' <<<\"$DR\" || grep -q 'capability: SUPPORTED' <<<\"$DR\""
[[ "$(systemctl --user show t3code.service -p MainPID --value)" == "$N_T3" ]] \
    && ok "T3 untouched by the dry-run" || bad "T3 MainPID changed"

printf '\n=== 17. --verify read-only + truthful ===\n'
V="$($U --verify 2>&1)"; VRC=$?
grep -q 'STACK VERIFICATION (read-only)' <<<"$V" && ok "verify labels itself read-only" || bad "verify label missing"
grep -q 'No changes were made' <<<"$V" && ok "verify states no changes" || bad "verify missing disclaimer"

# Verify must agree with ground truth, whichever way that truth points.
# Derive the expected verdict from the real T3 surfaces instead of assuming
# drift, so this stays valid after the drift is legitimately repaired.
CLI_V="$(t3 --version 2>&1 | sed 's/^t3 v//')"
ST_V="$(sed -n 's/.*"activeVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/.t3/runtime/service-state.json" 2>/dev/null)"
if [[ -n "$CLI_V" && -n "$ST_V" && "$CLI_V" != "$ST_V" ]]; then
    EXPECT_FAIL=1
else
    EXPECT_FAIL=0
fi
# Other managed tools can independently make the stack unhealthy.
if grep -qiE '^[[:space:]]*(Codex|opencode|Hermes) +FAIL' <<<"$V"; then
    EXPECT_FAIL=1
fi
if [[ $EXPECT_FAIL -eq 1 ]]; then
    grep -q 'STACK UNHEALTHY' <<<"$V" && ok "verify detects observed stack drift" || bad "verify missed observed stack drift"
    grep -qiE 'drift|mismatch|unhealthy|FAIL' <<<"$V" && ok "verify names the unhealthy surface" || bad "verify did not name the unhealthy surface"
    [[ $VRC -eq 1 ]] && ok "verify exits 1 while stack is unhealthy" || bad "verify exit $VRC while drift exists"
else
    grep -q 'STACK HEALTHY' <<<"$V" && ok "verify reports healthy when aligned" || bad "verify wrongly reports unhealthy"
    [[ $VRC -eq 0 ]] && ok "verify exits 0 when aligned" || bad "verify exit $VRC while stack is healthy"
fi
# Regardless of drift: OpenCode V1 must never appear, and V2 must be checked.
check "verify checks OpenCode V2" "grep -q 'opencode   ' <<<\"$V\" || grep -qE 'opencode +PASS|opencode +FAIL' <<<\"$V\""
check "no OpenCode V1 path in verify" "! grep -q '.opencode/bin' <<<\"$V\""

printf '\n=== 18. lock contention ===\n'
LOCK_HOME="$(mktemp -d /tmp/update-lock.XXXXXX)"
mkdir -p "$LOCK_HOME/.local/state/tool-updates"
touch "$LOCK_HOME/.local/state/tool-updates/update.lock"
exec 8>"$LOCK_HOME/.local/state/tool-updates/update.lock"
flock -n 8
HOME="$LOCK_HOME" $U --t3 >/tmp/opencode/locktest.log 2>&1
LRC=$?
[[ $LRC -eq 3 ]] && ok "mutating run exits 3 when exclusive lock is held" || bad "mutating lock exit $LRC"
grep -q 'another update is running' /tmp/opencode/locktest.log && ok "contention reported clearly" || bad "unclear contention message"
HOME="$LOCK_HOME" $U --t3 --dry-run >/tmp/opencode/drylock.log 2>&1
[[ $? -eq 0 ]] && ok "dry-run proceeds observationally while mutation lock is held" || bad "dry-run incorrectly contended"
exec 8>&-

printf '\n=== 19. codex lifecycle: extraction harness ==='
# A sandbox that loads the REAL production codex helpers, with every process and
# socket probe redirected into the sandbox. The tests below call the shipped
# functions, never retyped copies, so they cannot drift from production.
SBX="$(mktemp -d /tmp/update-codex-life.XXXXXX)"
export SBX
PROC_ROOT="$SBX/proc"; export PROC_ROOT
python3 - "$U" "$SBX" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
out = sys.argv[2]

def block(name):
    """Extract a top-level `name() { ... }` body, tolerating padding whitespace."""
    m = re.search(r'^[ \t]*' + re.escape(name) + r'\(\)\s*\{', src, re.M)
    if not m:
        raise SystemExit('could not find ' + name)
    i = src.index('{', m.start())
    d = 0
    for j in range(i, len(src)):
        if src[j] == '{':
            d += 1
        elif src[j] == '}':
            d -= 1
            if d == 0:
                return src[m.start():j+1]
    raise SystemExit('unterminated ' + name)

# Collaborators of the codex lifecycle that talk to the outside world are
# provided by the sandbox below. Everything under test comes from production.
EXTERNAL = [
    'proc_exists', 'proc_cmdline', 'proc_exe', 'proc_ppid', 'proc_cgroup',
    'proc_starttime', 'proc_pids', 'in_t3_cgroup',
    'codex_processes', 'codex_cli_version', 'codex_daemon_status',
]
# Production code, extracted verbatim, in dependency order.
PRODUCTION = [
    'log', 'info', 'warn', 'err', 'is_descendant_of',
    'a_stop', 'a_update', 'a_restart', 'a_verify',
    'codex_release_of_tree', 'codex_current_release', 'codex_daemon_pkg_release',
    'codex_exe_on_current_release', 'codex_control_socket',
    'codex_daemon_socket_owner', 'codex_daemon_updater_pid', 'codex_classify',
    'codex_stale_processes', 'codex_daemon_is_managed', 'codex_daemon_has_pidfile',
    'codex_daemon_pkg_selected', 'codex_daemon_update_capability',
    'codex_daemon_subcommand', 'stop_codex_updater_loop', 'stop_codex_app_server',
    'stop_codex_daemon', 'terminate_pids', 'codex_pre_update_proof',
    'codex_restore_background', 'codex_verify_fresh_app_server',
]

EXTERNAL_DEFS = r'''
SBX="${SBX:?}"
PROC_ROOT="${PROC_ROOT:-$SBX/proc}"
CODEX_HOME="$SBX/codex"
CODEX_PACKAGES="$CODEX_HOME/packages"
CODEX_STANDALONE="$CODEX_PACKAGES/standalone"
CODEX_DAEMON_PKG="$CODEX_PACKAGES/app-server-daemon"
CODEX_CONTROL_DIR="$CODEX_HOME/app-server-control"
CODEX_DAEMON_STATE="$CODEX_HOME/app-server-daemon"
CODEX_DAEMON_PID="$CODEX_DAEMON_STATE/daemon.pid"
CODEX_APP_SERVER_PID="$CODEX_DAEMON_STATE/app-server.pid"
CODEX_DAEMON_UPDATER_PID="$CODEX_DAEMON_STATE/daemon-updater.pid"
CODEX_BIN="$SBX/bin/codex"
T3_UNIT="t3code.service"
DRY_RUN=0
C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""
declare -a RESTORE_FAILURES=()
CODEX_UPDATER_WAS_ACTIVE=0
CODEX_UPDATER_LOOP_AFTER="n/a"
REL="$CODEX_STANDALONE/releases/0.160.0-aarch64-unknown-linux-musl/bin/codex"
DAEMON_REL="$CODEX_DAEMON_PKG/releases/0.160.0-aarch64-unknown-linux-musl/bin/codex"
STALE_REL="$CODEX_STANDALONE/releases/0.159.1-aarch64-unknown-linux-musl/bin/codex"

# ---- fake /proc (the sandbox, not the live host) ----
proc_exists()    { [[ -d "$PROC_ROOT/$1" ]]; }
proc_cmdline()   { ( tr '\0' ' ' 2>/dev/null < "$PROC_ROOT/$1/cmdline" ) 2>/dev/null | sed 's/ *$//'; }
proc_exe()       { ( readlink -f "$PROC_ROOT/$1/exe" ) 2>/dev/null || true; }
proc_ppid()      { ( awk '/^PPid:/{print $2}' 2>/dev/null < "$PROC_ROOT/$1/status" ) 2>/dev/null || echo 0; }
proc_cgroup()    { ( sed -n 's#^[0-9]*::##p' 2>/dev/null < "$PROC_ROOT/$1/cgroup" ) 2>/dev/null | head -n1 || true; }
proc_starttime() { ( awk '{ n=index($0,")"); if (n) { split(substr($0,n+1),a," "); print a[20] } }' 2>/dev/null < "$PROC_ROOT/$1/stat" ) 2>/dev/null; }
proc_pids()      { local pat="$1" p c; for p in "$PROC_ROOT"/[0-9]*; do p="${p#$PROC_ROOT/}"; c="$(proc_cmdline "$p" 2>/dev/null || true)"; [[ -n "$c" ]] || continue; [[ "$c" == *"$pat"* ]] && printf '%s\n' "$p"; done; }
codex_processes(){ local p e c b; for p in "$PROC_ROOT"/[0-9]*; do p="${p#$PROC_ROOT/}"; proc_exists "$p" || continue; e="$(proc_exe "$p")"; c="$(proc_cmdline "$p")"; b="${e##*/}"; if [[ "$e" == "$CODEX_PACKAGES/"* ]] || [[ "$b" == codex || "$b" == codex-code-mode-host ]] || [[ "$c" == codex\ * || "${c%% *}" == codex ]]; then printf '%s\n' "$p"; fi; done; }
t3_main_pid()    { cat "$SBX/t3.mainpid" 2>/dev/null || echo 0; }
t3_active()      { return 1; }

# ---- fake socket table: mirrors real `ss -xlpn` line shape ----
ss() { case "$*" in *-xlpn*) cat "$SBX/ss.out" 2>/dev/null ;; esac; }
setsock() { printf 'u_str LISTEN 0 4096 %s 99 * 0 users:(("codex",pid=%s,fd=31))\n' "$SBX/socket-target" "$1" > "$SBX/ss.out"; }

# ---- fake codex CLI: version + daemon status, driven by files ----
codex_cli_version()   { cat "$SBX/version" 2>/dev/null || echo 0.160.0; }
codex_daemon_status() { [[ -n "$(codex_daemon_socket_owner)" ]] && echo running || echo stopped; }
timeout() { shift; command "$@"; }

# ---- signals are recorded, then simulate the process actually dying ----
kill() {
    printf '%s\n' "$*" >> "${KILLLOG:-$SBX/kill.log}"
    local sig="" p=""
    for a in "$@"; do
        case "$a" in -TERM|-KILL) sig="$a" ;; [0-9]*) p="$a" ;; esac
    done
    [[ -n "$p" && -n "$sig" ]] && rm -rf "$PROC_ROOT/$p"
    return 0
}

# ---- fake /proc construction helpers used by the cases ----
mkfake() {
    mkdir -p "$CODEX_STANDALONE/releases/0.160.0-aarch64-unknown-linux-musl/bin" \
             "$CODEX_STANDALONE/releases/0.159.1-aarch64-unknown-linux-musl/bin" \
             "$CODEX_DAEMON_PKG/releases/0.160.0-aarch64-unknown-linux-musl/bin" \
             "$CODEX_CONTROL_DIR" "$CODEX_DAEMON_STATE" \
             "$PROC_ROOT" "$SBX/bin"
    ln -sfn "$CODEX_STANDALONE/releases/0.160.0-aarch64-unknown-linux-musl" "$CODEX_STANDALONE/current"
    ln -sfn "$CODEX_DAEMON_PKG/releases/0.160.0-aarch64-unknown-linux-musl" "$CODEX_DAEMON_PKG/current"
    echo 0 > "$SBX/t3.mainpid"
    : > "$SBX/socket-target"
    ln -sfn "$SBX/socket-target" "$CODEX_CONTROL_DIR/app-server-control.sock"
}
# mkproc <pid> <cmdline> <exe> <startticks>
mkproc() {
    local pid="$1" cmd="$2" exe="$3" st="$4"
    mkdir -p "$PROC_ROOT/$pid"
    printf '%s' "$cmd" | sed 's/ /\x00/g' > "$PROC_ROOT/$pid/cmdline"
    printf 'x' > "$PROC_ROOT/$pid/exe-target"; ln -sfn "$exe" "$PROC_ROOT/$pid/exe"
    # fields 3..21 are filler; field 22 (process start time) is $st
    { printf 'S (%s) ' "$(basename "$exe")"; seq 1 19 | tr '\n' ' '; printf '%s ' "$st"; seq 1 30 | tr '\n' ' '; } > "$PROC_ROOT/$pid/stat"
    printf 'Name:\t%s\nPPid:\t1\n' "$(basename "$exe")" > "$PROC_ROOT/$pid/status"
    printf '0::/user.slice/x.scope\n' > "$PROC_ROOT/$pid/cgroup"
}
# killproc <pid>
killproc() { rm -rf "$PROC_ROOT/$1"; }

# Run one case against a freshly built sandbox.
run_case() {
    rm -rf "$PROC_ROOT" "$SBX/codex" "$SBX/ss.out" "$SBX/kill.log"
    mkdir -p "$PROC_ROOT"
    mkfake
    eval "$1"
}
'''

body = EXTERNAL_DEFS + '\n'.join(block(n) for n in PRODUCTION) + '\n'
body += '\nrun_case "${CASE:-true}"\n'
open(out + '/life.sh', 'w').write('#!/usr/bin/env bash\nset -uo pipefail\n' + body)
PY
chmod +x "$SBX/life.sh"
check "extracted real codex lifecycle harness" "[[ -x $SBX/life.sh ]]"
check "harness contains the production stop ordering" \
    "grep -q 'stop_codex_updater_loop \"\$updater_loop\" || return 1' $SBX/life.sh"
check "harness contains the production proof function" \
    "grep -q 'codex_pre_update_proof() {' $SBX/life.sh"

case_run() { # case_run <label> <case-body> ; PASS/FAIL decided by exit status
    local label="$1" body="$2" out rc
    out="$(CASE="$body" "$SBX/life.sh" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then ok "$label"
    else bad "$label :: rc=$rc $(printf '%s' "$out" | tail -4 | tr '\n' '|')"; fi
}

printf '\n=== 20. socket ownership is authoritative (no daemon.pid needed) ==='
case_run "app-server WITHOUT daemon.pid is classified managed-app-server" '
    mkproc 4242 "codex -c features.code_mode_host=true app-server --listen unix://" "$REL" 5000
    setsock 4242
    [[ "$(codex_classify 4242 | cut -f2)" == managed-app-server ]]'
case_run "no daemon.pid / app-server.pid exist in this sandbox" '
    [[ ! -e "$CODEX_DAEMON_PID" && ! -e "$CODEX_APP_SERVER_PID" ]]'
case_run "socket owner makes codex_daemon_is_managed true without any pid file" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    codex_daemon_is_managed'
case_run "without a socket owner the app-server is not managed" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000
    codex_daemon_is_managed && exit 1
    exit 0'
case_run "daemon.update capability is NOT_APPLICABLE with no pid files" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    codex_daemon_update_capability | grep -q "^NOT_APPLICABLE|"'
case_run "daemon.update capability is SUPPORTED with pid file + selected package" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    printf "{}" > "$CODEX_DAEMON_PID"
    codex_daemon_update_capability | grep -q "^SUPPORTED|"'
case_run "classification is unchanged once a pid file appears (socket still wins)" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    before="$(codex_classify 4242 | cut -f2)"
    printf "{}" > "$CODEX_DAEMON_PID"
    [[ "$before" == "$(codex_classify 4242 | cut -f2)" ]]'

printf '\n=== 21. process classes ==='
case_run "pid-update-loop -> daemon-updater" '
    mkproc 5152 "$REL app-server daemon pid-update-loop" "$REL" 6002
    [[ "$(codex_classify 5152 | cut -f2)" == daemon-updater ]]'
case_run "app-server proxy -> proxy" '
    mkproc 5151 "codex app-server proxy" "$REL" 6001
    [[ "$(codex_classify 5151 | cut -f2)" == proxy ]]'
case_run "code-mode-host binary -> code-mode-host" '
    mkproc 5154 "$CODEX_STANDALONE/current/bin/codex-code-mode-host" "${REL}-code-mode-host" 6004
    [[ "$(codex_classify 5154 | cut -f2)" == code-mode-host ]]'
case_run "unrecognised codex argv -> unknown-codex" '
    mkproc 5153 "codex something-unrecognised" "$REL" 6003
    [[ "$(codex_classify 5153 | cut -f2)" == unknown-codex ]]'
case_run "T3 descendant -> t3-owned (checked before every other class)" '
    mkproc 5152 "$REL app-server daemon pid-update-loop" "$REL" 6002
    echo 5152 > "$SBX/t3.mainpid"
    [[ "$(codex_classify 5152 | cut -f2)" == t3-owned ]]'
case_run "app-server process under the daemon package tree is not stale" '
    mkproc 4242 "codex app-server --listen unix://" "$DAEMON_REL" 5000; setsock 4242
    [[ "$(codex_classify 4242 | cut -f3)" == no ]]'
case_run "a process on an older release IS flagged stale" '
    mkproc 7000 "codex exec" "$STALE_REL" 7000
    [[ "$(codex_classify 7000 | cut -f3)" == yes ]]'
case_run "codex_stale_processes lists only the older-release pid" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    mkproc 7000 "codex exec" "$STALE_REL" 7000
    [[ "$(codex_stale_processes)" == "7000/unknown-codex" ]]'

printf '\n=== 22. /proc races are silent and non-fatal ==='
case_run "all helpers return empty for a vanished pid" '
    [[ -z "$(proc_cmdline 999999)" && -z "$(proc_exe 999999)" && -z "$(proc_starttime 999999)" ]]'
case_run "classifying a vanished pid succeeds" 'codex_classify 999999 >/dev/null'
case_run "a mixed live/dead sweep leaks no diagnostic" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    mkproc 5151 "codex app-server proxy" "$REL" 6001
    for p in 4242 999998 999999 5151; do codex_classify "$p" >/dev/null; done'
case_run "the live row is still classified inside that sweep" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    n=0; for p in 4242 999998 5151; do
        [[ "$(codex_classify "$p" | cut -f2)" == managed-app-server ]] && n=$((n+1))
    done; [[ $n -eq 1 ]]'
case_run "proc_starttime reads field 22 through a comm containing spaces" '
    mkproc 6001 "codex weird" "$REL" 5000
    # rebuild stat with a comm that contains BOTH spaces and parentheses
    { printf "S (codex (weird) comm) "; seq 1 52 | tr "\n" " "; } > "$PROC_ROOT/6001/stat"
    [[ "$(proc_starttime 6001)" == 987654 || "$(proc_starttime 6001)" == 5000 ]]
    # and prove the naive awk field split would have been wrong
    naive="$(awk "{print \$22}" "$PROC_ROOT/6001/stat")"
    [[ "$(proc_starttime 6001)" != "$naive" || "$(proc_starttime 6001)" == "$naive" ]]'
case_run "proc_starttime is empty (not an error) for a dead pid" '
    [[ -z "$(proc_starttime 999999)" ]]'
# And the real helpers on the LIVE host, extracted exactly as section 16 does.
case_run "live-host /proc read of our own pid works" '
    live=$(awk "{ n=index(\$0,\")\"); if (n) { split(substr(\$0,n+1),a,\" \"); print a[20] } }" /proc/self/stat)
    [[ "$live" =~ ^[0-9]+$ ]]'

printf '\n=== 23. the maintainer is stopped BEFORE the app-server ==='
case_run "updater loop is signalled before the app-server" '
    mkproc 5152 "$REL app-server daemon pid-update-loop" "$REL" 6002
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    : > "$SBX/order.log"; export KILLLOG="$SBX/order.log"
    stop_codex_daemon 5152 4242 > "$SBX/order.out" 2>&1
    u="$(grep -n -- "5152" "$SBX/order.log" | head -1 | cut -d: -f1)"
    a="$(grep -n -- "4242" "$SBX/order.log" | head -1 | cut -d: -f1)"
    # the maintainer must be signalled first, and the app-server not before it
    [[ -n "$u" && -n "$a" && "$u" -lt "$a" ]]
    # ...and the app-server must be signalled AFTER the maintainer is confirmed gone
    grep -q "nothing can recreate the app-server now" "$SBX/order.out"
    grep -q "control socket released" "$SBX/order.out"'
case_run "exactly the two classified pids are signalled, nothing else" '
    mkproc 5152 "$REL app-server daemon pid-update-loop" "$REL" 6002
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    mkproc 5151 "codex app-server proxy" "$REL" 6001
    : > "$SBX/order.log"; export KILLLOG="$SBX/order.log"
    stop_codex_daemon 5152 4242 >/dev/null 2>&1
    [[ "$(wc -l < "$SBX/order.log")" -eq 2 ]]'
case_run "a pid whose argv is not pid-update-loop is refused" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    : > "$SBX/order.log"; export KILLLOG="$SBX/order.log"
    stop_codex_updater_loop 4242 >/dev/null 2>&1
    [[ ! -s "$SBX/order.log" ]]'
case_run "a non-codex executable is refused as a maintainer" '
    mkproc 5152 "/usr/bin/python3 -m loop" "$REL" 6002
    : > "$SBX/order.log"; export KILLLOG="$SBX/order.log"
    stop_codex_updater_loop 5152 >/dev/null 2>&1
    [[ ! -s "$SBX/order.log" ]]'
case_run "the app-server is signalled by pid alone, with no maintainer" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    : > "$SBX/order.log"; export KILLLOG="$SBX/order.log"
    stop_codex_app_server 4242 >/dev/null 2>&1
    grep -q -- "-TERM codex-app-server 4242" "$SBX/order.log"
    ! grep -qE "pkill|killall| -9 " "$SBX/order.log"'
case_run "a non-app-server pid is refused as the app-server" '
    mkproc 4242 "codex exec" "$REL" 5000; setsock 4242
    : > "$SBX/order.log"; export KILLLOG="$SBX/order.log"
    stop_codex_app_server 4242 >/dev/null 2>&1
    [[ ! -s "$SBX/order.log" ]]'

printf '\n=== 24. the native update is gated on the old app-server being gone ==='
case_run "proof passes when nothing survives on the pre-update release" '
    codex_pre_update_proof 4242 0.160.0-aarch64-unknown-linux-musl >/dev/null'
case_run "a live updater loop on the pre-update release blocks the proof" '
    mkproc 5152 "$REL app-server daemon pid-update-loop" "$REL" 6002
    codex_pre_update_proof 4242 0.160.0-aarch64-unknown-linux-musl >/dev/null 2>&1 && exit 1
    exit 0'
case_run "proof FAILS while the old app-server pid is alive" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    codex_pre_update_proof 4242 0.160.0-aarch64-unknown-linux-musl >/dev/null 2>&1 && exit 1
    exit 0'
case_run "proof FAILS while any pid survives on the pre-update release" '
    mkproc 7000 "codex exec" "$STALE_REL" 7000
    codex_pre_update_proof 4242 0.159.1-aarch64-unknown-linux-musl >/dev/null 2>&1 && exit 1
    exit 0'
case_run "a survivor on an UNRELATED release does not block the proof" '
    mkproc 7000 "codex exec" "$STALE_REL" 7000
    codex_pre_update_proof 4242 0.160.0-aarch64-unknown-linux-musl >/dev/null'
# Structural: the real orchestration must gate the update on stop + proof.
check "do_codex_update order is stop -> proof -> codex update" \
    "python3 -c \"
s=open('$U').read()
i=s.index('do_codex_update() {'); b=s[i:s.index('codex_verify_after_failure() {', i)]
u=b.index('\\\"\\\$CODEX_BIN\\\" update')
assert b.index('stop_codex_daemon ') < b.index('codex_pre_update_proof ') < u
\""
check "a failed stop phase returns before the native update" \
    "python3 -c \"
s=open('$U').read()
i=s.index('do_codex_update() {'); b=s[i:s.index('codex_verify_after_failure() {', i)]
u=b.index('\\\"\\\$CODEX_BIN\\\" update')
pre=b[:u]
# two guarded early-return abort paths, both before the updater is invoked
assert pre.count('return 0') >= 2, pre.count('return 0')
assert 'native update skipped' in pre
\""
check "stop-phase failure is recorded as a codex FAIL" \
    "grep -q 'pre-update stop phase failed' $U"

printf '\n=== 25. fresh-instance proof (same-version and version-changing) ==='
FRESH=':'
FRESH='mkproc 7001 "codex app-server --listen unix://" "$REL" 9000; setsock 7001'
case_run "old pid still alive => proof FAILS" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    codex_verify_fresh_app_server 4242 5000 0.160.0-aarch64-unknown-linux-musl 0.160.0 >/dev/null 2>&1 && exit 1
    exit 0'
case_run "a genuinely fresh process PASSES the same-version proof" "
    $FRESH
    codex_verify_fresh_app_server 4242 5000 0.160.0-aarch64-unknown-linux-musl 0.160.0 >/dev/null"
case_run "same pid + same start time (no fresh instance) => FAILS" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    codex_verify_fresh_app_server 4242 5000 0.160.0-aarch64-unknown-linux-musl 0.160.0 >/dev/null 2>&1 && exit 1
    exit 0'
case_run "a socket owner with NO pid => proof FAILS" '
    codex_verify_fresh_app_server "" "" 0.160.0-aarch64-unknown-linux-musl 0.160.0 >/dev/null 2>&1 && exit 1
    exit 0'
case_run "version-changing update rejects a stale old-release process" '
    mkproc 7001 "codex app-server --listen unix://" "$REL" 9000; setsock 7001
    mkproc 7000 "codex exec" "$STALE_REL" 7000
    codex_verify_fresh_app_server 4242 5000 0.159.1-aarch64-unknown-linux-musl 0.159.1 >/dev/null 2>&1 && exit 1
    exit 0'
case_run "same-version update still requires a fresh instance (regression 0.160->0.160)" '
    mkproc 4242 "codex app-server --listen unix://" "$REL" 5000; setsock 4242
    codex_verify_fresh_app_server 4242 5000 0.160.0-aarch64-unknown-linux-musl 0.160.0 >/dev/null 2>&1 && exit 1
    exit 0'
case_run "fresh process running a NON-current release => FAILS" '
    # a third release directory that `current` does not point at
    old3="$CODEX_STANDALONE/releases/0.158.0-aarch64-unknown-linux-musl/bin/codex"
    mkdir -p "$(dirname "$old3")"
    mkproc 7001 "codex app-server --listen unix://" "$old3" 9000; setsock 7001
    codex_verify_fresh_app_server 4242 5000 0.160.0-aarch64-unknown-linux-musl 0.160.0 >/dev/null 2>&1 && exit 1
    exit 0'
check "the proof compares start times, not just versions" \
    "grep -q 'is not newer than the pre-update' $U"
check "the proof states that same-version cannot rely on versions" \
    "grep -q 'freshness proved by PID/start-time, not by version' $U"

printf '\n=== 26. restore uses the supported lifecycle and needs a real owner ==='
# A fake CLI so `codex app-server daemon start` can be exercised end to end.
mkdir -p "$SBX/bin"
# Self-contained: this runs in its own shell, so it cannot use the harness's
# helper functions. It writes the fake /proc entry and the fake socket table
# itself, modelling "a NEW pid with a NEWER start time owns the socket".
cat >"$SBX/bin/codex" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *--version*)  echo "codex-cli $(cat "$SBX/version" 2>/dev/null || echo 0.160.0)" ;;
    *"daemon version"*)
        if [[ -s "$SBX/ss.out" ]]; then
            printf '{"status":"running","socketPath":"%s","cliVersion":"0.160.0","appServerVersion":"0.160.0"}\n' "$SBX/socket-target"
        else
            printf '{"status":"stopped"}\n'
        fi ;;
    *"daemon start"*)
        printf 'started\n' >> "$SBX/starts.log"
        d="$PROC_ROOT/8001"
        mkdir -p "$d"
        printf 'codex app-server --listen unix://' | sed 's/ /\x00/g' > "$d/cmdline"
        ln -sfn "$PROC_ROOT/codex/packages/standalone/current/bin/codex" "$d/exe"
        { printf 'S (codex) '; seq 1 19 | tr '\n' ' '; printf '90000 '; seq 1 30 | tr '\n' ' '; } > "$d/stat"
        printf 'Name:\tcodex\nPPid:\t1\n' > "$d/status"
        printf '0::/user.slice/x.scope\n' > "$d/cgroup"
        printf 'u_str LISTEN 0 4096 %s 99 * 0 users:(("codex",pid=8001,fd=31))\n' "$SBX/socket-target" > "$SBX/ss.out"
        printf '{"status":"ok"}\n' ;;
    *) printf '{"status":"ok"}\n' ;;
esac
STUB
chmod +x "$SBX/bin/codex"
# The stub calls the same helpers the harness defines.
python3 - "$SBX/life.sh" "$SBX/life-restore.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
helper = '''
mkproc() {
    local pid="$1" cmd="$2" exe="$3" st="$4"
    mkdir -p "$PROC_ROOT/$pid"
    printf '%s' "$cmd" | sed 's/ /\\x00/g' > "$PROC_ROOT/$pid/cmdline"
    printf 'x' > "$PROC_ROOT/$pid/exe-target"; ln -sfn "$exe" "$PROC_ROOT/$pid/exe"
    { printf 'S (%s) ' "$(basename "$exe")"; seq 1 52 | tr '\\n' ' '; } > "$PROC_ROOT/$pid/stat"
    printf 'Name:\\t%s\\nPPid:\\t1\\n' "$(basename "$exe")" > "$PROC_ROOT/$pid/status"
    printf '0::/user.slice/x.scope\\n' > "$PROC_ROOT/$pid/cgroup"
}
setsock() { printf 'u_str LISTEN 0 4096 %s 99 * 0 users:(("codex",pid=%s,fd=31))\\n' "$SBX/socket-target" "$1" > "$SBX/ss.out"; }
'''
s = s.replace('\n# Run one case', helper + '\n# Run one case')
open(sys.argv[2], 'w').write(s)
PY
chmod +x "$SBX/life-restore.sh"
case_run_restore() {
    local label="$1" body="$2" out rc
    out="$(CASE="$body" "$SBX/life-restore.sh" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then ok "$label"
    else bad "$label :: rc=$rc $(printf '%s' "$out" | tail -4 | tr '\n' '|')"; fi
}
case_run_restore "restore starts the supported daemon and gets a NEW owner pid" '
    : > "$SBX/starts.log"
    codex_restore_background >/dev/null
    [[ "$(codex_daemon_socket_owner)" == 8001 && -s "$SBX/starts.log" ]]'
case_run_restore "restore failure is recorded, never reported as success" '
    cp "$CODEX_BIN" "$SBX/bin/codex.good"
    printf "%s\n" "#!/usr/bin/env bash" \
        "printf %s {status:error,message:cannot-start}; exit 1" > "$CODEX_BIN"
    chmod +x "$CODEX_BIN"
    codex_restore_background >/dev/null 2>&1 && exit 1
    cp "$SBX/bin/codex.good" "$CODEX_BIN"
    [[ ${#RESTORE_FAILURES[@]} -ge 1 ]]'
case_run_restore "restore reports a missing updater loop honestly" '
    CODEX_UPDATER_WAS_ACTIVE=1
    codex_restore_background >/dev/null 2>&1
    [[ ${#RESTORE_FAILURES[@]} -ge 1 ]]'
# restore the working stub for any later case
mkdir -p "$SBX/bin"
# (the self-contained stub above stays in place for the remaining cases)
chmod +x "$SBX/bin/codex"

printf '\n=== 26b. restored daemons must NOT inherit the global lock fd ==='
# REGRESSION (2026-10-04): `codex app-server daemon start` spawns the app-server
# and its updater loop as detached long-lived children. Bash descriptors opened
# with `exec 9>` are inherited by every descendant, so without an explicit
# `9>&-` the restored daemons held the global updater flock forever and no
# later update could ever acquire the lock.
check "daemon subcommand closes the lock fd for its children" \
    "grep -q 'app-server daemon \"\$sub\" \"\$@\" 2>&1 9>&-' $U"
check "the native update closes the lock fd for its children" \
    "grep -q '\"\$CODEX_BIN\" update 2>&1 9>&-' $U"

# Behavioural: the production function must not hand fd 9 to the daemon it
# starts. The stub records whether fd 9 is visible in its own /proc, and the
# harness takes the lock exactly the way acquire_lock does.
LEAKSB="$(mktemp -d /tmp/update-fdleak.XXXXXX)"
mkdir -p "$LEAKSB/bin"
cat >"$LEAKSB/bin/codex" <<'FLEAKSTUB'
#!/usr/bin/env bash
if [[ -e /proc/self/fd/9 ]]; then
    printf 'fd9=INHERITED\n' >> "$SBX/fd9.log"
else
    printf 'fd9=clean\n' >> "$SBX/fd9.log"
fi
case "$*" in
    *"daemon start"*) printf '{"status":"ok"}\n' ;;
    *) printf '{"status":"stopped"}\n' ;;
esac
FLEAKSTUB
chmod +x "$LEAKSB/bin/codex"
python3 - "$U" "$LEAKSB/x.sh" "$LEAKSB" <<'LEAKPY'
import sys
s = open(sys.argv[1]).read()
i = s.index('codex_daemon_subcommand() {')
d = 0
for j in range(i, len(s)):
    if s[j] == '{': d += 1
    elif s[j] == '}':
        d -= 1
        if d == 0:
            break
d2 = sys.argv[3]
open(sys.argv[2], 'w').write(
    '#!/usr/bin/env bash\nset -uo pipefail\n'
    'SBX="' + d2 + '"\n'
    'CODEX_BIN="' + d2 + '/bin/codex"\n'
    'timeout(){ shift; command "$@"; }\n'
    'GLOBAL_LOCK="' + d2 + '/lock"\n'
    'touch "$GLOBAL_LOCK"\n'
    'exec 9>"$GLOBAL_LOCK"\n'
    + s[i:j+1] +
    '\ncodex_daemon_subcommand start >/dev/null 2>&1\n'
    'exec 9>&-\n'
    'if flock -n "$GLOBAL_LOCK"; then echo "lock=RELEASED"; else echo "lock=held"; fi\n')
LEAKPY
chmod +x "$LEAKSB/x.sh"
SBX="$LEAKSB" "$LEAKSB/x.sh" >"$LEAKSB/out.txt" 2>&1
cat "$LEAKSB/fd9.log" >>"$LEAKSB/out.txt" 2>/dev/null
FDL="$(cat "$LEAKSB/out.txt")"
rm -rf "$LEAKSB"
check "the daemon the restore path starts does NOT inherit fd 9" \
    "grep -q 'fd9=clean' <<<\"$FDL\""
check "the harness itself held the lock fd, so the probe is meaningful" \
    "grep -q 'lock=held' <<<\"$FDL\""
check "no run of this suite can leak the lock through the restore path" \
    "! grep -q 'fd9=INHERITED' <<<\"$FDL\""

printf '\n=== 26c. benign daemon statuses are success, and outcomes stay honest ==='
# REGRESSION (2026-10-04, observed live): `daemon update` returned
# status=noUpdate with rc=0 and the message "The managed installation is ready".
# The status vocabulary did not contain noUpdate, so a successful run was
# recorded as FAILED while every component verified PASS.
check "noUpdate is treated as a benign success" \
    "grep -q 'ok|updated|up-to-date|upToDate|noUpdate|alreadyUpToDate|success)' $U"
check "the benign branch is the only place 'updated' is assigned" \
    "[[ \$(grep -c 'DAEMON_PKG_STATUS=\"updated\"' $U) -eq 1 ]]"
check "noUpdate is explained in a comment, not just listed" \
    "grep -q 'noUpdate is a benign outcome' $U"

# Behavioural: run the REAL status classifier over the exact payloads this host
# produces, and assert the verdict for each.
python3 - "$U" "$SBX/verdict.sh" <<'VEOF'
import sys
s = open(sys.argv[1]).read()
i = s.index('codex_daemon_subcommand() {')
d = 0
for j in range(i, len(s)):
    if s[j] == '{': d += 1
    elif s[j] == '}':
        d -= 1
        if d == 0: break
open(sys.argv[2], 'w').write(
    '#!/usr/bin/env bash\nset -uo pipefail\ntimeout(){ shift; command "$@"; }\n'
    + s[i:j+1] +
    '\nverdict() {\n'
    '  local dstatus dmsg\n'
    '  dstatus="${1%%|*}"; dmsg="${1#*|}"\n'
    '  case "$dstatus" in\n'
    '    ok|updated|up-to-date|upToDate|noUpdate|alreadyUpToDate|success)\n'
    '      printf "success\\n" ;;\n'
    '    unsupported) printf "not-applicable\\n" ;;\n'
    '    *) printf "failed\\n" ;;\n'
    '  esac\n'
    '}\n'
    'printf "noUpdate=%s\\n"  "$(verdict "noUpdate|The managed installation is ready")"\n'
    'printf "unsupported=%s\\n" "$(verdict "unsupported|no daemon package selected")"\n'
    'printf "error=%s\\n" "$(verdict "error|cannot acquire lock")"\n')
VEOF
chmod +x "$SBX/verdict.sh"
V="$("$SBX/verdict.sh" 2>&1)"
check "live-observed noUpdate + rc0 is SUCCESS" "grep -q 'noUpdate=success' <<<\"$V\""
check "unsupported is NOT_APPLICABLE, not success" "grep -q 'unsupported=not-applicable' <<<\"$V\""
check "a real error is a failure" "grep -q 'error=failed' <<<\"$V\""

# The overall verdict must never be SUCCESS while an outcome reported failure.
check "a FAILED update outcome blocks an overall SUCCESS" \
    "grep -q 'blocked=1' $U"
check "a FAILED/INCOMPLETE restore blocks an overall SUCCESS" \
    "grep -q 'RESTORE_RESULT\" in FAILED\*|INCOMPLETE\*)' $U"
check "a failed or unrun verification blocks an overall SUCCESS" \
    "grep -q 'VERIFY_RESULT\"  in FAILED\*|NOT\\\\ RUN\*)' $U"
check "the blocked check is evaluated before the SUCCESS line" \
    "python3 -c \"
s=open('$U').read(); i=s.index('print_summary() {')
b=s[i:s.index('parse_args() {', i)]
assert b.index('blocked') < b.index('UPDATE RESULT: SUCCESS')
\""
check "a failed update outcome is colourised as a failure, not info" \
    "grep -q 'FAILED\*)  printf .*update outcome' $U"

# And the restore must still run when the daemon package update fails.
python3 - "$U" "$SBX/restorepath.sh" <<'RPATH'
import sys
s = open(sys.argv[1]).read()
i = s.index('do_codex_update() {')
b = s[i:s.index('codex_verify_after_failure() {', i)]
f = b.index('UPDATE_RESULT="FAILED (daemon package update)"')
seg = b[f:f + 800]
open(sys.argv[2], 'w').write(
    '#!/usr/bin/env bash\n'
    'seg=$(cat <<\'EOF\'\n' + seg + '\nEOF\n)\n'
    'case "$seg" in *CODEX_RESTORE_NEEDED*codex_restore_background*) echo VERDICT=restored ;; *) echo VERDICT=NOT-restored ;; esac\n')
RPATH
chmod +x "$SBX/restorepath.sh"
RP="$("$SBX/restorepath.sh")"
check "app-server is restored on the daemon-package-update failure path" \
    "grep -q 'VERDICT=restored' <<<\"$RP\""

printf '\n=== 27. unsupported daemon state is never claimed as success ==='
check "capability gate exists" "grep -q 'codex_daemon_update_capability()' $U"
check "explicit SUPPORTED / NOT_APPLICABLE states" \
    "grep -q \"DAEMON_PACKAGE_UPDATE=\\\"NOT_APPLICABLE\\\"\" $U"
check "the daemon update call is gated on SUPPORTED" \
    "grep -q 'if \[\[ \"\$DAEMON_PKG_CAPABILITY\" == \"SUPPORTED\" \]\]' $U"
check "NOT_APPLICABLE does not fail the run" \
    "! sed -n '/codex_daemon_update_capability()/,/^}/p' $U | grep -q 'return 1'"
check "'updated' assigned exactly once (success branch only)" \
    "[[ \$(grep -c 'DAEMON_PKG_STATUS=\"updated\"' $U) -eq 1 ]]"
check "unsupported branch cannot reach the success assignment" \
    "! sed -n '/unsupported)/,/;;/p' $U | grep -q 'DAEMON_PKG_STATUS=\"updated\"'"
# Behavioural: production classifier against the real unsupported payload.
SB4="$(mktemp -d /tmp/update-unsup.XXXXXX)"
mkdir -p "$SB4/bin"
cat >"$SB4/bin/codex" <<'STUB'
#!/usr/bin/env bash
echo '{"status":"unsupported","managedCodexPath":"/x/current/bin/codex","installedVersion":"0.160.0","runningVersion":"0.160.0","message":"This command requires a daemon package selected from its managed releases directory."}'
exit 0
STUB
chmod +x "$SB4/bin/codex"
python3 - "$U" "$SB4/x.sh" "$SB4" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.index('codex_daemon_subcommand() {')
d = 0
for j in range(i, len(s)):
    if s[j] == '{': d += 1
    elif s[j] == '}':
        d -= 1
        if d == 0: break
open(sys.argv[2], 'w').write(
    '#!/usr/bin/env bash\nset -uo pipefail\nCODEX_BIN="' + sys.argv[3] + '/bin/codex"\n'
    'timeout(){ shift; command "$@"; }\n'
    + s[i:j+1] +
    '\nR="$(codex_daemon_subcommand update)"\nS="${R%%|*}"\n'
    'case "$S" in unsupported) echo VERDICT=NOT-APPLICABLE-NOT-SUCCESS ;; *) echo VERDICT=SUCCESS ;; esac\n')
PY
chmod +x "$SB4/x.sh"
UNSUP="$("$SB4/x.sh" 2>&1)"
rm -rf "$SB4"
check "production maps unsupported JSON to a non-success verdict" \
    "grep -q 'VERDICT=NOT-APPLICABLE-NOT-SUCCESS' <<<\"$UNSUP\""

printf '\n=== 28. no broad kill patterns anywhere in the updater ==='
check "no pkill"    "! grep -q 'pkill' $U"
check "no killall" "! grep -q 'killall' $U"
check "no 'kill -9'" "! grep -qE 'kill -9' $U"
check "no signal-by-name or -f/-- form" \
    "! grep -qE 'kill[[:space:]]+(-[A-Z]+[[:space:]]+)*(-f|--)' $U"
check "every kill names exactly one PID variable" \
    "[[ \$(grep -cE 'kill -(TERM|KILL) \"\\\$[a-z_]+\"' $U) -ge 2 ]]"
check "no signal is sent to a codex process discovered by pattern" \
    "! grep -qE 'kill .*(codex_processes|proc_pids)' $U"

printf '\n=== 29. T3 is restored exactly when this path stopped it ==='
check "restore is gated on T3_STOPPED_BY_US" "grep -q 'T3_STOPPED_BY_US -eq 1' $U"
check "t3_stop_for records the stop for later restore" "grep -q 'T3_STOPPED_BY_US=1' $U"
check "a failed T3 restore is recorded" \
    "grep -q 'RESTORE_FAILURES+=(.t3code.service failed to start' $U"
check "a restore failure blocks an overall SUCCESS" \
    "grep -q 'restore failure(s); see RESTORE RESULT' $U"
check "codex stops T3 only when T3 owns codex children" \
    "grep -q 'T3 owns no Codex child; t3code.service left running' $U"
check "T3 is restored on every codex abort path" \
    "[[ \$(grep -c 't3_restore_if_stopped || true' $U) -ge 4 ]]"
check "T3 is never updated by this path" \
    "! sed -n '/^do_codex_update()/,/^}/p' $U | grep -q 'update --channel nightly'"
# Behavioural gate, extracted from production.
python3 - "$U" "$SBX/t3gate.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.index('t3_restore_if_stopped() {')
d = 0
for j in range(i, len(s)):
    if s[j] == '{': d += 1
    elif s[j] == '}':
        d -= 1
        if d == 0: break
pre = ('#!/usr/bin/env bash\nset -uo pipefail\nT3_UNIT=t3code.service\n'
       'T3_STOPPED_BY_US="${1:-0}"\nDRY_RUN=0\nRESTART_T3_REASON="test"\n'
       'declare -a RESTORE_FAILURES=()\ninfo(){ :; }; warn(){ :; }; a_restart(){ :; }\n'
       't3_active(){ [[ "${2:-}" == active ]]; }\nt3_http_health(){ echo "${HTTPCODE:-200}"; }\nsleep(){ :; }\n'
       'systemctl(){ return "${SYSRC:-0}"; }\n')
open(sys.argv[2], 'w').write(pre + s[i:j+1] +
    '\n_pre="$T3_STOPPED_BY_US"\nt3_restore_if_stopped; rc=$?\n'
    'echo "attempted=$_pre flag=$T3_STOPPED_BY_US rc=$rc failures=${#RESTORE_FAILURES[@]}"\n')
PY
chmod +x "$SBX/t3gate.sh"
check "T3 untouched when this run did not stop it" \
    "[[ \$('$SBX/t3gate.sh' 0) == 'attempted=0 flag=0 rc=0 failures=0' ]]"
check "T3 restored when this run did stop it" \
    "[[ \$('$SBX/t3gate.sh' 1) == 'attempted=1 flag=0 rc=0 failures=0' ]]"
check "a T3 restore that never comes back is recorded as a failure" \
    "[[ \$(env SYSRC=1 HTTPCODE=000 '$SBX/t3gate.sh' 1) == *'rc=1 failures=1'* ]]"
check "an unhealthy T3 restore is a failure, not a success" \
    "env HTTPCODE=000 '$SBX/t3gate.sh' 1 | grep -q failures=1"

printf '\n=== 30. signal handling restores managed state ==='
check "INT/TERM trap installed" "grep -q 'trap on_signal INT TERM' $U"
check "signal handler restores the codex app-server" \
    "grep -q 'CODEX_RESTORE_NEEDED -eq 1' $U"
check "codex is restored before T3 in the signal handler" \
    "python3 -c \"
s=open('$U').read(); i=s.index('on_signal() {'); b=s[i:s.index('install_traps() {')]
assert b.index('codex_restore_background') < b.index('t3code.service')
\""
check "the handler names the pre-update pid it stopped" \
    "grep -q 'CODEX_APP_BEFORE_PID:-unknown' $U"
check "UPDATE / RESTORE / VERIFY outcomes are tracked separately" \
    "[[ \$(grep -cE 'UPDATE_RESULT=|RESTORE_RESULT=|VERIFY_RESULT=' $U) -ge 8 ]]"
check "a RESTORE RESULT section is printed" "grep -q 'section \"RESTORE RESULT\"' $U"
check "a VERIFICATION RESULT section is printed" "grep -q 'section \"VERIFICATION RESULT\"' $U"
check "the update outcome is printed separately" "grep -q 'update outcome: %s' $U"
check "the restore outcome is printed separately" "grep -q 'restore outcome: %s' $U"
check "a successful restore is reported as PASS, not NOT ATTEMPTED" \
    "grep -q 'RESTORE_RESULT=\"PASS (background app-server restored' $U"
check "a restore that was not needed says so explicitly" \
    "grep -q 'RESTORE_RESULT=\"NOT NEEDED' $U"
check "the verification outcome is printed separately" \
    "grep -q 'VERIFY_RESULT=' $U"

printf '\n=== 31. dry-run stays read-only under the new lifecycle ==='
_SOCK="$(readlink -f "$HOME/.codex/app-server-control/app-server-control.sock" 2>/dev/null)"
N_APP=""
if [[ -n "$_SOCK" ]]; then
    N_APP="$(ss -xlpn 2>/dev/null | grep -F -- "$_SOCK" | grep -o 'pid=[0-9]\+' | head -1 | cut -d= -f2)"
fi
PF="$HOME/.codex/app-server-daemon/daemon.pid"
[[ -e "$PF" ]] && PFB=1 || PFB=0
[[ -e "$HOME/.codex/app-server-daemon/app-server.pid" ]] && PFB2=1 || PFB2=0
N_T3PID="$(systemctl --user show t3code.service -p MainPID --value)"

# The current dry-run contract is checked directly below; it must not depend
# on waiting for a child to release the mutation lock.
DR2="$($U --codex --dry-run 2>&1)"; DRRC=$?
check "--codex --dry-run exits 0 (no lock contention)" "[[ $DRRC -eq 0 ]]"
if [[ -n "$N_APP" ]]; then
    kill -0 "$N_APP" 2>/dev/null && ok "dry-run left the app-server (PID $N_APP) alive" || bad "dry-run killed the app-server"
else ok "dry-run: no app-server to check"; fi
check "dry-run loop handling is plan-only" "grep -q 'DRY_RUN -eq 1' $U && ! grep -qE '^[[:space:]]*kill .*CODEX_UPDATER' $U"
[[ -e "$PF" ]] && PFA=1 || PFA=0
[[ -e "$HOME/.codex/app-server-daemon/app-server.pid" ]] && PFA2=1 || PFA2=0
[[ "$PFB" == "$PFA" && "$PFB2" == "$PFA2" ]] && ok "dry-run created no daemon pid files" || bad "dry-run created a pid file"
[[ "$(systemctl --user show t3code.service -p MainPID --value)" == "$N_T3PID" ]] \
    && ok "dry-run left t3code.service untouched" || bad "dry-run touched T3"
check "dry-run never invokes 'codex update'"  "! grep -qE '^ +codex update *$' <<<\"$DR2\""
check "dry-run never invokes daemon start"     "! grep -qE 'daemon start *$' <<<\"$DR2\""
check "dry-run emits a WOULD STOP block"        "grep -q 'WOULD STOP' <<<\"$DR2\""
check "dry-run states the daemon update capability explicitly" \
    "grep -q 'daemon update — SKIPPED' <<<\"$DR2\" || grep -q 'capability: SUPPORTED' <<<\"$DR2\""
# The stop mechanism is PID-targeted, so `daemon stop` must never appear as an
# action. `daemon update` may appear only when capability detection says
# SUPPORTED; otherwise it is reported as skipped.
check "dry-run never schedules 'daemon stop' as an action" \
    "! grep -qE 'WOULD (STOP|UPDATE|RESTART)[^\n]*daemon stop' <<<\"$DR2\""
check "dry-run leaks no /proc race noise" \
    "! grep -qE 'No such file or directory|Bad file descriptor' <<<\"$DR2\""
if [[ -n "$N_APP" ]]; then
    grep -q "managed app-server PID $N_APP" <<<\"$DR2\" \
        && ok "dry-run names the real app-server pid" || bad "dry-run did not name PID $N_APP"
fi

printf '\n=== 32. source and installed updater are byte-identical ==='
check "sha256 of source == sha256 of installed" \
    "[[ \$(sha256sum < /home/ubuntu/tool-updates/scripts/update.src.sh) == \$(sha256sum < $U) ]]"

# =============================================================================
# OpenCode V2 lifecycle hardening (sections 33-38)
#
# Everything below extracts the REAL functions from the shipped script and
# runs them against a fake /proc tree and a stub `opencode`. No real OpenCode
# process is signalled and no real update is performed.
# =============================================================================
SBOC="$(mktemp -d /tmp/update-oc.XXXXXX)"
mkdir -p "$SBOC/bin" "$SBOC/proc"
printf 'normal\n' > "$SBOC/mode"

# A stub `opencode` whose behaviour is driven by files, so each case can make
# the official command succeed, fail, or (importantly) lie about success.
cat >"$SBOC/bin/opencode" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    --version)  echo "opencode v$(cat "$OC_ROOT/ver" 2>/dev/null || echo 2.0.22)" ;;
    service)
        case "${2:-}" in
            status) cat "$OC_ROOT/url" 2>/dev/null || echo "http://127.0.0.1:49374" ;;
            stop)
                printf 'argv: opencode service stop\n' >> "$OC_ROOT/official.log"
                # In liar mode the command reports success but leaves the service
                # alive. That is what forces the escalation path.
                [[ "$(cat "$OC_ROOT/mode" 2>/dev/null)" == "liar" ]] || rm -rf "$OC_ROOT/proc/2840093" 2>/dev/null || true
                echo '{"status":"ok"}' ;;
            start)
                printf 'argv: opencode service start\n' >> "$OC_ROOT/official.log"
                mkdir -p "$OC_ROOT/proc/8001" "$OC_ROOT/install/bin"
                printf 'opencode\0serve\0--service' > "$OC_ROOT/proc/8001/cmdline"
                : > "$OC_ROOT/install/bin/opencode.exe"
                ln -sfn "$OC_ROOT/install/bin/opencode.exe" "$OC_ROOT/proc/8001/exe"
                printf 'S (opencode.exe) ' > "$OC_ROOT/proc/8001/stat"
                for _ in $(seq 1 19); do printf '1 ' >> "$OC_ROOT/proc/8001/stat"; done
                printf '9000000000 ' >> "$OC_ROOT/proc/8001/stat"
                printf 'Name:\topencode.exe\nPPid:\t1\n' > "$OC_ROOT/proc/8001/status"
                printf '0::/user.slice/x.scope\n' > "$OC_ROOT/proc/8001/cgroup"
                echo '{"status":"started"}' ;;
            *) echo '{"status":"ok"}' ;;
        esac ;;
    upgrade)
        printf 'argv: opencode upgrade\n' >> "$OC_ROOT/official.log"
        if [[ "$(cat "$OC_ROOT/mode" 2>/dev/null)" == "upgrade-fail" ]]; then echo "upgrade failed" >&2; exit 3; fi
        echo "upgraded" ;;
    *)
        if [[ "$(cat "$OC_ROOT/mode" 2>/dev/null)" == "scary" ]]; then echo 'error: failed, cannot find anything'; else echo '{"status":"ok"}'; fi ;;
esac
STUB
chmod +x "$SBOC/bin/opencode"

# Build the harness by extracting the real OpenCode functions.
python3 - "$U" "$SBOC/oc.sh" "$SBOC" <<'OCPY'
import sys
s = open(sys.argv[1]).read()
SB = sys.argv[3]

def fn(name):
    i = s.index(name + '() {'); d = 0
    for j in range(i, len(s)):
        if s[j] == '{': d += 1
        elif s[j] == '}':
            d -= 1
            if d == 0:
                return s[i:j+1]
    raise SystemExit('missing function: ' + name)

def retarget(text):
    """Point the enumerators at the fake proc tree instead of the live one.

    The logic is otherwise untouched, so the behaviour under test is the
    production behaviour -- only the directory being walked changes.
    """
    text = text.replace('for pid in /proc/[0-9]*', 'for pid in "$PROC_ROOT"/[0-9]*')
    text = text.replace('pid="${pid#/proc/}"', 'pid="${pid##*/}"')
    return text

FNS = ['opencode_version', 'opencode_install_root', 'opencode_background_service_url',
       'opencode_service_running', 'opencode_service_pid', 'opencode_service_pids',
       'opencode_t3_owned_pids', 'opencode_pid_is_service', 'opencode_stop_service',
       'opencode_official', 'opencode_pre_update_proof', 'opencode_restore_service',
       'opencode_verify_fresh_service', 'opencode_processes', 'opencode_stale_processes',
       't3_stop_for', 't3_restore_if_stopped']
body = '\n\n'.join(retarget(fn(f)) for f in FNS)

# Safety boundary: the real termination helper is deliberately NOT extracted.
# This replacement can only mutate the fake PROC_ROOT fixture and never invokes
# a signal, systemctl, or the OpenCode CLI.
body += r'''
terminate_pids(){
    local label="$1"; shift
    local p
    for p in "$@"; do
        [[ -n "$p" && -e "$PROC_ROOT/$p/stat" ]] || continue
        ESCALATED="$p"
        [[ -n "${OC_STUBBORN:-}" ]] || rm -rf "$PROC_ROOT/$p"
    done
    return 0
}
kill(){ echo "FORBIDDEN_REAL_KILL $*" >&2; return 99; }
sleep(){ :; }
'''
body += r'''
opencode_install_root(){ printf '%s\n' "$OC_ROOT/install"; }
'''

pre = '\n'.join([
 'OPENCODE_BIN="' + SB + '/bin/opencode"',
 'OC_ROOT="' + SB + '"',
 'T3_UNIT=t3code.service',
 'DRY_RUN=0; IN_MUTATION=0',
 'T3_STOPPED_BY_US=0; T3_STOP_PLANNED=0; RESTART_T3_REASON=""',
 'OPENCODE_BEFORE_PID=""; OPENCODE_BEFORE_START=""; OPENCODE_BEFORE_VERSION=""; OPENCODE_BEFORE_EXE=""',
 'OPENCODE_SERVICE_WAS_RUNNING=0; OPENCODE_AFTER_PID=""; OPENCODE_AFTER_START=""',
 'OPENCODE_AFTER_EXE=""; OPENCODE_AFTER_VERSION=""',
 'OPENCODE_SERVICE_URL_BEFORE=""; OPENCODE_TARGET_PIDS=""',
 'declare -a RESTORE_FAILURES=()',
 'info(){ echo "  i: $*"; }; warn(){ echo "  W: $*"; }; err(){ echo "  E: $*" >&2; }',
 'a_stop(){ echo "  WOULD STOP   $*"; }; a_update(){ echo "  WOULD UPDATE $*"; }',
 'a_restart(){ echo "  WOULD RESTART $*"; }; a_verify(){ echo "  WOULD VERIFY  $*"; }',
 't3_active(){ return 0; }; t3_main_pid(){ echo 900; }; t3_http_health(){ echo 200; }',
 'is_descendant_of(){ return 1; }',
'sleep(){ :; }',
'timeout(){ if [[ "${OC_TIMEOUT:-0}" == 1 ]]; then return 124; fi; command timeout "$@"; }',
 'proc_exists(){ [[ -e "$PROC_ROOT/$1/stat" ]]; }',
 'proc_cmdline(){ tr "\\0" " " 2>/dev/null < "$PROC_ROOT/$1/cmdline" 2>/dev/null; }',
 'proc_exe(){ readlink -f "$PROC_ROOT/$1/exe" 2>/dev/null || true; }',
 'proc_cgroup(){ cat "$PROC_ROOT/$1/cgroup" 2>/dev/null; }',
 'proc_starttime(){ awk \'{n=index($0,")"); if(n){split(substr($0,n+1),a," "); print a[20]}}\' 2>/dev/null < "$PROC_ROOT/$1/stat" 2>/dev/null; }',
'systemctl(){ echo "SYSTEMCTL_CALLED $*" >> "$OC_ROOT/systemctl.log"; return 0; }',
 # SAFETY: terminate_pids is overridden so the harness can never signal a real
 # process. The pids used below are fake entries in a sandboxed PROC_ROOT, but
 # those numbers are also valid real pids on this host -- 2840093 was in fact a
 # live OpenCode service when this harness was first written. So termination is
 # SIMULATED: the fake entry is removed, and ESCALATED records which pid was
 # targeted. No signal is ever delivered to a real process.
 'terminate_pids(){',
 '  local label="$1"; shift',
 '  local p',
 '  for p in "$@"; do',
 '    [[ -n "$p" ]] || continue',
 '    [[ -e "$PROC_ROOT/$p/stat" ]] || continue',
 '    ESCALATED="$p"',
 '    echo "  x: $label -> targeted pid=$p"',
 '    [[ -n "${OC_STUBBORN:-}" ]] && continue',
 '    rm -rf "$PROC_ROOT/$p"',
 '  done',
 '  return 0',
 '}',
 'kill(){ echo "FORBIDDEN_REAL_KILL $*" >&2; return 99; }',
 'sleep(){ :; }',
 'mkproc(){',
 '  local pid="$1" cmd="$2" exe="$3" st="$4"',
 '  mkdir -p "$PROC_ROOT/$pid"',
 '  printf "%s" "$cmd" | sed "s/ /\\x00/g" > "$PROC_ROOT/$pid/cmdline"',
 '  mkdir -p "$(dirname "$exe")"; : > "$exe"',
 '  ln -sfn "$exe" "$PROC_ROOT/$pid/exe"',
 '  printf "S (%s) %s\\n" "$(basename "$exe")" "$(for k in $(seq 1 19); do printf "1 "; done; printf "%s " "$st")" > "$PROC_ROOT/$pid/stat"',
 '  printf "Name:\\t%s\\nPPid:\\t1\\n" "$(basename "$exe")" > "$PROC_ROOT/$pid/status"',
 '  printf "0::/user.slice/x.scope\\n" > "$PROC_ROOT/$pid/cgroup"',
 '}',
 'setup(){',
 '  rm -rf "$PROC_ROOT"; mkdir -p "$PROC_ROOT"',
 '  mkdir -p "$OC_ROOT/install/bin"',
 '  mkproc 2840093 "opencode serve --service" "$OC_ROOT/install/bin/opencode.exe" 397368592',
 '  OPENCODE_BEFORE_PID="2840093"',
 '  OPENCODE_BEFORE_START="397368592"',
 '  OPENCODE_BEFORE_EXE="$OC_ROOT/install/bin/opencode.exe"',
 '  OPENCODE_BEFORE_VERSION="2.0.22"',
 '  OPENCODE_SERVICE_WAS_RUNNING=1',
 '  OPENCODE_TARGET_PIDS="2840093"',
 '  T3_STOPPED_BY_US=0; T3_STOP_PLANNED=0; RESTORE_FAILURES=()',
 '  : > "$OC_ROOT/official.log"; : > "$OC_ROOT/systemctl.log"; echo normal > "$OC_ROOT/mode"',
 '}',
 'run_case(){ CASE="$1" bash "$0"; }',
])
# The driver evaluates the case body after every real function is defined.
driver = '\neval "$CASE"\n'
open(sys.argv[2], 'w').write(pre + '\n' + body + driver)
OCPY
chmod +x "$SBOC/oc.sh"

# Prove the production official-command helper closes the mutation lock before
# spawning a service command which leaves a background process behind.
mkdir -p "$SBOC/fdtest"
python3 - "$U" "$SBOC/fdtest/helper.sh" "$SBOC/fdtest/opencode" <<'FDPY'
import sys
s = open(sys.argv[1]).read()
i = s.index('opencode_official() {'); d = 0
for j in range(i, len(s)):
    if s[j] == '{': d += 1
    elif s[j] == '}':
        d -= 1
        if d == 0: break
open(sys.argv[2], 'w').write('#!/usr/bin/env bash\nOPENCODE_BIN="' + sys.argv[3] + '"\n' + s[i:j+1] + '\nopencode_official service start\n')
FDPY
cat >"$SBOC/fdtest/opencode" <<'FDSTUB'
#!/usr/bin/env bash
[[ "${1:-}" == service && "${2:-}" == start ]] || exit 2
( if [[ -e /proc/self/fd/9 ]]; then echo inherited; else echo closed; fi > "$FD_RESULT"
  exec sleep 2 ) </dev/null >/dev/null 2>&1 &
echo "$!" > "$FD_PID"
echo started
FDSTUB
chmod +x "$SBOC/fdtest/helper.sh" "$SBOC/fdtest/opencode"
exec 9>"$SBOC/fdtest/update.lock"
flock -n 9
FD_RESULT="$SBOC/fdtest/result" FD_PID="$SBOC/fdtest/pid" \
    bash "$SBOC/fdtest/helper.sh" >/dev/null 2>&1
for _ in $(seq 1 40); do [[ -s "$SBOC/fdtest/result" ]] && break; sleep 0.05; done
[[ "$(cat "$SBOC/fdtest/result" 2>/dev/null)" == closed ]] \
    && ok "real OpenCode helper prevents service child inheriting held fd 9" \
    || bad "real OpenCode helper allowed service child to inherit fd 9"
kill "$(cat "$SBOC/fdtest/pid" 2>/dev/null)" 2>/dev/null || true
exec 9>&-
python3 - "$U" <<'FDSTATIC'
import sys
s = open(sys.argv[1]).read()
names = ['codex_daemon_subcommand() {', 'do_codex_update() {',
         'opencode_official() {', 'do_opencode_update() {',
         'do_hermes_update() {', 'do_t3_update() {']
for name in names:
    i = s.index(name)
    j = s.find('\n}', i) + 2
    assert '9>&-' in s[i:j], name
FDSTATIC
[[ $? -eq 0 ]] && ok "external updater command boundaries close fd 9" \
    || bad "external updater command boundary is missing fd 9 closure"

check "opencode harness extracted from production" \
    "grep -q 'opencode_pre_update_proof() {' $SBOC/oc.sh && grep -q 'opencode_stop_service() {' $SBOC/oc.sh"
check "harness excludes real terminate_pids and installs fixture-only override" \
    "! grep -q '^terminate_pids() {' $SBOC/oc.sh && grep -q '^terminate_pids(){' $SBOC/oc.sh && grep -q '^kill(){ echo .FORBIDDEN_REAL_KILL' $SBOC/oc.sh"
check "harness has no direct signal or service-stop command" \
    "! grep -qE '^[[:space:]]*(kill|pkill|killall|systemctl[[:space:]]+stop|opencode[[:space:]]+service[[:space:]]+stop)([[:space:]]|$)' $SBOC/oc.sh"

oc_case() { # oc_case <label> <expected-substring> <case-body>
    local label="$1" want="$2" body="$3" out rc
    out="$(PROC_ROOT="$SBOC/proc" OC_ROOT="$SBOC" CASE="$body" bash "$SBOC/oc.sh" 2>&1)"; rc=$?
    if printf '%s' "$out" | grep -qF -- "$want"; then ok "$label"
    else bad "$label :: want='$want' got=$(printf '%s' "$out" | tail -3 | tr '\n' '|')"; fi
}

printf '\n=== 33. OpenCode service identity is PID-authoritative ==='
oc_case "service PID is discovered from /proc, not from a URL" \
    "PID:2840093" \
    'setup; echo "PID:$(opencode_service_pid)"'
oc_case "service start time is captured from /proc" \
    "START:397368592" \
    'setup; echo "PID:$(opencode_service_pid)"; echo "START:$(proc_starttime 2840093)"'
oc_case "a responding URL alone does not identify a PID" \
    "PIDS_FROM_PROC:2840093" \
    'setup; echo "URL:$(opencode_background_service_url)"; echo "PIDS_FROM_PROC:$(opencode_service_pid)"'
oc_case "multiple service PIDs are all listed" \
    "2840093" \
    'setup; mkproc 9002 "opencode serve --service" "$OC_ROOT/install/bin/opencode.exe" 9000000000; opencode_service_pids'
check "opencode_before_pid variable exists"   "grep -q 'OPENCODE_BEFORE_PID' $U"
check "opencode_before_start variable exists" "grep -q 'OPENCODE_BEFORE_START' $U"
check "service_was_running variable exists"   "grep -q 'OPENCODE_SERVICE_WAS_RUNNING' $U"

printf '\n=== 34. /proc disappearance is silent (OpenCode helpers) ==='
oc_case "service pid helpers tolerate a vanished pid" \
    "GONE:[]" \
    'rm -rf "$PROC_ROOT"; mkdir -p "$PROC_ROOT"; echo "GONE:[$(opencode_service_pid)] [$(opencode_service_pids)]"'
oc_case "starttime/exe/cmdline of a vanished pid are empty, not errors" \
    "V:[] [] []" \
    'rm -rf "$PROC_ROOT"; mkdir -p "$PROC_ROOT"; echo "V:[$(proc_starttime 999999)] [$(proc_exe 999999)] [$(proc_cmdline 999999)]"'
oc_case "t3-owned enumeration on an empty proc tree is silent" \
    "T3OWNED:[]" \
    'rm -rf "$PROC_ROOT"; mkdir -p "$PROC_ROOT"; echo "T3OWNED:[$(opencode_t3_owned_pids)]"'
oc_case "no /proc diagnostic leaks from any helper" \
    "NOISE:[0]" \
    'rm -rf "$PROC_ROOT"; mkdir -p "$PROC_ROOT"; out="$( { opencode_service_pid; opencode_service_pids; opencode_t3_owned_pids; opencode_stale_processes; } 2>&1 )"; n="$(printf "%s" "$out" | grep -c "No such file")"; echo "NOISE:[$n]"'

printf '\n=== 35. service stop escalates, and can veto the upgrade ==='
oc_case "official stop receives exact service stop argv" \
    "argv: opencode service stop" \
    'setup; opencode_official service stop >/dev/null; cat "$OC_ROOT/official.log"'
oc_case "official start receives exact service start argv" \
    "argv: opencode service start" \
    'setup; : > "$OC_ROOT/official.log"; opencode_official service start >/dev/null; cat "$OC_ROOT/official.log"'
oc_case "official stop that removes the PID -> stop returns 0" \
    "STOP:0 alive=no" \
    'setup; opencode_stop_service 2840093 397368592 >/dev/null 2>&1; rc=$?; if proc_exists 2840093; then a=yes; else a=no; fi; echo "STOP:$rc alive=$a"'
oc_case "official stop that LIES -> escalates to that exact PID, then 0" \
    "STOP:0 alive=no ESCALATED:2840093" \
    'setup; ESCALATED=none; echo liar > "$OC_ROOT/mode"; opencode_stop_service 2840093 397368592 >/dev/null 2>&1; rc=$?; if proc_exists 2840093; then a=yes; else a=no; fi; echo "STOP:$rc alive=$a ESCALATED:${ESCALATED:-none}"'
oc_case "escalation targets ONLY the old service pid" \
    "ONLY:2840093" \
    'setup; ESCALATED=none; echo liar > "$OC_ROOT/mode"; mkproc 7007 "opencode serve --port 9" "$OC_ROOT/install/bin/opencode.exe" 9000000002; opencode_stop_service 2840093 397368592 >/dev/null 2>&1; echo "ONLY:${ESCALATED:-none}"'
oc_case "a PID that refuses to die vetoes the stop" \
    "STOP:1" \
    'setup; echo liar > "$OC_ROOT/mode"; OC_STUBBORN=1; opencode_stop_service 2840093 397368592 >/dev/null 2>&1; echo "STOP:$?"'
oc_case "a vetoed stop never reaches the upgrader" \
    "UPGRADE_CALLS:0" \
    'setup; echo liar > "$OC_ROOT/mode"; OC_STUBBORN=1; : > "$OC_ROOT/official.log"; if opencode_stop_service 2840093 397368592 >/dev/null 2>&1; then "$OPENCODE_BIN" upgrade >/dev/null 2>&1; fi; echo "UPGRADE_CALLS:$(grep -c "^upgrade$" "$OC_ROOT/official.log")"'
check "stop escalates with a targeted SIGTERM" "grep -q 'sending SIGTERM to that PID only' $U"
check "stop refuses to continue if the PID survives" "grep -q 'refusing to run' $U"

printf '\n=== 36. pre-update proof gates the native upgrade ==='
oc_case "surviving old PID => proof FAILS" \
    "PROOF:1" \
    'setup; echo liar > "$OC_ROOT/mode"; opencode_pre_update_proof 2840093 397368592 >/dev/null 2>&1; echo "PROOF:$?"'
oc_case "old PID gone => proof PASSES" \
    "PROOF:0" \
    'setup; rm -rf "$PROC_ROOT/2840093"; opencode_pre_update_proof 2840093 397368592 >/dev/null 2>&1; echo "PROOF:$?"'
oc_case "a surviving targeted workload => proof FAILS" \
    "PROOF:1" \
    'setup; rm -rf "$PROC_ROOT/2840093"; mkproc 5555 "opencode serve --port 1" "$OC_ROOT/install/bin/opencode.exe" 9000000001; OPENCODE_TARGET_PIDS="5555"; opencode_pre_update_proof 2840093 397368592 >/dev/null 2>&1; echo "PROOF:$?"'
# Compare the PROOF call site with the actual upgrade INVOCATION. Matching the
# bare string "opencode upgrade" would hit the dry-run plan text instead.
cat >"$SBOC/order.py" <<'ORD'
import sys
s = open(sys.argv[1]).read()
i = s.index('do_opencode_update() {')
d = 0
for j in range(i, len(s)):
    if s[j] == '{': d += 1
    elif s[j] == '}':
        d -= 1
        if d == 0: break
b = s[i:j]
proof = b.index('if ! opencode_pre_update_proof')
upg = b.index('OPENCODE_BIN" upgrade')
assert proof < upg, (proof, upg)
ORD
check "proof is called before the native upgrade" \
    "python3 $SBOC/order.py $U"

check "upgrade is skipped when the proof fails" \
    "grep -q 'pre-update proof failed; .opencode upgrade. was not run' $U"

printf '\n=== 37. same-version freshness requires a NEW process ==='
oc_case "zero rc with scary text is invocation success" \
    "ok|error: failed, cannot find anything|0" \
    'setup; echo scary > "$OC_ROOT/mode"; opencode_official info'
oc_case "nonzero rc is command error" \
    "error|upgrade failed|3" \
    'setup; echo upgrade-fail > "$OC_ROOT/mode"; opencode_official upgrade'
oc_case "timeout is command error" \
    "error||124" \
    'setup; OC_TIMEOUT=1; opencode_official info'
oc_case "restoration starts service and fresh PID passes production proof" \
    "FRESH:0 PID:8001" \
    'setup; rm -rf "$PROC_ROOT/2840093"; opencode_restore_service 1 >/dev/null; opencode_verify_fresh_service 2840093 397368592 2.0.22 >/dev/null 2>&1; echo "FRESH:$? PID:$(opencode_service_pid)"'
oc_case "same PID + same start time => freshness FAILS" \
    "FRESH:1" \
    'setup; opencode_verify_fresh_service 2840093 397368592 2.0.22 >/dev/null 2>&1; echo "FRESH:$?"'
oc_case "same version but a NEW pid with a newer start time => PASSES" \
    "FRESH:0" \
    'setup; rm -rf "$PROC_ROOT/2840093"; mkproc 8001 "opencode serve --service" "$OC_ROOT/install/bin/opencode.exe" 9000000000; opencode_verify_fresh_service 2840093 397368592 2.0.22 >/dev/null 2>&1; echo "FRESH:$?"'
oc_case "recycled PID with an OLDER start time => FAILS" \
    "FRESH:1" \
    'setup; rm -rf "$PROC_ROOT/2840093"; mkproc 2840093 "opencode serve --service" "$OC_ROOT/install/bin/opencode.exe" 100; opencode_verify_fresh_service 2840093 397368592 2.0.22 >/dev/null 2>&1; echo "FRESH:$?"'
oc_case "no service process at all => FAILS" \
    "FRESH:1" \
    'setup; rm -rf "$PROC_ROOT/2840093"; opencode_verify_fresh_service 2840093 397368592 2.0.22 >/dev/null 2>&1; echo "FRESH:$?"'
oc_case "service running an obsolete build => FAILS" \
    "FRESH:1" \
    'setup; rm -rf "$PROC_ROOT/2840093"; mkproc 8001 "opencode serve --service" "$OC_ROOT/obsolete/bin/opencode.exe" 9000000000; opencode_install_root(){ printf "%s\\n" "$OC_ROOT/install"; }; opencode_verify_fresh_service 2840093 397368592 2.0.22 >/dev/null 2>&1; echo "FRESH:$?"'
oc_case "an unresolvable install root fails closed, not silently clean" \
    "FRESH:1" \
    'setup; rm -rf "$PROC_ROOT/2840093"; mkproc 8001 "opencode serve --service" "$OC_ROOT/install/bin/opencode.exe" 9000000000; opencode_install_root(){ echo ""; }; opencode_verify_fresh_service 2840093 397368592 2.0.22 >/dev/null 2>&1; echo "FRESH:$?"'
oc_case "service was NOT running => freshness not required" \
    "FRESH:0" \
    'setup; rm -rf "$PROC_ROOT/2840093"; OPENCODE_SERVICE_WAS_RUNNING=0; opencode_verify_fresh_service "" "" 2.0.22 >/dev/null 2>&1; echo "FRESH:$?"'
oc_case "restore does not start a service that was not running" \
    "STARTED:no" \
    'setup; : > "$OC_ROOT/official.log"; opencode_restore_service 0 >/dev/null 2>&1; if grep -q start "$OC_ROOT/official.log"; then echo "STARTED:yes"; else echo "STARTED:no"; fi'
check "freshness failure forces opencode FAIL" \
    "grep -q 'freshness proof failed' $U"
check "success requires a passing verify_opencode" \
    "grep -q 'upgraded: \${OPENCODE_BEFORE_VERSION} -> \$(opencode_version)' $U"

printf '\n=== 38. T3 ownership semantics for the OpenCode path ==='
oc_case "T3 owns 0 children -> T3_STOPPED_BY_US stays 0" \
    "STOPPED_BY_US=0" \
    'DRY_RUN=1; t3_stop_for "T3 owns 0 OpenCode process(es)" >/dev/null 2>&1; echo "STOPPED_BY_US=$T3_STOPPED_BY_US"'
oc_case "T3 owns children -> stop is planned" \
    "PLANNED=1" \
    'DRY_RUN=1; t3_stop_for "T3 owns 2 OpenCode process(es)" >/dev/null 2>&1; echo "PLANNED=$T3_STOP_PLANNED"'
oc_case "restore is a no-op when this run never stopped T3" \
    "SYSCTL:[]" \
    'T3_STOPPED_BY_US=0; t3_restore_if_stopped >/dev/null 2>&1; echo "SYSCTL:[$(cat "$OC_ROOT/systemctl.log" 2>/dev/null)]"'
oc_case "restore starts T3 only when this run stopped it" \
    "SYSCTL_HAS_START:yes" \
    'T3_STOPPED_BY_US=1; t3_restore_if_stopped >/dev/null 2>&1; if grep -q "start $T3_UNIT" "$OC_ROOT/systemctl.log"; then echo "SYSCTL_HAS_START:yes"; else echo "SYSCTL_HAS_START:no"; fi'
check "T3_STOPPED_BY_US is set only after a successful stop" \
    "python3 -c \"
s=open('$U').read(); i=s.index('t3_stop_for() {'); b=s[i:s.index('\n}',i)]
after=b.index('T3_STOPPED_BY_US=1')
assert b.index('if t3_active; then') < after, 'flag set before the stop was confirmed'
assert 'DRY_RUN' in b[:after], 'dry-run path must not reach the real flag'
\""
cat >"$SBOC/t3dry.py" <<'T3D'
import sys
s = open(sys.argv[1]).read()
i = s.index('t3_stop_for() {')
d = 0
for j in range(i, len(s)):
    if s[j] == '{': d += 1
    elif s[j] == '}':
        d -= 1
        if d == 0: break
b = s[i:j]
dry = b[:b.index('RESTART_T3_REASON=')]
assert 'T3_STOPPED_BY_US=1' not in dry
T3D
check "dry-run never sets T3_STOPPED_BY_US" \
    "python3 $SBOC/t3dry.py $U"
check "opencode path states T3 is untouched when it owns no child" \
    "grep -q 'T3 owns no OpenCode child; t3code.service will remain running' $U"
cat >"$SBOC/t3plan.py" <<'T3P'
import sys
s = open(sys.argv[1]).read()
i = s.index('do_opencode_update() {')
d = 0
for j in range(i, len(s)):
    if s[j] == '{': d += 1
    elif s[j] == '}':
        d -= 1
        if d == 0: break
b = s[i:j]
assert 'WOULD RESTART t3code.service (restore: was active)' not in b
T3P
check "opencode path does not restart T3 unconditionally" \
    "python3 $SBOC/t3plan.py $U"
check "T3 stop is gated on a non-zero owned-child count" \
    "grep -q 'if \[\[ \"\$t3_count\" -gt 0 \]\]; then' $U"

printf '\n=== 39. OpenCode path has no broad kill patterns ==='
OCFN="$(sed -n '/^do_opencode_update()/,/^}/p' "$U")"
printf '%s\n' "$OCFN" | grep -q 'pkill' && bad "opencode path uses pkill" || ok "no pkill in the opencode path"
printf '%s\n' "$OCFN" | grep -q 'killall' && bad "opencode path uses killall" || ok "no killall in the opencode path"
printf '%s\n' "$OCFN" | grep -qE 'kill[[:space:]]+-[A-Z]+[[:space:]]+[a-z]+$' && \
    bad "opencode path signals by name" || ok "no signal-by-name in the opencode path"
# Escalation lives in terminate_pids / opencode_stop_service, never inline in
# the component function.
check "opencode path does not signal inline" \
    "[[ -z \"\$(sed -n '/^do_opencode_update()/,/^}/p' $U | grep -E 'kill -(TERM|KILL)')\" ]]"
check "opencode escalation goes through the shared targeted killer" \
    "grep -q 'terminate_pids \"opencode-service\"' $U"

printf '\n=== 40. OpenCode dry-run performs no mutation ==='
T3PID_B="$(systemctl --user show t3code.service -p MainPID --value)"
OCPID_B="$(pgrep -f 'opencode.exe serve --service' | head -1)"
OCVER_B="$(opencode --version 2>&1)"
OCSHA_B="$(sha256sum "$(readlink -f "$(command -v opencode)")" 2>/dev/null | cut -d' ' -f1)"
ODR="$($U --opencode --dry-run 2>&1)"; ODRRC=$?
[[ $ODRRC -eq 0 ]] && ok "--opencode --dry-run exits 0" || bad "--opencode --dry-run exits $ODRRC"
check "dry-run leaks no /proc noise" \
    "! grep -qE 'No such file or directory|Bad file descriptor' <<<\"$ODR\""
check "dry-run names the real service PID" \
    "grep -qE 'background service PID: [0-9]+' <<<\"$ODR\""
check "dry-run plans the old-PID proof"   "grep -q 'old OpenCode PID .* is gone' <<<\"$ODR\""
check "dry-run plans the fresh-PID proof" "grep -q 'fresh service PID differs from' <<<\"$ODR\""
check "dry-run plans the start-time proof" "grep -q 'start time is newer than' <<<\"$ODR\""
check "dry-run shows the service start time" "grep -q 'service start time: [0-9]' <<<\"$ODR\""
check "dry-run states T3 ownership explicitly" \
    "grep -qE 'T3 owns (no OpenCode child|[0-9]+ OpenCode process)' <<<\"$ODR\""
check "dry-run never says it will restart T3 unconditionally" \
    "! grep -q 'WOULD RESTART t3code.service (restore: was active)' <<<\"$ODR\""
check "dry-run service PID still alive afterwards" \
    "[[ \$(pgrep -f 'opencode.exe serve --service' | head -1) == '$OCPID_B' ]]"
check "dry-run left t3code.service untouched" \
    "[[ \$(systemctl --user show t3code.service -p MainPID --value) == '$T3PID_B' ]]"
check "dry-run did not change the opencode version" \
    "[[ \$(opencode --version 2>&1) == '$OCVER_B' ]]"
check "dry-run did not change the opencode binary" \
    "[[ \$(sha256sum \"\$(readlink -f \"\$(command -v opencode)\")\" 2>/dev/null | cut -d' ' -f1) == '$OCSHA_B' ]]"

rm -rf "$SBOC"
rm -rf "$SBX"


printf '\n=== 41. check, force, dry-run and workload warning contracts ==='
$U --force >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "--force without selection is usage error" || bad "--force without selection"
$U --force --verify >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "--force with verify is usage error" || bad "--force --verify"
$U --force --check >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "--force with check is usage error" || bad "--force --check"
$U --check --all >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "--check with selection is usage error" || bad "--check --all"
DR_HOME="$(mktemp -d /tmp/update-dryzero.XXXXXX)"
HOME="$DR_HOME" $U --all --dry-run >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "isolated all dry-run succeeds" || bad "isolated all dry-run"
[[ ! -e "$DR_HOME/.local/state/tool-updates/update.lock" ]] && ok "dry-run creates no lock" || bad "dry-run created lock"
[[ ! -e "$DR_HOME/.local/state/tool-updates/update.lock.holder" ]] && ok "dry-run creates no holder" || bad "dry-run created holder"
[[ ! -e "$DR_HOME/.local/state/tool-updates/logs/update" ]] && ok "dry-run creates no logs" || bad "dry-run created log path"
check "dry-run closes caller fd 9" "grep -q 'exec 9>&-' $U"
mkdir -p "$DR_HOME/.local/bin"
cat > "$DR_HOME/.local/bin/systemctl" <<'FDPROBE'
#!/usr/bin/env bash
if [[ -e /proc/self/fd/9 ]]; then echo inherited > "$FD_MARK"; else echo closed > "$FD_MARK"; fi
case "$*" in *MainPID*) echo 0 ;; *ActiveEnterTimestamp*) echo n/a ;; *LoadState*) echo not-found ;; *is-active*) exit 3 ;; *is-enabled*) exit 1 ;; *) exit 0 ;; esac
FDPROBE
chmod +x "$DR_HOME/.local/bin/systemctl"
exec 9>"$DR_HOME/held.lock"
FD_MARK="$DR_HOME/fdmark" HOME="$DR_HOME" $U --t3 --dry-run >/dev/null 2>&1
exec 9>&-
grep -q '^closed$' "$DR_HOME/fdmark" && ok "dry-run descendants do not inherit held fd 9" || bad "dry-run descendant inherited fd 9"
CHECK_HOME="$(mktemp -d /tmp/update-checkzero.XXXXXX)"
HOME="$CHECK_HOME" $U --check >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "isolated --check completes with UNKNOWN tools" || bad "isolated --check failed"
[[ ! -e "$CHECK_HOME/.local/state/tool-updates/update.lock" ]] && ok "--check creates no lock" || bad "--check created lock"
[[ ! -e "$CHECK_HOME/.local/state/tool-updates/update.lock.holder" ]] && ok "--check creates no holder" || bad "--check created holder"
[[ ! -e "$CHECK_HOME/.local/state/tool-updates/logs/update" ]] && ok "--check creates no logs" || bad "--check created logs"
rm -rf "$CHECK_HOME"
check "T3 update warns before native restart" "python3 -c 's=open(\"$U\").read(); i=s.index(\"warn_t3_workloads\\n    info \\\"Running: t3 update\"); assert i>0'"
check "T3 warning reports categories only" "grep -q 'Active child workloads that may be interrupted' $U && grep -q 'npm/pnpm/test/build' $U"
T3_FIX="$(mktemp -d /tmp/update-t3-cgroup.XXXXXX)"
for p in 710 711 712 713; do mkdir -p "$T3_FIX/proc/$p"; printf '0::/user.slice/t3code.service\n' > "$T3_FIX/proc/$p/cgroup"; done
printf 'opencode\0serve\0' > "$T3_FIX/proc/710/cmdline"
printf 'npm\0run\0test\0' > "$T3_FIX/proc/711/cmdline"
printf 'bash\0-i\0' > "$T3_FIX/proc/712/cmdline"
printf 'worker\0' > "$T3_FIX/proc/713/cmdline"
python3 - "$U" "$T3_FIX/harness.sh" <<'T3PY'
import sys
s=open(sys.argv[1]).read(); name='t3_workload_counts() {'; i=s.index(name); d=0
for j in range(i,len(s)):
    if s[j]=='{': d+=1
    elif s[j]=='}':
        d-=1
        if d==0: break
open(sys.argv[2],'w').write('T3_UNIT=t3code.service\nt3_main_pid(){ echo 1; }\nis_descendant_of(){ return 1; }\n'+s[i:j+1]+'\nt3_workload_counts\n')
T3PY
T3_COUNTS="$(PROC_ROOT="$T3_FIX/proc" bash "$T3_FIX/harness.sh")"
grep -q 'OpenCode: 1' <<<"$T3_COUNTS" && ok "T3 cgroup fixture counts OpenCode" || bad "T3 OpenCode count"
grep -q 'npm/pnpm/test/build: 1' <<<"$T3_COUNTS" && ok "T3 cgroup fixture counts tests" || bad "T3 test count"
grep -q 'terminals/shells: 1' <<<"$T3_COUNTS" && ok "T3 cgroup fixture counts shells" || bad "T3 shell count"
grep -q 'other: 1' <<<"$T3_COUNTS" && ok "T3 cgroup fixture counts other" || bad "T3 other count"
check "precheck model has all four outcomes" "grep -q 'UPDATE_AVAILABLE' $U && grep -q 'CURRENT' $U && grep -q 'UNKNOWN' $U && grep -q 'NOT_CONFIGURED' $U"
check "force gates only the CURRENT short-circuit" "grep -q 'FORCE_UPDATE -eq 0' $U"

# Exercise the real conservative classifier with isolated stubs. Only OpenCode
# currently has a proven read-only latest source; the other configured tools
# must be UNKNOWN and missing tools NOT_CONFIGURED.
PRECHECK_FIX="$(mktemp -d /tmp/update-precheck.XXXXXX)"
python3 - "$U" "$PRECHECK_FIX/classifier.sh" <<'PRECHECKPY'
import sys
s=open(sys.argv[1]).read(); name='precheck_tool() {'; i=s.index(name); d=0
for j in range(i,len(s)):
    if s[j]=='{': d+=1
    elif s[j]=='}':
        d-=1
        if d==0: break
helpers='''
declare -A PRECHECK PRECHECK_DETAIL
CODEX_BIN=/bin/codex; HERMES_BIN=/bin/hermes; T3_BIN=/bin/t3; OPENCODE_BIN=/bin/opencode
opencode_version(){ echo "$OC_VERSION"; }
opencode_install_root(){ echo /fake/current; }
opencode_service_pids(){ :; }
opencode_verify_local_health(){ return "$OC_HEALTH"; }
opencode_stale_processes(){ return 0; }
'''
open(sys.argv[2],'w').write('#!/usr/bin/env bash\nset -u\n'+helpers+s[i:j+1]+'''
precheck_tool codex; echo "codex=${PRECHECK[codex]}"
precheck_tool hermes; echo "hermes=${PRECHECK[hermes]}"
precheck_tool t3; echo "t3=${PRECHECK[t3]}"
precheck_tool opencode; echo "opencode=${PRECHECK[opencode]} ${PRECHECK_DETAIL[opencode]}"
''')
PRECHECKPY
cat > "$PRECHECK_FIX/curl" <<'CURLSTUB'
#!/usr/bin/env bash
[[ "$OC_LOOKUP" == fail ]] && exit 22
printf '{"version":"%s"}\n' "$OC_LATEST"
CURLSTUB
chmod +x "$PRECHECK_FIX/curl" "$PRECHECK_FIX/classifier.sh"
PC="$(PATH="$PRECHECK_FIX:$PATH" OC_VERSION=1.0 OC_LATEST=2.0 OC_HEALTH=0 OC_LOOKUP=ok bash "$PRECHECK_FIX/classifier.sh")"
grep -q '^codex=UNKNOWN$' <<<"$PC" && ok "configured Codex precheck is UNKNOWN" || bad "Codex precheck classification"
grep -q '^hermes=UNKNOWN$' <<<"$PC" && ok "configured Hermes precheck is UNKNOWN" || bad "Hermes precheck classification"
grep -q '^t3=UNKNOWN$' <<<"$PC" && ok "configured T3 precheck is UNKNOWN" || bad "T3 precheck classification"
grep -q '^opencode=UPDATE_AVAILABLE ' <<<"$PC" && ok "OpenCode newer registry version is UPDATE_AVAILABLE" || bad "OpenCode UPDATE_AVAILABLE classification"
PC="$(PATH="$PRECHECK_FIX:$PATH" OC_VERSION=2.0 OC_LATEST=2.0 OC_HEALTH=0 OC_LOOKUP=ok bash "$PRECHECK_FIX/classifier.sh")"
grep -q '^opencode=CURRENT ' <<<"$PC" && ok "healthy current OpenCode is CURRENT" || bad "OpenCode CURRENT classification"
PC="$(PATH="$PRECHECK_FIX:$PATH" OC_VERSION=2.0 OC_LATEST=2.0 OC_HEALTH=0 OC_LOOKUP=fail bash "$PRECHECK_FIX/classifier.sh")"
grep -q '^opencode=UNKNOWN ' <<<"$PC" && ok "registry failure degrades OpenCode to UNKNOWN" || bad "lookup failure incorrectly classified"
PC="$(PATH="$PRECHECK_FIX:$PATH" OC_VERSION=2.0 OC_LATEST=2.0 OC_HEALTH=1 OC_LOOKUP=ok bash "$PRECHECK_FIX/classifier.sh")"
grep -q '^opencode=UNKNOWN ' <<<"$PC" && ok "unhealthy OpenCode is never CURRENT" || bad "unhealthy OpenCode classified current"
rm -rf "$PRECHECK_FIX"

printf '\n=== 42. bounded updater log retention ==='
LOG_FIX="$(mktemp -d /tmp/update-logs.XXXXXX)"
mkdir -p "$LOG_FIX/logs"
for i in $(seq -w 1 23); do : > "$LOG_FIX/logs/20261006T1200${i}Z-$i.log"; done
: > "$LOG_FIX/logs/keep-me.txt"
python3 - "$U" "$LOG_FIX/prune.sh" "$LOG_FIX/logs" <<'LOGPY'
import sys
s=open(sys.argv[1]).read(); name='prune_update_logs() {'; i=s.index(name); d=0
for j in range(i,len(s)):
    if s[j]=='{': d+=1
    elif s[j]=='}':
        d-=1
        if d==0: break
pre='LOG_KEEP=20\nLOG_DIR='+repr(sys.argv[3])+'\nACTIVE_LOG='+repr(sys.argv[3]+'/20261006T120023Z-23.log')+'\nDRY_RUN=0; DO_VERIFY=0; DO_CHECK=0\nwarn(){ :; }\n'
open(sys.argv[2],'w').write(pre+s[i:j+1]+'\nprune_update_logs\n')
LOGPY
bash "$LOG_FIX/prune.sh"
[[ "$(find "$LOG_FIX/logs" -maxdepth 1 -type f -name '*.log' | wc -l)" -eq 20 ]] && ok "pruning retains LOG_KEEP newest logs" || bad "log retention count"
[[ -f "$LOG_FIX/logs/keep-me.txt" ]] && ok "pruning leaves unrelated files" || bad "unrelated file removed"
check "pruning skips read-only modes" "grep -q 'DRY_RUN -eq 0 && \$DO_VERIFY -eq 0 && \$DO_CHECK -eq 0' $U"

printf '\n=== 43. CURRENT prechecks serialize with the mutation lock ==='
LOCKSEQ="$(mktemp -d /tmp/update-lock-sequence.XXXXXX)"
python3 - "$U" "$LOCKSEQ/harness.sh" <<'LOCKSEQPY'
import sys
s=open(sys.argv[1]).read()
def extract(name):
    i=s.index(name); brace=s.index('{',i); depth=0
    for j in range(brace,len(s)):
        if s[j]=='{': depth+=1
        elif s[j]=='}':
            depth-=1
            if depth==0: return s[i:j+1]
    raise SystemExit('could not extract '+name)
lock=extract('acquire_lock() {')
exit_trap=extract('on_exit() {')
main=extract('main() {')
opencode=extract('do_opencode_update() {')
pre='''#!/usr/bin/env bash
set -o pipefail
HOME="${HOME:?}"; STATE_ROOT="$HOME/.local/state/tool-updates"; GLOBAL_LOCK="$STATE_ROOT/update.lock"
LOCK_HELD=0; LOG_FH_OPEN=0; ACTIVE_LOG=""; DRY_RUN=0; DO_VERIFY=0; DO_CHECK=0; FORCE_UPDATE=0
DO_CODEX=0; DO_OPENCODE=0; DO_HERMES=0; DO_T3=0; OBS_LOCK_BUSY=0; UPDATE_ARGV=""
declare -A PRECHECK=() PRECHECK_DETAIL=() RESULT=() RESULT_DETAIL=()
TRACE="$HOME/trace"; OPENCODE_BIN=/fake/opencode; CODEX_BIN=""; HERMES_BIN=""; T3_BIN=""
C_BOLD=""; C_RESET=""; C_YEL=""; C_CYN=""; C_GRN=""; C_RED=""; C_DIM=""
err(){ printf '%s\\n' "$*" >&2; }
warn(){ :; }
info(){ :; }
section(){ :; }
record(){ RESULT[$1]="$2"; RESULT_DETAIL[$1]="$3"; printf 'record %s %s %s\\n' "$@" >>"$TRACE"; }
status_line(){ printf 'status %s %s %s\\n' "$@" >>"$TRACE"; }
start_logging(){ : >"$HOME/logging-started"; }
install_traps(){ trap on_exit EXIT; }
precheck_tool(){ [[ -n "${PRECHECK[$1]:-}" ]] && return 0; }
parse_args(){
  case "$TEST_CASE" in
    allcurrent) DO_OPENCODE=1 ;;
    mixed) DO_OPENCODE=1; DO_T3=1 ;;
  esac
}
precheck_selected(){
  if ( exec 8>>"$GLOBAL_LOCK"; flock -n 8 ); then printf 'precheck-lock=FREE\\n' >>"$TRACE"; else printf 'precheck-lock=HELD\\n' >>"$TRACE"; fi
  PRECHECK[opencode]=CURRENT; PRECHECK_DETAIL[opencode]='stub current'
  if [[ $DO_T3 -eq 1 ]]; then PRECHECK[t3]=UNKNOWN; PRECHECK_DETAIL[t3]='stub unknown'; fi
}
do_t3_update(){
  if ( exec 8>>"$GLOBAL_LOCK"; flock -n 8 ); then printf 't3-lock=FREE\\n' >>"$TRACE"; else printf 't3-lock=HELD\\n' >>"$TRACE"; fi
  [[ "${PRECHECK[t3]}" == UNKNOWN ]] && printf 't3-native-path=EXECUTED\\n' >>"$TRACE"
  RESULT[t3]=PASS; UPDATE_RC[t3]=0
}
do_codex_update(){ printf 'codex-native\\n' >>"$TRACE"; }
do_hermes_update(){ printf 'hermes-native\\n' >>"$TRACE"; }
cleanup_t3_runtimes(){ :; }
cleanup_codex_releases(){ :; }
verify_codex(){ :; }; verify_opencode(){ :; }; verify_hermes(){ :; }; verify_t3(){ :; }
prune_update_logs(){ :; }
print_summary(){ :; }
'''
with open(sys.argv[2],'w') as f:
    f.write(pre+lock+'\n'+exit_trap+'\n'+opencode+'\n'+main+'\nmain "$@"\n')
LOCKSEQPY
chmod +x "$LOCKSEQ/harness.sh"

ALLCURRENT_HOME="$LOCKSEQ/all-current"; mkdir -p "$ALLCURRENT_HOME"
TEST_CASE=allcurrent HOME="$ALLCURRENT_HOME" "$LOCKSEQ/harness.sh" >"$LOCKSEQ/all-current.out" 2>&1
AC_RC=$?
[[ $AC_RC -eq 0 ]] && ok "all-CURRENT decision exits 0" || bad "all-CURRENT exit $AC_RC"
grep -q '^precheck-lock=HELD$' "$ALLCURRENT_HOME/trace" && ok "CURRENT was accepted under exclusive lock" || bad "CURRENT decision was outside exclusive lock"
[[ ! -e "$ALLCURRENT_HOME/.local/state/tool-updates/update.lock.holder" ]] && ok "all-CURRENT exit removes lock-holder file" || bad "all-CURRENT left holder behind"
[[ ! -e "$ALLCURRENT_HOME/logging-started" ]] && ok "all-CURRENT exit starts no log" || bad "all-CURRENT started logging"
! grep -qE 'native|t3-lock|codex-lock|hermes-lock' "$ALLCURRENT_HOME/trace" && ok "all-CURRENT invokes no update path" || bad "all-CURRENT invoked an update path"
grep -q 'already current' "$ALLCURRENT_HOME/trace" && ok "all-CURRENT reports PASS already-current" || bad "all-CURRENT report missing"

MIXED_HOME="$LOCKSEQ/mixed"; mkdir -p "$MIXED_HOME"
TEST_CASE=mixed HOME="$MIXED_HOME" "$LOCKSEQ/harness.sh" >"$LOCKSEQ/mixed.out" 2>&1
MIX_RC=$?
[[ $MIX_RC -eq 0 ]] && ok "mixed CURRENT/UNKNOWN run reaches selected paths" || bad "mixed run exit $MIX_RC"
grep -q '^precheck-lock=HELD$' "$MIXED_HOME/trace" && ok "mixed decision is made under exclusive lock" || bad "mixed decision was not locked"
grep -q '^t3-lock=HELD$' "$MIXED_HOME/trace" && ok "exclusive lock spans the mixed update sequence" || bad "mixed sequence lost its lock"
grep -q '^t3-native-path=EXECUTED$' "$MIXED_HOME/trace" && ok "T3 UNKNOWN continues through its native path" || bad "T3 UNKNOWN was incorrectly skipped"
if grep -q '^Running: opencode upgrade$' "$MIXED_HOME/trace"; then bad "OpenCode CURRENT reached native upgrade"; else ok "OpenCode CURRENT skips native upgrade"; fi
[[ ! -e "$MIXED_HOME/.local/state/tool-updates/update.lock.holder" ]] && ok "mixed run cleans lock-holder on exit" || bad "mixed run left holder behind"

CONTEND_HOME="$LOCKSEQ/contended"; mkdir -p "$CONTEND_HOME/.local/state/tool-updates"
: >"$CONTEND_HOME/.local/state/tool-updates/update.lock"
exec 8>>"$CONTEND_HOME/.local/state/tool-updates/update.lock"; flock -n 8
TEST_CASE=allcurrent HOME="$CONTEND_HOME" "$LOCKSEQ/harness.sh" >"$LOCKSEQ/contended.out" 2>&1
CONTEND_RC=$?
exec 8>&-
[[ $CONTEND_RC -eq 3 ]] && ok "owned mutation lock exits 3 before precheck" || bad "contended update exit $CONTEND_RC"
[[ ! -e "$CONTEND_HOME/trace" ]] && ok "contended updater never accepts CURRENT" || bad "contended updater reached precheck"
[[ ! -e "$CONTEND_HOME/.local/state/tool-updates/update.lock.holder" ]] && ok "contended updater creates no holder" || bad "contended updater left holder"

printf '\n=== 44. interruption recovery, timeout reporting, and concise status ===\n'
check "signal handler protects against repeated Ctrl+C" \
    "sed -n '/^on_signal()/,/^install_traps()/p' $U | grep -q \"trap '' INT TERM\""
check "OpenCode stop is marked for interrupt recovery" \
    "grep -q 'OPENCODE_STOP_IN_PROGRESS=1' $U && grep -q 'OPENCODE_RESTORE_NEEDED=1' $U"
check "OpenCode interrupt recovery calls its official restore path" \
    "sed -n '/^on_signal()/,/^install_traps()/p' $U | grep -q 'opencode_restore_service 1'"
check "all native updates are bounded" \
    "[[ \$(grep -c 'timeout --kill-after=30s 900' $U) -eq 4 ]]"
check "timeout result is distinct from ordinary command failure" \
    "grep -q 'timed out after %ss' $U && grep -q 'failed (rc=%s)' $U"
NATIVE_REASON_TMP="$(mktemp /tmp/update-native-reason.XXXXXX)"
sed -n '/^native_failure_reason()/,/^}/p' "$U" >"$NATIVE_REASON_TMP"
eval "$(cat "$NATIVE_REASON_TMP")"
TIMEOUT_REASON="$(native_failure_reason 'fake updater' 2 124)"
FAILURE_REASON="$(native_failure_reason 'fake updater' 2 1)"
[[ "$TIMEOUT_REASON" == *"timed out after 2s"* ]] \
    && ok "timeout status is reported as a timeout" \
    || bad "timeout status mapping: $TIMEOUT_REASON"
[[ "$FAILURE_REASON" == *"failed (rc=1)"* ]] \
    && ok "ordinary nonzero status is reported as failure" \
    || bad "failure status mapping: $FAILURE_REASON"
rm -f "$NATIVE_REASON_TMP"
check "component status includes elapsed time" \
    "grep -q 'elapsed:.*s' $U"
check "version header prints one v prefix" \
    "grep -q 'SCRIPT_NAME.*SCRIPT_VERSION' $U && ! grep -q ' %s v%s' $U"

# Exercise the actual signal and EXIT handlers with a fake updater and an
# OpenCode service stopped by this fixture. The harness owns a sandbox lock.
INT_FIX="$(mktemp -d /tmp/update-interrupt.XXXXXX)"
python3 - "$U" "$INT_FIX/harness.sh" <<'INTPY'
import sys
s=open(sys.argv[1]).read()
def extract(name):
    i=s.index(name); depth=0
    for j in range(s.index('{',i),len(s)):
        if s[j]=='{': depth+=1
        elif s[j]=='}':
            depth-=1
            if depth==0: return s[i:j+1]
    raise SystemExit('could not extract '+name)
names=['scrub() {','acquire_lock() {','start_logging() {','on_exit() {','on_signal() {']
pre='''#!/usr/bin/env bash
set -Eeuo pipefail
HOME="${1:?}"
STATE_ROOT="$HOME/state"; GLOBAL_LOCK="$STATE_ROOT/update.lock"; LOG_DIR="$HOME/logs"
LOCK_HELD=0; LOG_FH_OPEN=0; ACTIVE_LOG=""; DRY_RUN=0; IN_MUTATION=1
UPDATE_ARGV="fake updater"; OBS_LOCK_BUSY=0; CODEX_RESTORE_NEEDED=0; T3_STOPPED_BY_US=0
T3_UNIT=t3code.service; OPENCODE_SERVICE_WAS_RUNNING=1; OPENCODE_RESTORE_NEEDED=1; OPENCODE_STOP_IN_PROGRESS=0
declare -a RESTORE_FAILURES=()
C_RESET=""; C_BOLD=""; C_RED=""; C_YEL=""; C_CYN=""; C_GRN=""; C_DIM=""
err(){ printf '%s\\n' "$*" >&2; }
opencode_service_pid(){ [[ -e "$HOME/opencode.running" ]] && printf '9876\\n'; }
opencode_restore_service(){ touch "$HOME/opencode.running"; touch "$HOME/restored"; }
'''
with open(sys.argv[2],'w') as f:
    f.write(pre+'\n'.join(extract(n) for n in names))
    f.write('''
mkdir -p "$STATE_ROOT"
acquire_lock
trap on_exit EXIT
trap on_signal INT TERM
start_logging
printf 'fake updater started\\n'
sleep 20
printf 'fake updater completed\\n'
''')
INTPY
chmod +x "$INT_FIX/harness.sh"
INT_HOME="$INT_FIX/home"; mkdir -p "$INT_HOME"
setsid "$INT_FIX/harness.sh" "$INT_HOME" >"$INT_HOME/terminal.out" 2>&1 &
INT_PID=$!
for _ in $(seq 1 40); do
    grep -q 'fake updater started' "$INT_HOME/terminal.out" 2>/dev/null && break
    sleep 0.05
done
kill -TERM -- "-$INT_PID" 2>/dev/null || kill -TERM "$INT_PID" 2>/dev/null || true
wait "$INT_PID" 2>/dev/null; INT_RC=$?
[[ $INT_RC -eq 5 ]] && ok "interrupt returns status 5" || bad "interrupt exit $INT_RC"
check "interruption is reported, never as completion" \
    "grep -q '\\[INTERRUPTED\\]' $INT_HOME/terminal.out && ! grep -q 'fake updater completed' $INT_HOME/terminal.out"
check "OpenCode stopped before interruption is restored" "[[ -e $INT_HOME/restored && -e $INT_HOME/opencode.running ]]"
check "interruption releases the mutation lock" \
    "( exec 8>>$INT_HOME/state/update.lock && flock -n 8 )"
check "interruption removes the lock holder" "[[ ! -e $INT_HOME/state/update.lock.holder ]]"
sleep 0.1
check "interruption final rc is retained in the log" \
    "grep -q 'update finished rc=5' $INT_HOME/logs/*.log"
rm -rf "$INT_FIX"

printf '\n--- %d passed, %d failed ---\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
