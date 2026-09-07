VERSION ?= 0.0.1-dev
PREFIX  ?= /usr/local

ARCH   := $(shell uname -m | sed -e s/x86_64/amd64/ -e s/aarch64/arm64/)
SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo "sha256sum" || echo "shasum -a 256")

.PHONY: build install uninstall dist test integration validation bench \
        fmt fmt-check clippy preflight check run clean

build:
	cargo build --release

install: build
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 target/release/mars $(DESTDIR)$(PREFIX)/bin/mars

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/mars

dist: build
	rm -rf dist && mkdir -p dist
	cp target/release/mars dist/mars
	tar -czf dist/mars_$(VERSION)_linux_$(ARCH).tar.gz -C dist mars -C .. LICENSE README.md
	rm dist/mars
	cd dist && $(SHA256) *.tar.gz > SHA256SUMS

test:
	cargo test --lib

integration: build
	cargo build
	sudo -E ./tests/run-integration.sh

validation: install
	sudo -E ./scripts/run-validation.sh

bench: install
	sudo -E ./scripts/hap-bench.sh

fmt:
	cargo fmt

fmt-check:
	cargo fmt --check

clippy:
	cargo clippy --all-targets -- -D warnings

preflight:
	./scripts/preflight.sh

check: fmt-check clippy test

run: build
	sudo -E target/release/mars --help

clean:
	rm -rf target dist
