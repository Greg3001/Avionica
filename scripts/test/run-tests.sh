#!/usr/bin/env bash
# run-tests.sh — Verifica los scripts de AV en macOS sin VM.
#
# Estrategia:
#   1) bash -n para syntax check.
#   2) Mock de lincus/incus (en ./mocks/) que registra cada llamada.
#   3) Ejecuta cada practica*.sh y comprueba aserciones sobre la traza:
#      - se llama a `lincus install/start` con el ID correcto
#      - los `incus exec HOST -- ip address add IP/PREF dev IFACE` aparecen
#        para todas las entradas del CONFIG
#      - en P3 las MACs AFDX se calculan correctamente
#   4) Verifica funciones puras (afdx_dst_mac, ipv4_mcast_to_mac).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
AV_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
MOCKS_DIR="$HERE/mocks"
TRACE="/tmp/av-mock-trace.log"
SCEN_ROOT="/tmp/av-scenarios"

# Extrae los .tgz a /tmp/av-scenarios para que el mock pueda leer topology.yaml
extract_scenarios() {
  rm -rf "$SCEN_ROOT"
  mkdir -p "$SCEN_ROOT"
  for tgz in "$AV_DIR"/practica-1/L01-E01.tgz \
             "$AV_DIR"/practica-1/L01-E02.tgz \
             "$AV_DIR"/practica-2/L02-E01.tgz \
             "$AV_DIR"/practica-3/L03-E01.tgz \
             "$AV_DIR"/practica-3/L03-E02.tgz; do
    [ -f "$tgz" ] && tar xzf "$tgz" -C "$SCEN_ROOT" 2>/dev/null
  done
}

PASS=0
FAIL=0
FAILED_TESTS=()

color_g() { printf "\033[1;32m%s\033[0m" "$*"; }
color_r() { printf "\033[1;31m%s\033[0m" "$*"; }
color_y() { printf "\033[1;33m%s\033[0m" "$*"; }

assert_contains() {
  local name="$1" file="$2" pattern="$3"
  if grep -qE "$pattern" "$file"; then
    color_g "  ✓"; printf " %s\n" "$name"
    PASS=$((PASS+1))
  else
    color_r "  ✗"; printf " %s\n" "$name"
    printf "      esperado patrón: %s\n" "$pattern"
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$name")
  fi
}

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    color_g "  ✓"; printf " %s\n" "$name"
    PASS=$((PASS+1))
  else
    color_r "  ✗"; printf " %s (got=%q want=%q)\n" "$name" "$got" "$want"
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$name")
  fi
}

run_with_mocks() {
  local script="$1"; shift
  local scenario_dir="${SCENARIO_DIR_OVERRIDE:-}"
  : >"$TRACE"
  PATH="$MOCKS_DIR:$PATH" \
  MOCK_TRACE="$TRACE" \
  MOCK_STRICT="${MOCK_STRICT:-1}" \
  SCENARIO_DIR="$scenario_dir" \
  MOCK_INSTALLED="L01-E01 L01-E02 L02-E01 L03-E01 L03-E02" \
  bash "$script" "$@" >/tmp/av-stdout.log 2>/tmp/av-stderr.log || true
}

section() { printf "\n\033[1;36m== %s ==\033[0m\n" "$*"; }

