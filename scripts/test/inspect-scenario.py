#!/usr/bin/env python3
"""
inspect-scenario.py — Lee un .tgz de lincus (o un directorio ya extraído) y
muestra la topología: instancias, interfaces+MAC+bridge, bridges con sus
adjuntos y los ficheros de configuración iniciales más relevantes.

Uso:
    inspect-scenario.py path/a/L02-E01.tgz
    inspect-scenario.py /tmp/scenarios/L02-E01
"""
from __future__ import annotations

import argparse
import io
import os
import sys
import tarfile
import tempfile
from pathlib import Path


def _safe_load(text: str):
    """Carga YAML usando PyYAML si está disponible; si no, parser mínimo
    suficiente para los topology.yaml de lincus (sin tags ni multi-doc)."""
    try:
        import yaml  # type: ignore
        return yaml.safe_load(text)
    except ImportError:
        return _mini_yaml(text)


def _mini_yaml(text: str):
    """Parser muy básico para los YAML planos que usa lincus.
    Soporta: dicts anidados por indentación, listas con guion, valores
    escalares (strings/ints/booleans). No soporta flow style, anchors, etc."""
    lines = []
    for raw in text.splitlines():
        # quitar comentarios
        stripped = raw.split('#', 1)[0].rstrip()
        if not stripped.strip():
            continue
        lines.append(stripped)

    def parse_value(v: str):
        v = v.strip()
        if v == '' or v == '~' or v.lower() == 'null':
            return None
        if v.lower() == 'true':
            return True
        if v.lower() == 'false':
            return False
        if v.startswith('"') and v.endswith('"'):
            return v[1:-1].encode().decode('unicode_escape')
        if v.startswith("'") and v.endswith("'"):
            return v[1:-1]
        try:
            return int(v)
        except ValueError:
            pass
        return v

    def indent_of(line: str) -> int:
        return len(line) - len(line.lstrip(' '))

    pos = 0

    def parse_block(base_indent: int):
        nonlocal pos
        # Detecta dict vs list
        if pos >= len(lines):
            return None
        first = lines[pos]
        if indent_of(first) < base_indent:
            return None
        is_list = first.lstrip().startswith('- ')
        if is_list:
            return parse_list(base_indent)
        return parse_dict(base_indent)

    def parse_dict(base_indent: int):
        nonlocal pos
        out = {}
        while pos < len(lines):
            line = lines[pos]
            ind = indent_of(line)
            if ind < base_indent:
                break
            if ind > base_indent:
                # no debería pasar (lo capturaría el parent)
                pos += 1
                continue
            stripped = line.strip()
            if stripped.startswith('- '):
                break  # esto es una lista, lo coge el parent
            if ':' not in stripped:
                pos += 1
                continue
            key, _, rest = stripped.partition(':')
            key = key.strip()
            rest = rest.strip()
            pos += 1
            if rest == '':
                # valor en líneas siguientes (más indentado)
                if pos < len(lines) and indent_of(lines[pos]) > base_indent:
                    out[key] = parse_block(indent_of(lines[pos]))
                else:
                    out[key] = None
            else:
                out[key] = parse_value(rest)
        return out

    def parse_list(base_indent: int):
        nonlocal pos
        out = []
        while pos < len(lines):
            line = lines[pos]
            ind = indent_of(line)
            if ind < base_indent:
                break
            stripped = line.strip()
            if not stripped.startswith('- '):
                break
            item = stripped[2:].strip()
            pos += 1
            if item == '':
                # item compuesto en líneas siguientes
                if pos < len(lines) and indent_of(lines[pos]) > base_indent:
                    out.append(parse_block(indent_of(lines[pos])))
                else:
                    out.append(None)
            elif ':' in item:
                # primer par de un dict; reinyectamos para parse_dict
                lines.insert(pos, ' ' * (base_indent + 2) + item)
                out.append(parse_block(base_indent + 2))
            else:
                out.append(parse_value(item))
        return out

    return parse_block(0)


