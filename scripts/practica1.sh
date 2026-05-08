#!/usr/bin/env bash
# practica1.sh — Redes IP de Área Local (L01-E01 y L01-E02)
# Modos:  topology | config | traffic | analysis | respuestas | cleanup | all
#         (puedes pasar también e01 / e02 para acotar al escenario)

set -eo pipefail
LOG_TAG="P1"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"

# ============================================================
#                          CONFIG
# ============================================================
# Si no defines TGZ_DIR, busca primero en ~/Descargas y luego en
# ../practica-1/ del repo.  Puedes forzarlo: TGZ_DIR=/ruta bash practica1.sh
TGZ_E01_PATH="$(find_tgz L01-E01 || true)"
TGZ_E02_PATH="$(find_tgz L01-E02 || true)"

# ---------- Escenario 1: L01-E01 ----------
NET_PREFIX_LEN_E01=24
HOSTS_E01=(
  "H01:192.168.1.101"
  "H02:192.168.1.102"
  "H03:192.168.1.103"
  "H04:192.168.1.104"
)
PING_SRC_E01="H01"
PING_DST_HOST_E01="H03"
PING_DST_IP_E01="192.168.1.103"

# ---------- Escenario 2: L01-E02 ----------
PERSIST_HOST="H01"
PERSIST_IP="192.168.1.10"
PERSIST_NETMASK="255.255.255.0"
DHCP_DYNAMIC_HOSTS=("H02")
# Asignación fija por MAC.  Formato "HOST:MAC:IP".
# Las MACs de H03 y H04 las leeremos de la topología en runtime.
DHCP_STATIC_HOSTS=("H03" "H04")
DHCP_STATIC_IPS=(  "192.168.1.20" "192.168.1.21")

DHCP_SERVER="R01"
DHCP_IFACE="eth0"
DHCP_RANGE_START="192.168.1.31"
DHCP_RANGE_END="192.168.1.254"
DHCP_LEASE="5m"

# ============================================================
#                       FIN CONFIG
# ============================================================

ensure_scenario() {
  local id="$1" tgz="$2"
  if ! lincus list 2>/dev/null | grep -q "$id"; then
    log "Instalando $id"
    lincus install "$tgz"
  fi
}

# ====================================================================
#                          TOPOLOGÍA
# ====================================================================
do_topology() {
  local which="${1:-all}"
  case "$which" in
    e01|all) header "Topología L01-E01"; show_topology_for "L01-E01" "$TGZ_E01_PATH" ;;
  esac
  case "$which" in
    e02|all) header "Topología L01-E02"; show_topology_for "L01-E02" "$TGZ_E02_PATH" ;;
  esac
}

# ====================================================================
#                          E01: CONFIG
# ====================================================================
config_e01() {
  ensure_scenario "L01-E01" "$TGZ_E01_PATH"
  log "Arrancando L01-E01"
  lincus start "L01-E01" || true

  log "Configurando IPs estáticas"
  for entry in "${HOSTS_E01[@]}"; do
    local host="${entry%%:*}" ip="${entry##*:}"
    incus exec "$host" -- ip address flush dev eth0 || true
    incus exec "$host" -- ip address add "${ip}/${NET_PREFIX_LEN_E01}" dev eth0
    incus exec "$host" -- ip link set dev eth0 up
    ok "$host eth0 -> ${ip}/${NET_PREFIX_LEN_E01}"
  done
}

# ====================================================================
#                       E01: TRÁFICO + ANÁLISIS
# ====================================================================
traffic_e01() {
  log "Limpiando cachés ARP"
  for entry in "${HOSTS_E01[@]}"; do
    incus exec "${entry%%:*}" -- ip neigh flush all || true
  done

  log "Iniciando captura ARP+ICMP en $PING_SRC_E01:eth0 (background)"
  capture_start "p1e01-cap" "$PING_SRC_E01" eth0 "arp or icmp"

  log "Lanzando ping $PING_SRC_E01 -> $PING_DST_IP_E01 en background (-c 2)"
  bg_start "p1e01-ping" "$PING_SRC_E01" "ping -c 2 $PING_DST_IP_E01"
  sleep 3

  log "Parando captura"
  capture_stop "p1e01-cap"
}

