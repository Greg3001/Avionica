#!/usr/bin/env bash
# practica3.sh — Emulación AFDX (L03-E01 Bonding y L03-E02 AFDX)
# Modos:  topology | config | traffic | analysis | respuestas | cleanup | all
#         (se acepta también e01 / e02 como alias)

set -eo pipefail
LOG_TAG="P3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"

# ============================================================
#                          CONFIG
# ============================================================
TGZ_E01_PATH="$(find_tgz L03-E01 || true)"
TGZ_E02_PATH="$(find_tgz L03-E02 || true)"

GEN_TC_EGRESS="${HOME}/Descargas/gen_tc_egress.sh"
IPV4_MCAST_TO_MAC="${HOME}/Descargas/ipv4_multicast_to_mac.py"

# ---------- E01: Bonding ----------
BOND_NAME="bond0"
BOND_HOSTS=( "H01:192.168.1.1/24" "H02:192.168.1.2/24" )
BOND_SLAVES=("eth0" "eth1")
TEST_RX_HOST="H01"
TEST_TX_HOST="H02"
TEST_PORT=9999
TEST_MSG_E01="PRUEBA"

# ---------- E02: AFDX ----------
ES1_HOST="H01"
ES1_IFACE="eth0"

# Identidad (User ID + Partition IDs).  Cambia por los que te toquen.
ES1_USER_ID_HEX="0001"      # 16 bits hex
ES1_PART1_ID_HEX="01"
ES1_PART2_ID_HEX="02"

# IPs origen (red 10.0.0.0/8, máscara /8).  Convención común:
#   10.<user_id_high>.<user_id_low>.<partition_id>
# Para User ID = 0x0001, Particiones 0x01 y 0x02:
ES1_PART1_IP="10.0.1.1/8"
ES1_PART2_IP="10.0.1.2/8"

# MAC origen (campo constante 02:00:00:00 + User ID).
# Para 0x0001 la MAC origen termina en 00:01.
ES1_SRC_MAC="02:00:00:00:00:01"

# Virtual Links (multicast destino dentro de 224.224.0.0/16).
VLS=(
  "VL1:224.224.0.1"
  "VL2:224.224.0.2"
)

# End System 3 (recibe sólo VL2)
ES3_HOST="H03"
ES3_IFACE="eth0"
ES3_MACVLAN_NAME="eth0-vl2"
ES3_VL_TARGET="VL2"
ES3_PART_IPS=( "10.0.3.1/8" "10.0.3.2/8" )

# End System 2 (recibe ambos VLs) — opcional; si configurado, se usa también.
ES2_HOST="H02"
ES2_IFACE="eth0"
ES2_MACVLAN_VL1="eth0-vl1"
ES2_MACVLAN_VL2="eth0-vl2"
ES2_PART_IPS=( "10.0.2.1/8" "10.0.2.2/8" )

TEST_MSG_E02="HOLA"
TEST_DST_PORT=9999
TEST_SRC_PORT=5555

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
#                       UTILIDADES PURAS
# ====================================================================
afdx_dst_mac() {
  IFS=. read -r a b c d <<<"$1"
  printf "02:00:00:00:%02x:%02x" "$c" "$d"
}
ipv4_mcast_to_mac() {
  IFS=. read -r a b c d <<<"$1"
  local mac4=$(( b & 0x7F ))
  printf "01:00:5e:%02x:%02x:%02x" "$mac4" "$c" "$d"
}

# ====================================================================
#                          TOPOLOGÍA
# ====================================================================
do_topology() {
  case "${1:-all}" in
    e01|all) header "Topología L03-E01 (Bonding A/B)"; show_topology_for "L03-E01" "$TGZ_E01_PATH" ;;
  esac
  case "${1:-all}" in
    e02|all) header "Topología L03-E02 (AFDX)";        show_topology_for "L03-E02" "$TGZ_E02_PATH" ;;
  esac
}

