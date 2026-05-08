#!/usr/bin/env bash
# practica2.sh — Interconexión de Redes IP (L02-E01)
# Modos:  topology | subnetting | config | traffic | analysis | respuestas | cleanup | all

set -eo pipefail
LOG_TAG="P2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"

# ============================================================
#                          CONFIG
# ============================================================
TGZ_E01_PATH="$(find_tgz L02-E01 || true)"
SCENARIO_ID="L02-E01"

# Subdivisión de 192.168.1.0/24 según los requisitos del Ejercicio 8.
# Red D: 70 disp -> /25 ; Red A: 48 disp -> /26 ; Red C: 30 disp -> /27 ; Red B: 24 disp -> /27
# (este es el subnetting "óptimo" cumpliendo los requisitos)
SUBNETS=(
  "D:70:25:192.168.1.0/25"
  "A:48:26:192.168.1.128/26"
  "C:30:27:192.168.1.192/27"
  "B:24:27:192.168.1.224/27"
)

# Direcciones IP a configurar.  Format: "DEVICE:IFACE:IP/PREFLEN"
IFACES=(
  # Redes G/H entre routers (10.0.0.x/30)
  "R01:eth1:10.0.0.1/30"
  "R02:eth1:10.0.0.2/30"
  "R02:eth2:10.0.0.5/30"
  "R03:eth2:10.0.0.6/30"

  # Redes stub
  "R01:eth0:192.168.1.1/25"     # Red D
  "R02:eth0:192.168.1.129/26"   # Red A
  "R02:eth3:192.168.1.193/27"   # Red C
  "R03:eth0:192.168.1.225/27"   # Red B
)

# Rutas estáticas (Ejercicio 13)
ROUTES=(
  # Ya vienen pre-configuradas R05 y R06 vía 10.0.0.13/14 (red K)
  "R05:192.168.2.128/25:10.0.0.14"   # red F
  "R06:192.168.2.0/25:10.0.0.13"     # red E
  # R01: una sola ruta -> default por R02
  "R01:0.0.0.0/0:10.0.0.2"
  # R02: dos rutas
  "R02:192.168.1.0/25:10.0.0.1"      # red D vía R01
  "R02:192.168.1.224/27:10.0.0.6"    # red B vía R03
  # R03: dos rutas
  "R03:0.0.0.0/0:10.0.0.5"
  # R04: tres rutas (red E,F y stub a 192.168.1/24 — ajusta según asigne)
  "R04:192.168.2.0/25:10.0.0.13"
  "R04:192.168.2.128/25:10.0.0.14"
  "R04:192.168.1.0/24:10.0.0.5"
)

# DHCP por interfaz (Ejercicio 14)
# Formato: "ROUTER:IFACE:RANGE_START:RANGE_END:LEASE:GATEWAY"
DHCP_BLOCKS=(
  "R01:eth0:192.168.1.10:192.168.1.120:12h:192.168.1.1"
  "R02:eth0:192.168.1.140:192.168.1.190:12h:192.168.1.129"
  "R02:eth3:192.168.1.200:192.168.1.220:12h:192.168.1.193"
  "R03:eth0:192.168.1.230:192.168.1.250:12h:192.168.1.225"
  "R06:eth1:192.168.2.140:192.168.2.250:12h:192.168.2.129"
)

# H06 con IP fija 192.168.2.135 (Ejercicio 4)
DHCP_FIXED_HOSTS=("H06")
DHCP_FIXED_ROUTERS=("R06")
DHCP_FIXED_IPS=(   "192.168.2.135")

# Para test de conectividad
PING_PAIRS=(
  "H01:H05:192.168.2.5"
  "H05:H06:192.168.2.135"
  "H01:H06:192.168.2.135"
  "H03:H02:#auto"
)

# ============================================================
#                       FIN CONFIG
# ============================================================

ensure_scenario() {
  if ! lincus list 2>/dev/null | grep -q "$SCENARIO_ID"; then
    log "Instalando $SCENARIO_ID"
    lincus install "$TGZ_E01_PATH"
  fi
}