analysis_e01() {
  header "Ejercicio 1: Tabla de MACs (datos reales del run)"
  printf "  %-6s %-8s %s\n" "DEV" "IFACE" "MAC"
  for entry in "${HOSTS_E01[@]}"; do
    local h="${entry%%:*}"
    printf "  %-6s %-8s %s\n" "$h" "eth0" "$(mac_of "$h" eth0)"
  done

  header "Ejercicio 2: Subnet 192.168.1.0/24"
  cat <<'EOF'
  Prefijo:           192.168.1.0/24
  Tamaño del prefijo:  24 bits
  Máscara:           255.255.255.0
  Núm. asignables:   254  (2^8 - 2)
  Dirección de red:  192.168.1.0
  Broadcast:         192.168.1.255
  Rango asignable:   192.168.1.1  -  192.168.1.254
EOF

  header "Ejercicio 4: Análisis de la captura ARP+ICMP"
  log "Decodificación de /tmp/p1e01-cap.pcap (en $PING_SRC_E01):"
  capture_dump "p1e01-cap" | sed 's/^/    /'

  log "Salida de ping (background):"
  bg_output "p1e01-ping" | sed 's/^/    /'
}

respuestas_e01() {
  local mac_h01 mac_h03
  mac_h01="$(mac_of H01 eth0)"
  mac_h03="$(mac_of H03 eth0)"

  header "Respuestas teóricas — L01-E01"
  cat <<EOF
PRIMER PAQUETE  (ARP Request)
  • Dirección destino:  ff:ff:ff:ff:ff:ff   (broadcast Ethernet)
  • Dirección origen:   ${mac_h01}
  • Dispositivo origen: H01
  • ¿Por qué broadcast? H01 desconoce la MAC asociada a 192.168.1.103.
    Al no saber a qué interfaz dirigir la pregunta la envía a todos.
  • Hardware Type:     1   (Ethernet)
  • Protocol Type:     0x0800 (IPv4)
  • Opcode:            1   (Request)
  • Sender MAC:        ${mac_h01}
  • Sender IP:         192.168.1.101
  • Target MAC:        00:00:00:00:00:00  (placeholder; es lo que se pregunta)
  • Target IP:         192.168.1.103
  • Objetivo:          resolver IP→MAC para 192.168.1.103.
  • Lo reciben:        H01, H02, H03 y H04 (todos los puertos del bridge br01).

SEGUNDO PAQUETE (ARP Reply)
  • Dirección destino:  ${mac_h01}   (unicast — H03 ya conoce la MAC del solicitante)
  • Dirección origen:   ${mac_h03}
  • Dispositivo origen: H03
  • ¿Por qué no broadcast? El ARP Request ya contenía la MAC del solicitante,
    así que H03 puede responder directamente a H01.
  • Opcode:            2   (Reply)
  • Sender MAC:        ${mac_h03}
  • Sender IP:         192.168.1.103
  • Target MAC:        ${mac_h01}
  • Target IP:         192.168.1.101
  • Objetivo:          comunicar a H01 la MAC asociada a 192.168.1.103.
  • Lo reciben:        sólo H01 (frame unicast en switching layer-2).

ICMP Request / Reply
  • H03 NO necesita ARP Request para enviar el Reply: al recibir el ARP
    Request de H01 ya aprendió y cacheó la asociación 192.168.1.101 ↔ ${mac_h01}.

ARP Request/Reply final (~1 min después)
  • Es la verificación que dispara Linux cuando una entrada pasa a estado
    STALE.  Comprueba que la MAC sigue siendo correcta antes de devolver
    la entrada a REACHABLE.

¿Por qué H02-eth0 y H04-eth0 sólo ven el primer paquete?
  • El primer paquete (ARP Request) es broadcast: lo recibe todo el dominio
    de difusión.  El resto de paquetes (ARP Reply, ICMP Request, ICMP Reply)
    son unicast hacia ${mac_h01} o ${mac_h03}, así que H02 y H04 los descartan.

Caché ARP — estados (Ejercicio 5)
  Inicio       caché vacía → INCOMPLETE/PROBE al disparar el primer ping
  Tras Reply   REACHABLE
  ~1 min       STALE  (entrada usable pero requiere verificación)
  Nuevo uso    DELAY → PROBE → REACHABLE (tras ARP Request/Reply confirmatorio)
EOF
}