def extract_if_tgz(path: Path) -> Path:
    if path.is_dir():
        return path
    if not tarfile.is_tarfile(path):
        sys.exit(f"No es un .tgz ni un directorio: {path}")
    tmp = Path(tempfile.mkdtemp(prefix="lincus-"))
    with tarfile.open(path, 'r:gz') as tf:
        try:
            tf.extractall(tmp, filter='data')
        except TypeError:
            tf.extractall(tmp)  # Python <3.12
    # asume un único directorio raíz dentro del tarball
    sub = [p for p in tmp.iterdir() if p.is_dir()]
    if len(sub) == 1:
        return sub[0]
    return tmp


def fmt_mac(mac):
    return mac if mac else "(auto-asignada)"


def render(scenario_dir: Path):
    topo_file = scenario_dir / "topology.yaml"
    scen_file = scenario_dir / "scenario.yaml"
    if not topo_file.exists():
        sys.exit(f"No se encuentra {topo_file}")

    topo = _safe_load(topo_file.read_text())
    scen = _safe_load(scen_file.read_text()) if scen_file.exists() else {}

    title = scen.get('title', '(sin título)') if isinstance(scen, dict) else ''
    sid = scen.get('id', scenario_dir.name) if isinstance(scen, dict) else scenario_dir.name

    print(f"\n\033[1;36m== {sid} — {title} ==\033[0m\n")

    instances = (topo or {}).get('instances', {}) or {}
    networks = (topo or {}).get('networks', {}) or {}

    # Tabla de instancias
    print("\033[1mInstancias:\033[0m")
    print(f"  {'NAME':<6} {'IFACE':<8} {'MAC':<19} {'BRIDGE':<8} HOST_NAME")
    for name in sorted(instances):
        inst = instances[name] or {}
        devices = ((inst.get('incus') or {}).get('devices')) or {}
        if not devices:
            print(f"  {name:<6} (sin interfaces)")
            continue
        for iface, dev in devices.items():
            mac = fmt_mac(dev.get('hwaddr'))
            br = dev.get('network', '?')
            hn = dev.get('host_name', '?')
            print(f"  {name:<6} {iface:<8} {mac:<19} {br:<8} {hn}")
    print()

    # Tabla de bridges
    print("\033[1mRedes (bridges) y dispositivos conectados:\033[0m")
    for br in sorted(networks):
        attached = (networks[br] or {}).get('attachedInterfaces', []) or []
        # extrae el dispositivo (parte antes del guion)
        devs = sorted({a.split('-')[0] for a in attached})
        print(f"  {br:<6} -> {' + '.join(devs)}    [{', '.join(attached)}]")
    print()

    # Diagrama tipo árbol
    print("\033[1mDiagrama:\033[0m")
    for br in sorted(networks):
        attached = (networks[br] or {}).get('attachedInterfaces', []) or []
        devs = sorted({a.split('-')[0] for a in attached})
        print(f"  [{br}]")
        for a in attached:
            print(f"     ├── {a}")
    print()

    # Ficheros de configuración iniciales
    print("\033[1mFicheros iniciales destacados:\033[0m")
    for inst_name in sorted(instances):
        inst_dir = scenario_dir / inst_name
        if not inst_dir.exists():
            continue
        # /etc/network/interfaces
        ifc = inst_dir / "etc" / "network" / "interfaces"
        dns = inst_dir / "etc" / "dnsmasq.conf"
        frr = inst_dir / "etc" / "frr" / "frr.conf"
        for f in (ifc, dns, frr):
            if f.exists():
                rel = f.relative_to(scenario_dir)
                print(f"\n  \033[1;33m{inst_name}: {rel}\033[0m")
                content = f.read_text(errors='replace').rstrip()
                if not content:
                    print("    (vacío)")
                else:
                    for line in content.splitlines():
                        print(f"    {line}")
    print()

    # Resumen rápido
    print("\033[1mResumen:\033[0m")
    print(f"  Instancias:  {len(instances)}")
    print(f"  Redes:       {len(networks)}")
    n_macs = sum(
        1 for inst in instances.values()
        for dev in ((inst or {}).get('incus') or {}).get('devices', {}).values()
        if dev.get('hwaddr')
    )
    print(f"  MACs fijas:  {n_macs}")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", help="Ruta a .tgz o directorio extraído")
    args = ap.parse_args()

    p = Path(args.path).expanduser()
    if not p.exists():
        sys.exit(f"No existe: {p}")
    sd = extract_if_tgz(p)
    render(sd)


if __name__ == '__main__':
    main()
