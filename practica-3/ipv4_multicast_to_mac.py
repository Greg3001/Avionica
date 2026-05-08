#!/usr/bin/env python3
import argparse
import sys

def ipv4_multicast_to_mac(ipv4_addr: str) -> str:
    # Parseo y validación básica
    parts = ipv4_addr.split(".")
    if len(parts) != 4:
        raise ValueError("Formato IPv4 no válido.")
    try:
        a, b, c, d = map(int, parts)
    except ValueError:
        raise ValueError("Formato IPv4 no válido.")

    for o in (a, b, c, d):
        if o < 0 or o > 255:
            raise ValueError("Octetos fuera de rango (0-255).")

    # Comprobación estricta del rango multicast 224.0.0.0/4 (1110xxxx)
    if (a & 0b11110000) != 0b11100000:
        raise ValueError("La dirección no pertenece al rango multicast IPv4 (224.0.0.0/4).")

    # Convertir IP a entero 32 bits y tomar los 23 bits inferiores
    ip_int = (a << 24) | (b << 16) | (c << 8) | d
    lower_23 = ip_int & 0x7FFFFF  # máscara de 23 bits

    # Obtener los 3 octetos finales
    mac4 = (lower_23 >> 16) & 0xFF
    mac5 = (lower_23 >> 8) & 0xFF
    mac6 = lower_23 & 0xFF

    return f"01:00:5e:{mac4:02x}:{mac5:02x}:{mac6:02x}"


def main():
    parser = argparse.ArgumentParser(
        description="Convierte una dirección IPv4 multicast en su MAC multicast Ethernet."
    )
    parser.add_argument(
        "ipv4",
        help="Dirección IPv4 multicast (224.0.0.0/4), ej. 224.0.1.129"
    )

    args = parser.parse_args()

    try:
        mac = ipv4_multicast_to_mac(args.ipv4)
        print(mac)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
