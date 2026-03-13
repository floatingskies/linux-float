# linux-float

A kernel variant built for **fluidity on modest hardware** — machines with 2 to 4 cores and 4 to 8 GB of RAM. Derived from [linux-psycachy](https://git.linux.toys/psygreg/linux-psycachy) and the CachyOS patchset, with a different set of priorities.

The goal is not raw throughput. It is **preventing stutters**: the mouse not freezing when a background process spikes, windows not locking up while the system swaps, disk I/O not blocking the UI. Everything below serves that goal.

---

## What makes it different

### Scheduler — BORE tuned for low core counts

The base patchset ships the [BORE scheduler](https://github.com/firelzrd/bore-scheduler) (Burst-Oriented Response Enhancer), which penalizes CPU-hungry background tasks and gives priority to interactive ones. linux-float ships with values tuned specifically for 2–4 core machines:

| Parameter | Upstream default | linux-float | Why |
|---|---|---|---|
| `sched_burst_penalty_offset` | 24 | 22 | Penalizes burst processes sooner — windows and mouse get CPU faster |
| `sched_burst_penalty_scale` | 1536 | 1280 | Softer penalty slope — prevents starvation on machines with few cores |
| `sched_burst_cache_lifetime` | 75 ms | 60 ms | Burst history forgotten faster — less residual penalty when switching tasks |
| `sched_burst_smoothness` | 1 | 2 | Smoother penalty transitions — less jitter on slow CPUs |
| `MIN_BASE_SLICE_NS` | 2 ms | 3 ms | Larger minimum time slice — fewer context switches per tick |

### Memory — protecting RAM from thrashing

The most impactful change for machines with 4–8 GB. The kernel normally makes aggressive decisions about what to evict from RAM. These settings make it protect what you are actually using:

| Parameter | Default | linux-float | Why |
|---|---|---|---|
| `ANON_MIN_RATIO` | 1% | 3% | Protects active process pages from being pushed to swap |
| `CLEAN_LOW_RATIO` | 15% | 20% | Keeps more file cache in RAM — browser tabs, shared libraries |
| `CLEAN_MIN_RATIO` | 4% | 6% | Hard floor on file cache — disk I/O does not thrash even under pressure |
| `ZSWAP` | off, lzo | **on, zstd** | Compressed RAM swap active by default — zstd gives ~30% better ratio than lzo |
| `THP` | ALWAYS | MADVISE | Disables automatic huge pages — prevents fragmentation waste on small RAM |
| `ZRAM` | module | built-in | Available at boot without manual `modprobe` |

### Kernel config

| Option | Upstream | linux-float | Why |
|---|---|---|---|
| `PREEMPT` | VOLUNTARY | **FULL** | Kernel interrupts any task immediately to serve the user |
| `HZ` | 1000 | **500** | Half the timer interrupts — real overhead on a 2-core CPU |
| `NR_CPUS` | 8192 | **16** | Saves ~50 MB of RAM in per-cpu structs that would never be used |
| `NUMA` | on | **off** | Removes NUMA decision overhead on every allocation — no modest machine has NUMA |
| `CPU governor` | schedutil | **performance** | No frequency ramp-up latency — CPU always ready |
| `BFQ I/O scheduler` | module | **built-in** | Active from boot — essential for HDDs and slow SSDs to not block the UI |

---

## Patches applied

The following patches are applied in order during build:

| File | Source | What it does |
|---|---|---|
| `0001-bore-cachy.patch` | Masahito Suzuki / Piotr Gorski | BORE scheduler — prioritizes interactive tasks over background burst processes |
| `0002-bbr3.patch` | Peter Jung (CachyOS) | BBR v3 TCP congestion control — better throughput and latency on home networks |
| `0003-block.patch` | Peter Jung (CachyOS) | BFQ and mq-deadline I/O scheduler improvements |
| `0004-cachy.patch` | Peter Jung (CachyOS) | CachyOS core: ADIOS I/O scheduler, memory ratio knobs, AMD/Intel GPU improvements, ZRAM, THP, v4l2loopback, vhba |
| `0005-fixes.patch` | Psygreg | Misc fixes for AMD CPU and Intel PSR |
| `config.patch` | Psygreg | Copies `.config` into kernel headers build directory for external module compatibility |

> `0010-bore-cachy-fix.patch` is intentionally skipped — its declarations are already present in `0001`.

---

## Building

### Prerequisites

Install dependencies (the build script handles this automatically):

```
libncurses-dev gawk flex bison openssl libssl-dev dkms libelf-dev
libudev-dev libpci-dev libiberty-dev autoconf llvm gcc bc rsync
kmod cpio zstd libzstd-dev libdw-dev libdwarf-dev elfutils
python3 wget curl debhelper
```

### Usage

```bash
git clone <this repo>
cd linux-float
chmod +x build.sh

# Build a specific version:
./build.sh 6.14.13

# Let the script resolve the latest patch release automatically:
./build.sh 6.14
```

The script will:
1. Normalize the version (strips Debian/Ubuntu suffixes like `6.14.0-37` → `6.14.0`)
2. Download the tarball from kernel.org (`.tar.xz`, falls back to `.tar.gz`)
3. Apply patches in order from `src/` then the root directory
4. Copy `config` and run `make olddefconfig`
5. Compile with `gcc` using `nproc - 1` threads
6. Output `.deb` packages to `build/`

### Installing

```bash
cd build/
sudo dpkg -i linux-image-*linuxfloat*.deb linux-headers-*linuxfloat*.deb linux-libc-dev_*.deb
sudo update-grub
```

Reboot and select the `linux-float` kernel in the boot menu.

### CachyOS system settings (optional but recommended)

After installing the kernel, apply CachyOS userspace tuning (udev rules, sysctl, tmpfiles, modprobe configs):

```bash
chmod +x cachyconfs.sh
./cachyconfs.sh
```

---

## Repository layout

```
.
├── build.sh              # Build script
├── cachyconfs.sh         # CachyOS userspace configuration installer
├── config                # Kernel .config tuned for linux-float
├── config.patch          # Patch to copy .config into headers build dir
├── 0001-bore-cachy.patch
├── 0002-bbr3.patch
├── 0003-block.patch
├── 0004-cachy.patch
├── 0005-fixes.patch
└── 0010-bore-cachy-fix.patch  (skipped during build — redundant)
```

---

## License

MIT, same as upstream linux-psycachy and CachyOS.
