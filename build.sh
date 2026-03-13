#!/bin/bash
# linux-float build script v1.1
# Usage: ./build.sh <version> [--localmodconfig|--localyesconfig|--full] [--clang|--gcc] [--profile modest|balanced|performance]
# Example: ./build.sh 6.14.13
#          ./build.sh 6.14.13 --clang --profile balanced

set -e

# =====================================================================
# CORES
# =====================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# =====================================================================
# DETECÇÃO DE CPU — Identifica geração, arquitetura e capacidades
# =====================================================================
detect_cpu() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}DETECTANDO CPU${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

    CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')
    CPU_CORES=$(nproc --all)
    CPU_THREADS=$(grep -c '^processor' /proc/cpuinfo)
    CPU_FAMILY=$(grep -m1 'cpu family' /proc/cpuinfo | awk '{print $NF}')
    CPU_MODEL_NUM=$(grep -m1 '^model\s' /proc/cpuinfo | awk '{print $NF}')
    CPU_FLAGS=$(grep -m1 '^flags' /proc/cpuinfo | sed 's/flags\s*:\s*//')

    echo -e "  Modelo:   ${GREEN}$CPU_MODEL${NC}"
    echo -e "  Núcleos:  ${GREEN}$CPU_CORES físicos / $CPU_THREADS threads${NC}"
    echo -e "  Vendor:   ${GREEN}$CPU_VENDOR${NC}"

    # ---- Classificar geração/arquitetura ----
    CPU_MARCH=""
    CPU_PROFILE=""   # modest | balanced | performance
    CPU_GENERATION=""

    if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
        case "$CPU_MODEL_NUM" in
            # Sandy Bridge — 2ª geração (i3/i5/i7-2xxx, Xeon E3/E5 v1)
            42|45)
                CPU_MARCH="sandybridge"
                CPU_GENERATION="Intel Sandy Bridge (2ª gen)"
                [[ $CPU_CORES -le 4 ]] && CPU_PROFILE="modest" || CPU_PROFILE="balanced"
                ;;
            # Ivy Bridge — 3ª geração (i3/i5/i7-3xxx, Xeon E3/E5 v2)
            58|62)
                CPU_MARCH="ivybridge"
                CPU_GENERATION="Intel Ivy Bridge (3ª gen)"
                [[ $CPU_CORES -le 4 ]] && CPU_PROFILE="modest" || CPU_PROFILE="balanced"
                ;;
            # Haswell — 4ª geração
            60|63|69|70)
                CPU_MARCH="haswell"
                CPU_GENERATION="Intel Haswell (4ª gen)"
                [[ $CPU_CORES -le 4 ]] && CPU_PROFILE="balanced" || CPU_PROFILE="performance"
                ;;
            # Broadwell — 5ª geração
            61|71)
                CPU_MARCH="broadwell"
                CPU_GENERATION="Intel Broadwell (5ª gen)"
                CPU_PROFILE="balanced"
                ;;
            # Skylake — 6ª geração
            78|94)
                CPU_MARCH="skylake"
                CPU_GENERATION="Intel Skylake (6ª gen)"
                CPU_PROFILE="balanced"
                ;;
            # Kaby Lake / Coffee Lake — 7ª–9ª
            142|158)
                CPU_MARCH="skylake"
                CPU_GENERATION="Intel Kaby/Coffee Lake (7ª-9ª gen)"
                CPU_PROFILE="balanced"
                ;;
            # Comet / Ice Lake — 10ª
            165|126)
                CPU_MARCH="icelake-client"
                CPU_GENERATION="Intel Ice/Comet Lake (10ª gen)"
                CPU_PROFILE="performance"
                ;;
            # Tiger Lake — 11ª
            140)
                CPU_MARCH="tigerlake"
                CPU_GENERATION="Intel Tiger Lake (11ª gen)"
                CPU_PROFILE="performance"
                ;;
            # Alder Lake / Raptor Lake — 12ª–13ª
            151|154)
                CPU_MARCH="alderlake"
                CPU_GENERATION="Intel Alder/Raptor Lake (12ª-13ª gen)"
                CPU_PROFILE="performance"
                ;;
            # Meteor Lake / Arrow Lake — 14ª+
            170|183)
                CPU_MARCH="x86-64-v3"
                CPU_GENERATION="Intel Meteor/Arrow Lake (14ª+ gen)"
                CPU_PROFILE="performance"
                ;;
            *)
                # Fallback: detectar via flags
                if echo "$CPU_FLAGS" | grep -q 'avx512'; then
                    CPU_MARCH="x86-64-v4"
                    CPU_GENERATION="Intel moderno (AVX-512)"
                    CPU_PROFILE="performance"
                elif echo "$CPU_FLAGS" | grep -q 'avx2'; then
                    CPU_MARCH="x86-64-v3"
                    CPU_GENERATION="Intel moderno (AVX2)"
                    CPU_PROFILE="balanced"
                elif echo "$CPU_FLAGS" | grep -q 'avx'; then
                    CPU_MARCH="sandybridge"
                    CPU_GENERATION="Intel com AVX"
                    CPU_PROFILE="balanced"
                else
                    CPU_MARCH="x86-64-v2"
                    CPU_GENERATION="Intel legado"
                    CPU_PROFILE="modest"
                fi
                ;;
        esac

        # Detectar Xeon (servidor)
        if echo "$CPU_MODEL" | grep -qi "xeon"; then
            echo -e "  Tipo:     ${MAGENTA}Xeon (servidor) — perfil ajustado${NC}"
            # Xeons com muitos núcleos → performance; modestos → balanced
            [[ $CPU_CORES -ge 8 ]] && CPU_PROFILE="performance" || CPU_PROFILE="balanced"
        fi

    elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        if echo "$CPU_FLAGS" | grep -q 'avx512'; then
            CPU_MARCH="znver4"
            CPU_GENERATION="AMD Zen 4"
            CPU_PROFILE="performance"
        elif echo "$CPU_MODEL" | grep -qiE 'ryzen.*[5-9]0[0-9][0-9]|threadripper|epyc'; then
            CPU_MARCH="znver3"
            CPU_GENERATION="AMD Zen 3/4 (Ryzen 5000+)"
            CPU_PROFILE="performance"
        elif echo "$CPU_MODEL" | grep -qiE 'ryzen.*[3-4][0-9][0-9][0-9]'; then
            CPU_MARCH="znver2"
            CPU_GENERATION="AMD Zen 2 (Ryzen 3000/4000)"
            CPU_PROFILE="balanced"
        elif echo "$CPU_MODEL" | grep -qiE 'ryzen.*[1-2][0-9][0-9][0-9]'; then
            CPU_MARCH="znver1"
            CPU_GENERATION="AMD Zen 1 (Ryzen 1000/2000)"
            CPU_PROFILE="balanced"
        elif echo "$CPU_FLAGS" | grep -q 'avx2'; then
            CPU_MARCH="x86-64-v3"
            CPU_GENERATION="AMD com AVX2"
            CPU_PROFILE="balanced"
        else
            CPU_MARCH="x86-64-v2"
            CPU_GENERATION="AMD legado"
            CPU_PROFILE="modest"
        fi
    else
        CPU_MARCH="x86-64-v2"
        CPU_GENERATION="Genérico x86-64"
        CPU_PROFILE="modest"
    fi

    # Override manual de perfil se passado por argumento
    [[ -n "$FORCED_PROFILE" ]] && CPU_PROFILE="$FORCED_PROFILE"

    echo -e "  Geração:  ${GREEN}$CPU_GENERATION${NC}"
    echo -e "  -march:   ${MAGENTA}$CPU_MARCH${NC}"
    echo -e "  Perfil:   ${BOLD}${GREEN}$CPU_PROFILE${NC}"

    export CPU_MARCH CPU_PROFILE CPU_GENERATION CPU_CORES CPU_THREADS
}

