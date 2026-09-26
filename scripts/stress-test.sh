#!/usr/bin/env bash
#
# Stress/regression harness for the headless Obsidian setup (obx client, GUI
# launch via as-obs, obsidian-up recovery). How to run it and how to judge the
# results: docs/testing-protocol.md.
#
#   scripts/stress-test.sh [phase ...]
#
# Phases (default: all non-destructive ones, in this order):
#   preflight correctness control concurrency unicode writes timeout soak
# Destructive, run only when named explicitly (they kill the GUI):
#   recovery wedge
#
# Knobs (env): N=50 (repeats per correctness test)  N_CONTROL=20
#   PAR=8 PAR_CALLS=25 (concurrency)  SOAK_MIN=10  OUT=<results dir>
#
# Every test is recorded as a row in $OUT/results.tsv; failing outputs are
# kept alongside it. Run as root (the harness user in these environments).
set -uo pipefail

N="${N:-50}"; N_CONTROL="${N_CONTROL:-20}"; PAR="${PAR:-8}"; PAR_CALLS="${PAR_CALLS:-25}"
SOAK_MIN="${SOAK_MIN:-10}"
OUT="${OUT:-/tmp/obx-stress-$(date +%Y%m%d-%H%M%S)}"
VAULT=/home/obs/vault
CRASH_DIR=/home/obs/crash
SCRATCH="ZZ obx stress test"          # vault folder for write tests; always removed
GUI_RE='^/opt/Obsidian/obsidian --no-sandbox'
DV_QUERY='const dv=app.plugins.plugins.dataview.api;JSON.stringify(dv.pages(`"GTD/Projects"`).where(p=>p.activationDate&&!p.completionDate&&p.activationDate<=dv.date("now")).map(p=>p.file.name).array())'

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
PHASES=("$@")
[ ${#PHASES[@]} -gt 0 ] || PHASES=(preflight correctness control concurrency unicode writes timeout soak)
mkdir -p "${OUT}/base" "${OUT}/fail"
RES="${OUT}/results.tsv"
[ -f "${RES}" ] || printf 'phase\ttest\tn\tfailures\texpected\tnote\n' >"${RES}"
cd /tmp || exit 1

# pgrep -u obs: the harness runs as root, so this can never match (and kill)
# the harness's own shell -- a -f pattern without it can.
gui_pid()   { pgrep -u obs -f "${GUI_RE}" | head -1; }
gui_count() { pgrep -u obs -fc "${GUI_RE}"; }
gui_ok()    { [ "$(obx eval code=1+1 2>/dev/null)" = "=> 2" ]; }
now_ms()    { echo $(( $(date +%s%N) / 1000000 )); }
stock()     { timeout 10 sudo -u obs -- env DISPLAY=:99 obsidian "$@"; }   # control phase only

record() {  # phase test n failures expected note
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"${RES}"
  printf '[%s] %-34s n=%-5s fail=%-5s expect=%-6s %s\n' "$@"
}

# Record a baseline output for a command; refuse an empty or error baseline.
mkbase() {  # name cmd...
  local name=$1; shift
  "$@" >"${OUT}/base/${name}" 2>/dev/null
  if [ ! -s "${OUT}/base/${name}" ] || grep -q '^Error:' "${OUT}/base/${name}"; then
    echo "baseline for ${name} is empty or an error -- can't test against it" >&2
    return 1
  fi
}

# Run a command N times with stdout into a pipe (the case that used to hang),
# compare with its baseline, keep failing outputs.
repeat() {  # phase name n baseline cmd...
  local phase=$1 name=$2 n=$3 base=$4; shift 4
  local fails=0 max=0 i t rc
  for i in $(seq 1 "${n}"); do
    t=$(now_ms)
    timeout 90 "$@" 2>"${OUT}/tmp.err" | cat >"${OUT}/tmp.out"; rc=${PIPESTATUS[0]}
    t=$(( $(now_ms) - t )); [ "${t}" -gt "${max}" ] && max=${t}
    if [ "${rc}" -ne 0 ] || ! cmp -s "${OUT}/tmp.out" "${OUT}/base/${base}"; then
      fails=$((fails + 1))
      cp "${OUT}/tmp.out" "${OUT}/fail/${name}.${i}.out"; cp "${OUT}/tmp.err" "${OUT}/fail/${name}.${i}.err"
      echo "rc=${rc} ms=${t}" >"${OUT}/fail/${name}.${i}.rc"
    fi
  done
  record "${phase}" "${name}" "${n}" "${fails}" 0 "max ${max}ms"
}

# ---------------------------------------------------------------------------
phase_preflight() {
  local fails=0 note="" p
  p="$(gui_pid)"
  ck() { if ! eval "$1"; then fails=$((fails + 1)); note="${note}$2; "; fi; }
  ck '[ "$(head -1 /usr/local/bin/obx)" = "#!/usr/bin/env python3" ]' "obx is not the python socket client (env predates the fix?)"
  ck '[ -x /usr/local/bin/as-obs ]' "as-obs missing"
  ck '[ "$(gui_count)" -eq 1 ]' "GUI main processes: $(gui_count) (want 1)"
  ck '[ -n "${p}" ] && [ "$(stat -c %U /proc/${p})" = obs ]' "GUI not running as obs"
  ck '[ -n "${p}" ] && grep -Eq "^Max core file size +unlimited" /proc/${p}/limits' "GUI core limit not unlimited"
  ck '[ -n "${p}" ] && [ "$(awk "/Max open files/{print \$4}" /proc/${p}/limits)" -ge 20000 ]' "GUI nofile < 20000"
  ck '[ -n "${p}" ] && [ "$(readlink /proc/${p}/cwd)" = "${CRASH_DIR}" ]' "GUI cwd is not ${CRASH_DIR} (cores would go elsewhere)"
  ck 'gui_ok' "eval 1+1 did not return => 2"
  ck 'obx eval "code=Object.keys(app.plugins.plugins).join()" | grep -q dataview' "Dataview not loaded"
  ck '[ -s "${VAULT}/GTD/Tasks.md" ]' "vault not synced (no GTD/Tasks.md)"
  record preflight checks 10 "${fails}" 0 "${note}"
  { obx version; echo "obx: $(head -2 /usr/local/bin/obx | tail -1)"; echo "gui pid ${p}";
    [ -n "${p}" ] && grep -E 'core file|open files' "/proc/${p}/limits";
    echo "vault files: $(find "${VAULT}" -type f -not -path '*/.obsidian/*' | wc -l)"; } >"${OUT}/env.txt" 2>&1
}

phase_correctness() {
  mkbase search      obx search "query=Mental Health Anchors" || return
  mkbase files       obx files || return
  mkbase context     obx search:context query=Mental || return
  mkbase eval200k    obx eval "code='x'.repeat(200000)" || return
  mkbase inbox       obx read path=GTD/Inbox.md || return
  mkbase dataview    obx eval "code=${DV_QUERY}" || return
  printf '=> 2\n' >"${OUT}/base/one"
  echo "  (files baseline is $(wc -c <"${OUT}/base/files") bytes: must exceed 64KB to exercise the old hang)"
  repeat correctness search-async            "${N}" search   obx search "query=Mental Health Anchors"
  repeat correctness files-pipe              "${N}" files    obx files
  repeat correctness search-context-100k     "${N}" context  obx search:context query=Mental
  repeat correctness eval-200k               "${N}" eval200k obx eval "code='x'.repeat(200000)"
  repeat correctness read-inbox              "${N}" inbox    obx read path=GTD/Inbox.md
  repeat correctness dataview-active-proj    "${N}" dataview obx eval "code=${DV_QUERY}"
  repeat correctness eval-small              "${N}" one      obx eval code=1+1
  # stdin variants: the old client's bug was driven by stdin EOF.
  repeat correctness search-stdin-closed     "${N}" search   bash -c 'obx search "query=Mental Health Anchors" <&-'
  repeat correctness search-stdin-pipe       "${N}" search   bash -c 'echo junk | obx search "query=Mental Health Anchors"'
  # Reader closing early must not error or leave a traceback.
  local fails=0 i rc
  for i in $(seq 1 "${N}"); do
    obx files 2>"${OUT}/tmp.err" | head -1 >/dev/null; rc=${PIPESTATUS[0]}
    if [ "${rc}" -ne 0 ] || [ -s "${OUT}/tmp.err" ]; then fails=$((fails + 1)); cp "${OUT}/tmp.err" "${OUT}/fail/head-close.${i}.err"; fi
  done
  record correctness files-into-head-1 "${N}" "${fails}" 0 "rc!=0 or stderr output counts as failure"
  # The GUI's own library reading must agree with the disk.
  if cmp -s <(obx read path=GTD/Inbox.md) "${VAULT}/GTD/Inbox.md"; then
    record correctness read-matches-disk 1 0 0 ""
  else
    record correctness read-matches-disk 1 1 0 "obx read differs from file on disk (sync mid-run? trailing newline?)"
  fi
}

# The stock client, to show the bugs obx avoids are still there upstream. Here
# "failures" are the bug reproducing, so >0 is the expected result; 0 would
# mean Obsidian fixed it (worth knowing, not a problem).
phase_control() {
  local empty=0 hang=0 i b
  for i in $(seq 1 "${N_CONTROL}"); do
    b=$(stock search "query=Mental Health Anchors" 2>/dev/null </dev/null | wc -c)
    [ "${b}" -eq 0 ] && empty=$((empty + 1))
  done
  record control stock-search-empty "${N_CONTROL}" "${empty}" ">0" "known bug: EOF stdin half-closes socket"
  for i in $(seq 1 "${N_CONTROL}"); do
    stock files 2>/dev/null </dev/null | cat >/dev/null
    [ "${PIPESTATUS[0]}" -eq 124 ] && hang=$((hang + 1))
  done
  record control stock-files-pipe-hang "${N_CONTROL}" "${hang}" ">0" "known bug: waits for a drain that never fires"
  [ "$(gui_count)" -eq 1 ] || record control gui-count-after 1 1 0 "stock client left $(gui_count) GUIs"
}

phase_concurrency() {
  [ -s "${OUT}/base/search" ] || phase_correctness_bases_only || return
  local w
  for w in $(seq 1 "${PAR}"); do
    (
      f=0
      for i in $(seq 1 "${PAR_CALLS}"); do
        case $(( (i + w) % 4 )) in
          0) obx search "query=Mental Health Anchors" >"${OUT}/w${w}.out" 2>/dev/null; b=search ;;
          1) obx files >"${OUT}/w${w}.out" 2>/dev/null; b=files ;;
          2) obx eval "code=${DV_QUERY}" >"${OUT}/w${w}.out" 2>/dev/null; b=dataview ;;
          3) obx read path=GTD/Inbox.md >"${OUT}/w${w}.out" 2>/dev/null; b=inbox ;;
        esac
        cmp -s "${OUT}/w${w}.out" "${OUT}/base/${b}" || { f=$((f + 1)); cp "${OUT}/w${w}.out" "${OUT}/fail/concurrent.w${w}.${i}.${b}"; }
      done
      echo "${f}" >"${OUT}/w${w}.fails"
    ) &
  done
  local t; t=$(now_ms); wait; t=$(( $(now_ms) - t ))
  local total=0; for w in $(seq 1 "${PAR}"); do total=$(( total + $(cat "${OUT}/w${w}.fails") )); done
  record concurrency mixed-parallel "$(( PAR * PAR_CALLS ))" "${total}" 0 "${PAR} workers, ${t}ms wall"
  gui_ok && [ "$(gui_count)" -eq 1 ]; record concurrency gui-healthy-after 1 $? 0 ""
}
phase_correctness_bases_only() {
  mkbase search obx search "query=Mental Health Anchors" && mkbase files obx files &&
  mkbase inbox obx read path=GTD/Inbox.md && mkbase dataview obx eval "code=${DV_QUERY}"
}