# ====================================================================
#                          TOPOLOGÍA
# ====================================================================
do_topology() {
  header "Topología L02-E01"
  show_topology_for "L02-E01" "$TGZ_E01_PATH"
}

# ====================================================================
#                          SUBNETTING
# ====================================================================
calc_subnet() {
  # arg: PREFIX/LEN  -> imprime: red, broadcast, primera asignable, última, máscara
  python3 - "$1" <<'PY'
import sys, ipaddress
n = ipaddress.ip_network(sys.argv[1], strict=False)
hosts = list(n.hosts())
print(f"red={n.network_address} bcast={n.broadcast_address} "
      f"mask={n.netmask} pri={hosts[0]} ult={hosts[-1]} "
      f"asignables={n.num_addresses-2 if n.num_addresses>2 else n.num_addresses}")
PY
}

do_subnetting() {
  header "Ejercicio 8 — Subnetting de 192.168.1.0/24"
  printf "  %-3s %-7s %-7s %-7s %s\n" "Red" "N.disp" "N.IPs" "Máscara" "Prefijo"
  for s in "${SUBNETS[@]}"; do
    local name="${s%%:*}"; local rest="${s#*:}"
    local n="${rest%%:*}"; rest="${rest#*:}"
    local mlen="${rest%%:*}"; rest="${rest#*:}"
    local pfx="$rest"
    local ips=$(( (1<<(32-mlen)) ))
    printf "  %-3s %-7s %-7s /%-6s %s\n" "$name" "$n" "$ips" "$mlen" "$pfx"
  done
  echo
  log "Detalle de cada subred:"
  for s in "${SUBNETS[@]}"; do
    local name="${s%%:*}"; local pfx="${s##*:}"
    printf "  Red %s  (%s)\n" "$name" "$pfx"
    calc_subnet "$pfx" | sed 's/^/      /'
  done
}

# ====================================================================
#                          CONFIG
# ====================================================================
vtysh_apply() {
  local router="$1"; shift
  local args=( -c "configure terminal" )
  for c in "$@"; do args+=( -c "$c" ); done
  args+=( -c "end" -c "write memory" )
  log "vtysh@$router: ${#@} comandos"
  incus exec "$router" -- vtysh "${args[@]}" >/dev/null
}

is_router() { incus exec "$1" -- which vtysh >/dev/null 2>&1; }

config_ifaces() {
  log "Configurando direcciones IP en interfaces"
  local devices=""
  for entry in "${IFACES[@]}"; do
    local d="${entry%%:*}"
    case " $devices " in *" $d "*) ;; *) devices="$devices $d";; esac
  done
  for dev in $devices; do
    local cmds=() plain=()
    for entry in "${IFACES[@]}"; do
      [ "${entry%%:*}" = "$dev" ] || continue
      local rest="${entry#*:}"; local iface="${rest%%:*}"; local ipmask="${rest#*:}"
      cmds+=( "interface ${iface}" "ip address ${ipmask}" "exit" )
      plain+=( "${iface}|${ipmask}" )
    done
    [ "${#cmds[@]}" -eq 0 ] && continue
    if is_router "$dev"; then
      vtysh_apply "$dev" "${cmds[@]}"
    else
      for p in "${plain[@]}"; do
        local iface="${p%%|*}"; local ipmask="${p#*|}"
        incus exec "$dev" -- ip address flush dev "$iface" || true
        incus exec "$dev" -- ip address add "$ipmask" dev "$iface"
        incus exec "$dev" -- ip link set dev "$iface" up
      done
    fi
  done
}

config_routes() {
  log "Configurando rutas estáticas"
  local routers=""
  for entry in "${ROUTES[@]}"; do
    local r="${entry%%:*}"
    case " $routers " in *" $r "*) ;; *) routers="$routers $r";; esac
  done
  for r in $routers; do
    local cmds=()
    for entry in "${ROUTES[@]}"; do
      [ "${entry%%:*}" = "$r" ] || continue
      local rest="${entry#*:}"; local pfx="${rest%%:*}"; local nh="${rest##*:}"
      cmds+=( "ip route ${pfx} ${nh}" )
    done
    [ "${#cmds[@]}" -gt 0 ] && vtysh_apply "$r" "${cmds[@]}"
  done
}