# =====================================================================
# DETECÇÃO DE COMPILADOR — clang preferido, gcc fallback
# =====================================================================
detect_compiler() {
    echo -e "\n${CYAN}[COMPILADOR]${NC}"

    CLANG_AVAIL=false
    CLANG_VER=""
    GCC_VER=$(gcc --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")

    if command -v clang &>/dev/null; then
        CLANG_AVAIL=true
        CLANG_VER=$(clang --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
        echo -e "  ${GREEN}✓ Clang $CLANG_VER disponível${NC}"
    else
        echo -e "  ${YELLOW}✗ Clang não encontrado${NC}"
    fi
    echo -e "  ${GREEN}✓ GCC $GCC_VER disponível${NC}"

    # Selecionar compilador
    if [[ "$FORCED_COMPILER" == "clang" && "$CLANG_AVAIL" == "true" ]]; then
        USE_COMPILER="clang"
    elif [[ "$FORCED_COMPILER" == "gcc" ]]; then
        USE_COMPILER="gcc"
    elif [[ "$CLANG_AVAIL" == "true" ]]; then
        # clang é preferido: builds mais rápidos com ThinLTO, melhor otimização
        USE_COMPILER="clang"
        echo -e "  ${CYAN}→ Clang selecionado automaticamente (build mais rápido + ThinLTO)${NC}"
    else
        USE_COMPILER="gcc"
        echo -e "  ${YELLOW}→ GCC selecionado (clang não disponível)${NC}"
    fi

    # Verificar ccache
    CCACHE_BIN=""
    if command -v ccache &>/dev/null; then
        CCACHE_BIN="ccache"
        echo -e "  ${GREEN}✓ ccache ativo — recompilações até 10x mais rápidas${NC}"
    fi

    export USE_COMPILER CCACHE_BIN CLANG_AVAIL
}

# =====================================================================
# DETECÇÃO DE HARDWARE (GPU, áudio, rede, etc.)
# =====================================================================
detect_hardware() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}DETECTANDO HARDWARE DO SISTEMA${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

    declare -gA DETECTED_GPU
    declare -gA DETECTED_AUDIO
    declare -gA DETECTED_NET
    declare -gA DETECTED_STORAGE
    declare -gA DETECTED_INPUT
    declare -gA DETECTED_OTHER

    GPU_INFO=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | head -5)

    echo -e "\n${YELLOW}[GPU]${NC}"
    echo "$GPU_INFO" | grep -qi 'nvidia' && { DETECTED_GPU[nvidia]=1; echo -e "  ${GREEN}✓ NVIDIA${NC}"; }
    echo "$GPU_INFO" | grep -qi 'amd\|radeon' && { DETECTED_GPU[amd]=1; echo -e "  ${GREEN}✓ AMD/Radeon${NC}"; }
    echo "$GPU_INFO" | grep -qi 'intel' && { DETECTED_GPU[intel]=1; echo -e "  ${GREEN}✓ Intel${NC}"; }
    lsmod | grep -q "^nvidia" && DETECTED_GPU[nvidia]=1
    lsmod | grep -q "^amdgpu" && DETECTED_GPU[amd]=1
    lsmod | grep -q "^i915" && DETECTED_GPU[intel]=1

    echo -e "\n${YELLOW}[ÁUDIO]${NC}"
    lsmod | grep -q "snd_hda" && { DETECTED_AUDIO[hda]=1; echo -e "  ${GREEN}✓ HDA${NC}"; }
    lsmod | grep -q "snd_soc" && { DETECTED_AUDIO[soc]=1; echo -e "  ${GREEN}✓ SoC${NC}"; }

    echo -e "\n${YELLOW}[REDE]${NC}"
    ETH_DRIVERS=$(lsmod | grep -E "^r8169|^e1000|^igb|^bnx|^tg3|^sky2" | awk '{print $1}')
    [[ -n "$ETH_DRIVERS" ]] && { DETECTED_NET[ethernet]=1; echo -e "  ${GREEN}✓ Ethernet: $ETH_DRIVERS${NC}"; }
    WIFI_DRIVERS=$(lsmod | grep -E "^iwlwifi|^ath|^rtw|^rtl|^mt76|^brcmfmac" | awk '{print $1}')
    [[ -n "$WIFI_DRIVERS" ]] && { DETECTED_NET[wifi]=1; echo -e "  ${GREEN}✓ WiFi: $WIFI_DRIVERS${NC}"; }
    lsmod | grep -q "btusb\|bluetooth" && { DETECTED_NET[bluetooth]=1; echo -e "  ${GREEN}✓ Bluetooth${NC}"; }

    echo -e "\n${YELLOW}[ARMAZENAMENTO]${NC}"
    lsmod | grep -q "nvme" && { DETECTED_STORAGE[nvme]=1; echo -e "  ${GREEN}✓ NVMe${NC}"; }
    lsmod | grep -qE "^sd_mod|^ahci" && { DETECTED_STORAGE[sata]=1; echo -e "  ${GREEN}✓ SATA${NC}"; }
    lsmod | grep -q "usb_storage" && { DETECTED_STORAGE[usb]=1; echo -e "  ${GREEN}✓ USB Storage${NC}"; }

    echo -e "\n${YELLOW}[VIRTUALIZAÇÃO]${NC}"
    lsmod | grep -qE "^kvm" && { DETECTED_OTHER[kvm]=1; echo -e "  ${GREEN}✓ KVM em uso${NC}"; }
    systemd-detect-virt &>/dev/null && {
        DETECTED_OTHER[virt_guest]=1
        echo -e "  ${GREEN}✓ VM: $(systemd-detect-virt)${NC}"
    }

    echo -e "\n${YELLOW}[OUTROS]${NC}"
    # nullglob evita travamento quando /dev/video* nao existe
    shopt -s nullglob
    video_devs=(/dev/video*)
    shopt -u nullglob
    if [[ ${#video_devs[@]} -gt 0 ]] || lsmod | grep -q "uvcvideo"; then
        DETECTED_OTHER[webcam]=1; echo -e "  ${GREEN}✓ Webcam${NC}"
    fi
    # lpstat omitido - pode travar se CUPS nao responder
    if lsmod | grep -q "usblp"; then
        DETECTED_OTHER[printer]=1; echo -e "  ${GREEN}✓ Impressora${NC}"
    fi
    echo -e "  ${GREEN}✓ Deteccao concluida${NC}"
}

# =====================================================================
# CONFIGURAR KERNEL — otimizações por perfil + hardware
# =====================================================================
auto_configure_kernel() {
    local KERNEL_DIR="$1"
    local MODE="$2"
    cd "$KERNEL_DIR"

    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}CONFIGURANDO KERNEL — MODO: ${GREEN}$MODE | PERFIL: $CPU_PROFILE${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

    case "$MODE" in
        localmodconfig)
            echo -e "${YELLOW}>>> localmodconfig (apenas módulos em uso)...${NC}"
            yes '' | make localmodconfig 2>/dev/null || true
            make olddefconfig
            ;;
        localyesconfig)
            echo -e "${YELLOW}>>> localyesconfig (módulos como built-in)...${NC}"
            yes '' | make localyesconfig 2>/dev/null || true
            make olddefconfig
            ;;
        full)
            echo -e "${YELLOW}>>> Configuração completa...${NC}"
            make olddefconfig
            ;;
    esac

    # ------------------------------------------------------------------
    # 1. OTIMIZAÇÕES DO COMPILADOR — nativas para a CPU detectada
    # ------------------------------------------------------------------
    echo -e "\n${CYAN}[Otimizações nativas de CPU]${NC}"

    # Habilitar otimização nativa para a arquitetura detectada
    case "$CPU_MARCH" in
        sandybridge)
            ./scripts/config --enable CONFIG_MCORE2 2>/dev/null || true
            echo -e "  ${GREEN}✓ Otimizado para Sandy Bridge (Core2/SSE4.2/AVX)${NC}"
            ;;
        ivybridge)
            ./scripts/config --enable CONFIG_MCORE2 2>/dev/null || true
            echo -e "  ${GREEN}✓ Otimizado para Ivy Bridge${NC}"
            ;;
        haswell)
            ./scripts/config --enable CONFIG_MHASWELL 2>/dev/null || true
            echo -e "  ${GREEN}✓ Otimizado para Haswell (AVX2/FMA3)${NC}"
            ;;
        broadwell)
            ./scripts/config --enable CONFIG_MBROADWELL 2>/dev/null || true
            echo -e "  ${GREEN}✓ Otimizado para Broadwell${NC}"
            ;;
        skylake|icelake-client|tigerlake)
            ./scripts/config --enable CONFIG_MSKYLAKE 2>/dev/null || true
            echo -e "  ${GREEN}✓ Otimizado para Skylake/Ice/Tiger Lake${NC}"
            ;;
        alderlake|x86-64-v3)
            ./scripts/config --enable CONFIG_MSKYLAKEX 2>/dev/null || true
            echo -e "  ${GREEN}✓ Otimizado para Alder Lake / x86-64-v3${NC}"
            ;;
        znver1)
            ./scripts/config --enable CONFIG_MZEN 2>/dev/null || true
            echo -e "  ${GREEN}✓ Otimizado para AMD Zen 1${NC}"
            ;;
        znver2)
            ./scripts/config --enable CONFIG_MZEN2 2>/dev/null || true
            echo -e "  ${GREEN}✓ Otimizado para AMD Zen 2${NC}"
            ;;
        znver3)
            ./scripts/config --enable CONFIG_MZEN3 2>/dev/null || true
            echo -e "  ${GREEN}✓ Otimizado para AMD Zen 3${NC}"
            ;;
        znver4|x86-64-v4)
            ./scripts/config --enable CONFIG_MZEN4 2>/dev/null || true
            echo -e "  ${GREEN}✓ Otimizado para AMD Zen 4 / x86-64-v4${NC}"
            ;;
        *)
            ./scripts/config --enable CONFIG_MX86_64_V2 2>/dev/null || true
            echo -e "  ${YELLOW}→ Usando x86-64-v2 genérico${NC}"
            ;;
    esac

    # ------------------------------------------------------------------
    # 2. PREEMPT, HZ E SCHEDULER — por perfil de hardware
    # ------------------------------------------------------------------
    echo -e "\n${CYAN}[Preempção e Timer]${NC}"

    case "$CPU_PROFILE" in
        modest)
            # Hardware modesto: FULL preempt + HZ 500 (menos overhead)
            ./scripts/config --enable CONFIG_PREEMPT 2>/dev/null || true
            ./scripts/config --disable CONFIG_PREEMPT_VOLUNTARY 2>/dev/null || true
            ./scripts/config --set-val CONFIG_HZ 500 2>/dev/null || true
            ./scripts/config --disable CONFIG_HZ_1000 2>/dev/null || true
            ./scripts/config --enable CONFIG_HZ_500 2>/dev/null || true
            ./scripts/config --set-val CONFIG_NR_CPUS 16 2>/dev/null || true
            ./scripts/config --disable CONFIG_NUMA 2>/dev/null || true
            echo -e "  ${GREEN}✓ PREEMPT FULL + HZ 500 + NR_CPUS=16 (modesto)${NC}"
            ;;
        balanced)
            # Hardware médio: FULL preempt + HZ 1000
            ./scripts/config --enable CONFIG_PREEMPT 2>/dev/null || true
            ./scripts/config --disable CONFIG_PREEMPT_VOLUNTARY 2>/dev/null || true
            ./scripts/config --set-val CONFIG_HZ 1000 2>/dev/null || true
            ./scripts/config --enable CONFIG_HZ_1000 2>/dev/null || true
            ./scripts/config --set-val CONFIG_NR_CPUS 64 2>/dev/null || true
            echo -e "  ${GREEN}✓ PREEMPT FULL + HZ 1000 + NR_CPUS=64 (balanced)${NC}"
            ;;
        performance)
            # Hardware forte: FULL preempt + HZ 1000 + NUMA se Xeon
            ./scripts/config --enable CONFIG_PREEMPT 2>/dev/null || true
            ./scripts/config --disable CONFIG_PREEMPT_VOLUNTARY 2>/dev/null || true
            ./scripts/config --set-val CONFIG_HZ 1000 2>/dev/null || true
            ./scripts/config --enable CONFIG_HZ_1000 2>/dev/null || true
            ./scripts/config --set-val CONFIG_NR_CPUS 512 2>/dev/null || true
            # Habilitar NUMA apenas se CPU_CORES >= 8 (prováveis Xeons/HEDT)
            if [[ $CPU_CORES -ge 8 ]]; then
                ./scripts/config --enable CONFIG_NUMA 2>/dev/null || true
                echo -e "  ${GREEN}✓ NUMA habilitado (Xeon/HEDT detectado)${NC}"
            fi
            echo -e "  ${GREEN}✓ PREEMPT FULL + HZ 1000 + NR_CPUS=512 (performance)${NC}"
            ;;
    esac

    # ------------------------------------------------------------------
    # 3. GOVERNOR DE CPU E ENERGIA
    # ------------------------------------------------------------------
    echo -e "\n${CYAN}[Governor de CPU]${NC}"

    case "$CPU_PROFILE" in
        modest)
            # schedutil no modesto: economiza energia, reduz calor
            ./scripts/config --enable CONFIG_CPU_FREQ_GOV_SCHEDUTIL 2>/dev/null || true
            ./scripts/config --enable CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL 2>/dev/null || true
            ./scripts/config --disable CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE 2>/dev/null || true
            # Habilitar P-states para Intel (melhor economia)
            ./scripts/config --enable CONFIG_X86_INTEL_PSTATE 2>/dev/null || true
            ./scripts/config --enable CONFIG_CPU_IDLE 2>/dev/null || true
            ./scripts/config --enable CONFIG_CPU_IDLE_GOV_MENU 2>/dev/null || true
            echo -e "  ${GREEN}✓ schedutil (economia de energia ativa)${NC}"
            ;;
        balanced)
            # schedutil com boost: responsivo mas eficiente
            ./scripts/config --enable CONFIG_CPU_FREQ_GOV_SCHEDUTIL 2>/dev/null || true
            ./scripts/config --enable CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL 2>/dev/null || true
            ./scripts/config --enable CONFIG_X86_INTEL_PSTATE 2>/dev/null || true
            ./scripts/config --enable CONFIG_CPU_IDLE 2>/dev/null || true
            echo -e "  ${GREEN}✓ schedutil balanceado${NC}"
            ;;
        performance)
            # performance governor: sem latência de ramp-up
            ./scripts/config --enable CONFIG_CPU_FREQ_GOV_PERFORMANCE 2>/dev/null || true
            ./scripts/config --enable CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE 2>/dev/null || true
            ./scripts/config --disable CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL 2>/dev/null || true
            ./scripts/config --enable CONFIG_X86_INTEL_PSTATE 2>/dev/null || true
            echo -e "  ${GREEN}✓ performance governor (sem latência de freq)${NC}"
            ;;
    esac

    # ------------------------------------------------------------------
    # 4. MEMÓRIA — proteção contra thrashing (escala com perfil)
    # ------------------------------------------------------------------
    echo -e "\n${CYAN}[Memória e Swap]${NC}"

    case "$CPU_PROFILE" in
        modest)
            # Configurações agressivas anti-thrash para 4-8GB
            ./scripts/config --set-val CONFIG_ANON_MIN_RATIO 3 2>/dev/null || true
            ./scripts/config --set-val CONFIG_CLEAN_LOW_RATIO 20 2>/dev/null || true
            ./scripts/config --set-val CONFIG_CLEAN_MIN_RATIO 6 2>/dev/null || true
            # THP desabilitado em modesto (fragmentação)
            ./scripts/config --set-str CONFIG_TRANSPARENT_HUGEPAGE_MADVISE y 2>/dev/null || true
            ./scripts/config --disable CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS 2>/dev/null || true
            echo -e "  ${GREEN}✓ Anti-thrash agressivo para RAM limitada${NC}"
            ;;
        balanced)
            ./scripts/config --set-val CONFIG_ANON_MIN_RATIO 2 2>/dev/null || true
            ./scripts/config --set-val CONFIG_CLEAN_LOW_RATIO 15 2>/dev/null || true
            ./scripts/config --set-val CONFIG_CLEAN_MIN_RATIO 5 2>/dev/null || true
            echo -e "  ${GREEN}✓ Memória balanceada${NC}"
            ;;
        performance)
            ./scripts/config --set-val CONFIG_ANON_MIN_RATIO 1 2>/dev/null || true
            ./scripts/config --set-val CONFIG_CLEAN_LOW_RATIO 10 2>/dev/null || true
            ./scripts/config --set-val CONFIG_CLEAN_MIN_RATIO 4 2>/dev/null || true
            # THP sempre ativo em performance (RAM abundante)
            ./scripts/config --enable CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS 2>/dev/null || true
            echo -e "  ${GREEN}✓ Memória otimizada para throughput${NC}"
            ;;
    esac

    # ZSWAP + zstd em todos os perfis
    ./scripts/config --enable CONFIG_ZSWAP 2>/dev/null || true
    ./scripts/config --enable CONFIG_ZSWAP_COMPRESSOR_DEFAULT_ZSTD 2>/dev/null || true
    ./scripts/config --disable CONFIG_ZSWAP_COMPRESSOR_DEFAULT_LZO 2>/dev/null || true
    ./scripts/config --enable CONFIG_ZRAM 2>/dev/null || true   # built-in
    echo -e "  ${GREEN}✓ ZSWAP + zstd ativo | ZRAM built-in${NC}"

    # ------------------------------------------------------------------
    # 5. I/O SCHEDULER
    # ------------------------------------------------------------------
    echo -e "\n${CYAN}[I/O Scheduler]${NC}"

    ./scripts/config --enable CONFIG_IOSCHED_BFQ 2>/dev/null || true
    ./scripts/config --enable CONFIG_BLK_DEV_ZONED 2>/dev/null || true

    case "$CPU_PROFILE" in
        modest)
            ./scripts/config --enable CONFIG_DEFAULT_IOSCHED_BFQ 2>/dev/null || true
            echo -e "  ${GREEN}✓ BFQ padrão (essencial para HDD/SSD lentos)${NC}"
            ;;
        balanced)
            ./scripts/config --enable CONFIG_DEFAULT_IOSCHED_BFQ 2>/dev/null || true
            echo -e "  ${GREEN}✓ BFQ padrão${NC}"
            ;;
        performance)
            # kyber para NVMe em sistemas performáticos
            ./scripts/config --enable CONFIG_IOSCHED_KYBER 2>/dev/null || true
            if [[ "${DETECTED_STORAGE[nvme]}" == "1" ]]; then
                ./scripts/config --enable CONFIG_DEFAULT_IOSCHED_KYBER 2>/dev/null || true
                echo -e "  ${GREEN}✓ Kyber padrão (NVMe detectado)${NC}"
            else
                ./scripts/config --enable CONFIG_DEFAULT_IOSCHED_BFQ 2>/dev/null || true
                echo -e "  ${GREEN}✓ BFQ padrão (sem NVMe)${NC}"
            fi
            ;;
    esac

    # ------------------------------------------------------------------
    # 6. LTO — aceleração de build + otimização interprocedural
    # ------------------------------------------------------------------
    echo -e "\n${CYAN}[LTO]${NC}"

    if [[ "$USE_COMPILER" == "clang" && "$CPU_PROFILE" == "performance" ]]; then
        ./scripts/config --enable CONFIG_LTO_CLANG_THIN 2>/dev/null || true
        ./scripts/config --disable CONFIG_LTO_NONE 2>/dev/null || true
        echo -e "  ${GREEN}✓ ThinLTO ativo (clang + performance)${NC}"
    elif [[ "$USE_COMPILER" == "clang" ]]; then
        ./scripts/config --enable CONFIG_LTO_CLANG_THIN 2>/dev/null || true
        ./scripts/config --disable CONFIG_LTO_NONE 2>/dev/null || true
        echo -e "  ${GREEN}✓ ThinLTO ativo (clang)${NC}"
    else
        ./scripts/config --disable CONFIG_LTO_CLANG_THIN 2>/dev/null || true
        ./scripts/config --enable CONFIG_LTO_NONE 2>/dev/null || true
        echo -e "  ${YELLOW}→ LTO desabilitado (GCC — use --clang para habilitar)${NC}"
    fi

    # ------------------------------------------------------------------
    # 7. OTIMIZAÇÕES DE BUILD — desabilitar o que atrasa compilação
    # ------------------------------------------------------------------
    echo -e "\n${CYAN}[Velocidade de compilação]${NC}"

    # Debug info = maior tempo de compilação + binário maior
    ./scripts/config --disable CONFIG_DEBUG_INFO 2>/dev/null || true
    ./scripts/config --disable CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT 2>/dev/null || true
    ./scripts/config --disable CONFIG_DEBUG_INFO_DWARF4 2>/dev/null || true
    ./scripts/config --disable CONFIG_DEBUG_INFO_DWARF5 2>/dev/null || true
    ./scripts/config --disable CONFIG_DEBUG_INFO_BTF 2>/dev/null || true
    ./scripts/config --disable CONFIG_DEBUG_INFO_COMPRESSED_NONE 2>/dev/null || true
    ./scripts/config --disable CONFIG_SAMPLES 2>/dev/null || true
    ./scripts/config --disable CONFIG_KERNEL_DOC 2>/dev/null || true
    # Frame pointers aumentam overhead
    ./scripts/config --disable CONFIG_FRAME_POINTER 2>/dev/null || true
    echo -e "  ${GREEN}✓ Debug info/docs desabilitados${NC}"

    # ------------------------------------------------------------------
    # 8. HARDWARE NÃO DETECTADO — desabilitar para build mais rápido
    # ------------------------------------------------------------------
    echo -e "\n${CYAN}[Hardware não detectado]${NC}"

    [[ "${DETECTED_GPU[nvidia]}" != "1" ]] && {
        ./scripts/config --disable CONFIG_DRM_NOUVEAU 2>/dev/null || true
        echo -e "  ${YELLOW}✗ Nouveau desabilitado${NC}"
    }
    [[ "${DETECTED_GPU[amd]}" != "1" ]] && {
        ./scripts/config --disable CONFIG_DRM_AMDGPU 2>/dev/null || true
        ./scripts/config --disable CONFIG_DRM_RADEON 2>/dev/null || true
        echo -e "  ${YELLOW}✗ AMDGPU/Radeon desabilitados${NC}"
    }
    [[ "${DETECTED_GPU[intel]}" != "1" ]] && {
        ./scripts/config --disable CONFIG_DRM_I915 2>/dev/null || true
        echo -e "  ${YELLOW}✗ i915 desabilitado${NC}"
    }
    [[ "${DETECTED_NET[bluetooth]}" != "1" ]] && {
        ./scripts/config --disable CONFIG_BT 2>/dev/null || true
        echo -e "  ${YELLOW}✗ Bluetooth desabilitado${NC}"
    }
    [[ "${DETECTED_OTHER[kvm]}" != "1" ]] && {
        ./scripts/config --disable CONFIG_KVM 2>/dev/null || true
        ./scripts/config --disable CONFIG_KVM_INTEL 2>/dev/null || true
        ./scripts/config --disable CONFIG_KVM_AMD 2>/dev/null || true
        echo -e "  ${YELLOW}✗ KVM desabilitado${NC}"
    }
    [[ "${DETECTED_OTHER[webcam]}" != "1" ]] && {
        ./scripts/config --disable CONFIG_USB_VIDEO_CLASS 2>/dev/null || true
        echo -e "  ${YELLOW}✗ UVC webcam desabilitado${NC}"
    }
    [[ "${DETECTED_OTHER[printer]}" != "1" ]] && {
        ./scripts/config --disable CONFIG_USB_PRINTER 2>/dev/null || true
        echo -e "  ${YELLOW}✗ USB Printer desabilitado${NC}"
    }

    # Barramentos legados (nunca necessários em hardware pós-2000)
    ./scripts/config --disable CONFIG_ISA 2>/dev/null || true
    ./scripts/config --disable CONFIG_EISA 2>/dev/null || true
    ./scripts/config --disable CONFIG_MCA 2>/dev/null || true
    ./scripts/config --disable CONFIG_PCMCIA 2>/dev/null || true
    ./scripts/config --disable CONFIG_PARPORT 2>/dev/null || true
    echo -e "  ${YELLOW}✗ Barramentos legados desabilitados${NC}"

    # ------------------------------------------------------------------
    # 9. REDE — BBR3 e otimizações
    # ------------------------------------------------------------------
    echo -e "\n${CYAN}[Rede]${NC}"
    ./scripts/config --enable CONFIG_TCP_CONG_BBR 2>/dev/null || true
    ./scripts/config --set-str CONFIG_DEFAULT_TCP_CONG "bbr" 2>/dev/null || true
    ./scripts/config --enable CONFIG_NET_SCH_FQ 2>/dev/null || true
    echo -e "  ${GREEN}✓ TCP BBR3 + FQ ativo${NC}"

    # ------------------------------------------------------------------
    # Resolver dependências finais
    # ------------------------------------------------------------------
    echo -e "\n${YELLOW}>>> Resolvendo dependências...${NC}"
    make olddefconfig

    # Estatísticas
    local ENABLED=$(grep -c "^CONFIG_.*=y" .config 2>/dev/null || echo "0")
    local MODULES=$(grep -c "^CONFIG_.*=m" .config 2>/dev/null || echo "0")
    echo -e "\n${CYAN}Config: ${GREEN}$ENABLED built-in${NC} | ${YELLOW}$MODULES módulos${NC}"
}