# ---------------------------------------------------------------
section "0) Extracción de escenarios"
extract_scenarios
for d in "$SCEN_ROOT"/*; do
  if [ -f "$d/topology.yaml" ]; then
    color_g "  ✓"; printf " %s\n" "$(basename "$d")"
    PASS=$((PASS+1))
  fi
done

section "1) Syntax check (bash -n)"
for f in "$SCRIPTS_DIR"/practica1.sh "$SCRIPTS_DIR"/practica2.sh \
         "$SCRIPTS_DIR"/practica3.sh "$SCRIPTS_DIR"/av.sh \
         "$SCRIPTS_DIR"/lib/common.sh; do
  if bash -n "$f" 2>/dev/null; then
    color_g "  ✓"; printf " %s\n" "$(basename "$f")"
    PASS=$((PASS+1))
  else
    color_r "  ✗"; printf " %s\n" "$(basename "$f")"
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("syntax:$(basename "$f")")
  fi
done

# ---------------------------------------------------------------
section "2) Práctica 1 — E01 completa"
SCENARIO_DIR_OVERRIDE="$SCEN_ROOT/L01-E01" run_with_mocks "$SCRIPTS_DIR/practica1.sh" e01
assert_contains "lincus start L01-E01"           "$TRACE" "^lincus start L01-E01"
assert_contains "ip add 192.168.1.101 en H01"    "$TRACE" "incus exec H01 -- ip address add 192.168.1.101/24 dev eth0"
assert_contains "ip add 192.168.1.104 en H04"    "$TRACE" "incus exec H04 -- ip address add 192.168.1.104/24 dev eth0"
assert_contains "neigh flush en H01"             "$TRACE" "incus exec H01 -- ip neigh flush all"
assert_contains "captura tcpdump (ARP+ICMP)"     "$TRACE" "incus exec H01 -- sh -c"
assert_contains "ping en background"             "$TRACE" "ping -c 2 192.168.1.103"

section "2b) Práctica 1 — E02 completa"
SCENARIO_DIR_OVERRIDE="$SCEN_ROOT/L01-E02" run_with_mocks "$SCRIPTS_DIR/practica1.sh" e02
assert_contains "lincus start L01-E02"            "$TRACE" "^lincus start L01-E02"
assert_contains "push dnsmasq.conf a R01"         "$TRACE" "file push .* R01/etc/dnsmasq.conf"
assert_contains "rc-service dnsmasq restart R01"  "$TRACE" "incus exec R01 -- rc-service dnsmasq restart"
assert_contains "rc-service networking restart H01" "$TRACE" "incus exec H01 -- rc-service networking restart"
assert_contains "captura DHCP en R01"             "$TRACE" "incus exec R01 -- sh -c"

# ---------------------------------------------------------------
section "3) Práctica 2 — all"
SCENARIO_DIR_OVERRIDE="$SCEN_ROOT/L02-E01" run_with_mocks "$SCRIPTS_DIR/practica2.sh" all
assert_contains "lincus start L02-E01"          "$TRACE" "^lincus start L02-E01"
assert_contains "vtysh en R01"                  "$TRACE" "incus exec R01 -- vtysh"
assert_contains "vtysh en R03"                  "$TRACE" "incus exec R03 -- vtysh"
assert_contains "ruta estática en R05"          "$TRACE" "incus exec R05 -- vtysh"
assert_contains "push dnsmasq.conf a R01"       "$TRACE" "file push .* R01/etc/dnsmasq.conf"
assert_contains "push dnsmasq.conf a R02"       "$TRACE" "file push .* R02/etc/dnsmasq.conf"
assert_contains "push dnsmasq.conf a R03"       "$TRACE" "file push .* R03/etc/dnsmasq.conf"
assert_contains "rc-service dnsmasq restart R06" "$TRACE" "incus exec R06 -- rc-service dnsmasq restart"
assert_contains "captura DHCP en R05"           "$TRACE" "incus exec R05 -- sh -c"
assert_contains "ping H05 -> H06"               "$TRACE" "ping -c 2 -W 2 192.168.2.135"

# ---------------------------------------------------------------
section "4) Práctica 3 — E01 completa (bonding+tráfico)"
SCENARIO_DIR_OVERRIDE="$SCEN_ROOT/L03-E01" run_with_mocks "$SCRIPTS_DIR/practica3.sh" e01
assert_contains "lincus start L03-E01"            "$TRACE" "^lincus start L03-E01"
assert_contains "crear bond0 en H01"              "$TRACE" "incus exec H01 -- ip link add bond0 type bond mode broadcast"
assert_contains "crear bond0 en H02"              "$TRACE" "incus exec H02 -- ip link add bond0 type bond mode broadcast"
assert_contains "esclavizar eth0 en H01"          "$TRACE" "incus exec H01 -- ip link set dev eth0 master bond0"
assert_contains "ip 192.168.1.1 en bond0 H01"     "$TRACE" "incus exec H01 -- ip address add 192.168.1.1/24 dev bond0"
assert_contains "captura tcpdump en H01"          "$TRACE" "incus exec H01 -- sh -c"
assert_contains "ARP estática en H02"             "$TRACE" "incus exec H02 -- ip neigh replace 192.168.1.1 lladdr"
assert_contains "socat receptor en H01"           "$TRACE" "socat -v UDP-RECVFROM"
assert_contains "nc emisor desde H02"             "$TRACE" "nc -u -w 1 192.168.1.1"

section "4b) Práctica 3 — E02 completa (AFDX+tráfico)"
SCENARIO_DIR_OVERRIDE="$SCEN_ROOT/L03-E02" run_with_mocks "$SCRIPTS_DIR/practica3.sh" e02
assert_contains "lincus start L03-E02"            "$TRACE" "^lincus start L03-E02"
assert_contains "MAC origen en H01:eth0"          "$TRACE" "incus exec H01 -- ip link set dev eth0 address 02:00:00:00:00:01"
assert_contains "IP partición 1 en H01"           "$TRACE" "incus exec H01 -- ip address add 10.0.1.1/8 dev eth0"
assert_contains "IP partición 2 en H01"           "$TRACE" "incus exec H01 -- ip address add 10.0.1.2/8 dev eth0"
assert_contains "macvlan VL2 en H03"              "$TRACE" "incus exec H03 -- ip link add link eth0 name eth0-vl2 type macvlan mode bridge"
assert_contains "macvlan VL1 en H02"              "$TRACE" "incus exec H02 -- ip link add link eth0 name eth0-vl1 type macvlan mode bridge"
assert_contains "captura tcpdump en H02"          "$TRACE" "incus exec H02 -- sh -c"
assert_contains "envío P1->VL1 desde H01"         "$TRACE" "UDP4-DATAGRAM:224.224.0.1:9999"
assert_contains "envío P1->VL2 desde H01"         "$TRACE" "UDP4-DATAGRAM:224.224.0.2:9999"
assert_contains "receptor socat en H03"           "$TRACE" "ip-add-membership=224.224.0.2"

# ---------------------------------------------------------------
section "5) Funciones puras de practica3.sh (cálculo de MAC)"
# Reimplementamos las funciones aquí (no se puede `source` el script porque
# ejecuta main al final).  Si cambias la lógica en practica3.sh, sincroniza
# estos helpers o este test dejará de cubrirla.

afdx_dst_mac_t() {
  local ip="$1"
  IFS=. read -r a b c d <<<"$ip"
  printf "02:00:00:00:%02x:%02x" "$c" "$d"
}
ipv4_mcast_to_mac_t() {
  local ip="$1"
  IFS=. read -r a b c d <<<"$ip"
  local mac4=$(( b & 0x7F ))
  printf "01:00:5e:%02x:%02x:%02x" "$mac4" "$c" "$d"
}

assert_eq "afdx 224.224.0.1 -> 02:00:00:00:00:01"   "$(afdx_dst_mac_t 224.224.0.1)"   "02:00:00:00:00:01"
assert_eq "afdx 224.224.0.2 -> 02:00:00:00:00:02"   "$(afdx_dst_mac_t 224.224.0.2)"   "02:00:00:00:00:02"
assert_eq "afdx 224.224.10.20 -> 02:00:00:00:0a:14" "$(afdx_dst_mac_t 224.224.10.20)" "02:00:00:00:0a:14"

# Compara con la implementación oficial (practica-3/ipv4_multicast_to_mac.py)
PY="$SCRIPTS_DIR/../practica-3/ipv4_multicast_to_mac.py"
if [ -f "$PY" ] && command -v python3 >/dev/null 2>&1; then
  for ip in 224.0.1.129 224.224.0.1 239.1.2.3 224.255.255.255; do
    expected="$(python3 "$PY" "$ip")"
    got="$(ipv4_mcast_to_mac_t "$ip")"
    assert_eq "ipv4_mcast_to_mac($ip) coincide con script oficial" "$got" "$expected"
  done
else
  color_y "  ⚠"; printf " python3 / fichero oficial no encontrado, salto comparación\n"
fi

# ---------------------------------------------------------------
section "6) Coherencia CONFIG ↔ topología real"
# Para cada HOST:IFACE referenciado por los scripts, comprobar que existe en
# el topology.yaml correspondiente.

check_in_topology() {
  local name="$1" topo="$2" host="$3" iface="$4"
  python3 - "$topo" "$host" "$iface" <<'PY' 2>/dev/null
import sys, re
path, host, iface = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
m = re.search(rf'^  {re.escape(host)}:\s*\n(.*?)(?=^  \w|^networks:|\Z)',
              text, re.S | re.M)
if not m: sys.exit(2)
if iface == "*":
    sys.exit(0)
sys.exit(0 if re.search(rf'^\s+{re.escape(iface)}:\s*\n', m.group(1), re.M) else 1)
PY
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    color_g "  ✓"; printf " %s\n" "$name"
    PASS=$((PASS+1))
  else
    color_r "  ✗"; printf " %s (host=%s iface=%s rc=%d)\n" "$name" "$host" "$iface" "$rc"
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$name")
  fi
}

# P1-E01: hosts H01..H04 con eth0 en L01-E01
for h in H01 H02 H03 H04; do
  check_in_topology "P1-E01: $h:eth0 existe" "$SCEN_ROOT/L01-E01/topology.yaml" "$h" "eth0"
done
# P1-E02: R01 existe y tiene eth0
check_in_topology "P1-E02: R01:eth0 existe" "$SCEN_ROOT/L01-E02/topology.yaml" "R01" "eth0"

# P2: las interfaces declaradas en IFACES de practica2.sh deben existir
# Extraemos los pares dispositivo/iface del CONFIG
while IFS= read -r entry; do
  dev="${entry%%:*}"
  rest="${entry#*:}"
  iface="${rest%%:*}"
  check_in_topology "P2: $dev:$iface existe" "$SCEN_ROOT/L02-E01/topology.yaml" "$dev" "$iface"
done < <(awk '/^IFACES=\(/{flag=1;next}/^\)$/{flag=0}flag{gsub(/[" ]/,"");gsub(/#.*/,"");if($0!="")print $0}' "$SCRIPTS_DIR/practica2.sh")

