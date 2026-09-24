#!/usr/bin/env bash
# Builds an AUR package (and recursively, any AUR-only dependencies) as an
# unprivileged user, while this script itself runs as root.
#
# We deliberately avoid sudo/su-to-root here: BuildKit RUN steps are mounted
# nosuid (even with --security=insecure), so a setuid-root binary like sudo
# can never regain root once dropped to a normal user. Instead we stay root
# for anything that needs to install packages, and only drop privileges
# *downward* to the builder user (via `su`, which needs no setuid since the
# calling process is already root) to run makepkg itself.
set -euo pipefail

BUILD_USER=builder
BUILD_ROOT=/home/builder/build
PKGDEST="${PKGDEST:-/home/builder/output}"

mkdir -p "$BUILD_ROOT" "$PKGDEST"
chown "$BUILD_USER:$BUILD_USER" "$BUILD_ROOT" "$PKGDEST"

declare -A VISITED

as_builder() {
  su - "$BUILD_USER" -c "$1"
}

build_aur_pkg() {
  local pkg="$1"
  [[ -n "${VISITED[$pkg]:-}" ]] && return 0
  VISITED[$pkg]=1

  pacman -Qi "$pkg" >/dev/null 2>&1 && return 0

  local dir="$BUILD_ROOT/$pkg"
  rm -rf "$dir"
  git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "$dir"

  # Some AUR PKGBUILDs hardcode x86-only build flags and don't actually
  # know/care about aarch64. patches/<pkg>.patch (if present) fixes those
  # up before we build; see patches/opencv4.patch for an example.
  local patch_file="/patches/${pkg}.patch"
  if [[ -f "$patch_file" ]]; then
    patch -d "$dir" -p1 < "$patch_file"
  fi

  chown -R "$BUILD_USER:$BUILD_USER" "$dir"

  local deps
  deps=$(as_builder "cd '$dir' && bash -c 'source PKGBUILD; printf \"%s\n\" \"\${depends[@]}\" \"\${makedepends[@]}\"'" | sed -E 's/[<>=].*//' | sort -u)

  local repo_deps=() aur_deps=()
  for d in $deps; do
    [[ -z "$d" ]] && continue
    pacman -Qi "$d" >/dev/null 2>&1 && continue
    if pacman -S --needed --noconfirm --print "$d" >/dev/null 2>&1; then
      repo_deps+=("$d")
    else
      aur_deps+=("$d")
    fi
  done

  if ((${#repo_deps[@]})); then
    pacman -S --needed --noconfirm "${repo_deps[@]}"
  fi

  for a in "${aur_deps[@]}"; do
    build_aur_pkg "$a"
  done

  # Deps are already installed, so makepkg's own dependency-install phase
  # (which would need sudo) is a no-op here.
  as_builder "cd '$dir' && PKGDEST='$PKGDEST' makepkg -s --noconfirm --skippgpcheck --ignorearch"

  pacman -U --noconfirm "$dir"/*.pkg.tar.*
}

build_aur_pkg "$1"