config_dhcp() {
  log "Generando dnsmasq.conf por router"
  local routers=""
  for entry in "${DHCP_BLOCKS[@]}"; do
    local r="${entry%%:*}"
    case " $routers " in *" $r "*) ;; *) routers="$routers $r";; esac
  done

  for r in $routers; do
    local tmp; tmp="$(mktemp)"
    {
      for entry in "${DHCP_BLOCKS[@]}"; do
        [ "${entry%%:*}" = "$r" ] || continue
        local rest="${entry#*:}"
        local iface="${rest%%:*}"; rest="${rest#*:}"
        local rs="${rest%%:*}";    rest="${rest#*:}"
        local re="${rest%%:*}";    rest="${rest#*:}"
        local lease="${rest%%:*}"; rest="${rest#*:}"
        local gw="${rest}"
        echo "interface=${iface}"
        echo "dhcp-range=tag:${iface},${rs},${re},${lease}"
        echo "dhcp-option=tag:${iface},3,${gw}"
      done
      # Fixed hosts en este router
      local i=0
      for h in "${DHCP_FIXED_HOSTS[@]}"; do
        if [ "${DHCP_FIXED_ROUTERS[$i]}" = "$r" ]; then
          local mac; mac="$(mac_of "$h" eth0)"
          [ -n "$mac" ] && echo "dhcp-host=${mac},${DHCP_FIXED_IPS[$i]}"
        fi
        i=$((i+1))
      done
    } >"$tmp"
    incus file push "$tmp" "${r}/etc/dnsmasq.conf"
    rm -f "$tmp"
    incus exec "$r" -- rc-service dnsmasq restart || true
    ok "dnsmasq actualizado en $r"
  done
}

do_config() {
  ensure_scenario
  log "Arrancando $SCENARIO_ID"
  lincus start "$SCENARIO_ID" || true
  config_ifaces
  config_routes
  config_dhcp
}

# ====================================================================
#                          TRÁFICO
# ====================================================================
do_traffic() {
  log "Captura DHCP en R05:eth1 (background)"
  capture_start "p2-dhcp" "R05" eth1 "port 67 or port 68"
  bg_start "p2-h05-renew" "H05" "rc-service networking restart"
  sleep 3
  capture_stop "p2-dhcp"

  log "Test de conectividad punto-a-punto en background"
  for pair in "${PING_PAIRS[@]}"; do
    local src="${pair%%:*}" rest="${pair#*:}"
    local dst="${rest%%:*}" ip="${rest##*:}"
    if [ "$ip" = "#auto" ]; then
      ip="$(ip_of "$dst" eth0)"
      [ -z "$ip" ] && { warn "no se pudo resolver IP de $dst"; continue; }
    fi
    bg_start "p2-ping-$src-$dst" "$src" "ping -c 2 -W 2 $ip"
  done
  sleep 5
}

do_analysis() {
  header "IPs efectivas tras configuración"
  for entry in "${IFACES[@]}"; do
    local dev="${entry%%:*}" rest="${entry#*:}"
    local iface="${rest%%:*}"
    local ip; ip="$(ip_of "$dev" "$iface")"
    printf "  %-4s %-6s -> %s\n" "$dev" "$iface" "${ip:-(ninguna)}"
  done

  header "Captura DHCP (R05:eth1)"
  capture_dump "p2-dhcp" | sed 's/^/    /'

  header "Resultados de los pings"
  for pair in "${PING_PAIRS[@]}"; do
    local src="${pair%%:*}" rest="${pair#*:}"
    local dst="${rest%%:*}"
    log "$src -> $dst :"
    bg_output "p2-ping-${src}-${dst}" | sed 's/^/      /'
  done
}

