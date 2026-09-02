# Standard prefixes and fallbacks
XDG_DATA_HOME   ?= $(HOME)/.local/share
XDG_CONFIG_HOME ?= $(HOME)/.config
XDG_STATE_HOME  ?= $(HOME)/.local/state

LOCAL_PREFIX	:= $(HOME)/.local
DEFAULT_PREFIX  := /usr/local

# Dynamic prefix selection 
ifeq ($(DESTDIR),)
	WRITABLE := $(shell test -w $(DEFAULT_PREFIX) 2>/dev/null && echo "yes" || (test -w $$(dirname $(DEFAULT_PREFIX)) 2>/dev/null && echo "yes") || echo "no")
	ifeq ($(WRITABLE),no)
		# User / non-root install -> XDG (immutable FHS directories)
		PREFIX		?= $(LOCAL_PREFIX)
		datadir		?= $(XDG_DATA_HOME)
		sysconfdir  ?= $(XDG_CONFIG_HOME)/wg-vpn
	else
		# System Install (able to edit system directories)
		PREFIX		?= $(DEFAULT_PREFIX)
		datadir		?= $(PREFIX)/share
		sysconfdir  ?= /etc/wg-vpn
	endif
else
	# Upstream packaging environment context
	PREFIX		?= /usr
	datadir		?= $(PREFIX)/share
	sysconfdir  ?= /etc/wg-vpn
endif

bindir		 = $(PREFIX)/bin
applibdir	 = $(datadir)/wg-vpn

.PHONY: all install uninstall check test lint clean

all:
	@echo "wg-vpn is a shell script and does not need to be compiled."
	@echo " make install"
	@echo " make check - lints and tests like CI"
	@echo " make uninstall"
	@echo ""
	@echo "Current Configuration:"
	@echo " PREFIX      = $(PREFIX)"
	@echo " DESTDIR     = $(DESTDIR)"
	@echo " sysconfdir  = $(sysconfdir)"
	@echo " applibdir   = $(applibdir)"

install:
	@echo "Installing wg-vpn to $(DESTDIR)$(PREFIX)..."
	install -d "$(DESTDIR)$(bindir)"
	install -d "$(DESTDIR)$(applibdir)"

	# Install lib files to lib dir
	if [ -d lib ]; then \
		cp -RPp lib/. "$(DESTDIR)$(applibdir)"; \
		find "$(DESTDIR)$(applibdir)" -type d -exec chmod 755 {} +; \
		find "$(DESTDIR)$(applibdir)" -type f -name '*.sh' -exec chmod 644 {} +; \
	fi

	# Inject path constraints for LIB_DIR into installed entrypoint
	sed -e 's%@LIBDIR@%$(applibdir)%g' wg-vpn > wg-vpn.tmp

	# Install main executable to bin dir
	install -m 755 wg-vpn.tmp "$(DESTDIR)$(bindir)/wg-vpn"
	rm -f wg-vpn.tmp

	@echo "Note: Config will be created on first run in $(sysconfdir)"
	@echo "		 (or run 'wg-vpn init' to initialize an empty config)"
	@echo "Installation complete."

uninstall:
	@echo "Uninstalling wg-vpn..."
	rm -f "$(DESTDIR)$(bindir)/wg-vpn"
	[ -n "$(applibdir)" ] && [ "$(applibdir)" != "/" ] && rm -rf "$(DESTDIR)$(applibdir)"
	@echo "Note: Configuration and state files left untouched."
	@echo "To fully remove wg-vpn data:"
	@echo "  rm -rf ~/.config/wg-vpn ~/.local/state/wg-vpn"
	@echo "Uninstallation complete."

lint:
	shellcheck -x -s bash --source-path=SCRIPTDIR wg-vpn
	if [ -d lib ]; then \
		find lib -name '*.sh' -print0 | xargs -0 shellcheck -x -s bash --source-path=SCRIPTDIR; \
		shfmt -l -d -i 4 wg-vpn lib/; \
	else \
		shfmt -l -d -i 4 wg-vpn; \
	fi

test:
	bats --tap test/

check: lint test

clean:
	rm -f wg-vpn.tmp
	# rm -rf /tmp/test-install-*
