#!/bin/bash
# linux-float build script
# Usage: ./build.sh <version>
# Example: ./build.sh 6.14.13
#          ./build.sh 6.14   (resolve automaticamente a última patch release)

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 6.14.13"
    echo "         $0 6.14    (resolve automaticamente)"
    exit 1
fi

RAW="$1"
# Normalizar versão: remove sufixos de empacotador Debian/Ubuntu como -37, ~24.04, etc.
CLEAN=$(echo "$RAW" | sed 's/[-~][^0-9].*//;s/[-~][0-9]*$//')
DOTS=$(echo "$CLEAN" | tr -cd '.' | wc -c)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
mkdir -p "$BUILD_DIR"

# Se só MAJOR.MINOR, resolver a última patch release
if [ "$DOTS" -lt 2 ]; then
    MAJOR_MINOR="$CLEAN"
    v_base="v$(echo "$MAJOR_MINOR" | cut -d. -f1).x"
    echo "Resolvendo última patch release de $MAJOR_MINOR ..."
    LATEST=$(curl -s "https://www.kernel.org/pub/linux/kernel/$v_base/" \
        | grep -oP "linux-${MAJOR_MINOR//./\\.}\.[0-9]+\.tar\.xz" \
        | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -V | tail -1)
    if [ -z "$LATEST" ]; then
        echo "ERRO: não foi possível resolver versão para $MAJOR_MINOR"
        exit 1
    fi
    v_full="$LATEST"
    echo "Versão resolvida: $v_full"
else
    v_full="$CLEAN"
fi

v_base="v$(echo "$v_full" | cut -d. -f1).x"
TARBALL_XZ="linux-$v_full.tar.xz"
TARBALL_GZ="linux-$v_full.tar.gz"
KERNEL_URL_BASE="https://www.kernel.org/pub/linux/kernel/$v_base"

echo "Versão: $v_full  |  URL base: $KERNEL_URL_BASE"

# --- dependências ---
dep_miss=()
dependencies=(libncurses-dev gawk flex bison openssl libssl-dev dkms libelf-dev \
    libudev-dev libpci-dev libiberty-dev autoconf llvm gcc bc rsync kmod cpio \
    zstd libzstd-dev python3 wget curl debhelper libdw-dev libdwarf-dev elfutils)
for dep in "${dependencies[@]}"; do
    if ! dpkg -s "$dep" &> /dev/null; then
        dep_miss+=("$dep")
    fi
done
if [ ${#dep_miss[@]} -ne 0 ]; then
    echo "Instalando dependências: ${dep_miss[*]}"
    sudo apt-get update -q
    sudo apt-get install -y "${dep_miss[@]}"
fi

# --- download ---
cd "$BUILD_DIR"
if [ ! -f "$TARBALL_XZ" ] && [ ! -f "$TARBALL_GZ" ]; then
    echo "Baixando $TARBALL_XZ ..."
    if ! wget -q --show-progress "$KERNEL_URL_BASE/$TARBALL_XZ"; then
        echo "Falhou .tar.xz, tentando .tar.gz ..."
        if ! wget --show-progress "$KERNEL_URL_BASE/$TARBALL_GZ"; then
            echo "ERRO: versão '$v_full' não encontrada."
            echo "Versões disponíveis: https://www.kernel.org/pub/linux/kernel/$v_base/"
            exit 1
        fi
    fi
else
    echo "Tarball já existe, pulando download."
fi

# --- extração ---
if [ -d "linux-$v_full" ]; then
    echo "Fonte já extraída, pulando."
else
    if [ -f "$TARBALL_XZ" ]; then
        tar -xf "$TARBALL_XZ"
    else
        tar -xzf "$TARBALL_GZ"
    fi
fi

cd "linux-$v_full"

# --- patches ---
# Patches para IGNORAR (redundantes ou quebrados nesta versão do kernel)
SKIP_PATCHES="0010-bore-cachy-fix.patch"

echo "Aplicando patches..."
for dir in "$SCRIPT_DIR/src" "$SCRIPT_DIR"; do
    for patch in $(ls "$dir"/*.patch 2>/dev/null | sort); do
        [ -f "$patch" ] || continue
        basename=$(basename "$patch")
        # Pular patches problemáticos
        if echo "$SKIP_PATCHES" | grep -qw "$basename"; then
            echo "  -- $basename (ignorado: redundante com 0001)"
            continue
        fi
        echo "  -> $basename"
        patch -Np1 --forward --reject-file=/dev/null < "$patch" || \
            echo "     AVISO: falhou ou já aplicado, continuando..."
    done
done

# --- config ---
echo "Copiando .config ..."
for cfg in "$SCRIPT_DIR/src/config" "$SCRIPT_DIR/config"; do
    if [ -f "$cfg" ]; then
        cp "$cfg" .config
        break
    fi
done
[ -f .config ] || { echo "ERRO: arquivo config não encontrado"; exit 1; }

make olddefconfig

# --- build ---
# -d: ignora dependências de build do debhelper-compat (já satisfeitas pelo debhelper instalado)
JOBS=$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))
echo "Compilando com $JOBS threads..."
make CC=gcc bindeb-pkg \
    -j"$JOBS" \
    LOCALVERSION="-linuxfloat" \
    KDEB_PKGVERSION="$(make kernelversion)-1" \
    DPKG_FLAGS="-d"

echo ""
echo "=============================="
echo " Build completo!"
echo " Pacotes .deb em: $BUILD_DIR/"
echo "=============================="
ls -lh "$BUILD_DIR"/*.deb 2>/dev/null || true
