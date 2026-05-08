# Aviónica · Prácticas de Redes

Automatización completa de las tres prácticas de la asignatura **Aviónica (4º curso)**:

- **Práctica 1** — Redes IP de Área Local (gestión de interfaces, ARP, DHCP)
- **Práctica 2** — Interconexión de Redes IP (subnetting, routing con FRR/vtysh, DHCP)
- **Práctica 3** — Emulación AFDX (bonding redundante, direccionamiento, multicast)

Cada práctica se ejecuta con un único comando que **configura el escenario, lanza el tráfico real en background, captura con `tcpdump`, decodifica las capturas, rellena las tablas de los enunciados con datos del run y responde a las preguntas teóricas**.

---

## Estructura

```
AV/
├── practica-1/                  enunciado, presentación y .tgz de Práctica 1
├── practica-2/                  enunciado, presentación y .tgz de Práctica 2
├── practica-3/                  enunciado, presentación, helpers y .tgz de Práctica 3
├── lincus/                      tarball + instalador del runtime lincus
├── scripts/
│   ├── av.sh                    orquestador (entrada principal)
│   ├── practica1.sh             P1 — IP/ARP/DHCP
│   ├── practica2.sh             P2 — Routing/Subnetting
│   ├── practica3.sh             P3 — Bonding/AFDX
│   ├── lib/
│   │   └── common.sh            helpers compartidos (logging, bg traffic, captura)
│   └── test/
│       ├── inspect-scenario.py  visor de topología (lee los .tgz)
│       ├── run-tests.sh         harness con mocks (78 tests)
│       └── mocks/               stubs de lincus/incus para testear sin VM
└── README.md
```

---

## Requisitos

### Para ejecutar las prácticas (configuración real)
- Linux con `incus` (o el alias `lxc`) y `bridge-utils` instalados.
- `lincus` (incluido en `lincus/lincus.tgz`; instalar con `sudo bash lincus/install-lincus.sh`).
- Python 3.
- `tcpdump`, `socat`, `nc`, `iproute2` dentro de los contenedores Alpine (vienen por defecto en las imágenes del aula).
- FRR/`vtysh` en los routers (P2). Imágenes `router` del aula ya lo traen.

### Para inspeccionar/testear en cualquier sistema (incluido macOS)
- `bash` 3.2+
- `python3`
- `tar` y `gzip`

---

## Comandos por práctica

### Entrada principal — `av.sh`

| Comando                          | Qué hace                                                    |
| -------------------------------- | ----------------------------------------------------------- |
| `bash av.sh check`               | Verifica `lincus`/`incus`, los `.tgz` y los helpers          |
| `bash av.sh status`              | `lincus list` — qué escenarios están instalados             |
| `bash av.sh inspect <ruta.tgz>`  | Visor de topología (sin necesitar VM ni `lincus`)           |
| `bash av.sh test`                | Ejecuta el harness (78 tests con mocks)                     |
| `bash av.sh p1 <modo>`           | Práctica 1 — ver modos abajo                                |
| `bash av.sh p2 <modo>`           | Práctica 2 — ver modos abajo                                |
| `bash av.sh p3 <modo>`           | Práctica 3 — ver modos abajo                                |
| `bash av.sh stop`                | `lincus stop` — para los escenarios en ejecución            |
| `bash av.sh save <ID>`           | `lincus save <ID>` — guarda progreso (genera `<ID>.tgz`)    |

### Práctica 1 — `bash av.sh p1 <modo>`

```
bash av.sh p1 all          # E01 + E02 (config + tráfico bg + análisis + respuestas)
bash av.sh p1 e01          # solo L01-E01 (IP estáticas + ARP)
bash av.sh p1 e02          # solo L01-E02 (DHCP + persistencia)

bash av.sh p1 topology     # solo dibuja la topología
bash av.sh p1 config       # solo configura (sin tráfico)
bash av.sh p1 traffic      # solo lanza ping/DHCP en bg + captura
bash av.sh p1 analysis     # solo decodifica capturas y rellena tablas
bash av.sh p1 respuestas   # solo imprime respuestas teóricas
bash av.sh p1 cleanup      # mata procesos en background
```

### Práctica 2 — `bash av.sh p2 <modo>`

```
bash av.sh p2 all          # subnetting + config + tráfico bg + análisis + respuestas
bash av.sh p2 topology
bash av.sh p2 subnetting   # tabla de subredes calculada (no necesita VM)
bash av.sh p2 config       # IPs en routers vía vtysh + rutas estáticas + DHCP
bash av.sh p2 traffic      # captura DHCP + ping entre pares de hosts
bash av.sh p2 analysis
bash av.sh p2 respuestas
bash av.sh p2 cleanup
bash av.sh p2 save         # lincus save (genera L02-E01.tgz para sesión siguiente)
```

### Práctica 3 — `bash av.sh p3 <modo>`

```
bash av.sh p3 all          # E01 + E02 (config + tráfico bg + análisis + respuestas)
bash av.sh p3 e01          # solo L03-E01 (Bonding redundante)
bash av.sh p3 e02          # solo L03-E02 (AFDX direccionamiento)

bash av.sh p3 topology
bash av.sh p3 table        # tabla de MACs AFDX calculadas (no necesita VM)
bash av.sh p3 config
bash av.sh p3 traffic      # tráfico AFDX bg (3 paquetes P1→VL1, P1→VL2, P2→VL2)
bash av.sh p3 analysis
bash av.sh p3 respuestas
bash av.sh p3 cleanup
```

---

## Flujo típico en la VM del aula

