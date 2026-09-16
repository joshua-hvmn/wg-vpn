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

# Test Variables
# Add variables to both to add dirs to the lint test
test_libdir		?= lib
test_testdir	?= test
test_searchdirs := $(strip $(test_libdir) $(test_testdir))

# Verbosity
V				?= 0
ifeq ($(V), 1)
	Q :=
else
	Q := @
endif

.PHONY: all help build install uninstall check lint test test-unit test-integration test-integration-host check clean

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
	@if [ -f VERSION ]; then \
		$(INSTALL_DATA) VERSION "$(DESTDIR)$(applibdir)/VERSION"; \
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
	@if [ -z "$(test_searchdirs)" ]; then \
		echo "error: No search directories defined!" >&2; \
		exit 1; \
	fi
	@for dir in $(test_searchdirs); do \
		[ -d "$$dir" ] || { echo "error: Directory not found!" >&2; exit 1; }; \
	done
	@printf ' %-8s %s\n' "LINT" " Running shellcheck..."
	$(Q)$(SHELLCHECK) -x -s bash --source-path=SCRIPTDIR $(TARGET)
	$(Q)$(FIND) $(test_searchdirs) -type f \( -name '*.sh' -o -name '*.bash' \) \
		-exec $(SHELLCHECK) -x -s bash --source-path=SCRIPTDIR {} +
	@printf ' %-8s %s\n' "FMT" " Running shfmt..."
	$(Q)$(SHFMT) -l -d -i 4 $(TARGET)
	$(Q)$(FIND) $(TARGET) $(test_searchdirs) -type f \( -name '*.sh' -o -name '*.bash' \) \
		-exec $(SHFMT) -l -d -i 4 {} +

test-unit: ## Run the mocked bats test suite
	@command -v $(BATS) >/dev/null 2>&1 || { echo 'error: bats not found in path.' >&2; exit 1; }
	@printf ' %-8s %s\n' "TEST" "Running unit tests..."
	$(Q)$(BATS) --tap test/

test-integration: ## Run the kill-switch test suite in a docker container
	@printf ' %-8s %s\n' "TEST" "Running kill-switch integration tests..."
	$(Q)./test/integration/run.sh $(BATS_ARGS)

test-integration-host: ## DESTRUCTIVE: run the kill-switch test suite on this host (CI runners only, use 'sudo -E')
	@printf ' %-8s %s\n' "TEST" "Running kill-switch integration tests on THIS host..."
	$(Q)if [ -z "$$CI" ]; then \
		echo "refusing: this resets this machine's firewall and CI is not set." >&2; \
		echo "run 'make test-integration' to use the container instead." >&2; \
		exit 1; \
	fi
	$(Q)WPVPN_ALLOW_UFW_RESET=1 $(BATS) --print-output-on-failure \
		test/integration/killswitch.bats $(BATS_ARGS)

test: test-unit test-integration ## Run the full test suite

check: lint test ## Run lint and test together

clean: ## Remove build artifacts
	@printf ' %-8s %s\n' "RM" "$(TMP_TARGET)"
	$(Q)$(RM) $(TMP_TARGET)