# =====================================================================
# DIAGNÓSTICO DO MAKEFILE
# =====================================================================
diagnose_and_fix_makefile() {
    local KERNEL_DIR="$1"
    cd "$KERNEL_DIR"

    local REJ_COUNT=$(find . -name "*.rej" 2>/dev/null | wc -l)
    [[ "$REJ_COUNT" -gt 0 ]] && { echo -e "${RED}>>> $REJ_COUNT rejeições de patch${NC}"; return 1; }

    find . -name "*.orig" -delete 2>/dev/null || true

    if [ -f "Makefile" ]; then
        if ! make -n kernelversion &>/dev/null; then
            echo -e "${RED}>>> Makefile com erro de sintaxe${NC}"
            return 1
        fi
    else
        return 1
    fi
    return 0
}

# =====================================================================
# MAIN
# =====================================================================
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           LINUX-FLOAT BUILD SCRIPT v1.1                     ║"
echo "║     Auto-Detecção · Clang/ThinLTO · Perfis Adaptativos      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# -- Parse argumentos --
BUILD_MODE="localmodconfig"
VERSION_ARG=""
FORCED_COMPILER=""
FORCED_PROFILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --localmodconfig) BUILD_MODE="localmodconfig"; shift ;;
        --localyesconfig) BUILD_MODE="localyesconfig"; shift ;;
        --full)           BUILD_MODE="full"; shift ;;
        --clang)          FORCED_COMPILER="clang"; shift ;;
        --gcc)            FORCED_COMPILER="gcc"; shift ;;
        --profile)        FORCED_PROFILE="$2"; shift 2 ;;
        --modest)         FORCED_PROFILE="modest"; shift ;;
        --balanced)       FORCED_PROFILE="balanced"; shift ;;
        --performance)    FORCED_PROFILE="performance"; shift ;;
        --help|-h)
            echo "Usage: $0 <version> [opções]"
            echo ""
            echo -e "${GREEN}Modos de config:${NC}"
            echo "  --localmodconfig  Apenas módulos em uso (padrão, ~15-40 min)"
            echo "  --localyesconfig  Módulos como built-in (~20-50 min)"
            echo "  --full            Config completa (~1-3 horas)"
            echo ""
            echo -e "${GREEN}Compilador:${NC}"
            echo "  --clang           Forçar Clang + ThinLTO (recomendado)"
            echo "  --gcc             Forçar GCC"
            echo ""
            echo -e "${GREEN}Perfil de hardware:${NC}"
            echo "  --profile modest      2-4 núcleos, 4-8 GB (economia + fluidez)"
            echo "  --profile balanced    4-8 núcleos, 8-16 GB"
            echo "  --profile performance 8+ núcleos / hardware forte"
            echo "  (atalhos: --modest | --balanced | --performance)"
            echo ""
            echo "Exemplo: $0 6.14.13 --clang --profile balanced"
            exit 0
            ;;
        *) VERSION_ARG="$1"; shift ;;
    esac