# ====================================================================
#                          E01: BONDING
# ====================================================================
config_e01() {
  ensure_scenario "L03-E01" "$TGZ_E01_PATH"
  log "Arrancando L03-E01"
  lincus start "L03-E01" || true

  for entry in "${BOND_HOSTS[@]}"; do
    local host="${entry%%:*}" ip="${entry#*:}"
    log "[$host] crear bonding broadcast con esclavos ${BOND_SLAVES[*]}"
    incus exec "$host" -- ip link del "$BOND_NAME" 2>/dev/null || true
    incus exec "$host" -- ip link add "$BOND_NAME" type bond mode broadcast
    incus exec "$host" -- ip link set dev "$BOND_NAME" up
    for sl in "${BOND_SLAVES[@]}"; do
      incus exec "$host" -- ip link set dev "$sl" down
      incus exec "$host" -- ip link set dev "$sl" master "$BOND_NAME"
      incus exec "$host" -- ip link set dev "$sl" up
    done
    incus exec "$host" -- ip address flush dev "$BOND_NAME" || true
    incus exec "$host" -- ip address add "$ip" dev "$BOND_NAME"
    incus exec "$host" -- ip link set dev "$BOND_NAME" up
  done

  # ARP estática para evitar el ARP Request al hacer la prueba
  local rx_ip; rx_ip="${BOND_HOSTS[0]##*:}"; rx_ip="${rx_ip%/*}"
  local rx_mac; rx_mac="$(mac_of "$TEST_RX_HOST" "$BOND_NAME")"
  if [ -n "$rx_mac" ]; then
    log "ARP estática en $TEST_TX_HOST: $rx_ip -> $rx_mac"
    incus exec "$TEST_TX_HOST" -- ip neigh replace "$rx_ip" lladdr "$rx_mac" dev "$BOND_NAME" || true
  fi
}

traffic_e01() {
  local rx_ip; rx_ip="${BOND_HOSTS[0]##*:}"; rx_ip="${rx_ip%/*}"

  log "Captura tcpdump en $TEST_RX_HOST:$BOND_NAME (background, todas las copias del bonding)"
  capture_start "p3e01-cap" "$TEST_RX_HOST" "$BOND_NAME" "udp port $TEST_PORT"

  log "Receptor socat en $TEST_RX_HOST:$TEST_PORT (background)"
  bg_start "p3e01-rx" "$TEST_RX_HOST" \
    "socat -v UDP-RECVFROM:${TEST_PORT},fork OPEN:/tmp/p3e01-rx-data,creat,append"

  sleep 1
  log "Emisor desde $TEST_TX_HOST -> $rx_ip:$TEST_PORT"
  bg_start "p3e01-tx" "$TEST_TX_HOST" \
    "printf '${TEST_MSG_E01}\n' | nc -u -w 1 ${rx_ip} ${TEST_PORT}"

  sleep 3
  capture_stop "p3e01-cap"
  bg_stop "p3e01-rx"
  bg_stop "p3e01-tx"
}

analysis_e01() {
  header "Bonding — estado de interfaces"
  for entry in "${BOND_HOSTS[@]}"; do
    local h="${entry%%:*}"
    log "$h:"
    incus exec "$h" -- ip link show "$BOND_NAME" | sed 's/^/    /'
    for sl in "${BOND_SLAVES[@]}"; do
      incus exec "$h" -- ip link show "$sl" | sed 's/^/    /'
    done
  done

  header "Tabla del Ejercicio 2 — flags y MAC tras crear bond0"
  printf "  %-4s %-7s %-19s %s\n" "DEV" "IFACE" "MAC" "FLAGS"
  for entry in "${BOND_HOSTS[@]}"; do
    local h="${entry%%:*}"
    for i in "${BOND_SLAVES[@]}" "$BOND_NAME"; do
      local line; line="$(incus exec "$h" -- ip link show "$i" 2>/dev/null | head -1)"
      local mac; mac="$(mac_of "$h" "$i")"
      local flags; flags="$(echo "$line" | grep -oE '<[^>]+>')"
      printf "  %-4s %-7s %-19s %s\n" "$h" "$i" "${mac:--}" "${flags:--}"
    done
  done

  header "Captura UDP en $TEST_RX_HOST:$BOND_NAME (verás cada paquete duplicado)"
  capture_dump "p3e01-cap" | sed 's/^/    /'

  header "Mensaje recibido en $TEST_RX_HOST (socat lo escribió en /tmp/p3e01-rx-data)"
  incus exec "$TEST_RX_HOST" -- cat /tmp/p3e01-rx-data 2>/dev/null | sed 's/^/    /'
}

