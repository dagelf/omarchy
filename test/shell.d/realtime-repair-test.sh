#!/bin/bash
#
# The rtkit migration, with the real omarchy-realtime-repair, must leave no
# logged-in user's process with a hard RLIMIT_RTTIME of 0 at the moment rtkit
# lands or after the portals restart, must touch nothing else, must stay
# pending whenever it could not repair or inspect something, and must do
# nothing on a second run.
#
# Only the system boundary is stubbed: /proc/<pid>/{status,stat,limits} under
# a fake proc root, prlimit rewriting them, sudo, loginctl, the D-Bus and
# systemd answers, the package helpers and the PipeWire process lookup.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

migration="$ROOT/migrations/1789747667.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

stub_bin="$test_dir/bin"
state="$test_dir/state"
proc_root="$test_dir/proc"
calls="$test_dir/calls"
mkdir -p "$stub_bin"

me=$(id -un)
my_uid=1000

# Writes a fake process: pid uid start-time soft hard.
cat >"$stub_bin/fake-proc" <<'STUB'
#!/bin/bash
mkdir -p "$OMARCHY_PROC_ROOT/$1"
printf 'Name:\tfake\nUid:\t%s\t%s\t%s\t%s\n' "$2" "$2" "$2" "$2" >"$OMARCHY_PROC_ROOT/$1/status"
echo "$1 (fake proc) S $(printf '0 %.0s' {1..18})$3 0 0" >"$OMARCHY_PROC_ROOT/$1/stat"
echo "Max realtime timeout $4 $5 us" >"$OMARCHY_PROC_ROOT/$1/limits"
STUB
cat >"$stub_bin/loginctl" <<'STUB'
#!/bin/bash
[[ $* == "list-users --no-legend" ]] || exit 2
[[ -z ${LOGINCTL_FAILS:-} ]] || exit 1
cat "$STATE/users"
STUB
cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
[[ $1 == -n ]] || { echo "sudo without -n: $*" >>"$CALLS"; exit 1; }
shift
[[ -z ${NO_SUDO:-} ]] || exit 1
# The process scan must run as root, or hidepid hides other users' processes.
[[ $* != *SCAN_ROOT* ]] || echo scan >>"$STATE/root-scans"
[[ -z ${STALE_BEFORE_PRLIMIT:-} || $* != *PROC_ROOT* ]] || sed -i 's/ 0 us$/ 100000 us/' "$OMARCHY_PROC_ROOT/$STALE_BEFORE_PRLIMIT/limits"
[[ -z ${OWNER_CHANGES_BEFORE_PRLIMIT:-} || $* != *PROC_ROOT* ]] || sed -i 's/^Uid:.*/Uid:\t0\t0\t0\t0/' "$OMARCHY_PROC_ROOT/$OWNER_CHANGES_BEFORE_PRLIMIT/status"
exec "$@"
STUB
cat >"$stub_bin/prlimit" <<'STUB'
#!/bin/bash
pid=${2:?} limit=${3#--rttime=}
echo "prlimit $pid" >>"$CALLS"
sed -i "s/^Max realtime timeout .*/Max realtime timeout ${limit%:*} ${limit#*:} us/" "$OMARCHY_PROC_ROOT/$pid/limits"
STUB
cat >"$stub_bin/busctl" <<'STUB'
#!/bin/bash
user=$(id -un)
for arg; do [[ $arg == --machine=* ]] && { user=${arg#--machine=}; user=${user%@}; }; done
case $* in
  *RealtimeKit1*) [[ -e $STATE/rtkit ]] && echo "x $RTKIT_BUDGET" ;;
  *portal.Realtime*) [[ -e $STATE/portal-$user ]] && echo "x $(<"$STATE/portal-$user")" ;;
  *) exit 2 ;;
esac
STUB
cat >"$stub_bin/systemctl" <<'STUB'
#!/bin/bash
user=$(id -un)
for arg; do [[ $arg == --machine=* ]] && { user=${arg#--machine=}; user=${user%@}; }; done
case $* in
  *"show -p ActiveState --value xdg-desktop-portal.service")
    [[ -z ${PORTAL_SHOW_FAILS:-} ]] || exit 1
    cat "$STATE/portal-state-$user" 2>/dev/null || echo active ;;
  *"restart xdg-desktop-portal.service")
    echo "restart portal $user" >>"$CALLS"
    [[ -z ${PORTAL_RESTART_FAILS:-} ]] || exit 1
    [[ -n ${PORTAL_STAYS_ZERO:-} ]] || cat "$STATE/budget" >"$STATE/portal-$user"
    # A client that read the old portal just before it went away.
    [[ -z ${ZERO_DURING_RESTART:-} ]] || fake-proc 77 1000 7700 0 0 ;;
  *"show -p MainPID --value pipewire.service")
    if [[ -e $STATE/pipewire ]]; then echo 500; else echo 0; fi ;;
  *"try-restart pipewire.service pipewire-pulse.service wireplumber.service")
    echo "restart audio" >>"$CALLS"
    echo RR >"$STATE/pipewire" ;;
  *) exit 2 ;;