done

# -- Verificar versão ANTES de qualquer detecção --
[[ -z "$VERSION_ARG" ]] && {
    echo -e "${RED}ERRO: Versão não especificada.${NC}"
    echo -e "Usage: $0 <version> [opções]"
    echo -e "Exemplo: $0 6.14.13"
    echo -e "         $0 6.14"
    exit 1
}

# -- Normalizar versão --
# Remove sufixos Debian/Ubuntu como 6.14.0-37-generic → 6.14.0
# Preserva versões curtas como 6.14 (sem patch) intactas
RAW="$VERSION_ARG"
CLEAN=$(echo "$RAW" | sed 's/^\([0-9]\+\.[0-9]\+\(\.[0-9]\+\)\?\).*/\1/')
DOTS=$(echo "$CLEAN" | tr -cd '.' | wc -c)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
mkdir -p "$BUILD_DIR"

# -- Resolver versão curta (ex: 6.14 → 6.14.13) --
if [ "$DOTS" -lt 2 ]; then
    MAJOR_MINOR="$CLEAN"
    v_base="v$(echo "$MAJOR_MINOR" | cut -d. -f1).x"
    echo -e "${YELLOW}>>> Resolvendo última patch release de ${BOLD}$MAJOR_MINOR${NC}${YELLOW}...${NC}"
    LISTING=$(curl -fs "https://www.kernel.org/pub/linux/kernel/$v_base/" || true)
    if [[ -z "$LISTING" ]]; then
        echo -e "${RED}ERRO: não foi possível acessar kernel.org${NC}"
        exit 1
    fi
    ESCAPED="${MAJOR_MINOR//./\\.}"
    LATEST=$(echo "$LISTING" \
        | grep -oE "linux-${ESCAPED}\.[0-9]+\.tar\.xz" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -V | tail -1)
    # Fallback para versão .0 (ex: linux-6.15.tar.xz → 6.15.0)
    if [[ -z "$LATEST" ]]; then
        HAS_BASE=$(echo "$LISTING" | grep -oE "linux-${ESCAPED}\.tar\.xz" | head -1)
        [[ -n "$HAS_BASE" ]] && LATEST="${MAJOR_MINOR}.0"
    fi
    [[ -z "$LATEST" ]] && {
        echo -e "${RED}ERRO: versão '$MAJOR_MINOR' não encontrada em kernel.org${NC}"
        echo -e "${YELLOW}Dica: especifique a versão completa, ex: $0 6.14.13${NC}"
        exit 1
    }
    v_full="$LATEST"
    echo -e "${GREEN}>>> Versão resolvida: $v_full${NC}"