respuestas_e01() {
  header "Respuestas teóricas — L03-E01 (Bonding)"
  cat <<'EOF'
¿Por qué las MACs de eth0, eth1 y bond0 coinciden tras esclavizar?
  El driver bonding hereda la MAC de la primera esclava activa y la replica
  en todas las esclavas (y en sí misma) para que el bonding aparezca como una
  única entidad MAC.  Es esencial en mode broadcast: las dos copias salen con
  la MISMA MAC origen, y el receptor no las trata como flujos distintos.

Por qué duplicación:
  bond0 en mode=broadcast (modo 3) replica cada frame en TODAS las esclavas
  activas.  La trama se transmite por eth0 (red A) y por eth1 (red B).  En el
  otro extremo, ambas esclavas reciben sus respectivas copias y las elevan a
  bond0, que pasa al stack IP — por eso socat imprime el mensaje DOS veces.

ARP estática:
  Se añade `ip neigh add` para que el emisor no envíe un ARP Request
  (broadcast) antes del primer envío.  Si lo enviara, también se replicaría
  por ambas redes y veríamos respuestas duplicadas; al haber entrada estática,
  el primer paquete UDP sale ya con la MAC destino correcta.

Flag NO-CARRIER en bond0 al crearlo:
  Un bond sin esclavos activas no tiene "portadora": Linux no puede transmitir
  porque no sabe por qué interfaz física hacerlo.  Al esclavizar al menos una
  interfaz que está UP, el flag desaparece.
EOF
}

# ====================================================================
#                          E02: AFDX
# ====================================================================
push_helpers() {
  if [ -f "$GEN_TC_EGRESS" ]; then
    incus file push "$GEN_TC_EGRESS" "${ES1_HOST}/usr/local/bin/gen_tc_egress.sh"
    incus exec "$ES1_HOST" -- chmod +x /usr/local/bin/gen_tc_egress.sh
    ok "gen_tc_egress.sh subido a $ES1_HOST"
  else
    warn "no encontrado $GEN_TC_EGRESS — saltado push"
  fi
}

config_es1() {
  log "[$ES1_HOST] MAC origen $ES1_SRC_MAC + IP aliasing"
  incus exec "$ES1_HOST" -- ip link set dev "$ES1_IFACE" down
  incus exec "$ES1_HOST" -- ip link set dev "$ES1_IFACE" address "$ES1_SRC_MAC"
  incus exec "$ES1_HOST" -- ip link set dev "$ES1_IFACE" up
  incus exec "$ES1_HOST" -- ip address flush dev "$ES1_IFACE" || true
  incus exec "$ES1_HOST" -- ip address add "$ES1_PART1_IP" dev "$ES1_IFACE"
  incus exec "$ES1_HOST" -- ip address add "$ES1_PART2_IP" dev "$ES1_IFACE"
}

apply_tc_rules() {
  local ips=()
  for vl in "${VLS[@]}"; do ips+=( "${vl#*:}" ); done
  log "[$ES1_HOST] tc egress: mapear ${ips[*]} a su MAC AFDX"
  incus exec "$ES1_HOST" -- /usr/local/bin/gen_tc_egress.sh "$ES1_IFACE" --clear || true
  incus exec "$ES1_HOST" -- /usr/local/bin/gen_tc_egress.sh "$ES1_IFACE" "${#ips[@]}" "${ips[@]}"
}

