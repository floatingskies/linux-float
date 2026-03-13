# linux-float

Um kernel adaptativo construído para **máxima fluidez sem sacrificar eficiência energética** — detecta automaticamente seu hardware e compila otimizado especificamente para ele.

Derivado do [linux-psycachy](https://git.linux.toys/psygreg/linux-psycachy) e do patchset CachyOS, com foco em três objetivos simultâneos:

> **Performance máxima · Economia de energia · Tempo de compilação mínimo**

---

## O que diferencia o linux-float

### Detecção automática de hardware

O build script identifica sua geração de CPU antes de compilar e aplica o perfil correto:

| Hardware detectado | Perfil | Comportamento |
|---|---|---|
| i3/i5/i7 2ª–3ª gen, Xeon E3/E5 v1-v2, 2–4 núcleos | **modest** | HZ 500, schedutil, anti-thrash agressivo, NR_CPUS=16 |
| i5/i7 4ª–9ª gen, Xeon E3/E5 v3-v4, Ryzen 1000–3000, 4–8 núcleos | **balanced** | HZ 1000, schedutil, memória equilibrada, NR_CPUS=64 |
| i7/i9 10ª+ gen, Xeon Scalable, Ryzen 5000+, EPYC, 8+ núcleos | **performance** | HZ 1000, performance governor, THP ativo, NR_CPUS=512 |

Você também pode forçar um perfil manualmente: `./build.sh 6.14.13 --profile balanced`

---

### Compilador — Clang + ThinLTO (padrão)

O script detecta e usa **Clang** automaticamente quando disponível, com fallback para GCC:

| Compilador | Vantagem |
|---|---|
| `clang + ThinLTO` | Build ~20–40% mais rápido · otimização interprocedural · melhor inline |
| `clang + ccache` | Recompilações até 10× mais rápidas |
| `gcc` | Fallback seguro quando Clang não está instalado |

Para forçar: `./build.sh 6.14.13 --clang` ou `--gcc`

---

### Scheduler — BORE ajustado por perfil

O patchset inclui o [BORE scheduler](https://github.com/firelzrd/bore-scheduler), que penaliza processos burst e prioriza tarefas interativas. Os parâmetros variam por perfil:

| Parâmetro | Upstream | modest | balanced | performance |
|---|---|---|---|---|
| `sched_burst_penalty_offset` | 24 | 22 | 23 | 24 |
| `sched_burst_penalty_scale` | 1536 | 1280 | 1400 | 1536 |
| `sched_burst_cache_lifetime` | 75 ms | 60 ms | 70 ms | 75 ms |
| `sched_burst_smoothness` | 1 | 2 | 1 | 1 |
| `MIN_BASE_SLICE_NS` | 2 ms | 3 ms | 2 ms | 2 ms |

---

### Memória — proteção contra thrashing por perfil

| Parâmetro | modest (4–8 GB) | balanced (8–16 GB) | performance (16+ GB) |
|---|---|---|---|
| `ANON_MIN_RATIO` | 3% | 2% | 1% |
| `CLEAN_LOW_RATIO` | 20% | 15% | 10% |
| `CLEAN_MIN_RATIO` | 6% | 5% | 4% |
| `ZSWAP` | on, zstd | on, zstd | on, zstd |
| `THP` | MADVISE | MADVISE | ALWAYS |
| `ZRAM` | built-in | built-in | built-in |

---

### Kernel config — por perfil

| Opção | modest | balanced | performance |
|---|---|---|---|
| `PREEMPT` | FULL | FULL | FULL |
| `HZ` | **500** | 1000 | 1000 |
| `NR_CPUS` | **16** | 64 | 512 |
| `NUMA` | off | off | on (se Xeon/HEDT) |
| `CPU governor` | schedutil | schedutil | **performance** |
| `I/O scheduler` | BFQ built-in | BFQ built-in | Kyber (NVMe) / BFQ |
| `LTO` | ThinLTO | ThinLTO | ThinLTO |
| `DEBUG_INFO` | off | off | off |
| `FRAME_POINTER` | off | off | off |

---

### Velocidade de compilação

O linux-float foi projetado para compilar **o mais rápido possível**:

- **`--localmodconfig`** por padrão — compila apenas os módulos que seu sistema usa (~15–40 min)
- **Todos os threads disponíveis** são usados (não `nproc - 1`)
- **Clang + ThinLTO** reduz tempo de link em 20–40%
- **ccache** instalado automaticamente — recompilações são até 10× mais rápidas
- **Debug info desabilitada** — reduz tamanho do binário e tempo de compilação
- **Drivers não detectados são desabilitados** — menos código para compilar

---

## Patches aplicados

| Arquivo | Fonte | O que faz |
|---|---|---|
| `0001-bore-cachy.patch` | Masahito Suzuki / Piotr Gorski | BORE scheduler — prioriza tarefas interativas |
| `0002-bbr3.patch` | Peter Jung (CachyOS) | TCP BBR v3 — melhor throughput e latência |
| `0003-block.patch` | Peter Jung (CachyOS) | Melhorias no BFQ e mq-deadline |
| `0004-cachy.patch` | Peter Jung (CachyOS) | ADIOS I/O, memory ratio knobs, ZRAM, THP, GPU |
| `0005-fixes.patch` | Psygreg | Correções AMD CPU e Intel PSR |
| `config.patch` | Psygreg | Copia `.config` no diretório de headers para módulos externos |

> `0010-bore-cachy-fix.patch` é pulado — as declarações já estão presentes em `0001`.

---

## Compilando

### Pré-requisitos

O script instala as dependências automaticamente. Para referência:

```
libncurses-dev gawk flex bison openssl libssl-dev dkms libelf-dev
libudev-dev libpci-dev libiberty-dev autoconf bc rsync kmod cpio
zstd libzstd-dev python3 wget curl debhelper libdw-dev elfutils
libnuma-dev libcap-dev ccache clang lld llvm gcc
```

### Uso

```bash
git clone <este repo>
cd linux-float
chmod +x build.sh

# Versão específica (recomendado):
./build.sh 6.14.13

# Resolver última patch release automaticamente:
./build.sh 6.14

# Com opções:
./build.sh 6.14.13 --clang --profile balanced
./build.sh 6.14.13 --gcc --localyesconfig
./build.sh 6.14.13 --profile performance --full
```

O script vai:
1. Detectar sua CPU e classificar geração/arquitetura
2. Selecionar Clang ou GCC (com ccache)
3. Normalizar a versão (ex: `6.14.0-37` → `6.14.0`)
4. Baixar o tarball de kernel.org
5. Aplicar patches em ordem de `src/` e depois da raiz
6. Configurar com o perfil correto para seu hardware
7. Compilar com todos os threads disponíveis
8. Gerar `.deb` em `build/`

### Instalando

```bash
cd build/
sudo dpkg -i linux-image-*linuxfloat*.deb linux-headers-*linuxfloat*.deb linux-libc-dev_*.deb
sudo update-grub
```

Reinicie e selecione o kernel **linux-float** no menu de boot.

### Configurações userspace CachyOS (opcional, recomendado)

Após instalar o kernel, aplique as otimizações de userspace (udev, sysctl, tmpfiles, modprobe):

```bash
chmod +x cachyconfs.sh
./cachyconfs.sh
```

---

## Estrutura do repositório

```
.
├── build.sh                   # Build script principal
├── cachyconfs.sh              # Instalador de configurações CachyOS userspace
├── config                     # Kernel .config base do linux-float
├── config.patch               # Copia .config no diretório de headers
├── src/
│   ├── 0001-bore-cachy.patch
│   ├── 0002-bbr3.patch
│   ├── 0003-block.patch
│   ├── 0004-cachy.patch
│   ├── 0005-fixes.patch
│   └── 0010-bore-cachy-fix.patch  (pulado — redundante)
└── secureboot/
    ├── create-key.sh          # Assinar kernel para Secure Boot
    └── mokconfig.cnf
```

---

## Guia de escolha de perfil

Não sabe qual perfil escolher? Deixe o script detectar automaticamente, ou use esta tabela:

| Seu hardware | Perfil recomendado |
|---|---|
| Notebook antigo, Celeron, Pentium, i3 2ª–4ª gen | `modest` |
| i5/i7 Sandy Bridge, Ivy Bridge, Xeon E3/E5 v1–v2 | `modest` |
| i5/i7 Haswell–Coffee Lake (4ª–9ª gen) | `balanced` |
| Xeon E3/E5 v3–v4, Ryzen 1000–3000 | `balanced` |
| i7/i9 Ice Lake+ (10ª gen+), Ryzen 5000+ | `performance` |
| Xeon Scalable, EPYC, Threadripper | `performance` |

---

## Secure Boot

Para assinar o kernel em sistemas com Secure Boot ativo:

```bash
cd secureboot/
chmod +x create-key.sh
./create-key.sh
```

O script cria um par de chaves MOK, as registra no firmware e assina o kernel instalado.

---

## Licença

MIT, igual ao linux-psycachy e CachyOS upstream.