# ====================================================================
#                          E02: CONFIG
# ====================================================================
write_iface_static() {
  local host="$1" ip="$2" mask="$3"
  incus exec "$host" -- sh -c "cat >/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${ip}
    netmask ${mask}
EOF
  incus exec "$host" -- rc-service networking restart || true
}

write_iface_dhcp() {
  local host="$1"
  incus exec "$host" -- sh -c "cat >/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
  incus exec "$host" -- rc-service networking restart || true
}

write_dnsmasq_with_static() {
  local tmp; tmp="$(mktemp)"
  {
    echo "interface=${DHCP_IFACE}"
    echo "dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE}"
    local i=0
    for h in "${DHCP_STATIC_HOSTS[@]}"; do
      local mac
      mac="$(mac_of "$h" eth0)"
      [ -z "$mac" ] && { warn "no se pudo leer MAC de $h"; i=$((i+1)); continue; }
      echo "dhcp-host=${mac},${DHCP_STATIC_IPS[$i]}"
      i=$((i+1))
    done
  } >"$tmp"
  incus file push "$tmp" "${DHCP_SERVER}/etc/dnsmasq.conf"
  rm -f "$tmp"
  incus exec "$DHCP_SERVER" -- rc-service dnsmasq restart || true
}

config_e02() {
  ensure_scenario "L01-E02" "$TGZ_E02_PATH"
  log "Arrancando L01-E02"
  lincus start "L01-E02" || true

  log "Persistiendo IP en $PERSIST_HOST ($PERSIST_IP / $PERSIST_NETMASK)"
  write_iface_static "$PERSIST_HOST" "$PERSIST_IP" "$PERSIST_NETMASK"

  log "Generando dnsmasq.conf con asignaciones fijas en $DHCP_SERVER"
  write_dnsmasq_with_static

  log "Configurando clientes DHCP dinámicos: ${DHCP_DYNAMIC_HOSTS[*]}"
  for h in "${DHCP_DYNAMIC_HOSTS[@]}"; do write_iface_dhcp "$h"; done

  log "Configurando clientes DHCP fijos: ${DHCP_STATIC_HOSTS[*]}"
  for h in "${DHCP_STATIC_HOSTS[@]}"; do write_iface_dhcp "$h"; done
}

traffic_e02() {
  log "Captura DHCP (filtro bootp) en $DHCP_SERVER:eth0 (background)"
  capture_start "p1e02-cap" "$DHCP_SERVER" eth0 "port 67 or port 68"

  log "Disparando renovación DHCP en clientes (rc-service networking restart)"
  for h in "${DHCP_DYNAMIC_HOSTS[@]}" "${DHCP_STATIC_HOSTS[@]}"; do
    bg_start "p1e02-renew-$h" "$h" "rc-service networking restart"
  done
  sleep 4

  capture_stop "p1e02-cap"
}

analysis_e02() {
  header "IPs efectivas tras DHCP"
  for h in "$PERSIST_HOST" "${DHCP_DYNAMIC_HOSTS[@]}" "${DHCP_STATIC_HOSTS[@]}"; do
    local ip; ip="$(ip_of "$h" eth0)"
    local mac; mac="$(mac_of "$h" eth0)"
    printf "  %-4s eth0  IP=%-15s MAC=%s\n" "$h" "${ip:-(ninguna)}" "$mac"
  done

  header "Captura DHCP decodificada"
  capture_dump "p1e02-cap" | sed 's/^/    /'
}