config_es3() {
  local vl_ip="" vl_mac=""
  for vl in "${VLS[@]}"; do
    if [ "${vl%%:*}" = "$ES3_VL_TARGET" ]; then vl_ip="${vl#*:}"; fi
  done
  vl_mac="$(afdx_dst_mac "$vl_ip")"
  log "[$ES3_HOST] macvlan $ES3_MACVLAN_NAME con MAC=$vl_mac (VL=$ES3_VL_TARGET, IP=$vl_ip)"
  incus exec "$ES3_HOST" -- ip link del "$ES3_MACVLAN_NAME" 2>/dev/null || true
  incus exec "$ES3_HOST" -- ip link add link "$ES3_IFACE" name "$ES3_MACVLAN_NAME" type macvlan mode bridge
  incus exec "$ES3_HOST" -- ip link set dev "$ES3_MACVLAN_NAME" address "$vl_mac"
  incus exec "$ES3_HOST" -- ip link set dev "$ES3_MACVLAN_NAME" up
  for ip in "${ES3_PART_IPS[@]}"; do
    incus exec "$ES3_HOST" -- ip address add "$ip" dev "$ES3_MACVLAN_NAME"
  done
}

config_es2() {
  log "[$ES2_HOST] macvlan VL1 + VL2 (recibe ambos)"
  for vl in "${VLS[@]}"; do
    local name="${vl%%:*}" ip="${vl#*:}"
    local mac; mac="$(afdx_dst_mac "$ip")"
    local mvl_name=""
    case "$name" in VL1) mvl_name="$ES2_MACVLAN_VL1" ;; VL2) mvl_name="$ES2_MACVLAN_VL2" ;; esac
    [ -z "$mvl_name" ] && continue
    incus exec "$ES2_HOST" -- ip link del "$mvl_name" 2>/dev/null || true
    incus exec "$ES2_HOST" -- ip link add link "$ES2_IFACE" name "$mvl_name" type macvlan mode bridge
    incus exec "$ES2_HOST" -- ip link set dev "$mvl_name" address "$mac"
    incus exec "$ES2_HOST" -- ip link set dev "$mvl_name" up
  done
  # Reparte las dos IPs unicast entre las dos macvlan (una por partición)
  incus exec "$ES2_HOST" -- ip address add "${ES2_PART_IPS[0]}" dev "$ES2_MACVLAN_VL1" || true
  incus exec "$ES2_HOST" -- ip address add "${ES2_PART_IPS[1]}" dev "$ES2_MACVLAN_VL2" || true
}

config_e02() {
  ensure_scenario "L03-E02" "$TGZ_E02_PATH"
  log "Arrancando L03-E02"
  lincus start "L03-E02" || true
  push_helpers
  config_es1
  apply_tc_rules
  config_es3
  config_es2
}

traffic_e02() {
  local vl1_ip vl2_ip
  for vl in "${VLS[@]}"; do
    case "${vl%%:*}" in VL1) vl1_ip="${vl#*:}";; VL2) vl2_ip="${vl#*:}";; esac
  done
  local part1_src="${ES1_PART1_IP%/*}"
  local part2_src="${ES1_PART2_IP%/*}"

  log "Captura br01-equivalent: tcpdump en $ES2_HOST:eth0 (recibe todo lo del bus físico)"
  capture_start "p3e02-cap" "$ES2_HOST" eth0 "ip multicast and udp"

  log "Receptores socat en $ES3_HOST:$ES3_MACVLAN_NAME (background, partición 1)"
  bg_start "p3e02-rx-vl2-p1" "$ES3_HOST" \
    "socat UDP4-RECVFROM:${TEST_DST_PORT},reuseaddr,ip-add-membership=${vl2_ip}:${ES3_PART_IPS[0]%/*} OPEN:/tmp/p3e02-rx-vl2-p1.log,creat,append"

  sleep 1
  log "Generando 3 paquetes desde $ES1_HOST (P1->VL1, P1->VL2, P2->VL2)"
  bg_start "p3e02-tx-1" "$ES1_HOST" \
    "echo ${TEST_MSG_E02} | socat - UDP4-DATAGRAM:${vl1_ip}:${TEST_DST_PORT},bind=${part1_src}:${TEST_SRC_PORT}"
  sleep 0.5
  bg_start "p3e02-tx-2" "$ES1_HOST" \
    "echo ${TEST_MSG_E02} | socat - UDP4-DATAGRAM:${vl2_ip}:${TEST_DST_PORT},bind=${part1_src}:${TEST_SRC_PORT}"
  sleep 0.5
  bg_start "p3e02-tx-3" "$ES1_HOST" \
    "echo ${TEST_MSG_E02} | socat - UDP4-DATAGRAM:${vl2_ip}:${TEST_DST_PORT},bind=${part2_src}:${TEST_SRC_PORT}"

  sleep 3
  capture_stop "p3e02-cap"
  bg_stop "p3e02-rx-vl2-p1"
}