```bash
# 1) Llevar el repo a la VM (USB / scp / git clone si tienes acceso)
cd ~/Avionica

# 2) Comprobar que el entorno está OK
bash scripts/av.sh check

# 3) Ejecutar la práctica completa
bash scripts/av.sh p1 all          # P1 entera

# Inspeccionar resultados:
#   - Las capturas .pcap están en cada contenedor en /tmp/<tag>.pcap
#   - Los logs de bg en /tmp/<tag>.out
#   - La traza de procesos bg lanzados desde el host: /tmp/av-bg/

# 4) Antes de salir del aula, guardar progreso (P2 lo soporta)
bash scripts/av.sh save L02-E01    # genera ~/L02-E01.tgz

# 5) Limpieza
bash scripts/av.sh stop
```

---

## Ejecución en macOS / sin VM (modo offline)

En macOS no hay `lincus`/`incus`, pero sí puedes:

```bash
cd scripts/

# Ver topología de cualquier escenario
bash av.sh p1 topology
bash av.sh inspect ../practica-2/L02-E01.tgz

# Calcular subnetting (P2)
bash av.sh p2 subnetting

# Calcular tabla de MACs AFDX (P3)
bash av.sh p3 table

# Imprimir las respuestas teóricas
bash av.sh p2 respuestas

# Correr el harness completo (78 tests con mocks de lincus/incus)
bash av.sh test
```

Si intentas correr un modo que requiere VM (`config`, `traffic`, `all`...), el script falla con un mensaje claro indicándolo.

---

## Adaptar a tu enunciado / valores asignados

Cada `practica*.sh` tiene un bloque `CONFIG` arriba. **Sólo edita ese bloque** y todo lo demás se ajusta solo:

### `practica1.sh`
```bash
HOSTS_E01=("H01:192.168.1.101" ...)   # IPs por host
DHCP_STATIC_HOSTS=("H03" "H04")        # asignación fija por MAC
DHCP_STATIC_IPS=("192.168.1.20" ...)
DHCP_RANGE_START="192.168.1.31"
```

### `practica2.sh`
```bash
SUBNETS=("D:70:25:192.168.1.0/25" ...) # red:ndisp:prefix:network
IFACES=("R01:eth1:10.0.0.1/30" ...)    # device:iface:ip/prefix
ROUTES=("R05:192.168.2.128/25:10.0.0.14" ...)  # router:prefix:nexthop
DHCP_BLOCKS=("R01:eth0:192.168.1.10:192.168.1.50:12h:192.168.1.1" ...)
```

### `practica3.sh`
```bash
ES1_USER_ID_HEX="0001"          # tu User ID asignado
ES1_PART1_ID_HEX="01"           # IDs de partición
ES1_SRC_MAC="02:00:00:00:00:01" # MAC origen del End System
ES1_PART1_IP="10.0.1.1/8"       # IP origen partición 1
VLS=("VL1:224.224.0.1" ...)     # virtual links multicast
```

Tras editar, valida con `bash av.sh test` (en cualquier OS) que las aserciones siguen pasando.

---

## Variables de entorno útiles

| Variable          | Default                | Para qué sirve                                                  |
| ----------------- | ---------------------- | --------------------------------------------------------------- |
| `TGZ_DIR`         | (auto-detectado)       | Forzar dónde están los `.tgz` (orden: env → `~/Descargas` → `../practica-N/`) |
| `BG_DIR`          | `/tmp/av-bg`           | Donde guardar PIDs y outputs de procesos en background          |
| `MOCK_TRACE`      | `/tmp/av-mock-trace.log` | Solo en testing: traza de llamadas a `lincus`/`incus`           |
| `MOCK_STRICT`     | `1` en run-tests.sh    | Solo en testing: aborta si el script invoca un host inexistente |

---

## Tests

```bash
bash scripts/av.sh test
```

El harness:
1. Sintaxis de los 5 scripts (`bash -n`).
2. Extrae los 5 escenarios `.tgz` y los pone en `/tmp/av-scenarios/`.
3. Reemplaza `lincus`/`incus` por mocks topology-aware que leen `topology.yaml` y responden con MACs reales.
4. Ejecuta cada práctica en cada modo y verifica con `grep` que la traza de llamadas tiene los comandos correctos.
5. Compara `afdx_dst_mac` y `ipv4_mcast_to_mac` con el `ipv4_multicast_to_mac.py` oficial del enunciado.
6. Cruza los `IFACES` del CONFIG con la topología real para detectar referencias a interfaces que no existen.

Resultado actual: **78/78 tests OK**.

---

## Material original

Los `.docx` con los enunciados, las `.pptx` de fundamentos y los `.tgz` originales del aula están en `practica-{1,2,3}/` y `lincus/`. No los tocamos — son la fuente de verdad para las preguntas teóricas embebidas en los scripts.

---

## Limitaciones honestas

- En macOS los scripts solo simulan (mocks). No hay `incus` ARM trivial; podrías levantar Ubuntu en UTM, instalar `lincus` con `sudo bash lincus/install-lincus.sh` y correr todo de verdad — pero es trabajo de tarde.
- Los **User IDs y Partition IDs de P3** son placeholder. Cuando te asignen los tuyos, edita `ES1_USER_ID_HEX`, `ES1_PART1_ID_HEX`, `ES1_SRC_MAC` y las IPs de partición en `practica3.sh`.
- El **subnetting de P2** está pre-calculado para los requisitos del enunciado (D=70→/25, A=48→/26, C=30→/27, B=24→/27). Si te dan otros, edita `SUBNETS` y `IFACES`.
- Las **respuestas teóricas** son las del enunciado oficial. Si la rúbrica del profesor pide más detalle, revisa.

---

## Autoría

Trabajo realizado para la asignatura de Aviónica del 4º curso. Scripts generados en colaboración con Claude Code.
