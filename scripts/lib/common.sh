#!/usr/bin/env bash
# common.sh — utilidades compartidas por practica{1,2,3}.sh
# No es ejecutable directamente; se sourcea desde los scripts.

: "${BG_DIR:=/tmp/av-bg}"
mkdir -p "$BG_DIR"

# ---------- localización de los .tgz ----------
# find_tgz <ID>  busca <ID>.tgz en, por orden:
#   1) $TGZ_DIR (si está definida y existe)
#   2) $HOME/Descargas (estándar de la VM del aula)
#   3) ../practica-N/ relativo al directorio scripts/ (en local)
find_tgz() {
  local id="$1"
  local candidates=()
  [ -n "${TGZ_DIR:-}" ]              && candidates+=( "${TGZ_DIR}/${id}.tgz" )
  candidates+=( "${HOME}/Descargas/${id}.tgz" )
  # Detecta el número de práctica del id (L0X-EYY -> X)
  local n="${id#L0}"; n="${n%%-*}"
  local av_dir
  av_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  candidates+=( "${av_dir}/practica-${n}/${id}.tgz" )

  for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}

# require_lincus — corta de raíz si no estamos en la VM con lincus disponible
require_lincus() {
  if ! command -v lincus >/dev/null 2>&1; then
    cat >&2 <<EOF

[AV] ERROR: 'lincus' no está en PATH.

Estos modos (config / traffic / analysis / cleanup / all / e01 / e02) sólo
pueden ejecutarse en la VM del aula (Ubuntu con incus + lincus instalados).

En tu Mac puedes usar:
  bash av.sh inspect <ruta-al-.tgz>   # ver la topología sin VM
  bash av.sh test                     # correr el harness con mocks

Para ejecutar la práctica de verdad:
  - Copia la carpeta scripts/ + los .tgz a la VM avionica.
  - Allí lanza: bash scripts/av.sh p1 all  (etc.)

EOF
    exit 2
  fi
}

# ---------- logging ----------
_lcolor() { case "${1:-info}" in
  info) printf "\033[1;34m";;
  ok)   printf "\033[1;32m";;
  warn) printf "\033[1;33m";;
  err)  printf "\033[1;31m";;
  hdr)  printf "\033[1;36m";;
esac; }
_lnocolor() { printf "\033[0m"; }

LOG_TAG="${LOG_TAG:-AV}"
log()   { _lcolor info; printf "[%s]" "$LOG_TAG"; _lnocolor; printf " %s\n" "$*"; }
ok()    { _lcolor ok;   printf "[%s] ✓" "$LOG_TAG"; _lnocolor; printf " %s\n" "$*"; }
warn()  { _lcolor warn; printf "[%s] WARN:" "$LOG_TAG"; _lnocolor; printf " %s\n" "$*"; }
err()   { _lcolor err;  printf "[%s] ERR :" "$LOG_TAG"; _lnocolor; printf " %s\n" "$*" >&2; }
header(){ echo; _lcolor hdr; printf "==== %s ====" "$*"; _lnocolor; echo; }

# ---------- background helpers ----------
# bg_start <tag> <host> <comando shell completo>
# Ejecuta el comando dentro del contenedor `host` en background,
# guarda el PID en $BG_DIR/<tag>.pid (PID dentro del contenedor)
bg_start() {
  local tag="$1" host="$2"; shift 2
  local cmd="$*"
  local pidfile="${BG_DIR}/${tag}.pid"
  local hostfile="${BG_DIR}/${tag}.host"
  echo "$host" > "$hostfile"
  # Lanzar dentro del contenedor con doble fork para que el PID quede dentro.
  incus exec "$host" -- sh -c "
    nohup sh -c '$cmd' >/tmp/${tag}.out 2>&1 &
    echo \$! > /tmp/${tag}.pid
  "
  ok "bg start [$tag@$host] -> /tmp/${tag}.{out,pid}"
}

# bg_stop <tag>  -> mata el proceso en el host registrado
bg_stop() {
  local tag="$1"
  local hostfile="${BG_DIR}/${tag}.host"
  [ -f "$hostfile" ] || { warn "no hay registro de bg [$tag]"; return; }
  local host; host="$(cat "$hostfile")"
  incus exec "$host" -- sh -c "
    if [ -f /tmp/${tag}.pid ]; then
      kill \$(cat /tmp/${tag}.pid) 2>/dev/null || true
      rm -f /tmp/${tag}.pid
    fi
  " || true
  rm -f "$hostfile"
  ok "bg stop  [$tag@$host]"
}