analysis_e02() {
  header "Tabla de direccionamiento AFDX (calculada)"
  printf "  %-4s %-18s %-20s %-20s %s\n" "VL" "IP destino" "MAC dst (AFDX)" "MAC dst (Linux)" "OK?"
  for vl in "${VLS[@]}"; do
    local name="${vl%%:*}" ip="${vl#*:}"
    local mac_afdx mac_linux
    mac_afdx="$(afdx_dst_mac "$ip")"
    mac_linux="$(ipv4_mcast_to_mac "$ip")"
    printf "  %-4s %-18s %-20s %-20s %s\n" "$name" "$ip" "$mac_afdx" "$mac_linux" \
      "MAC AFDX se aplica via tc, MAC Linux es la 'natural' de multicast IPv4"
  done

  header "Configuración resultante en $ES1_HOST (Ejercicio 1+2+3)"
  log "MAC origen y direcciones IP de las particiones:"
  incus exec "$ES1_HOST" -- ip -4 address show "$ES1_IFACE" | sed 's/^/    /'
  log "Reglas tc egress aplicadas:"
  incus exec "$ES1_HOST" -- tc filter show dev "$ES1_IFACE" egress 2>/dev/null | sed 's/^/    /' || true

  header "Captura del bus AFDX (Ejercicio 4)"
  capture_dump "p3e02-cap" | sed 's/^/    /'

  header "Datos recibidos en $ES3_HOST (sólo VL2 — Ejercicio 8)"
  incus exec "$ES3_HOST" -- cat /tmp/p3e02-rx-vl2-p1.log 2>/dev/null | sed 's/^/    /' || true
}

