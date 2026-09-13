#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Ubuntu ISO Docker Image Multi-Release Builder
# Builds clean, minimal, systemd-enabled Docker images from Ubuntu installation ISOs
# ==============================================================================

C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

log_info()    { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${C_CYAN}[INFO]${C_RESET} $*"; }
log_step()    { echo -e "\n[$(date +'%Y-%m-%d %H:%M:%S')] ${C_BOLD}===> $*${C_RESET}"; }
log_success() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${C_GREEN}[SUCCESS]${C_RESET} $*"; }
log_warn()    { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${C_YELLOW}[WARNING]${C_RESET} $*"; }
log_error()   { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_exec()    { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${C_YELLOW}[EXEC]${C_RESET} + $*"; }

s() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

PRESET_CHOICE="${PRESET:-server}"
IMAGE_NAME="${DOCKER_IMAGE_NAME:-runalsh/ubuntu-iso-patch}"
RELEASES_FILE="releases.txt"
EXTRA_INCLUDE_PKGS=""
SKIP_EXISTS_CHECK="${SKIP_EXISTS_CHECK:-false}"
PUSH_TO_DOCKERHUB="${PUSH_TO_DOCKERHUB:-false}"
PUSH_TO_GHCR="${PUSH_TO_GHCR:-false}"
TEST_VERSION="${TEST_VERSION:-true}"
CLEANUP_DOCKER_IMAGES="${CLEANUP_DOCKER_IMAGES:-true}"

declare -a CLI_ISOS=()

show_help() {
  cat << 'EOF_HELP'
Usage: ./build.sh [OPTIONS] [ISO_PATH_OR_TAG...]

Options:
  -p, --preset PRESET       Select package preset: 'server' (default) or 'minimal'
  -e, --extra-pkgs PKGS     Comma-separated list of extra packages to install in chroot
  -r, --releases-file FILE  Path to releases.txt (default: releases.txt)
  -n, --no-check-exists     Force build even if image tags exist in remote registries
  --push-dockerhub          Push generated images to Docker Hub
  --push-ghcr               Push generated images to GitHub Container Registry (GHCR)
  --no-test                 Skip local docker run smoke-test
  -h, --help                Show this help message

Presets:
  server   (default) Base system + SSH + network/admin utils, stripped of kernel/firmware bloat.
  minimal  Lightweight headless systemd base container.
  * Note: tags are strictly pure OS versions (e.g. runalsh/ubuntu-iso-patch:24.04.5, 24.04, latest) without preset suffixes.
EOF_HELP
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--preset)
      PRESET_CHOICE="$2"
      shift 2
      ;;
    --preset=*)
      PRESET_CHOICE="${1#*=}"
      shift
      ;;
    -e|--extra-pkgs)
      EXTRA_INCLUDE_PKGS="$2"
      shift 2
      ;;
    --extra-pkgs=*)
      EXTRA_INCLUDE_PKGS="${1#*=}"
      shift
      ;;
    -r|--releases-file)
      RELEASES_FILE="$2"
      shift 2
      ;;
    --releases-file=*)
      RELEASES_FILE="${1#*=}"
      shift
      ;;
    -n|--no-check-exists)
      SKIP_EXISTS_CHECK="true"
      shift
      ;;
    --push-dockerhub)
      PUSH_TO_DOCKERHUB="true"
      shift
      ;;
    --push-ghcr)
      PUSH_TO_GHCR="true"
      shift
      ;;
    --no-test)
      TEST_VERSION="false"
      shift
      ;;
    -h|--help)
      show_help
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        CLI_ISOS+=("$1")
        shift
      done
      break
      ;;
    *)
      CLI_ISOS+=("$1")
      shift
      ;;
  esac
done

ensure_host_dependencies() {
  local missing=()
  for cmd in curl tar gzip docker mount umount; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    log_info "Missing host tools: ${missing[*]}. Installing..."
    if command -v apt-get &>/dev/null; then
      s apt-get update -qq || true
      s apt-get install -y -qq "${missing[@]}" squashfs-tools || true
    elif command -v dnf &>/dev/null; then
      s dnf install -y -q "${missing[@]}" squashfs-tools || true
    elif command -v yum &>/dev/null; then
      s yum install -y -q "${missing[@]}" squashfs-tools || true
    fi
  fi
}
ensure_host_dependencies

declare -a TARGETS=()

