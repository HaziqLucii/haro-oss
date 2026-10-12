.PHONY: publish linux install-linux

# Push a squashed public snapshot to HaziqLucii/haro-oss (see scripts/publish-oss.sh).
publish:
	@./scripts/publish-oss.sh

# Linux release: tarball + AppImage in dist/ (see scripts/build-linux.sh).
linux:
	@./scripts/build-linux.sh

# Build and install on this machine: swap ~/Applications, fix the launcher entries, verify.
install-linux:
	@./scripts/install-linux-local.sh
