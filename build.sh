#!/bin/bash
# Usage: ./build-optimized.sh <version> [--localmodconfig|--localyesconfig|--full]
# Example: ./build.sh 6.14.13
#          ./build.sh 6.14.13 --localmodconfig  (padrão)

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =====================================================================
# FUNÇÃO: DIAGNÓSTICO E CORREÇÃO DO MAKEFILE
# =====================================================================
diagnose_and_fix_makefile() {
    local KERNEL_DIR="$1"
    local NEED_REEXTRACT=false
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}DIAGNÓSTICO DO KERNEL SOURCE${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    
    cd "$KERNEL_DIR"
    
    # 1. Verificar rejeições de patch
    local REJ_COUNT=$(find . -name "*.rej" 2>/dev/null | wc -l)
    if [ "$REJ_COUNT" -gt 0 ]; then
        echo -e "${RED}>>> $REJ_COUNT arquivo(s) com rejeições de patch encontrados${NC}"
        find . -name "*.rej" 2>/dev/null | head -10
        NEED_REEXTRACT=true
    else
        echo -e "${GREEN}>>> Nenhum .rej encontrado${NC}"
    fi
    
    # 2. Verificar arquivos .orig (backup de patches)
    local ORIG_COUNT=$(find . -name "*.orig" 2>/dev/null | wc -l)
    if [ "$ORIG_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}>>> $ORIG_COUNT arquivo(s) .orig encontrados (backup de patches)${NC}"
        # Remover .orig files
        find . -name "*.orig" -delete
        echo -e "${GREEN}    Arquivos .orig removidos${NC}"
    fi
    
    # 3. Verificar caracteres não-ASCII no Makefile
    if [ -f "Makefile" ]; then
        local WEIRD_CHARS=$(LC_ALL=C grep -c '[^[:print:][:space:]]' Makefile 2>/dev/null || echo "0")
        if [ "$WEIRD_CHARS" -gt 0 ]; then
            echo -e "${RED}>>> Makefile contém $WEIRD_CHARS caracteres inválidos${NC}"
            NEED_REEXTRACT=true
        else
            echo -e "${GREEN}>>> Makefile sem caracteres inválidos${NC}"
        fi
        
        # Verificar sintaxe do Makefile
        echo -e "${YELLOW}>>> Testando sintaxe do Makefile...${NC}"
        if ! make -n kernelversion &>/dev/null; then
            echo -e "${RED}>>> ERRO: Makefile com sintaxe inválida${NC}"
            
            # Mostrar linha problemática
            echo -e "${YELLOW}>>> Linha 1570 e contexto:${NC}"
            sed -n '1565,1575p' Makefile 2>/dev/null || true
            
            NEED_REEXTRACT=true
        else
            echo -e "${GREEN}>>> Makefile sintaxe OK${NC}"
        fi
    else
        echo -e "${RED}>>> Makefile não encontrado${NC}"
        NEED_REEXTRACT=true
    fi
    
    # 4. Verificar se .config está válido
    if [ -f ".config" ]; then
        if ! head -1 .config | grep -q "^#"; then
            echo -e "${YELLOW}>>> .config pode estar corrompido${NC}"
        else
            echo -e "${GREEN}>>> .config OK${NC}"
        fi
    fi
    
    # Retornar se precisa reextrair
    if [ "$NEED_REEXTRACT" = true ]; then
        echo ""
        return 1
    fi
    
    return 0
}

# =====================================================================
# FUNÇÃO: DETECÇÃO AUTOMÁTICA DE HARDWARE
# =====================================================================
detect_hardware() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}DETECTANDO HARDWARE DO SISTEMA${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    
    # Arrays para armazenar hardware detectado
    declare -A DETECTED_GPU
    declare -A DETECTED_AUDIO
    declare -A DETECTED_NET
    declare -A DETECTED_STORAGE
    declare -A DETECTED_INPUT
    declare -A DETECTED_OTHER
    
    # ===== GPU =====
    echo -e "\n${YELLOW}[GPU] Detectando...${NC}"
    
    # Detectar via lspci
    GPU_INFO=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | head -5)
    
    if echo "$GPU_INFO" | grep -qi 'nvidia'; then
        DETECTED_GPU[nvidia]=1
        echo -e "  ${GREEN}✓ NVIDIA detectado${NC}"
    fi
    
    if echo "$GPU_INFO" | grep -qi 'amd\|radeon\|advanced micro'; then
        DETECTED_GPU[amd]=1
        echo -e "  ${GREEN}✓ AMD/Radeon detectado${NC}"
    fi
    
    if echo "$GPU_INFO" | grep -qi 'intel'; then
        DETECTED_GPU[intel]=1
        echo -e "  ${GREEN}✓ Intel detectado${NC}"
    fi
    
    # Detectar via driver em uso
    if lsmod | grep -q "^nvidia"; then
        DETECTED_GPU[nvidia]=1
        echo -e "  ${GREEN}✓ Driver NVIDIA em uso${NC}"
    fi
    
    if lsmod | grep -q "^amdgpu"; then
        DETECTED_GPU[amd]=1
        echo -e "  ${GREEN}✓ Driver AMDGPU em uso${NC}"
    fi
    
    if lsmod | grep -q "^i915"; then
        DETECTED_GPU[intel]=1
        echo -e "  ${GREEN}✓ Driver i915 em uso${NC}"
    fi
    
    # ===== AUDIO =====
    echo -e "\n${YELLOW}[ÁUDIO] Detectando...${NC}"
    
    if lsmod | grep -q "snd_hda"; then
        DETECTED_AUDIO[hda]=1
        echo -e "  ${GREEN}✓ HDA Intel detectado${NC}"
    fi
    
    if lsmod | grep -q "snd_soc"; then
        DETECTED_AUDIO[soc]=1
        echo -e "  ${GREEN}✓ SoC audio detectado${NC}"
    fi
    
    if pactl info &>/dev/null || pgrep -x pipewire &>/dev/null; then
        DETECTED_AUDIO[pulse]=1
        echo -e "  ${GREEN}✓ PulseAudio/PipeWire em uso${NC}"
    fi
    
    # ===== REDE =====
    echo -e "\n${YELLOW}[REDE] Detectando...${NC}"
    
    # Ethernet
    ETH_DRIVERS=$(lsmod | grep -E "^r8169|^e1000|^igb|^bnx|^tg3|^sky2|^forcedeth" | awk '{print $1}')
    if [ -n "$ETH_DRIVERS" ]; then
        DETECTED_NET[ethernet]=1
        echo -e "  ${GREEN}✓ Ethernet: $ETH_DRIVERS${NC}"
    fi
    
    # WiFi
    WIFI_DRIVERS=$(lsmod | grep -E "^iwlwifi|^ath|^rtw|^rtl|^mt76|^brcmfmac|^mwifiex" | awk '{print $1}')
    if [ -n "$WIFI_DRIVERS" ]; then
        DETECTED_NET[wifi]=1
        echo -e "  ${GREEN}✓ WiFi: $WIFI_DRIVERS${NC}"
    fi
    
    # Verificar interfaces
    if ip link 2>/dev/null | grep -q "wlan\|wlp"; then
        DETECTED_NET[wifi]=1
    fi
    
    # Bluetooth
    if lsmod | grep -q "btusb\|bluetooth" || hciconfig hci0 &>/dev/null; then
        DETECTED_NET[bluetooth]=1
        echo -e "  ${GREEN}✓ Bluetooth detectado${NC}"
    fi
    
    # ===== ARMAZENAMENTO =====
    echo -e "\n${YELLOW}[ARMAZENAMENTO] Detectando...${NC}"
    
    if lsmod | grep -q "nvme"; then
        DETECTED_STORAGE[nvme]=1
        echo -e "  ${GREEN}✓ NVMe detectado${NC}"
    fi
    
    if lsmod | grep -qE "^sd_mod|^ahci|^libata"; then
        DETECTED_STORAGE[sata]=1
        echo -e "  ${GREEN}✓ SATA/SCSI detectado${NC}"
    fi
    
    if lsmod | grep -q "usb_storage"; then
        DETECTED_STORAGE[usb]=1
        echo -e "  ${GREEN}✓ USB Storage detectado${NC}"
    fi
    
    # ===== INPUT =====
    echo -e "\n${YELLOW}[INPUT] Detectando...${NC}"
    
    if lsmod | grep -q "usbhid"; then
        DETECTED_INPUT[usb_hid]=1
        echo -e "  ${GREEN}✓ USB HID detectado${NC}"
    fi
    
    if ls /dev/input/by-path/*kbd* &>/dev/null; then
        DETECTED_INPUT[keyboard]=1
    fi
    
    if ls /dev/input/by-path/*mouse* &>/dev/null || ls /dev/input/mice &>/dev/null; then
        DETECTED_INPUT[mouse]=1
    fi
    
    # ===== VIRTUALIZAÇÃO =====
    echo -e "\n${YELLOW}[VIRTUALIZAÇÃO] Detectando...${NC}"
    
    if lsmod | grep -qE "^kvm"; then
        DETECTED_OTHER[kvm]=1
        echo -e "  ${GREEN}✓ KVM em uso${NC}"
    fi
    
    if systemd-detect-virt &>/dev/null; then
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null)
        DETECTED_OTHER[virt_guest]=1
        echo -e "  ${GREEN}✓ Executando em VM: $VIRT_TYPE${NC}"
    fi
    
    # ===== WEBCAM =====
    echo -e "\n${YELLOW}[WEBCAM] Detectando...${NC}"
    
    if ls /dev/video* &>/dev/null; then
        DETECTED_OTHER[webcam]=1
        echo -e "  ${GREEN}✓ Webcam detectada: $(ls /dev/video* 2>/dev/null | head -1)${NC}"
    fi
    
    if lsmod | grep -q "uvcvideo"; then
        DETECTED_OTHER[webcam]=1
        echo -e "  ${GREEN}✓ Driver UVC carregado${NC}"
    fi
    
    # ===== IMPRESSÃO =====
    echo -e "\n${YELLOW}[IMPRESSORA] Detectando...${NC}"
    
    if lsmod | grep -q "usblp" || lpstat -p &>/dev/null; then
        DETECTED_OTHER[printer]=1
        echo -e "  ${GREEN}✓ Impressora detectada${NC}"
    fi
    
    # Exportar para uso posterior
    export DETECTED_GPU DETECTED_AUDIO DETECTED_NET DETECTED_STORAGE DETECTED_INPUT DETECTED_OTHER
    
    echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Detecção de hardware concluída${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
}

# =====================================================================
# FUNÇÃO: CONFIGURAR KERNEL AUTOMATICAMENTE
# =====================================================================
auto_configure_kernel() {
    local KERNEL_DIR="$1"
    local MODE="$2"
    
    cd "$KERNEL_DIR"
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}CONFIGURANDO KERNEL - MODO: ${GREEN}$MODE${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    
    # Aplicar configuração baseada no modo
    case "$MODE" in
        localmodconfig)
            echo -e "${YELLOW}>>> Aplicando localmodconfig automaticamente...${NC}"
            echo -e "${YELLOW}    (Todas as perguntas serão respondidas automaticamente)${NC}"
            
            # Método 1: Usar yes '' para responder vazio a todas perguntas
            # Isso faz o kernel usar os defaults para novas opções
            yes '' | make localmodconfig 2>/dev/null || true
            
            # Método alternativo: usar olddefconfig após
            make olddefconfig
            ;;
            
        localyesconfig)
            echo -e "${YELLOW}>>> Aplicando localyesconfig automaticamente...${NC}"
            
            yes '' | make localyesconfig 2>/dev/null || true
            make olddefconfig
            ;;
            
        full)
            echo -e "${YELLOW}>>> Configuração completa do kernel...${NC}"
            make olddefconfig
            ;;
    esac
    
    # =====================================================================
    # APLICAR OTIMIZAÇÕES BASEADO NO HARDWARE DETECTADO
    # =====================================================================
    echo -e "\n${YELLOW}>>> Aplicando otimizações baseadas no hardware...${NC}"
    
    # GPU Drivers - Desabilitar não utilizados
    echo -e "\n${CYAN}[GPU Drivers]${NC}"
    
    if [ "${DETECTED_GPU[nvidia]}" != "1" ]; then
        echo -e "  ${YELLOW}✗ Nouveau (NVIDIA) - desabilitado${NC}"
        ./scripts/config --disable CONFIG_DRM_NOUVEAU 2>/dev/null || true
        ./scripts/config --disable CONFIG_DRM_NOUVEAU_BACKLIGHT 2>/dev/null || true
        ./scripts/config --disable CONFIG_NOUVEAU_DEBUG 2>/dev/null || true
    else
        echo -e "  ${GREEN}✓ Nouveau mantido${NC}"
    fi
    
    if [ "${DETECTED_GPU[amd]}" != "1" ]; then
        echo -e "  ${YELLOW}✗ AMDGPU/Radeon - desabilitado${NC}"
        ./scripts/config --disable CONFIG_DRM_AMDGPU 2>/dev/null || true
        ./scripts/config --disable CONFIG_DRM_RADEON 2>/dev/null || true
        ./scripts/config --disable CONFIG_DRM_RADEON_USERPTR 2>/dev/null || true
    else
        echo -e "  ${GREEN}✓ AMDGPU/Radeon mantido${NC}"
    fi
    
    if [ "${DETECTED_GPU[intel]}" != "1" ]; then
        echo -e "  ${YELLOW}✗ i915 (Intel) - desabilitado${NC}"
        ./scripts/config --disable CONFIG_DRM_I915 2>/dev/null || true
    else
        echo -e "  ${GREEN}✓ i915 mantido${NC}"
    fi
    
    # Bluetooth
    echo -e "\n${CYAN}[Bluetooth]${NC}"
    if [ "${DETECTED_NET[bluetooth]}" != "1" ]; then
        echo -e "  ${YELLOW}✗ Bluetooth - desabilitado${NC}"
        ./scripts/config --disable CONFIG_BT 2>/dev/null || true
        ./scripts/config --disable CONFIG_BT_RFCOMM 2>/dev/null || true
        ./scripts/config --disable CONFIG_BT_BNEP 2>/dev/null || true
        ./scripts/config --disable CONFIG_BT_HIDP 2>/dev/null || true
    else
        echo -e "  ${GREEN}✓ Bluetooth mantido${NC}"
    fi
    
    # Virtualização
    echo -e "\n${CYAN}[Virtualização]${NC}"
    if [ "${DETECTED_OTHER[kvm]}" != "1" ]; then
        echo -e "  ${YELLOW}✗ KVM - desabilitado${NC}"
        ./scripts/config --disable CONFIG_KVM 2>/dev/null || true
        ./scripts/config --disable CONFIG_KVM_INTEL 2>/dev/null || true
        ./scripts/config --disable CONFIG_KVM_AMD 2>/dev/null || true
    else
        echo -e "  ${GREEN}✓ KVM mantido${NC}"
    fi
    
    # Webcam
    echo -e "\n${CYAN}[Webcam]${NC}"
    if [ "${DETECTED_OTHER[webcam]}" != "1" ]; then
        echo -e "  ${YELLOW}✗ Webcam/UVC - desabilitado${NC}"
        ./scripts/config --disable CONFIG_USB_VIDEO_CLASS 2>/dev/null || true
        ./scripts/config --disable CONFIG_VIDEO_USBTV 2>/dev/null || true
    else
        echo -e "  ${GREEN}✓ Webcam mantida${NC}"
    fi
    
    # Impressora
    echo -e "\n${CYAN}[Impressora]${NC}"
    if [ "${DETECTED_OTHER[printer]}" != "1" ]; then
        echo -e "  ${YELLOW}✗ Impressora USB - desabilitado${NC}"
        ./scripts/config --disable CONFIG_USB_PRINTER 2>/dev/null || true
    else
        echo -e "  ${GREEN}✓ Impressora mantida${NC}"
    fi
    
    # =====================================================================
    # DESABILITAR HARDWARE LEGADO E DESNECESSÁRIO
    # =====================================================================
    echo -e "\n${CYAN}[Hardware Legado]${NC}"
    
    # Barramentos legados
    ./scripts/config --disable CONFIG_ISA 2>/dev/null || true
    ./scripts/config --disable CONFIG_EISA 2>/dev/null || true
    ./scripts/config --disable CONFIG_MCA 2>/dev/null || true
    ./scripts/config --disable CONFIG_PCMCIA 2>/dev/null || true
    echo -e "  ${YELLOW}✗ ISA/EISA/MCA/PCMCIA - desabilitados${NC}"
    
    # Dispositivos legados
    ./scripts/config --disable CONFIG_PARPORT 2>/dev/null || true
    ./scripts/config --disable CONFIG_PARPORT_PC 2>/dev/null || true
    echo -e "  ${YELLOW}✗ Porta paralela - desabilitada${NC}"
    
    ./scripts/config --disable CONFIG_SERIO_I8042 2>/dev/null || true
    echo -e "  ${YELLOW}✗ i8042 (teclado PS/2 legado) - pode ser desabilitado${NC}"
    
    # Firmwares extras (não necessários na maioria dos casos)
    echo -e "\n${CYAN}[Firmware]${NC}"
    ./scripts/config --disable CONFIG_EXTRA_FIRMWARE 2>/dev/null || true
    echo -e "  ${YELLOW}✗ Extra firmware embutido - desabilitado${NC}"
    
    # Documentação e exemplos
    ./scripts/config --disable CONFIG_SAMPLES 2>/dev/null || true
    ./scripts/config --disable CONFIG_KERNEL_DOC 2>/dev/null || true
    echo -e "  ${YELLOW}✗ Samples/Documentação - desabilitados${NC}"
    
    # Debug excessivo
    echo -e "\n${CYAN}[Debug]${NC}"
    ./scripts/config --disable CONFIG_DEBUG_INFO 2>/dev/null || true
    ./scripts/config --disable CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT 2>/dev/null || true
    ./scripts/config --disable CONFIG_DEBUG_INFO_DWARF4 2>/dev/null || true
    ./scripts/config --disable CONFIG_DEBUG_INFO_DWARF5 2>/dev/null || true
    ./scripts/config --disable CONFIG_DEBUG_INFO_BTF 2>/dev/null || true
    echo -e "  ${YELLOW}✗ Debug info - desabilitado (kernel menor e mais rápido)${NC}"
    
    # Resolver dependências após todas as mudanças
    echo -e "\n${YELLOW}>>> Resolvendo dependências de configuração...${NC}"
    make olddefconfig
    
    # =====================================================================
    # ESTATÍSTICAS
    # =====================================================================
    echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}ESTATÍSTICAS DA CONFIGURAÇÃO${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    
    local ENABLED=$(grep -c "^CONFIG_.*=y" .config 2>/dev/null || echo "0")
    local MODULES=$(grep -c "^CONFIG_.*=m" .config 2>/dev/null || echo "0")
    local DISABLED=$(grep -c "^# CONFIG_" .config 2>/dev/null || echo "0")
    
    echo -e "Built-in (y):    ${GREEN}$ENABLED${NC}"
    echo -e "Módulos (m):     ${YELLOW}$MODULES${NC}"
    echo -e "Desabilitados:   ${RED}$DISABLED${NC}"
}

# =====================================================================
# MAIN
# =====================================================================

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         LINUX-FLOAT BUILD SCRIPT OTIMIZADO v2.0              ║"
echo "║         Compilação Inteligente + Auto-Detecção               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Parse argumentos
BUILD_MODE="localmodconfig"  # default
VERSION_ARG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --localmodconfig)
            BUILD_MODE="localmodconfig"
            shift
            ;;
        --localyesconfig)
            BUILD_MODE="localyesconfig"
            shift
            ;;
        --full)
            BUILD_MODE="full"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 <version> [--localmodconfig|--localyesconfig|--full]"
            echo ""
            echo -e "${GREEN}Opções de compilação:${NC}"
            echo "  --localmodconfig  Compila APENAS módulos em uso (RÁPIDO, ~15-40 min)"
            echo "  --localyesconfig  Módulos built-in para hardware detectado (~20-50 min)"
            echo "  --full            Kernel completo tradicional (LENTO, ~1-3 horas)"
            echo ""
            echo -e "${YELLOW}O script detecta automaticamente:${NC}"
            echo "  - GPU (NVIDIA/AMD/Intel)"
            echo "  - Áudio (HDA/SoC)"
            echo "  - Rede (Ethernet/WiFi/Bluetooth)"
            echo "  - Armazenamento (NVMe/SATA/USB)"
            echo "  - Input (Teclado/Mouse/USB HID)"
            echo "  - Virtualização (KVM)"
            echo "  - Webcam, Impressora, etc"
            echo ""
            echo "Example: $0 6.14.13"
            echo "         $0 6.14"
            exit 0
            ;;
        *)
            VERSION_ARG="$1"
            shift
            ;;
    esac
done

if [ -z "$VERSION_ARG" ]; then
    echo -e "${RED}ERRO: Versão não especificada${NC}"
    echo "Usage: $0 <version> [--localmodconfig|--localyesconfig|--full]"
    echo "Example: $0 6.14.13"
    exit 1
fi

RAW="$VERSION_ARG"
CLEAN=$(echo "$RAW" | sed 's/[-~][^0-9].*//;s/[-~][0-9]*$//')
DOTS=$(echo "$CLEAN" | tr -cd '.' | wc -c)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
mkdir -p "$BUILD_DIR"