esac
STUB
cat >"$stub_bin/omarchy-pkg-missing" <<'STUB'
#!/bin/bash
[[ ! -e $STATE/rtkit ]]
STUB
cat >"$stub_bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
# rtkit can make any user's zero-limit thread realtime from here on.
for dir in "$OMARCHY_PROC_ROOT"/*; do
  [[ $(awk '/^Uid:/ { print $2 }' "$dir/status") != 0 ]] || continue
  [[ $(awk '/^Max realtime timeout/ { print $5 }' "$dir/limits") == 0 ]] && echo "zero at install ${dir##*/}" >>"$CALLS"
done
touch "$STATE/rtkit"
echo "$RTKIT_BUDGET" >"$STATE/budget"
STUB
# pgrep finds the server (500) and the speaker tuning host (501), which is
# also named pipewire; only systemd's MainPID tells them apart.
cat >"$stub_bin/pgrep" <<'STUB'
#!/bin/bash
[[ -e $STATE/pipewire ]] && printf '500\n501\n'
STUB
cat >"$stub_bin/ps" <<'STUB'
#!/bin/bash
for arg; do
  case $arg in
    *500*) cat "$STATE/pipewire" ;;&
    *501*) cat "$STATE/tuning-host" 2>/dev/null ;;
  esac