# P3-E01: hosts H01,H02 con eth0 y eth1
for h in H01 H02; do
  for i in eth0 eth1; do
    check_in_topology "P3-E01: $h:$i existe" "$SCEN_ROOT/L03-E01/topology.yaml" "$h" "$i"
  done
done
# P3-E02: H01 (ES1) y H03 (ES3) con eth0
for h in H01 H02 H03; do
  check_in_topology "P3-E02: $h:eth0 existe" "$SCEN_ROOT/L03-E02/topology.yaml" "$h" "eth0"
done

# Verifica que los hosts del bonding (P3-E01) están en el mismo bridge que su pareja
check_bonding_topology() {
  local name="$1" topo="$2"
  python3 - "$topo" <<'PY' 2>/dev/null
import sys, re
text = open(sys.argv[1]).read()
# Encuentra bridges que tengan al menos un H01-* y un H02-*
ok = False
for m in re.finditer(r'^  (br\w+):\s*\n\s+attachedInterfaces:\s*\n((?:\s+- .*\n)+)',
                     text, re.M):
    block = m.group(2)
    devs = [ln.strip()[2:].split('-')[0] for ln in block.splitlines() if ln.strip()]
    if 'H01' in devs and 'H02' in devs:
        ok = True
        break
sys.exit(0 if ok else 1)
PY
  if [ $? -eq 0 ]; then
    color_g "  ✓"; printf " %s\n" "$name"
    PASS=$((PASS+1))
  else
    color_r "  ✗"; printf " %s\n" "$name"
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$name")
  fi
}
check_bonding_topology "P3-E01: H01 y H02 comparten bridge" "$SCEN_ROOT/L03-E01/topology.yaml"

section "Resumen"
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "  %s %d/%d tests OK\n" "$(color_g PASS)" "$PASS" "$TOTAL"
  exit 0
else
  printf "  %s %d/%d tests OK, %d fallaron:\n" "$(color_r FAIL)" "$PASS" "$TOTAL" "$FAIL"
  for t in "${FAILED_TESTS[@]}"; do printf "    - %s\n" "$t"; done
  exit 1
fi