phase_unicode() {
  local s out fails
  s="ünï 🦊 \"dq\" 'sq' \$dollar \`bt\` back\\slash"
  out=$(obx eval "code=$(printf '%s' "${s}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")
  [ "${out}" = "=> ${s}" ]; record unicode eval-roundtrip 1 $? 0 "got: ${out:0:80}"
  out=$(obx eval "code='$(head -c 100000 /dev/zero | tr '\0' a)'.length")
  [ "${out}" = "=> 100000" ]; record unicode argv-100KB 1 $? 0 "got: ${out:0:40}"
  fails=0
  for q in "don't" 'ü' '🦊' '"quoted phrase"' 'a&b|c;d' '$HOME'; do
    obx search "query=${q}" >"${OUT}/tmp.out" 2>&1 || fails=$((fails + 1))
    grep -q '^Error' "${OUT}/tmp.out" && fails=$((fails + 1))
  done
  record unicode odd-search-queries 6 "${fails}" 0 "rc/Error only; result content not asserted"
}

phase_writes() {
  local note="${SCRATCH}/scratch.md" disk="${VAULT}/${SCRATCH}/scratch.md" i w fails
  trap 'obx delete path="${SCRATCH}/scratch.md" permanent >/dev/null 2>&1; rm -rf "${VAULT:?}/${SCRATCH}"' RETURN
  obx create path="${note}" content='header' >/dev/null
  for i in $(seq 1 "${N}"); do obx append path="${note}" content="seq-${i}" >/dev/null; done
  sleep 1
  [ "$(grep -c '^seq-' "${disk}")" -eq "${N}" ]; record writes sequential-appends "${N}" $? 0 "$(grep -c '^seq-' "${disk}") of ${N} on disk"
  for w in $(seq 1 "${PAR}"); do
    ( for i in $(seq 1 10); do obx append path="${note}" content="par-${w}-${i}" >/dev/null; done ) &
  done
  wait; sleep 2
  local got; got=$(grep -c '^par-' "${disk}")
  record writes parallel-appends "$(( PAR * 10 ))" "$(( PAR * 10 - got ))" 0 "lost appends = Obsidian read-modify-write race; informs whether parallel agents may append"
  fails=0
  for i in $(seq 1 10); do
    obx property:set path="${note}" name=stress value="${i}" type=number >/dev/null
    [ "$(obx property:read path="${note}" name=stress)" = "${i}" ] || fails=$((fails + 1))
  done
  record writes property-roundtrip 10 "${fails}" 0 ""
  obx append path="${note}" content='- [ ] stress task [project:: [[Stress Project]]] - [context:: computer] - [timescale:: next]' >/dev/null
  local ok=1
  for i in $(seq 1 20); do
    obx eval "code=JSON.stringify(app.plugins.plugins.dataview.api.page(\`${note}\`)?.file.tasks.array().map(t=>[t.context,t.timescale]))" \
      | grep -q '"computer","next"' && { ok=0; break; }
    sleep 1
  done
  record writes dataview-sees-house-task 1 "${ok}" 0 "task fields parsed within 20s"
  obx delete path="${note}" permanent >/dev/null; rm -rf "${VAULT:?}/${SCRATCH}"
  [ ! -e "${VAULT}/${SCRATCH}" ] && ! ls "${VAULT}/.trash" 2>/dev/null | grep -q scratch
  record writes cleanup 1 $? 0 "scratch folder must not survive to the Stop-hook sync"
}

phase_timeout() {
  local t rc err
  t=$(now_ms)
  err=$(OBX_TIMEOUT=3 obx eval code='(()=>{const t=Date.now();while(Date.now()-t<8000){};return 1})()' 2>&1 >/dev/null); rc=$?
  t=$(( $(now_ms) - t ))
  [ "${rc}" -eq 1 ] && [ "${t}" -lt 6000 ] && [[ "${err}" == *"no complete reply"* ]]
  record timeout obx-timeout-fires 1 $? 0 "rc=${rc} after ${t}ms"
  local ok=1; t=$(now_ms)
  for _ in $(seq 1 30); do gui_ok && { ok=0; break; }; sleep 1; done
  record timeout gui-recovers-after-busy 1 "${ok}" 0 "answered again after $(( $(now_ms) - t ))ms"
}

phase_soak() {
  local end=$(( $(date +%s) + SOAK_MIN * 60 )) calls=0 fails=0 next=0 p r
  printf 'epoch\tgui_rss_kb\trenderer_rss_kb\tgui_fds\tcalls\tfails\n' >"${OUT}/soak.tsv"
  while [ "$(date +%s)" -lt "${end}" ]; do
    if [ "$(date +%s)" -ge "${next}" ]; then
      p=$(gui_pid); r=$(pgrep -u obs -f -- '--type=renderer' | head -1)
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(awk '/VmRSS/{print $2}' /proc/${p}/status 2>/dev/null)" \
        "$(awk '/VmRSS/{print $2}' /proc/${r}/status 2>/dev/null)" "$(ls /proc/${p}/fd 2>/dev/null | wc -l)" \
        "${calls}" "${fails}" >>"${OUT}/soak.tsv"
      next=$(( $(date +%s) + 30 ))
    fi
    for c in "search query=Mental" "eval code=${DV_QUERY}" "read path=GTD/Tasks.md" "tasks total" "files"; do
      read -r -a args <<<"${c}"
      [ "${c#eval }" != "${c}" ] && args=(eval "code=${DV_QUERY}")
      obx "${args[@]}" 2>/dev/null | cat >"${OUT}/tmp.out"
      calls=$((calls + 1))
      { [ "${PIPESTATUS[0]}" -ne 0 ] || [ ! -s "${OUT}/tmp.out" ]; } && fails=$((fails + 1))
    done
  done
  local first last; first=$(sed -n 2p "${OUT}/soak.tsv"); last=$(tail -1 "${OUT}/soak.tsv")
  record soak workload "${calls}" "${fails}" 0 "${SOAK_MIN}min; gui rss $(cut -f2 <<<"${first}")->$(cut -f2 <<<"${last}")KB, renderer $(cut -f3 <<<"${first}")->$(cut -f3 <<<"${last}")KB, fds $(cut -f4 <<<"${first}")->$(cut -f4 <<<"${last}")"
}

# ---------------------------------------------------------------------------
# Destructive: each step kills the GUI and checks obsidian-up brings it back
# with the evidence preserved. obsidian-up also runs `ob sync` (pull + push),
# which is why this runs after the writes phase has cleaned up.
up() { obsidian-up >"${OUT}/obsidian-up.$1.log" 2>&1; }
newest_archive() { ls -1dt "${CRASH_DIR}"/*-gui/ 2>/dev/null | head -1; }

phase_recovery() {
  local p before t rc err
  # a) SIGSEGV: core must land, client must fail fast, no second GUI.
  p=$(gui_pid); kill -SEGV "${p}"
  for _ in $(seq 1 30); do [ -z "$(gui_pid)" ] && break; sleep 1; done; sleep 3
  [ -e "${CRASH_DIR}/core" ]; record recovery segv-leaves-core 1 $? 0 "$(du -sh "${CRASH_DIR}/core" 2>/dev/null | cut -f1) on disk"
  t=$(now_ms); err=$(obx eval code=1+1 2>&1); rc=$?; t=$(( $(now_ms) - t ))
  [ "${rc}" -eq 1 ] && [[ "${err}" == *"isn't running"* ]] && [ "${t}" -lt 2000 ]
  record recovery obx-fails-fast-when-dead 1 $? 0 "rc=${rc} ${t}ms"
  sleep 3; [ "$(gui_count)" -eq 0 ]; record recovery no-second-gui-spawned 1 $? 0 ""
  up segv; gui_ok; record recovery obsidian-up-after-segv 1 $? 0 "$(tail -1 "${OUT}/obsidian-up.segv.log")"
  local a; a=$(newest_archive)
  [ -e "${a}core" ] && [ -s "${a}gui.log" ]; record recovery archive-has-core-and-log 1 $? 0 "${a}"
  timeout 180 gdb -batch -ex 'thread apply all bt 3' /opt/Obsidian/obsidian "${a}core" >"${OUT}/gdb.txt" 2>&1
  grep -q '^Thread ' "${OUT}/gdb.txt"; record recovery core-readable-in-gdb 1 $? 0 "$(grep -c '^Thread ' "${OUT}/gdb.txt") threads"
  # b) SIGKILL: stale socket left behind.
  kill -9 "$(gui_pid)"; sleep 2
  err=$(obx eval code=1+1 2>&1); [[ "${err}" == *"Connection refused"* || "${err}" == *"isn't running"* ]]
  record recovery stale-socket-clean-error 1 $? 0 "${err:0:90}"
  up stale; gui_ok && [ "$(gui_count)" -eq 1 ]; record recovery obsidian-up-after-sigkill 1 $? 0 ""
  # c) everything gone (fresh-launch branch, which clears Chromium caches).
  pkill -u obs -f "${GUI_RE}"; pkill -u obs -x Xvfb; sleep 2
  up fresh; gui_ok; record recovery obsidian-up-fresh-launch 1 $? 0 ""
  # d) idempotent when healthy: same pid, no new archive.
  p=$(gui_pid); before=$(newest_archive)
  up idem; [ "$(gui_pid)" = "${p}" ] && [ "$(newest_archive)" = "${before}" ]
  record recovery obsidian-up-idempotent 1 $? 0 ""
  # e) retention.
  local n; n=$(ls -1d "${CRASH_DIR}"/*/ 2>/dev/null | wc -l)
  [ "${n}" -le 5 ]; record recovery archive-retention 1 $? 0 "${n} archives, $(du -sh "${CRASH_DIR}" | cut -f1)"
}

# A renderer stuck in a JS loop: socket answers connect() but never replies.
# obsidian-up's probe gives it 20 x 15s before killing and relaunching, so
# this takes ~5-6 minutes.
phase_wedge() {
  OBX_TIMEOUT=2 obx eval code='(()=>{while(true){}})()' >/dev/null 2>&1
  local t; t=$(now_ms); up wedge; t=$(( ($(now_ms) - t) / 1000 ))
  gui_ok && [ "$(gui_count)" -eq 1 ]; record wedge obsidian-up-recovers-wedged-gui 1 $? 0 "took ${t}s"
}

for ph in "${PHASES[@]}"; do
  echo "=== ${ph} ==="
  "phase_${ph}" || record "${ph}" phase-aborted 1 1 0 "see output above"
done
echo
echo "results: ${RES}"
awk -F'\t' 'NR>1 && $5=="0" && $4!="0" {bad++} END {print (bad ? bad " test(s) FAILED" : "all pass/fail tests passed")}' "${RES}"