else
    v_full="$CLEAN"
fi

# -- Detectar hardware e compilador (após validar versão) --
detect_cpu
detect_compiler

v_base="v$(echo "$v_full" | cut -d. -f1).x"
TARBALL_XZ="linux-$v_full.tar.xz"
TARBALL_GZ="linux-$v_full.tar.gz"
KERNEL_URL_BASE="https://www.kernel.org/pub/linux/kernel/$v_base"

echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "Versão:     ${GREEN}$v_full${NC}"
echo -e "Compilador: ${GREEN}$USE_COMPILER${NC}$([ -n "$CCACHE_BIN" ] && echo " + ccache")"
echo -e "Arquit.:    ${MAGENTA}$CPU_MARCH${NC} (${CPU_GENERATION})"
echo -e "Perfil:     ${BOLD}${GREEN}$CPU_PROFILE${NC}"
echo -e "Modo:       ${GREEN}$BUILD_MODE${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

# -- Dependências --
echo -e "\n${YELLOW}>>> Verificando dependências...${NC}"
BASE_DEPS=(libncurses-dev gawk flex bison openssl libssl-dev dkms libelf-dev
    libudev-dev libpci-dev libiberty-dev autoconf bc rsync kmod cpio
    zstd libzstd-dev python3 wget curl debhelper libdw-dev elfutils
    libnuma-dev libcap-dev ccache)

