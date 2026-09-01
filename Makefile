PREFIX ?= /usr/local
DESTDIR ?=

bindir = $(PREFIX)/bin
libdir = $(PREFIX)/lib
applibdir = $(libdir)/wg-vpn

.PHONY: all install uninstall check test lint clean

all:
	@echo "wg-vpn is a shell script and does not need to be compiled."
	@echo " make install"
	@echo " make check #lint +plus tests like CI"
	@echo " make uninstall"

install:
	@echo "Installing wg-vpn..."
	install -d "$(DESTDIR)$(bindir)"
	install -d "$(DESTDIR)$(applibdir)"

	# Install lib files to lib dir
	cp -a lib/. "$(DESTDIR)$(applibdir)"
	find "$(DESTDIR)$(applibdir)" -type d -exec chmod 755 {} +
	find "$(DESTDIR)$(applibdir)" -type f -name '*.sh' -exec chmod 644 {} +

	# Install main executable to bin dir
	sed -E 's%^[[:space:]]*LIB_DIR=.*%LIB_DIR="$(applibdir)"%' wg-vpn > wg-vpn.tmp
	install -m 755 wg-vpn.tmp "$(DESTDIR)$(bindir)/wg-vpn"
	rm -f wg-vpn.tmp

	@echo "Installation complete."

uninstall:
	@echo "Uninstalling wg-vpn..."
	rm -f "$(DESTDIR)$(bindir)/wg-vpn"
	[ -n "$(applibdir)" ] && rm -rf "$(DESTDIR)$(applibdir)"
	@echo "Uninstallation complete."

lint:
	shellcheck -x -s bash --source-path=SCRIPTDIR wg-vpn
	find lib -name '*.sh' -print0 | xargs -0 shellcheck -x -s bash --source-path=SCRIPTDIR
	shfmt -l -d -i 4 -ci wg-vpn lib/

test:
	bats --tap test/

check: lint test

clean:
	rm -f wg-vpn.tmp
	# rm -rf /tmp/test-install-*