done
STUB
chmod +x "$stub_bin"/*

# A session without rtkit: the shell and a terminal at a hard zero, another
# logged-in user's process at a hard zero, root logged in too with a service
# at a hard zero, a process with a limit of its own, both portals reporting
# zero, PipeWire not realtime.
fresh_machine() {
  rm -rf "$state" "$proc_root" "$calls"
  mkdir -p "$state" "$proc_root"
  touch "$calls"
  printf '0 root no active\n%s %s no active\n1001 user2 no active\n' "$my_uid" "$me" >"$state/users"
  echo 0 >"$state/portal-$me"
  echo 0 >"$state/portal-user2"
  echo TS >"$state/pipewire"
  local fake="$stub_bin/fake-proc"
  OMARCHY_PROC_ROOT=$proc_root "$fake" 10 "$my_uid" 1000 0 0
  OMARCHY_PROC_ROOT=$proc_root "$fake" 11 "$my_uid" 1100 0 0
  OMARCHY_PROC_ROOT=$proc_root "$fake" 12 "$my_uid" 1200 50000 100000
  OMARCHY_PROC_ROOT=$proc_root "$fake" 20 1001 2000 0 0
  OMARCHY_PROC_ROOT=$proc_root "$fake" 30 0 3000 0 0
}

migrate() {
  OMARCHY_PROC_ROOT=$proc_root STATE=$state CALLS=$calls RTKIT_BUDGET=200000 \
    PATH="$stub_bin:$ROOT/bin:$PATH" bash -euo pipefail "$migration" >"$test_dir/out" 2>&1
}

hard_of() {
  awk '/^Max realtime timeout/ { print $5 }' "$proc_root/$1/limits"
}

fresh_machine
ZERO_DURING_RESTART=1 migrate || fail "the migration succeeds on a fresh machine" "$(cat "$test_dir/out")"
! grep -q '^zero at install' "$calls" || fail "no process has a zero budget when rtkit lands" "$(cat "$calls")"
pass "no process has a zero budget when rtkit lands"
[[ $(hard_of 10):$(hard_of 11):$(hard_of 20) == "200000:200000:200000" ]] ||
  fail "logged-in users' zeros, another user's included, get rtkit's budget" "$(hard_of 10) $(hard_of 11) $(hard_of 20)"
pass "logged-in users' zeros, another user's included, get rtkit's budget"
[[ -s $state/root-scans ]] || fail "the process scan runs as root, so hidepid cannot hide other users' zeros"
pass "the process scan runs as root, so hidepid cannot hide other users' zeros"
[[ $(hard_of 77) == 200000 ]] || fail "a zero that appears while the portal restarts is raised"
pass "a zero that appears while the portal restarts is raised"
[[ $(hard_of 30):$(hard_of 12) == "0:100000" ]] || fail "root's services and other limits are left alone"
! grep -qx "restart portal root" "$calls" || fail "root's portal is left alone"
pass "root's services and other limits are left alone"
grep -qx "restart portal $me" "$calls" && grep -qx "restart portal user2" "$calls" ||
  fail "each logged-in user's zero-budget portal restarts" "$(cat "$calls")"
grep -qx "restart audio" "$calls" || fail "the audio units restart while PipeWire is not realtime"
pass "each user's stale portal and the audio units restart"

# A laptop with a speaker tuning: its host, also named pipewire, already got
# realtime from rtkit while the server did not, which still needs the restart.
fresh_machine
echo RR >"$state/tuning-host"
migrate || fail "the migration succeeds with a speaker tuning host" "$(cat "$test_dir/out")"
grep -qx "restart audio" "$calls" || fail "the audio units restart when only the tuning host is realtime"
pass "the audio units restart when only the tuning host is realtime"

: >"$calls"
migrate || fail "a second run succeeds" "$(cat "$test_dir/out")"
[[ ! -s $calls ]] || fail "a second run restarts nothing and raises nothing" "$(cat "$calls")"
pass "a second run restarts nothing and raises nothing"

fresh_machine
if LOGINCTL_FAILS=1 migrate; then fail "the migration stays pending when loginctl fails"; fi
[[ ! -e $state/rtkit ]] || fail "rtkit is not installed while the users are unknown"
pass "the migration stays pending when loginctl fails"

fresh_machine
echo activating >"$state/portal-state-$me"
if migrate; then fail "the migration stays pending while a portal is activating"; fi
pass "the migration stays pending while a portal is activating"

fresh_machine
if PORTAL_SHOW_FAILS=1 migrate; then fail "the migration stays pending when a portal's state cannot be read"; fi
pass "the migration stays pending when a portal's state cannot be read"

fresh_machine
echo inactive >"$state/portal-state-$me"
migrate || fail "a stopped portal is left to start with rtkit's budget" "$(cat "$test_dir/out")"
! grep -qx "restart portal $me" "$calls" || fail "a stopped portal is not restarted"
pass "a stopped portal is left to start with rtkit's budget"

fresh_machine
if PORTAL_RESTART_FAILS=1 migrate; then fail "the migration stays pending when a portal restart fails"; fi
pass "the migration stays pending when a portal restart fails"

fresh_machine
if PORTAL_STAYS_ZERO=1 migrate; then fail "the migration stays pending while a portal still reports zero"; fi
pass "the migration stays pending while a portal still reports zero"

fresh_machine
rm "$proc_root/11/limits"
if migrate; then fail "the migration stays pending when a live process's limits cannot be read"; fi
pass "the migration stays pending when a live process's limits cannot be read"

fresh_machine
rm "$proc_root/11/stat"
if migrate; then fail "the migration stays pending when a live process's start time cannot be read"; fi
pass "the migration stays pending when a live process's start time cannot be read"

fresh_machine
rm "$proc_root/20/status"
if migrate; then fail "the migration stays pending when a live process's owner cannot be read"; fi
pass "the migration stays pending when a live process's owner cannot be read"

fresh_machine
if NO_SUDO=1 migrate; then fail "the migration stays pending without sudo"; fi
grep -q "next omarchy update finishes it" "$test_dir/out" || fail "it says the next update finishes it" "$(cat "$test_dir/out")"
! grep -q '^prlimit\|^sudo without' "$calls" || fail "nothing is raised and nothing prompts without sudo" "$(cat "$calls")"
pass "the migration stays pending without sudo, and says why"

fresh_machine
for pid in 10 11 20; do sed -i 's/ 0 0 us$/ 200000 200000 us/' "$proc_root/$pid/limits"; done
if NO_SUDO=1 migrate; then fail "with no zeros to raise, rtkit is still not installed without sudo"; fi
[[ ! -e $state/rtkit ]] || fail "with no zeros to raise, rtkit is still not installed without sudo"
pass "with no zeros to raise, rtkit is still not installed without sudo"

fresh_machine
STALE_BEFORE_PRLIMIT=11 migrate || fail "a limit set by someone else is not an error" "$(cat "$test_dir/out")"
[[ $(hard_of 11) == 100000 ]] || fail "a limit set by someone else after the scan is not overwritten" "$(hard_of 11)"
pass "a limit set by someone else after the scan is not overwritten"

fresh_machine
OWNER_CHANGES_BEFORE_PRLIMIT=11 migrate || fail "a process that changed owner is not an error" "$(cat "$test_dir/out")"
[[ $(hard_of 11) == 0 ]] || fail "a PID that now belongs to someone else is left alone" "$(hard_of 11)"
pass "a PID that now belongs to someone else is left alone"

fresh_machine
printf '11 (odd ) name\nwith a newline) S %s1300 0 0\n' "$(printf '0 %.0s' {1..18})" >"$proc_root/11/stat"
migrate || fail "a process whose name holds a newline is repaired" "$(cat "$test_dir/out")"
[[ $(hard_of 11) == 200000 ]] || fail "a process whose name holds a newline is repaired" "$(hard_of 11)"
pass "a process whose name holds a newline is repaired"