if [ ${#CLI_ISOS[@]} -gt 0 ]; then
  for item in "${CLI_ISOS[@]}"; do
    if [ -f "$RELEASES_FILE" ] && grep -qE "^${item}[[:space:]]+" "$RELEASES_FILE"; then
      matched_line=$(grep -E "^${item}[[:space:]]+" "$RELEASES_FILE" | head -n1)
      matched_tag=$(echo "$matched_line" | awk '{print $1}')
      matched_src=$(echo "$matched_line" | awk '{$1=""; print $0}' | sed -e 's/^[[:space:]]*//')
      TARGETS+=("$matched_tag|$matched_src")
    elif [[ "$item" =~ ^https?:// ]]; then
      tag=$(basename "$item" .iso | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || echo "latest")
      TARGETS+=("$tag|$item")
    elif [ -f "$item" ]; then
      tag=$(basename "$item" .iso | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || echo "latest")
      TARGETS+=("$tag|$item")
    else
      log_warn "File or tag '$item' not found, skipping."
    fi
  done
elif [ -f "$RELEASES_FILE" ]; then
  while read -r tag url || [ -n "$tag" ]; do
    [[ -z "$tag" || "$tag" =~ ^# ]] && continue
    TARGETS+=("$tag|$url")
  done < "$RELEASES_FILE"
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  log_warn "Neither populated $RELEASES_FILE nor valid CLI ISO arguments were provided. Nothing to build."
  exit 0
fi

echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}Ubuntu ISO Docker Multi-Release Builder${C_RESET}"
echo -e "Repository:            ${C_YELLOW}${IMAGE_NAME}${C_RESET}"
echo -e "Preset:                ${C_YELLOW}${PRESET_CHOICE}${C_RESET}"
if [ -n "$EXTRA_INCLUDE_PKGS" ]; then
  echo -e "Extra packages:        ${C_YELLOW}${EXTRA_INCLUDE_PKGS}${C_RESET}"
fi
echo -e "Releases in queue:     ${#TARGETS[@]}"
echo -e "Push to Docker Hub:    ${PUSH_TO_DOCKERHUB}"
echo -e "Push to GHCR:          ${PUSH_TO_GHCR}"
echo -e "${C_BOLD}==============================================================================${C_RESET}"

global_cleanup() {
  log_info "Running cleanup of leftover mounts and temporary files..."
  for m in $(mount 2>/dev/null | grep -E '/tmp/ubuntu-iso-patch_' | awk '{print $3}' || true); do
    s umount -f "$m" 2>/dev/null || true
  done
  s rm -rf /tmp/ubuntu-iso-patch_* 2>/dev/null || true
}
global_cleanup

SUCCESS_TAGS=()

for target in "${TARGETS[@]}"; do
  tag="${target%%|*}"
  source="${target##*|}"

  log_step "Processing release: tag='${tag}', source='${source}'"

  FULL_IMAGE_TAG="${IMAGE_NAME}:${tag}"
  GHCR_IMAGE_NAME="ghcr.io/$(echo "${IMAGE_NAME}" | tr '[:upper:]' '[:lower:]')"
  FULL_GHCR_TAG="${GHCR_IMAGE_NAME}:${tag}"

  # Remote registry check
  if [ "$SKIP_EXISTS_CHECK" != "true" ]; then
    dh_exists=false
    ghcr_exists=false
    if [ "$PUSH_TO_DOCKERHUB" = "true" ]; then
      if docker manifest inspect "${FULL_IMAGE_TAG}" &>/dev/null || curl -sfSL "https://hub.docker.com/v2/repositories/${IMAGE_NAME}/tags/${tag}/" &>/dev/null; then
        dh_exists=true
      fi
    else
      dh_exists=true
    fi
    if [ "$PUSH_TO_GHCR" = "true" ]; then
      if docker manifest inspect "${FULL_GHCR_TAG}" &>/dev/null; then
        ghcr_exists=true
      fi
    else
      ghcr_exists=true
    fi
    if [ "$dh_exists" = "true" ] && [ "$ghcr_exists" = "true" ] && { [ "$PUSH_TO_DOCKERHUB" = "true" ] || [ "$PUSH_TO_GHCR" = "true" ]; }; then
      log_success "Tag ${FULL_IMAGE_TAG} already exists on all enabled registries. Skipping build."
      continue
    fi
  fi

  RAND_ID=$(head /dev/urandom | tr -dc a-z0-9 | head -c 8 ; echo '')
  LOCAL_ISO=""
  MNT_DIR="/tmp/ubuntu-iso-patch_iso_mnt_${RAND_ID}"
  ROOTFS_DIR="/tmp/ubuntu-iso-patch_rootfs_${RAND_ID}"
  SQUASH_MNT="/tmp/ubuntu-iso-patch_squash_${RAND_ID}"

  cleanup_run() {
    log_info "Cleaning up temporary mount points and rootfs directory..."
    s umount -f "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
    s umount -f "$SQUASH_MNT" 2>/dev/null || true
    s umount -f "$MNT_DIR" 2>/dev/null || true
    s rm -rf "$MNT_DIR" "$ROOTFS_DIR" "$SQUASH_MNT"
    if [ -n "${LOCAL_ISO:-}" ] && [[ "$LOCAL_ISO" =~ ^/tmp/ubuntu-iso-patch_download_.*\.iso$ ]] && [ -f "$LOCAL_ISO" ]; then
      log_info "Removing downloaded temporary ISO: $LOCAL_ISO"
      rm -f "$LOCAL_ISO"
    fi
    if [ "${CLEANUP_DOCKER_IMAGES:-false}" = "true" ]; then
      log_info "Pruning local Docker images for this tag to free disk space..."
      docker rmi -f "${FULL_IMAGE_TAG}" "${FULL_GHCR_TAG}" 2>/dev/null || true
      for extra_tag in "${ALL_EXTRA_TAGS[@]:-}"; do
        docker rmi -f "${IMAGE_NAME}:${extra_tag}" "${GHCR_IMAGE_NAME}:${extra_tag}" 2>/dev/null || true
      done
    fi
  }
  trap cleanup_run EXIT INT TERM HUP

  s mkdir -p "$MNT_DIR" "$ROOTFS_DIR" "$SQUASH_MNT"

  if [[ "$source" =~ ^https?:// ]]; then
    LOCAL_ISO="/tmp/ubuntu-iso-patch_download_${RAND_ID}.iso"
    log_info "Downloading Ubuntu ISO from ${source}..."
    log_exec "curl -fLC - -sS --show-error -o $LOCAL_ISO $source"
    curl -fLC - -sS --show-error -o "$LOCAL_ISO" "$source"
    ISO_SIZE=$(du -h "$LOCAL_ISO" | awk '{print $1}')
    log_success "Download complete. File size: ${ISO_SIZE}"
  elif [ -f "$source" ]; then
    LOCAL_ISO="$source"
  else
    log_error "ISO source '$source' not found!"
    exit 1
  fi

  log_info "Mounting ISO image..."
  s mount -o loop,ro "$LOCAL_ISO" "$MNT_DIR"

  # If ISO was downloaded to /tmp, we can free disk space if squashfs files are extracted
  # But loop mount keeps file open, so we remove after rootfs extraction

  log_step "Extracting rootfs from Ubuntu ISO"
  FOUND_ROOTFS=false

  # 1. Check for modern Ubuntu Live Server squashfs files (20.04, 22.04, 24.04+)
  MINIMAL_SQUASH=$(find "$MNT_DIR/casper" -name "ubuntu-server-minimal.squashfs" 2>/dev/null | head -n1 || true)
  SERVER_SQUASH=$(find "$MNT_DIR/casper" -name "ubuntu-server-minimal.ubuntu-server.squashfs" 2>/dev/null | head -n1 || true)
  GENERIC_SQUASH=$(find "$MNT_DIR/casper" -name "filesystem.squashfs" 2>/dev/null | head -n1 || true)

  extract_squashfs() {
    local squash_file="$1"
    local target_dir="$2"
    log_info "Extracting squashfs layer: $(basename "$squash_file")"
    if [ -z "$(ls -A "$target_dir" 2>/dev/null)" ] && command -v unsquashfs &>/dev/null; then
      s unsquashfs -f -d "$target_dir" "$squash_file"
    elif command -v unsquashfs &>/dev/null; then
      local layer_tmp
      layer_tmp=$(mktemp -d /tmp/squashfs_layer.XXXXXX)
      s unsquashfs -d "$layer_tmp" "$squash_file"
      s cp -a "$layer_tmp/." "$target_dir/"
      s rm -rf "$layer_tmp"
    else
      s mkdir -p "$SQUASH_MNT"
      s mount -t squashfs -o loop,ro "$squash_file" "$SQUASH_MNT"
      s cp -a "$SQUASH_MNT/." "$target_dir/"
      s umount "$SQUASH_MNT"
    fi
  }

  if [ -n "$MINIMAL_SQUASH" ] && [ -f "$MINIMAL_SQUASH" ]; then
    extract_squashfs "$MINIMAL_SQUASH" "$ROOTFS_DIR"
    FOUND_ROOTFS=true

    if [ "$PRESET_CHOICE" = "server" ] && [ -n "$SERVER_SQUASH" ] && [ -f "$SERVER_SQUASH" ]; then
      log_info "Applying Ubuntu Server overlay layer..."
      extract_squashfs "$SERVER_SQUASH" "$ROOTFS_DIR"
    fi
  elif [ -n "$GENERIC_SQUASH" ] && [ -f "$GENERIC_SQUASH" ]; then
    extract_squashfs "$GENERIC_SQUASH" "$ROOTFS_DIR"
    FOUND_ROOTFS=true
  fi

  if [ "$FOUND_ROOTFS" != "true" ]; then
    log_error "No valid rootfs squashfs image found in ISO ($MNT_DIR/casper)!"
    exit 1
  fi

  # Unmount ISO and free temporary download file immediately
  s umount "$MNT_DIR" 2>/dev/null || true
  if [ -n "${LOCAL_ISO:-}" ] && [[ "$LOCAL_ISO" =~ ^/tmp/ubuntu-iso-patch_download_.*\.iso$ ]] && [ -f "$LOCAL_ISO" ]; then
    log_info "Removing downloaded temporary ISO to free disk space..."
    rm -f "$LOCAL_ISO"
    LOCAL_ISO=""
  fi

  log_step "Configuring container chroot environment"

  # Prevent services from starting during configuration
  cat << 'EOF_POLICY' | s tee "$ROOTFS_DIR/usr/sbin/policy-rc.d" >/dev/null
#!/bin/sh
exit 101
EOF_POLICY
  s chmod +x "$ROOTFS_DIR/usr/sbin/policy-rc.d"

  # Setup DNS resolution inside chroot
  if [ -f /etc/resolv.conf ]; then
    s cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
  fi

  # Detect Ubuntu codename from /etc/os-release
  UBUNTU_CODENAME="noble"
  if [ -f "$ROOTFS_DIR/etc/os-release" ]; then
    c_name=$(grep -E '^VERSION_CODENAME=' "$ROOTFS_DIR/etc/os-release" | cut -d= -f2 | tr -d ' "\r\n' || true)
    [ -n "$c_name" ] && UBUNTU_CODENAME="$c_name"
  fi
  log_info "Detected Ubuntu release codename: ${UBUNTU_CODENAME}"

  # Configure official remote APT repositories
  s mkdir -p "$ROOTFS_DIR/etc/apt/sources.list.d"
  if [ -f "$ROOTFS_DIR/etc/apt/sources.list.d/ubuntu.sources" ]; then
    log_info "Modern ubuntu.sources format already present."
  else
    cat << EOF_APTLIST | s tee "$ROOTFS_DIR/etc/apt/sources.list" >/dev/null
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF_APTLIST
  fi

  if [ "$PRESET_CHOICE" = "server" ]; then
    log_step "Configuring Server preset (Base tools + SSH; excluding hardware/kernel bloat)"

    SERVER_PKGS=(
      mc vim bash-completion p7zip-full unzip bzip2 xz-utils zstd
      less nano curl wget rsync sudo locales iproute2 net-tools
      openssh-server openssh-client
    )

    if [ -n "$EXTRA_INCLUDE_PKGS" ]; then
      IFS=',' read -ra ADDS <<< "$EXTRA_INCLUDE_PKGS"
      SERVER_PKGS+=("${ADDS[@]}")
    fi

    # Mount proc and sysfs for apt operations
    s mount -t proc proc "$ROOTFS_DIR/proc" 2>/dev/null || true
    s mount -t sysfs sysfs "$ROOTFS_DIR/sys" 2>/dev/null || true

    log_info "Updating package lists inside rootfs..."
    s chroot "$ROOTFS_DIR" env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get update -qq || true

    log_exec "apt-get install -y --no-install-recommends ${SERVER_PKGS[*]}"
    s chroot "$ROOTFS_DIR" env DEBIAN_FRONTEND=noninteractive LC_ALL=C \
      apt-get install -y -qq --no-install-recommends "${SERVER_PKGS[@]}" 2>/dev/null || {
        log_warn "Some packages failed on batch install, installing individually..."
        for p in "${SERVER_PKGS[@]}"; do
          s chroot "$ROOTFS_DIR" env DEBIAN_FRONTEND=noninteractive LC_ALL=C \
            apt-get install -y -qq --no-install-recommends "$p" 2>/dev/null || true
        done
      }

    s umount "$ROOTFS_DIR/proc" 2>/dev/null || true
    s umount "$ROOTFS_DIR/sys" 2>/dev/null || true

    # Enable SSH service in systemd
    if [ -f "$ROOTFS_DIR/lib/systemd/system/ssh.service" ] || [ -f "$ROOTFS_DIR/usr/lib/systemd/system/ssh.service" ]; then
      log_info "Enabling ssh.service in multi-user.target.wants..."
      s mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
      SSH_SRC="/lib/systemd/system/ssh.service"
      [ ! -f "$ROOTFS_DIR$SSH_SRC" ] && SSH_SRC="/usr/lib/systemd/system/ssh.service"
      s ln -sf "$SSH_SRC" "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/ssh.service"
    fi
  fi

  log_step "Deep optimization of rootfs for Docker container"

  # Purge snapd, lxd, and snap files
  log_exec "Purging snapd, lxd, and snap data..."
  s rm -rf "$ROOTFS_DIR"/var/lib/snapd "$ROOTFS_DIR"/usr/lib/snapd "$ROOTFS_DIR"/var/snap "$ROOTFS_DIR"/snap "$ROOTFS_DIR"/var/lib/lxd 2>/dev/null || true

  # Purge kernel images, modules, and hardware firmware
  log_exec "Purging host kernel images, initramfs, modules and firmware..."
  s rm -rf "$ROOTFS_DIR"/boot/vmlinuz* "$ROOTFS_DIR"/boot/initrd* "$ROOTFS_DIR"/boot/System.map* "$ROOTFS_DIR"/boot/config* 2>/dev/null || true
  s rm -rf "$ROOTFS_DIR"/lib/modules/* "$ROOTFS_DIR"/usr/lib/modules/* 2>/dev/null || true
  s rm -rf "$ROOTFS_DIR"/lib/firmware/* "$ROOTFS_DIR"/usr/lib/firmware/* 2>/dev/null || true

  # Purge documentation, man pages, caches, and logs
  log_exec "Purging documentation, man pages, caches, and temporary files..."
  s rm -rf "$ROOTFS_DIR"/usr/share/doc/* "$ROOTFS_DIR"/usr/share/man/* "$ROOTFS_DIR"/usr/share/info/* 2>/dev/null || true
  s rm -rf "$ROOTFS_DIR"/var/cache/apt/* "$ROOTFS_DIR"/var/lib/apt/lists/* 2>/dev/null || true
  s rm -rf "$ROOTFS_DIR"/tmp/* "$ROOTFS_DIR"/var/tmp/* "$ROOTFS_DIR"/var/log/* 2>/dev/null || true
  s rm -f "$ROOTFS_DIR"/usr/sbin/policy-rc.d 2>/dev/null || true

  # Configure systemd units for clean container execution
  log_info "Configuring systemd units for container compatibility..."
  s rm -f "$ROOTFS_DIR"/etc/systemd/system/*.wants/* 2>/dev/null || true
  s rm -f "$ROOTFS_DIR"/lib/systemd/system/multi-user.target.wants/getty.target 2>/dev/null || true
  s rm -f "$ROOTFS_DIR"/usr/lib/systemd/system/multi-user.target.wants/getty.target 2>/dev/null || true
  s rm -f "$ROOTFS_DIR"/lib/systemd/system/basic.target.wants/* 2>/dev/null || true
  s rm -f "$ROOTFS_DIR"/usr/lib/systemd/system/basic.target.wants/* 2>/dev/null || true

  log_step "Importing rootfs into Docker -> ${FULL_IMAGE_TAG}"
  s tar -C "$ROOTFS_DIR" -c . | docker import \
    -c "ENV container=docker" \
    -c "ENV LANG=C.UTF-8" \
    -c "STOPSIGNAL SIGRTMIN+3" \
    -c 'CMD ["/sbin/init"]' \
    - "${FULL_IMAGE_TAG}"

  # Extract semantic components from OS version
  INTERNAL_VERSION=""
  if [ -f "$ROOTFS_DIR/etc/os-release" ]; then
    INTERNAL_VERSION=$(grep -E '^VERSION_ID=' "$ROOTFS_DIR/etc/os-release" | head -n1 | cut -d= -f2 | tr -d ' "\r\n' || true)
  fi
  if [ -z "$INTERNAL_VERSION" ]; then
    INTERNAL_VERSION="$tag"
  fi

  if [[ "$INTERNAL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    PATCH_VER="$INTERNAL_VERSION"
    MINOR_VER=$(echo "$INTERNAL_VERSION" | cut -d. -f1,2)
    MAJOR_VER="$MINOR_VER"
  elif [[ "$INTERNAL_VERSION" =~ ^[0-9]+\.[0-9]+ ]]; then
    PATCH_VER="$INTERNAL_VERSION"
    MINOR_VER="$INTERNAL_VERSION"
    MAJOR_VER="$INTERNAL_VERSION"
  else
    PATCH_VER="$tag"
    MINOR_VER="$tag"
    MAJOR_VER="$tag"
  fi

  log_info "Extracted release versions:"
  log_info "  -> Full Tag:  $tag"
  log_info "  -> Patch Ver: $PATCH_VER"
  log_info "  -> Minor Ver: $MINOR_VER"
  log_info "  -> Major Ver: $MAJOR_VER"

  declare -a ALL_EXTRA_TAGS=()
  [ -n "$PATCH_VER" ] && [ "$PATCH_VER" != "$tag" ] && ALL_EXTRA_TAGS+=("$PATCH_VER")
  [ -n "$MINOR_VER" ] && [ "$MINOR_VER" != "$tag" ] && [ "$MINOR_VER" != "$PATCH_VER" ] && ALL_EXTRA_TAGS+=("$MINOR_VER")
  [ -n "$MAJOR_VER" ] && [ "$MAJOR_VER" != "$tag" ] && [ "$MAJOR_VER" != "$PATCH_VER" ] && [ "$MAJOR_VER" != "$MINOR_VER" ] && ALL_EXTRA_TAGS+=("$MAJOR_VER")

  docker tag "${FULL_IMAGE_TAG}" "${FULL_GHCR_TAG}"

  for extra_tag in "${ALL_EXTRA_TAGS[@]}"; do
    log_exec "docker tag ${FULL_IMAGE_TAG} ${IMAGE_NAME}:${extra_tag}"
    docker tag "${FULL_IMAGE_TAG}" "${IMAGE_NAME}:${extra_tag}"
    log_exec "docker tag ${FULL_IMAGE_TAG} ${GHCR_IMAGE_NAME}:${extra_tag}"
    docker tag "${FULL_IMAGE_TAG}" "${GHCR_IMAGE_NAME}:${extra_tag}"
  done

  if [ "$TEST_VERSION" = "true" ]; then
    log_step "Validating generated Docker image"
    if TEST_VER=$(docker run --rm "${FULL_IMAGE_TAG}" cat /etc/os-release 2>/dev/null); then
      echo -e "${C_CYAN}------------------------------------------------------------${C_RESET}"
      echo -e "${C_BOLD}Container OS identification:${C_RESET}\n${C_YELLOW}${TEST_VER}${C_RESET}"
      echo -e "${C_CYAN}------------------------------------------------------------${C_RESET}"
    else
      log_warn "Container execution failed or architecture mismatch. Skipping."
    fi
  fi

  if [ "$PUSH_TO_DOCKERHUB" = "true" ]; then
    log_step "Pushing to Docker Hub: ${FULL_IMAGE_TAG}"
    docker push "${FULL_IMAGE_TAG}"
    for extra_tag in "${ALL_EXTRA_TAGS[@]}"; do
      docker push "${IMAGE_NAME}:${extra_tag}"
    done
  fi

  if [ "$PUSH_TO_GHCR" = "true" ]; then
    log_step "Pushing to GHCR: ${FULL_GHCR_TAG}"
    docker push "${FULL_GHCR_TAG}"
    for extra_tag in "${ALL_EXTRA_TAGS[@]}"; do
      docker push "${GHCR_IMAGE_NAME}:${extra_tag}"
    done
  fi

  SUCCESS_TAGS+=("${FULL_IMAGE_TAG}")
  cleanup_run
  trap - EXIT
done

echo ""
echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}BUILD SUMMARY REPORT${C_RESET}"
echo -e "Images successfully built: ${#SUCCESS_TAGS[@]}"
for t in "${SUCCESS_TAGS[@]}"; do
  echo -e "  - ${C_BOLD}${t}${C_RESET}"
done
echo -e "${C_BOLD}==============================================================================${C_RESET}"