respuestas_e02() {
  header "Respuestas teóricas — L03-E02 (AFDX)"
  cat <<EOF
Direccionamiento End System 1 (Ejercicio 1)
  Usando User ID = 0x${ES1_USER_ID_HEX}, Particiones 0x${ES1_PART1_ID_HEX} y 0x${ES1_PART2_ID_HEX}:
    Dirección MAC origen (red A):  ${ES1_SRC_MAC}    (campo constante 02:00:00:00 + UserID)
    Dirección MAC origen (red B):  02:00:00:01:00:01 (mismo, alterando el bit de red)
    Dirección IP partición 1:      ${ES1_PART1_IP}
    Dirección IP partición 2:      ${ES1_PART2_IP}
    Dirección MAC destino VL1:     $(afdx_dst_mac 224.224.0.1)
    Dirección MAC destino VL2:     $(afdx_dst_mac 224.224.0.2)
    Dirección IP destino VL1:      224.224.0.1
    Dirección IP destino VL2:      224.224.0.2

Análisis de las tres tramas (Ejercicio 4)
  PAQUETE 1  (P1 → VL1):
    MAC origen   ${ES1_SRC_MAC}
    MAC destino  $(afdx_dst_mac 224.224.0.1)   (tras tc; Linux por defecto pondría $(ipv4_mcast_to_mac 224.224.0.1))
    IP origen    ${ES1_PART1_IP%/*}
    IP destino   224.224.0.1
  PAQUETE 2  (P1 → VL2):
    MAC origen   ${ES1_SRC_MAC}
    MAC destino  $(afdx_dst_mac 224.224.0.2)
    IP origen    ${ES1_PART1_IP%/*}
    IP destino   224.224.0.2
  PAQUETE 3  (P2 → VL2):
    MAC origen   ${ES1_SRC_MAC}
    MAC destino  $(afdx_dst_mac 224.224.0.2)
    IP origen    ${ES1_PART2_IP%/*}
    IP destino   224.224.0.2

¿Por qué hay que reescribir la MAC destino con tc?
  Linux, al ver una IP multicast 224.0.0.0/4, calcula automáticamente la MAC
  destino siguiendo la regla 01:00:5e + (23 bits inferiores de la IP).  Pero
  AFDX usa un formato distinto: 02:00:00:00:<VL16>.  Con el filtro tc en
  egress (clsact+flower) interceptamos el frame y le hacemos pedit munge para
  reescribir la MAC destino con el formato AFDX antes de salir por la red.

¿Por qué macvlan en los receptores?
  Una macvlan es una sub-interfaz lógica con su propia MAC.  Asignándole la
  MAC AFDX del VL al que el End System está suscrito, el kernel "captura" en
  esa interfaz todos los frames con ese MAC destino.  Como cada macvlan tiene
  su propio stack de red, podemos asignarle direcciones IP unicast (las de
  las particiones receptoras) que SÍ permiten al kernel procesar el paquete a
  nivel IP — la IP destino multicast no se puede asignar a una interfaz como
  unicast, así que sin la macvlan + MAC + IPs no podríamos hacer la suscripción
  multicast con socat (ip-add-membership).

¿Por qué socat ip-add-membership=<MCAST>:<UNICAST>?
  Une el grupo multicast usando como interfaz local la que tiene asignada
  esa IP unicast.  Como la macvlan tiene la MAC del VL, sólo recibe ese VL
  aunque el bus físico transporte ambos.

¿Por qué el End System 3 sólo ve VL2?
  Su macvlan está configurada con la MAC de VL2.  Los frames de VL1 llegan al
  bridge físico (br01) pero ninguna interfaz de H03 los acepta — los descarta
  el switch interno del kernel.
EOF
}

# ====================================================================
do_cleanup() { kill_all_bg; }

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
  case "${1:-all}" in
    topology|table|"") ;;  # no necesitan lincus
    *) require_lincus ;;
  esac
  case "${1:-all}" in
    topology)   do_topology "${2:-all}" ;;
    config)     case "${2:-all}" in
                  e01) config_e01 ;; e02) config_e02 ;;
                  *)   config_e01; lincus stop || true; config_e02 ;;
                esac ;;
    traffic)    case "${2:-all}" in
                  e01) traffic_e01 ;; e02) traffic_e02 ;;
                  *)   traffic_e01; traffic_e02 ;;
                esac ;;
    analysis)   case "${2:-all}" in
                  e01) analysis_e01 ;; e02) analysis_e02 ;;
                  *)   analysis_e01; analysis_e02 ;;
                esac ;;
    respuestas) case "${2:-all}" in
                  e01) respuestas_e01 ;; e02) respuestas_e02 ;;
                  *)   respuestas_e01; respuestas_e02 ;;
                esac ;;
    e01)  do_topology e01; config_e01; traffic_e01; analysis_e01; respuestas_e01 ;;
    e02)  do_topology e02; config_e02; traffic_e02; analysis_e02; respuestas_e02 ;;
    table) header "Tabla AFDX (sin tocar nada)"
           for vl in "${VLS[@]}"; do
             local name="${vl%%:*}" ip="${vl#*:}"
             printf "  %-4s %-18s -> AFDX %s   (Linux %s)\n" \
               "$name" "$ip" "$(afdx_dst_mac "$ip")" "$(ipv4_mcast_to_mac "$ip")"
           done ;;
    cleanup) do_cleanup ;;
    stop)    do_cleanup; lincus stop || true ;;
    all)     do_all ;;
    *) err "Uso: $0 [topology|config|traffic|analysis|respuestas|e01|e02|table|cleanup|stop|all]"; exit 1 ;;
  esac
}

main "$@"