respuestas_e02() {
  local mac_h03 mac_h04
  mac_h03="$(mac_of H03 eth0)"
  mac_h04="$(mac_of H04 eth0)"
  header "Respuestas teóricas — L01-E02"
  cat <<EOF
Flujo DHCP (Ejercicio 2)
  El cliente (sin IP) envía DHCPDISCOVER en broadcast capa 2 (ff:ff:ff:ff:ff:ff)
  con IP origen 0.0.0.0 y destino 255.255.255.255 (UDP 67 ← 68).
  El servidor ($DHCP_SERVER) responde con DHCPOFFER (oferta de IP) en unicast/broadcast.
  El cliente envía DHCPREQUEST confirmando la oferta.
  El servidor responde DHCPACK con la IP, máscara, gateway opcional y "lease time".
  Campos clave:
    - Your IP Address (yiaddr)            : la IP asignada
    - IP Address Lease Time (option 51)   : tiempo de préstamo
    - Subnet Mask (option 1)              : la máscara
    - Router (option 3)                   : gateway por defecto (en P2)
    - Server Identifier (option 54)       : IP del DHCP server

Asignación fija por MAC (Ejercicio 3)
  dnsmasq usa el campo "Client hardware address" (chaddr) del DHCPDISCOVER
  para mapear MAC→IP definida en dhcp-host.  En este escenario:
    H03  ${mac_h03}  →  ${DHCP_STATIC_IPS[0]}
    H04  ${mac_h04}  →  ${DHCP_STATIC_IPS[1]}
  Ese mapeo es fijo aunque H03/H04 reinicien o cambien de red, mientras
  conserven la MAC.

Persistencia (Ejercicio 1)
  Sin entrada "auto eth0" ni método (static/dhcp) en /etc/network/interfaces,
  ifupdown no toca la interfaz al arrancar y la IP configurada manualmente
  con "ip address add" se pierde con el reboot.
EOF
}

# ====================================================================
#                          MODES
# ====================================================================
do_cleanup() {
  log "Matando procesos en background"
  kill_all_bg
}

do_all() {
  do_topology all
  config_e01
  traffic_e01
  analysis_e01
  respuestas_e01
  lincus stop || true
  config_e02
  traffic_e02
  analysis_e02
  respuestas_e02
  do_cleanup
}

main() {
  local mode="${1:-all}"
  case "$mode" in
    topology|"")  ;;  # no necesita lincus
    *)            require_lincus ;;
  esac
  case "$mode" in
    topology)    do_topology "${2:-all}" ;;
    config)      case "${2:-all}" in
                   e01) config_e01 ;;
                   e02) config_e02 ;;
                   *)   config_e01; lincus stop || true; config_e02 ;;
                 esac ;;
    traffic)     case "${2:-all}" in
                   e01) traffic_e01 ;;
                   e02) traffic_e02 ;;
                   *)   traffic_e01; traffic_e02 ;;
                 esac ;;
    analysis)    case "${2:-all}" in
                   e01) analysis_e01 ;;
                   e02) analysis_e02 ;;
                   *)   analysis_e01; analysis_e02 ;;
                 esac ;;
    respuestas)  case "${2:-all}" in
                   e01) respuestas_e01 ;;
                   e02) respuestas_e02 ;;
                   *)   respuestas_e01; respuestas_e02 ;;
                 esac ;;
    e01)         do_topology e01; config_e01; traffic_e01; analysis_e01; respuestas_e01 ;;
    e02)         do_topology e02; config_e02; traffic_e02; analysis_e02; respuestas_e02 ;;
    cleanup)     do_cleanup ;;
    stop)        do_cleanup; lincus stop || true ;;
    all)         do_all ;;
    *) err "Uso: $0 [topology|config|traffic|analysis|respuestas|e01|e02|cleanup|stop|all]"; exit 1 ;;
  esac
}

main "$@"