# bg_output <tag>  -> muestra el output capturado
bg_output() {
  local tag="$1"
  local hostfile="${BG_DIR}/${tag}.host"
  [ -f "$hostfile" ] || { warn "no hay output de [$tag]"; return; }
  local host; host="$(cat "$hostfile")"
  incus exec "$host" -- cat "/tmp/${tag}.out" 2>/dev/null || true
}

bg_pull_pcap() {
  local tag="$1" dest="$2"
  local hostfile="${BG_DIR}/${tag}.host"
  [ -f "$hostfile" ] || return 1
  local host; host="$(cat "$hostfile")"
  incus file pull "${host}/tmp/${tag}.pcap" "$dest" 2>/dev/null || true
}

# kill_all_bg — mata cualquier proceso bg que hayamos lanzado
kill_all_bg() {
  for hf in "${BG_DIR}"/*.host; do
    [ -f "$hf" ] || continue
    local tag
    tag="$(basename "$hf" .host)"
    bg_stop "$tag"
  done
}

# ---------- inspect topology helper ----------
SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSPECT_PY="${SCRIPT_LIB_DIR}/../test/inspect-scenario.py"

show_topology_for() {
  local id="$1" tgz_path="$2"
  if [ -f "$INSPECT_PY" ] && [ -f "$tgz_path" ]; then
    python3 "$INSPECT_PY" "$tgz_path" 2>/dev/null
  else
    warn "No puedo mostrar topología (falta inspect-scenario.py o $tgz_path)"
  fi
}

# ---------- consultar la red (sin asumir Wireshark, sólo tcpdump dentro del contenedor) ----------
# capture_start <tag> <host> <iface> [<extra-tcpdump-args>...]
# Inicia tcpdump dentro del contenedor, escribiendo /tmp/<tag>.pcap
capture_start() {
  local tag="$1" host="$2" iface="$3"; shift 3
  echo "$host" > "${BG_DIR}/${tag}.host"
  incus exec "$host" -- sh -c "
    nohup tcpdump -i ${iface} -U -w /tmp/${tag}.pcap $* >/tmp/${tag}.out 2>&1 &
    echo \$! > /tmp/${tag}.pid
  "
  # Pequeña espera para asegurar que tcpdump está listo
  sleep 0.5
  ok "capture [$tag@$host:$iface] -> /tmp/${tag}.pcap"
}

capture_stop() {
  local tag="$1"
  local hostfile="${BG_DIR}/${tag}.host"
  [ -f "$hostfile" ] || return
  local host; host="$(cat "$hostfile")"
  incus exec "$host" -- sh -c "
    if [ -f /tmp/${tag}.pid ]; then
      kill -INT \$(cat /tmp/${tag}.pid) 2>/dev/null || true
      sleep 0.3
      kill -KILL \$(cat /tmp/${tag}.pid) 2>/dev/null || true
      rm -f /tmp/${tag}.pid
    fi
  " || true
  ok "capture stop [$tag]"
}

# capture_dump <tag>  -> imprime el pcap decodificado por tcpdump
capture_dump() {
  local tag="$1"
  local hostfile="${BG_DIR}/${tag}.host"
  [ -f "$hostfile" ] || return
  local host; host="$(cat "$hostfile")"
  incus exec "$host" -- tcpdump -r "/tmp/${tag}.pcap" -nn -e -v 2>/dev/null || true
}

# Devuelve la MAC de una interfaz de un contenedor
mac_of() {
  local host="$1" iface="${2:-eth0}"
  incus exec "$host" -- ip link show "$iface" 2>/dev/null \
    | awk '/link\/ether/ {print $2; exit}'
}

# Devuelve la IPv4 (sin máscara) de la primera dirección de una interfaz
ip_of() {
  local host="$1" iface="${2:-eth0}"
  incus exec "$host" -- ip -4 addr show "$iface" 2>/dev/null \
    | awk '/inet / {print $2; exit}' | cut -d/ -f1
}