# Resolver versão
if [ "$DOTS" -lt 2 ]; then
    MAJOR_MINOR="$CLEAN"
    v_base="v$(echo "$MAJOR_MINOR" | cut -d. -f1).x"
    echo -e "${YELLOW}>>> Resolvendo última patch release de $MAJOR_MINOR ...${NC}"
    LATEST=$(curl -s "https://www.kernel.org/pub/linux/kernel/$v_base/" \
        | grep -oP "linux-${MAJOR_MINOR//./\\.}\.[0-9]+\.tar\.xz" \
        | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -V | tail -1)
    if [ -z "$LATEST" ]; then
        echo -e "${RED}ERRO: não foi possível resolver versão para $MAJOR_MINOR${NC}"
        exit 1
    fi
    v_full="$LATEST"
    echo -e "${GREEN}>>> Versão resolvida: $v_full${NC}"
else
    v_full="$CLEAN"
fi

v_base="v$(echo "$v_full" | cut -d. -f1).x"
TARBALL_XZ="linux-$v_full.tar.xz"
TARBALL_GZ="linux-$v_full.tar.gz"
KERNEL_URL_BASE="https://www.kernel.org/pub/linux/kernel/$v_base"

echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "Versão:     ${GREEN}$v_full${NC}"
echo -e "URL base:   ${YELLOW}$KERNEL_URL_BASE${NC}"
echo -e "Modo:       ${GREEN}$BUILD_MODE${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

