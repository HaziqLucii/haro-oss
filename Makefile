.PHONY: publish linux

# Push a squashed public snapshot to HaziqLucii/haro-oss (see scripts/publish-oss.sh).
publish:
	@./scripts/publish-oss.sh

# Linux release: tarball + AppImage in dist/ (see scripts/build-linux.sh).
linux:
	@./scripts/build-linux.sh
