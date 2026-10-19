#!/bin/bash
# build UEFI firmware (XEN_EFI.fd)
die () {
    echo >&2 "${0##*/}:${BASH_LINENO[0]}: ERROR:" "$@" && exit 1
}

dieif () {
    local exitcode
    "$@"
    exitcode="$?"
    if [ $exitcode -ne 0 ]; then
        echo >&2 "${0##*/}:${BASH_LINENO[0]}: ERROR: command \"$*\" failed with exit code $exitcode" && exit 1
    fi
}

cmdcheck () {
    local cmd
    for cmd in "$@"; do
        [ -z "$(which "$cmd")" ] && die "command $cmd not found"
    done
}

[ -n "${WORKDIR:-}" ] || die "WORKDIR is not set (expected to be called from build.sh)"

EDK2_DIR="${WORKDIR}/edk2"
EDK2_SRC="${EDK2_DIR}/src"
EDK2_OUT="${EDK2_DIR}/out"
PATCH_DIR="${EDK2_DIR}/patches"

APPLY_PATCHES=1

EDK2_TAG="edk2-stable202608"
EDK2_URL="https://github.com/tianocore/edk2.git"

EDK2_SUBMODULES=(
    MdePkg/Library/BaseFdtLib/libfdt
    BaseTools/Source/C/BrotliCompress/brotli
    MdePkg/Library/MipiSysTLib/mipisyst
    MdeModulePkg/Library/BrotliCustomDecompressLib/brotli
    SecurityPkg/DeviceSecurity/SpdmLib/libspdm
)

TARGETS=(RELEASE DEBUG)
while [ $# -gt 0 ]; do
    case "$1" in
        --no-debug) TARGETS=(RELEASE); shift ;;
        *)          die "unknown argument: $1" ;;
    esac
done

echo "=== Building EDK2 ArmVirtXen (${EDK2_TAG}) ==="

cmdcheck git make python3 aarch64-linux-gnu-gcc iasl

echo "--- iasl: $(which iasl)"

# clone edk2
if [ -d "${EDK2_SRC}/.git" ]; then
    got="$(git -C "${EDK2_SRC}" describe --tags 2>/dev/null || echo '?')"
    case "$got" in
        "${EDK2_TAG}"|"${EDK2_TAG}"-*)
            echo "--- EDK2: ${EDK2_SRC} (${got})" ;;
        *)
            die "EDK2 version mismatch: ${got} (expected ${EDK2_TAG})." \
                "To start over: rm -rf ${EDK2_SRC}" ;;
    esac
else
    echo "--- Cloning EDK2 ${EDK2_TAG} into ${EDK2_SRC}"
    dieif mkdir -p "${EDK2_DIR}"
    dieif git clone --depth 1 --branch "${EDK2_TAG}" "${EDK2_URL}" "${EDK2_SRC}"
fi

echo "--- EDK2 submodules (${#EDK2_SUBMODULES[@]})"
dieif git -C "${EDK2_SRC}" submodule update --init --depth 1 "${EDK2_SUBMODULES[@]}"

# Apply patches
APPLIED_PATCHES=()

apply_patches() {
    local dir="$1" p n=0
    [ -d "${dir}" ] || die "no such patch directory: ${dir}"
    shopt -s nullglob
    for p in "${dir}"/*.patch; do
        n=$((n + 1))
        if git -C "${EDK2_SRC}" apply --reverse --check "${p}" 2>/dev/null; then
            echo "  already applied (will be reverted on exit): $(basename "${p}")"
            APPLIED_PATCHES+=("${p}")
            continue
        fi
        echo "  applying: $(basename "${p}")"
        dieif git -C "${EDK2_SRC}" apply "${p}"
        APPLIED_PATCHES+=("${p}")
    done
    shopt -u nullglob
    [ "${n}" -gt 0 ] || die "no *.patch found in ${dir}"
}

revert_patches() {
    local i
    for (( i=${#APPLIED_PATCHES[@]}-1 ; i>=0 ; i-- )); do
        echo "  reverting: $(basename "${APPLIED_PATCHES[i]}")"
        git -C "${EDK2_SRC}" apply --reverse "${APPLIED_PATCHES[i]}" || \
            echo "WARNING: failed to revert $(basename "${APPLIED_PATCHES[i]}")." \
                 "Check with: git -C ${EDK2_SRC} status"
    done
    APPLIED_PATCHES=()
}

cleanup() {
    if [ "${#APPLIED_PATCHES[@]}" -gt 0 ]; then
        echo "--- Cleanup: reverting patches in edk2/src ---"
        revert_patches
    fi
}
trap cleanup EXIT

if [ "${APPLY_PATCHES}" = "1" ]; then
    echo "--- Applying patches"
    apply_patches "${PATCH_DIR}"
else
    echo "--- APPLY_PATCHES=0: building the unmodified upstream sources"
fi

# Build
cd "${EDK2_SRC}" || die "cannot cd ${EDK2_SRC}"

export GCC_AARCH64_PREFIX=aarch64-linux-gnu-

echo "--- BaseTools"
dieif make -C BaseTools -j"$(nproc)"

unset WORKSPACE EDK_TOOLS_PATH CONF_PATH PACKAGES_PATH EDK_TOOLS_BIN

source ./edksetup.sh || die "edksetup.sh failed"

[ "${WORKSPACE}" = "${EDK2_SRC}" ] || \
    die "edksetup.sh picked the wrong tree: WORKSPACE=${WORKSPACE} (expected ${EDK2_SRC})"

for t in "${TARGETS[@]}"; do
    echo "--- ArmVirtXen.dsc (${t})"
    dieif build -a AARCH64 -t GCC -p ArmVirtPkg/ArmVirtXen.dsc -b "${t}" -n "$(nproc)"
done

# Artifacts
dieif mkdir -p "${EDK2_OUT}"
cd "${EDK2_OUT}" || die "cannot cd ${EDK2_OUT}"

cd "${EDK2_SRC}" || die "cannot cd ${EDK2_SRC}"
dieif cp "${EDK2_SRC}/Build/ArmVirtXen-AARCH64/RELEASE_GCC/FV/XEN_EFI.fd" \
         "${EDK2_OUT}/XEN_EFI.fd"
if [ -f "${EDK2_SRC}/Build/ArmVirtXen-AARCH64/DEBUG_GCC/FV/XEN_EFI.fd" ]; then
    dieif cp "${EDK2_SRC}/Build/ArmVirtXen-AARCH64/DEBUG_GCC/FV/XEN_EFI.fd" \
             "${EDK2_OUT}/XEN_EFI-debug.fd"
fi