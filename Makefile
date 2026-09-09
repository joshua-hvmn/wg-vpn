# ==================================================================================
# wg-vpn Makefile
# packager friendly, MIT license
# Run `make help` for usage
# ==================================================================================

# Safety rules
.POSIX:
.DELETE_ON_ERROR:

# System tools
SHELL			:= /bin/sh
.SHELLFLAGS		:= -ec
INSTALL			?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 755
INSTALL_DATA	?= $(INSTALL) -m 644
INSTALL_DIR     ?= $(INSTALL) -d -m 755
FIND			?= find
SED				?= sed
RM				?= rm -f
SHFMT			?= shfmt
SHELLCHECK		?= shellcheck
BATS			?= bats

# Standard directory variables
DESTDIR			?=
prefix		    ?= /usr/local
exec_prefix     ?= $(prefix)
bindir		    ?= $(exec_prefix)/bin
datarootdir     ?= $(prefix)/share
datadir			?= $(datarootdir)

# App specific dirs
applibdir	    := $(datadir)/wg-vpn

# Files
TARGET			:= wg-vpn
TMP_TARGET		:= $(TARGET).tmp

# Verbosity
V				?= 0
ifeq ($(V), 1)
	Q :=
else
	Q := @
endif

.PHONY: all help build install uninstall check lint test check clean

all: build ## Build the script (default target)

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf " %-12s %s\n", $$1, $$2 }' $(MAKEFILE_LIST) | sort
	@echo ""
	@echo "Current Configuration:"
	@echo " prefix      = $(prefix)"
	@echo " DESTDIR     = $(DESTDIR)"
	@echo " bindir      = $(bindir)"
	@echo " applibdir   = $(applibdir)"
	@echo ""
	@echo "Override with e.g. 'make install prefix=/usr' or 'make V=1 install'."

build: $(TMP_TARGET) ## Inject install paths into a local copy of the script

$(TMP_TARGET): $(TARGET)
	@printf ' %-8s %s\n' "SED" "$(TARGET) -> $(TMP_TARGET)"
	$(Q)$(SED) -e "s|@LIBDIR@|$(applibdir)|g" $(TARGET) > $(TMP_TARGET)
	$(Q)chmod +x $(TMP_TARGET)

install: build ## Install the script and libraries (respects DESTDIR, prefix)
	@printf ' %-8s %s\n' "DIR" "$(DESTDIR)$(bindir)"
	$(Q)$(INSTALL_DIR) "$(DESTDIR)$(bindir)"
	@printf ' %-8s %s\n' "INSTALL" "$(DESTDIR)$(bindir)/$(TARGET)"
	$(Q)$(INSTALL_PROGRAM) $(TMP_TARGET) "$(DESTDIR)$(bindir)/$(TARGET)"
	@if [ -d lib ]; then \
		printf ' %-8s %s\n' "INSTALL" "$(DESTDIR)$(applibdir)/ (preserving layout)"; \
		$(FIND) lib -type f -name '*.sh' -exec sh -c ' \
			for file; do \
				rel="$${file#lib/}"; \
				dest="$(DESTDIR)$(applibdir)/$$rel"; \
				$(INSTALL_DIR) "$$(dirname "$$dest")"; \
				$(INSTALL_DATA) "$$file" "$$dest"; \
			done \
		' sh {} +; \
	fi

	@echo "Note: Config will be created on first run in ~/.config/wg-vpn"
	@echo "		 (or run 'wg-vpn init' to initialize an empty config)"
	@echo "Installation complete."

uninstall: ## Remove installed system files
	@printf ' %-8s %s\n' "RM" "$(DESTDIR)$(bindir)/$(TARGET)"
	$(Q)$(RM) "$(DESTDIR)$(bindir)/$(TARGET)"
	@if [ -d "$(DESTDIR)$(applibdir)" ]; then \
		printf ' %-8s %s\n' "RM" "$(DESTDIR)$(applibdir)"; \
		rm -rf "$(DESTDIR)$(applibdir)"; \
	fi
	@echo "Note: Configuration and state files left untouched."
	@echo "To fully remove wg-vpn data:"
	@echo "  rm -rf ~/.config/wg-vpn ~/.local/state/wg-vpn"
	@echo "Uninstallation complete."

lint: ## Run shellcheck and shfmt over the script and libraries
	@command -v $(SHELLCHECK) >/dev/null 2>&1 || { echo "error: shellcheck not found in PATH." >&2; exit 1; }
	@command -v $(SHFMT) >/dev/null 2>&1 || { echo "error: shfmt not found in PATH." >&2; exit 1; }
	@printf ' %-8s %s\n' "LINT" " Running shellcheck..."
	$(Q)$(SHELLCHECK) -x -s bash --source-path=SCRIPTDIR $(TARGET)
	@if [ -d lib ]; then \
		$(FIND) lib -type f -name '*.sh' -exec sh -c ' \
			for file; do \
				$(SHELLCHECK) -x -s bash --source-path=SCRIPTDIR "$$file" || exit 1; \
			done \
		' sh {} +; \
		printf ' %-8s %s\n' "FMT" " Running shfmt..."; \
		$(FIND) $(TARGET) lib -type f \( -name '*.sh' -o -name '$(TARGET)' \) -exec $(SHFMT) -l -d -i 4 {} +; \
	else \
		$(SHFMT) -l -d -i 4 $(TARGET); \
	fi

test: ## Run the bats test suite
	@command -v $(BATS) >/dev/null 2>&1 || { echo 'error: bats not found in path.' >&2; exit 1; }
	@printf ' %-8s %s\n' "TEST" "Running BATS..."
	$(Q)$(BATS) --tap test/

check: lint test ## Run lint and test together

clean: ## Remove build artifacts
	@printf ' %-8s %s\n' "RM" "$(TMP_TARGET)"
	$(Q)$(RM) $(TMP_TARGET)
