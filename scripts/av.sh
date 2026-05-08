#!/usr/bin/env bash
# av.sh — Orquestador de las prácticas de AV
# Lanza practica1.sh / practica2.sh / practica3.sh con un único punto de entrada.
#
# Uso:
#   bash av.sh check                # verifica lincus/incus y los .tgz
#   bash av.sh p1 [e01|e02|all]     # ejecuta práctica 1
#   bash av.sh p2 [install|all|...] # ejecuta práctica 2
#   bash av.sh p3 [e01|e02|all]     # ejecuta práctica 3
#   bash av.sh stop                 # lincus stop
#   bash av.sh clear                # lincus clear (cuidado: elimina escenarios)
#   bash av.sh save <ID>            # lincus save del escenario activo
#   bash av.sh status               # lincus list

set -euo pipefail

# ============================================================
#                          CONFIG
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P1="${SCRIPT_DIR}/practica1.sh"
P2="${SCRIPT_DIR}/practica2.sh"
P3="${SCRIPT_DIR}/practica3.sh"

TGZ_DIR="${HOME}/Descargas"
REQUIRED_TGZ=(
  "L01-E01.tgz"
  "L01-E02.tgz"
  "L02-E01.tgz"
  "L03-E01.tgz"
  "L03-E02.tgz"
)
REQUIRED_HELPERS=(
  "gen_tc_egress.sh"
  "ipv4_multicast_to_mac.py"
)

# ============================================================
#                       FIN CONFIG
# ============================================================

log()  { printf "\033[1;32m[AV]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[AV] WARN:\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[AV] ERR :\033[0m %s\n" "$*" >&2; }

check_env() {
  log "Comprobando entorno…"
  for cmd in lincus incus; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "No se encuentra '$cmd' en el PATH"
      return 1
    fi
  done
  log "  lincus -> $(command -v lincus)"
  log "  incus  -> $(command -v incus)"

  log "Comprobando ficheros .tgz en $TGZ_DIR"
  for f in "${REQUIRED_TGZ[@]}"; do
    if [ -f "${TGZ_DIR}/${f}" ]; then
      log "  ✓ $f"
    else
      warn "  ✗ falta $f"
    fi
  done

  log "Comprobando helpers de la práctica 3"
  for f in "${REQUIRED_HELPERS[@]}"; do
    if [ -f "${TGZ_DIR}/${f}" ]; then
      log "  ✓ $f"
    else
      warn "  ✗ falta $f"
    fi
  done

  log "Escenarios instalados:"
  lincus list 2>/dev/null | sed 's/^/    /' || warn "lincus list falló"
}

usage() {
  cat <<EOF
Uso: $0 <comando> [args]

Comandos:
  check            Verifica lincus, incus y ficheros .tgz/helper
  status           Muestra escenarios instalados (lincus list)
  p1 [mode]        Ejecuta práctica 1 (modes: topology|config|traffic|analysis|respuestas|e01|e02|cleanup|stop|all)
  p2 [mode]        Ejecuta práctica 2 (modes: topology|subnetting|config|traffic|analysis|respuestas|cleanup|save|stop|all)
  p3 [mode]        Ejecuta práctica 3 (modes: topology|config|traffic|analysis|respuestas|e01|e02|table|cleanup|stop|all)
  inspect <tgz>    Muestra topología, MACs, bridges y ficheros de un escenario
  test             Ejecuta el harness de tests (mocks lincus/incus)
  stop             lincus stop
  clear            lincus clear (¡borra escenarios instalados!)
  save <ID>        lincus save (genera <ID>.tgz en \$HOME)

Ejemplo:
  $0 check
  $0 p1 e01
  $0 p2 all
  $0 p3 e02
EOF
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    check)   check_env ;;
    status)  lincus list ;;
    p1)      bash "$P1" "${1:-all}" ;;
    p2)      bash "$P2" "${1:-all}" ;;
    p3)      bash "$P3" "${1:-all}" ;;
    inspect)
      [ -z "${1:-}" ] && { err "Uso: $0 inspect <ruta-al-.tgz-o-dir>"; exit 1; }
      python3 "${SCRIPT_DIR}/test/inspect-scenario.py" "$1"
      ;;
    test)    bash "${SCRIPT_DIR}/test/run-tests.sh" ;;
    stop)    lincus stop ;;
    clear)
      read -r -p "¿Seguro que quieres ejecutar 'lincus clear'? [y/N] " r
      [[ "$r" =~ ^[yY]$ ]] && lincus clear || log "cancelado"
      ;;
    save)
      [ -z "${1:-}" ] && { err "Falta ID del escenario"; exit 1; }
      lincus save "$1"
      ;;
    -h|--help|help|"") usage ;;
    *) err "Comando desconocido: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