# Adicionar clang se necessário
[[ "$USE_COMPILER" == "clang" ]] && BASE_DEPS+=(clang lld llvm)
BASE_DEPS+=(gcc)

dep_miss=()
for dep in "${BASE_DEPS[@]}"; do
    dpkg -s "$dep" &>/dev/null || dep_miss+=("$dep")
done

if [ ${#dep_miss[@]} -ne 0 ]; then
    echo -e "${YELLOW}>>> Instalando: ${dep_miss[*]}${NC}"
    sudo apt-get update -q
    sudo apt-get install -y "${dep_miss[@]}"
else
    echo -e "${GREEN}>>> Todas as dependências OK${NC}"
fi

# -- Download --
cd "$BUILD_DIR"
if [ ! -f "$TARBALL_XZ" ] && [ ! -f "$TARBALL_GZ" ]; then
    echo -e "\n${YELLOW}>>> Baixando $TARBALL_XZ...${NC}"
    if ! wget -q --show-progress "$KERNEL_URL_BASE/$TARBALL_XZ"; then
        echo -e "${YELLOW}>>> Tentando .tar.gz...${NC}"
        wget --show-progress "$KERNEL_URL_BASE/$TARBALL_GZ" || {
            echo -e "${RED}ERRO: versão '$v_full' não encontrada${NC}"; exit 1; }
    fi
else
    echo -e "${GREEN}>>> Tarball já presente${NC}"
fi

# -- Extração --
KERNEL_SRC="$BUILD_DIR/linux-$v_full"
NEED_EXTRACT=false

if [ -d "$KERNEL_SRC" ]; then
    diagnose_and_fix_makefile "$KERNEL_SRC" || { rm -rf "$KERNEL_SRC"; NEED_EXTRACT=true; }
else
    NEED_EXTRACT=true
fi

if [ "$NEED_EXTRACT" = true ]; then
    echo -e "\n${YELLOW}>>> Extraindo...${NC}"
    cd "$BUILD_DIR"
    [ -f "$TARBALL_XZ" ] && tar -xf "$TARBALL_XZ" || tar -xzf "$TARBALL_GZ"
    echo -e "${GREEN}>>> OK${NC}"
fi

cd "$KERNEL_SRC"

# -- Patches --
SKIP_PATCHES="0010-bore-cachy-fix.patch"

echo -e "\n${YELLOW}>>> Aplicando patches...${NC}"
for dir in "$SCRIPT_DIR/src" "$SCRIPT_DIR"; do
    [ -d "$dir" ] || continue
    for patch in $(ls "$dir"/*.patch 2>/dev/null | sort); do
        [ -f "$patch" ] || continue
        basename=$(basename "$patch")
        if echo "$SKIP_PATCHES" | grep -qw "$basename"; then
            echo -e "  ${YELLOW}-- $basename (pulado)${NC}"
            continue
        fi
        echo -e "  ${GREEN}-> $basename${NC}"
        if patch -Np1 --dry-run --forward --fuzz=3 < "$patch" &>/dev/null; then
            patch -Np1 --forward --fuzz=3 --reject-file=/dev/null < "$patch" || true
        else
            echo -e "     ${YELLOW}já aplicado ou incompatível${NC}"
        fi
    done
done

find . -name "*.rej" -delete 2>/dev/null || true
find . -name "*.orig" -delete 2>/dev/null || true

# -- Config --
for cfg in "$SCRIPT_DIR/src/config" "$SCRIPT_DIR/config"; do
    [ -f "$cfg" ] && { cp "$cfg" .config; echo -e "${GREEN}>>> Config base: $cfg${NC}"; break; }
done
[ ! -f .config ] && make defconfig

# -- Detecção e configuração --
detect_hardware
auto_configure_kernel "$KERNEL_SRC" "$BUILD_MODE"

# -- Compilação --
# Usar todos os núcleos disponíveis (localmodconfig já é pequeno)
JOBS="$CPU_THREADS"

echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}COMPILANDO com $JOBS threads${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

START_TIME=$(date +%s)
LOG="$BUILD_DIR/build-$(date +%Y%m%d-%H%M%S).log"
echo -e "Log: ${YELLOW}$LOG${NC}\n"

# Montar flags de compilação
# CC deve ser uma string unica — ccache gcc ou ccache clang, nao variaveis separadas
if [[ "$USE_COMPILER" == "clang" ]]; then
    if [[ -n "$CCACHE_BIN" ]]; then
        CC_VAL="ccache clang"
    else
        CC_VAL="clang"
    fi
    EXTRA_FLAGS="LD=ld.lld LLVM=1 LLVM_IAS=1"
else
    if [[ -n "$CCACHE_BIN" ]]; then
        CC_VAL="ccache gcc"
    else
        CC_VAL="gcc"
    fi
    EXTRA_FLAGS=""
fi

echo -e "  CC: ${GREEN}$CC_VAL${NC}"

# Compilar
make bindeb-pkg \
    -j"$JOBS" \
    CC="$CC_VAL" \
    $EXTRA_FLAGS \
    LOCALVERSION="-linuxfloat" \
    KDEB_PKGVERSION="$(make kernelversion)-1" \
    DPKG_FLAGS="-d" \
    2>&1 | tee "$LOG"
BUILD_STATUS=${PIPESTATUS[0]}

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECS=$((ELAPSED % 60))

if [ "$BUILD_STATUS" -ne 0 ]; then
    echo -e "\n${RED}════════════════ BUILD FALHOU ════════════════${NC}"
    echo -e "${RED}Tempo: ${MINUTES}m ${SECS}s | Log: $LOG${NC}"
    grep -E "^.*(error:|fatal error:|undefined reference|FAILED)" "$LOG" \
        | grep -v "^make" | tail -20
    exit "$BUILD_STATUS"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              BUILD COMPLETO COM SUCESSO!                 ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Tempo:      ${MINUTES}m ${SECS}s                                   ║${NC}"
echo -e "${GREEN}║  CPU:        $CPU_MARCH ($CPU_PROFILE)                  ║${NC}"
echo -e "${GREEN}║  Compilador: $USE_COMPILER                                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
ls -lh "$BUILD_DIR"/*.deb 2>/dev/null || true
echo -e "\n${CYAN}Para instalar:${NC}"
echo -e "${YELLOW}sudo dpkg -i $BUILD_DIR/*.deb && sudo update-grub && sudo reboot${NC}"