respuestas() {
  header "Respuestas teóricas — L02-E01"
  cat <<'EOF'
Ejercicio 2 — ¿Entre qué dispositivos hay conectividad?
  Sin rutas estáticas configuradas, sólo entre dispositivos que están en la
  MISMA red física (mismo bridge):
    - H01 ↔ R01 (br01)
    - H02 ↔ R02 (br02)
    - H03 ↔ R02 (br03)
    - H04 ↔ R03 (br04)
    - H05 ↔ R05 (br06, vía DHCP)
    - H06 ↔ R06 (br05)
    - R01 ↔ R02 (br07)
    - R02 ↔ R03 (br08)
    - R03 ↔ R04 (br09)
    - R04 ↔ R05 (br10)
    - R04 ↔ R06 (br11)
    - R05 ↔ R06 (br12)
  Cualquier ping que cruce más de una red falla porque los routers no saben
  rutas a las redes que no están directamente conectadas.

Ejercicio 3 — ¿Cómo configura H05 su IP?
  Por DHCP.  R05 tiene dnsmasq corriendo con dhcp-range=192.168.2.50-125 y
  asignación fija 00:16:3e:a4:6d:28 → 192.168.2.5 (la MAC original de H05).
  H05 envía DHCPDISCOVER → recibe DHCPOFFER (192.168.2.5) → DHCPREQUEST →
  DHCPACK con yiaddr=192.168.2.5 y option 3 (router) = 192.168.2.1.

Ejercicio 11 — ¿Por qué falla el primer ping H05 → 192.168.2.135?
  H05 envía a su gateway (R05).  R05 no conoce la red 192.168.2.128/25 y la
  rechaza con "Destination Net Unreachable" (en un pcap vería ICMP type 3
  code 0).  La solución es la ruta estática a 192.168.2.128/25 vía R06.

Tabla de rutas estáticas mínimas (Ejercicio 13)
  R01 :  default vía R02 (10.0.0.2)         [1 ruta]
  R02 :  192.168.1.0/25 vía R01            [2 rutas — D y B]
         192.168.1.224/27 vía R03
  R03 :  default vía R02 (10.0.0.5)         [2 rutas con la pre-existente]
  R04 :  192.168.2.0/25 vía R06             [3 rutas — E, F y stub 1.0/24]
         192.168.2.128/25 vía R05
         192.168.1.0/24 vía R03
  R05 :  192.168.2.128/25 vía R06           [pre-existente + 1]
  R06 :  192.168.2.0/25 vía R05             [pre-existente + 1]
  Notas: con esta topología R04 es el "core" y necesita rutas a ambos
  extremos de stub.

Ejercicio 14 — DHCP con varias interfaces (gateway por interfaz)
  En dnsmasq, dhcp-option global aplica el último valor a todas las
  interfaces.  Para diferenciar gateway por red es obligatorio etiquetar:
      interface=eth0
      dhcp-option=tag:eth0,3,<gw-eth0>
  Así cada cliente recibe el gateway correcto de su red de origen.
EOF
}

do_cleanup() { kill_all_bg; }

do_all() {
  do_topology
  do_subnetting
  do_config
  do_traffic
  do_analysis
  respuestas
  do_cleanup
}

main() {
  case "${1:-all}" in
    topology|subnetting|respuestas) ;;  # no necesitan lincus
    *) require_lincus ;;
  esac
  case "${1:-all}" in
    topology)   do_topology ;;
    subnetting) do_subnetting ;;
    config)     do_config ;;
    traffic)    do_traffic ;;
    analysis)   do_analysis ;;
    respuestas) respuestas ;;
    cleanup)    do_cleanup ;;
    save)       lincus save ;;
    stop)       do_cleanup; lincus stop || true ;;
    all)        do_all ;;
    *) err "Uso: $0 [topology|subnetting|config|traffic|analysis|respuestas|cleanup|save|stop|all]"; exit 1 ;;
  esac
}

main "$@"
