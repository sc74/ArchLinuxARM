PLATFORMS?=linux/arm64
IMAGE?=archlinuxarm
KERNEL_FLAVOR?=rpi

.PHONY: binfmt
binfmt:
	docker run --privileged --rm tonistiigi/binfmt --install arm64

# --- Builds ---
.PHONY: build-minimal
build-minimal:
	docker buildx build \
	  --platform $(PLATFORMS) \
	  -t $(IMAGE):minimal-aarch64 \
          -f dockerfiles/Dockerfile.base \
          --target archarm \
          --load \
	  .

.PHONY: build-aarch64
build-aarch64: binfmt
	docker buildx build \
	  --platform $(PLATFORMS) \
	  -t $(IMAGE):generic-aarch64 \
          -f dockerfiles/Dockerfile.aarch64 \
	  --target builder \
          --load \
	  .

.PHONY: build-aarch64-rootfs
build-aarch64-rootfs: binfmt
	docker buildx build \
	  --platform $(PLATFORMS) \
	  -t $(IMAGE):generic-aarch64-rootfs \
          -f dockerfiles/Dockerfile.aarch64 \
	  --target export \
          --load \
	  .

.PHONY: build-astroarch
build-astroarch: binfmt
	docker buildx build \
	  --build-arg KERNEL_FLAVOR=$(KERNEL_FLAVOR) \
	  --platform $(PLATFORMS) \
	  -t astroarch:latest \
          -f dockerfiles/Dockerfile.astroarch \
	  --target builder \
          --load \
	  .

.PHONY: build-astroarch-rootfs
build-astroarch-rootfs: binfmt
	docker buildx build \
	  --build-arg BUILDKIT_SANDBOX_SIZE=30G \
	  --build-arg KERNEL_FLAVOR=$(KERNEL_FLAVOR) \
	  --platform $(PLATFORMS) \
	  -t astroarch-rootfs:latest \
          -f dockerfiles/Dockerfile.astroarch \
	  --target astroarch-rootfs \
          --load \
	  .

.PHONY: build-aur
build-aur: binfmt
	@if [ -z "$(PKG)" ]; then \
	  echo "Usage: make build-aur PKG=<aur-package-name>"; \
	  exit 1; \
	fi
	docker buildx build \
	  --platform $(PLATFORMS) \
	  -f dockerfiles/Dockerfile.aur \
	  --target export \
	  --build-arg PKG=$(PKG) \
	  --output type=local,dest=$(CURDIR) \
	  .

.PHONY: create-rootfs-container
create-rootfs-container:
	docker create --platform=$(PLATFORMS) --name take astroarch-rootfs:latest sh

.PHONY: copy-rootfs-tar
copy-rootfs-tar:
	docker cp take:/astroarch-rootfs.tar ./rootfs.tar
	docker rm -f take

# --- Bootable images ---
# Board profiles live in boards/<name>.conf (KERNEL_FLAVOR, boot strategy,
# bootloader, console, ...). Add a board by dropping in a new .conf file -
# no Makefile changes needed.
.PHONY: check-board
check-board:
	@[ -n "$(BOARD)" ] || { echo "Usage: make prepare-img BOARD=<board>"; exit 1; }
	@[ -f boards/$(BOARD).conf ] || { echo "Unknown BOARD=$(BOARD) (no boards/$(BOARD).conf)"; exit 1; }

.PHONY: prepare-img
prepare-img: KERNEL_FLAVOR = $(shell . boards/$(BOARD).conf 2>/dev/null && echo $$KERNEL_FLAVOR)
prepare-img: check-board build-astroarch-rootfs create-rootfs-container copy-rootfs-tar
	BOARD=$(BOARD) IMG=archarm-$(BOARD)-aarch64.img ./scripts/build_img.sh
