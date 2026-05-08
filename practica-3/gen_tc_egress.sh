#!/bin/sh

clear_mode=0
show_mode=0

# --- Procesar opciones ---
while [ "$#" -gt 0 ]; do
    case "$1" in
        --clear)
            clear_mode=1
            shift
            ;;
        --show)
            show_mode=1
            shift
            ;;
        *)
            iface="$1"
            shift
            break
            ;;
    esac
done

if [ -z "$iface" ]; then
    echo "Uso: $0 [--clear|--show] INTERFACE N ip1 ip2 ... ipN" >&2
    exit 1
fi

# --- MODO CLEAR ---
if [ "$clear_mode" -eq 1 ]; then
    echo "Eliminando qdisc y filtros en $iface…"
    tc qdisc del dev "$iface" clsact 2>/dev/null
    exit 0
fi

# --- MODO SHOW ---
if [ "$show_mode" -eq 1 ]; then
    echo "=== QDISC ==="
    tc qdisc show dev "$iface" 2>/dev/null
    echo ""
    echo "=== FILTERS (egress) ==="
    tc filter show dev "$iface" egress 2>/dev/null
    exit 0
fi

# --- MODO NORMAL (crear reglas) ---
if [ "$#" -lt 1 ]; then
    echo "Uso: $0 INTERFACE N ip1 ip2 ... ipN" >&2
    exit 1
fi

N="$1"
shift

# Comprobación N
case "$N" in
    ''|*[!0-9]*) echo "N debe ser número entero >=1" >&2; exit 1 ;;
esac
if [ "$N" -lt 1 ]; then
    echo "N debe ser >=1" >&2
    exit 1
fi

if [ "$#" -ne "$N" ]; then
    echo "Número incorrecto de IPs: se esperaban $N" >&2
    exit 1
fi

# Crear qdisc
tc qdisc replace dev "$iface" clsact

for ip in "$@"; do
    # Validación IP
    IFS=. read -r a b c d <<EOF
$ip
EOF

    if [ "$a" -ne 224 ] || [ "$b" -ne 224 ]; then
        echo "IP fuera de 224.224.x.y: $ip" >&2
        exit 1
    fi
    for oct in "$c" "$d"; do
        case "$oct" in
            ''|*[!0-9]*) echo "IP inválida: $ip" >&2; exit 1 ;;
        esac
        if [ "$oct" -lt 0 ] || [ "$oct" -gt 255 ]; then
            echo "IP inválida: $ip" >&2
            exit 1
        fi
    done

    # MAC 02:00:00:00:XX:YY
    hex_c=$(printf "%02x" "$c")
    hex_d=$(printf "%02x" "$d")
    mac="02:00:00:00:${hex_c}:${hex_d}"

    tc filter add dev "$iface" egress protocol ip flower \
        dst_ip "$ip" \
        action pedit ex munge eth dst set "$mac" \
        action ok
done