# --- dependências ---
echo -e "\n${YELLOW}>>> Verificando dependências...${NC}"
dep_miss=()
dependencies=(libncurses-dev gawk flex bison openssl libssl-dev dkms libelf-dev \
    libudev-dev libpci-dev libiberty-dev autoconf llvm gcc bc rsync kmod cpio \
    zstd libzstd-dev python3 wget curl debhelper libdw-dev libdwarf-dev elfutils \
    libnuma-dev libcap-dev)
for dep in "${dependencies[@]}"; do
    if ! dpkg -s "$dep" &> /dev/null; then
        dep_miss+=("$dep")
    fi
done
if [ ${#dep_miss[@]} -ne 0 ]; then
    echo -e "${YELLOW}>>> Instalando dependências: ${dep_miss[*]}${NC}"
    sudo apt-get update -q
    sudo apt-get install -y "${dep_miss[@]}"
else
    echo -e "${GREEN}>>> Todas dependências instaladas${NC}"
fi

# --- download ---
cd "$BUILD_DIR"
if [ ! -f "$TARBALL_XZ" ] && [ ! -f "$TARBALL_GZ" ]; then
    echo -e "\n${YELLOW}>>> Baixando $TARBALL_XZ ...${NC}"
    if ! wget -q --show-progress "$KERNEL_URL_BASE/$TARBALL_XZ"; then
        echo -e "${YELLOW}>>> Falhou .tar.xz, tentando .tar.gz ...${NC}"
        if ! wget --show-progress "$KERNEL_URL_BASE/$TARBALL_GZ"; then
            echo -e "${RED}ERRO: versão '$v_full' não encontrada${NC}"
            exit 1
        fi
    fi
else
    echo -e "${GREEN}>>> Tarball já existe${NC}"
fi

# --- extração e verificação ---
KERNEL_SRC="$BUILD_DIR/linux-$v_full"
NEED_EXTRACT=false

if [ -d "$KERNEL_SRC" ]; then
    # Verificar se o fonte está íntegro
    if ! diagnose_and_fix_makefile "$KERNEL_SRC"; then
        echo -e "${YELLOW}>>> Fonte corrompido, será reextraído${NC}"
        rm -rf "$KERNEL_SRC"
        NEED_EXTRACT=true
    fi
else
    NEED_EXTRACT=true
fi

if [ "$NEED_EXTRACT" = true ]; then
    echo -e "\n${YELLOW}>>> Extraindo sources...${NC}"
    cd "$BUILD_DIR"
    if [ -f "$TARBALL_XZ" ]; then
        tar -xf "$TARBALL_XZ"
    else
        tar -xzf "$TARBALL_GZ"
    fi
    echo -e "${GREEN}>>> Extração concluída${NC}"
fi

cd "$KERNEL_SRC"

# --- patches ---
SKIP_PATCHES="0010-bore-cachy-fix.patch"

echo -e "\n${YELLOW}>>> Aplicando patches...${NC}"
for dir in "$SCRIPT_DIR/src" "$SCRIPT_DIR"; do
    if [ -d "$dir" ]; then
        for patch in $(ls "$dir"/*.patch 2>/dev/null | sort); do
            [ -f "$patch" ] || continue
            basename=$(basename "$patch")
            if echo "$SKIP_PATCHES" | grep -qw "$basename"; then
                echo -e "  ${YELLOW}-- $basename (ignorado)${NC}"
                continue
            fi
            echo -e "  ${GREEN}-> $basename${NC}"
            
            # Tentar aplicar patch
            if patch -Np1 --dry-run --forward --fuzz=3 < "$patch" &>/dev/null; then
                patch -Np1 --forward --fuzz=3 --reject-file=/dev/null < "$patch" || true
            else
                echo -e "     ${YELLOW}já aplicado ou não aplicável${NC}"
            fi
        done
    fi
done

# Limpar arquivos de rejeição e backup
find . -name "*.rej" -delete 2>/dev/null || true
find . -name "*.orig" -delete 2>/dev/null || true

# --- config ---
echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}PREPARANDO CONFIGURAÇÃO${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

# Copiar config base
for cfg in "$SCRIPT_DIR/src/config" "$SCRIPT_DIR/config"; do
    if [ -f "$cfg" ]; then
        cp "$cfg" .config
        echo -e "${GREEN}>>> Config base copiado de: $cfg${NC}"
        break
    fi
done

if [ ! -f .config ]; then
    # Se não tem config, criar um mínimo
    echo -e "${YELLOW}>>> Criando config mínimo...${NC}"
    make defconfig
fi

# --- detecção de hardware ---
detect_hardware

# --- configuração automática ---
auto_configure_kernel "$KERNEL_SRC" "$BUILD_MODE"

# --- build ---
JOBS=$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))
echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}INICIANDO COMPILAÇÃO${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "Threads: ${GREEN}$JOBS${NC}"
echo -e "Início:  ${GREEN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"

START_TIME=$(date +%s)

LOG="$BUILD_DIR/build-$(date +%Y%m%d-%H%M%S).log"
echo -e "Log:     ${YELLOW}$LOG${NC}\n"

# Compilar
make CC=gcc bindeb-pkg \
    -j"$JOBS" \
    LOCALVERSION="-linuxfloat" \
    KDEB_PKGVERSION="$(make kernelversion)-1" \
    DPKG_FLAGS="-d" \
    2>&1 | tee "$LOG" ; BUILD_STATUS=${PIPESTATUS[0]}

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

if [ "$BUILD_STATUS" -ne 0 ]; then
    echo ""
    echo -e "${RED}════════════════════════════ BUILD FALHOU ═══════════════════${NC}"
    echo -e "${RED}Tempo: ${MINUTES}m ${SECONDS}s${NC}"
    echo -e "${RED}Últimos erros:${NC}"
    grep -E "^.*(error:|fatal error:|undefined reference|FAILED)" "$LOG" \
        | grep -v "^make" | tail -20
    echo ""
    echo -e "${YELLOW}Log: $LOG${NC}"
    exit "$BUILD_STATUS"
fi

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║               BUILD COMPLETO COM SUCESSO!                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo -e "${GREEN}Tempo: ${MINUTES} min ${SECONDS} seg${NC}"
echo ""
ls -lh "$BUILD_DIR"/*.deb 2>/dev/null || true

echo -e "\n${CYAN}Para instalar:${NC}"
echo -e "${YELLOW}sudo dpkg -i $BUILD_DIR/*.deb${NC}"
echo -e "${YELLOW}sudo reboot${NC}"
