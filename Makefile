# Build and test ud18.
#
#   make        -- build bin/ud18 (embeds the SBCL core, ~50 MB)
#   make test   -- run the portable protocol suite (no BLE stack needed)
#   make clean  -- remove bin/ and this tree's fasl cache
#
# The binary embeds the SBCL core, so build it on the platform you will run
# it on. Offline subcommands (decode) work anywhere; everything that touches
# an adapter is Linux-only.

SBCL       ?= sbcl
SBCL_FLAGS := --non-interactive --no-userinit --no-sysinit

# Where the shared `ble\' library lives: its own repository, a sibling
# checkout rather than a vendored dependency because ocicl has nothing to
# fetch -- ble is ours. Override if yours is elsewhere.
BLE_DIR ?= ../ble

# Hermetic source registry: this tree, its vendored ocicl/ deps, and exactly
# one directory of the sibling checkout -- :directory, not :tree, so we pick
# up ble.asd without also inheriting ble's own vendored dependencies and
# ending up with two copies of cffi on the registry. Nothing else the machine
# happens to have lying around gets in; a missing dependency should fail
# loudly here rather than silently resolve to a neighbour's copy.
BOOT := --eval "(require :asdf)" \
        --eval "(asdf:initialize-source-registry \`(:source-registry (:tree ,(truename \"./\")) (:directory ,(truename \"$(BLE_DIR)/\")) :ignore-inherited-configuration))"

SRC := $(wildcard src/*.lisp) $(wildcard cli/*.lisp) ud18.asd \
       $(wildcard $(BLE_DIR)/src/*.lisp) $(BLE_DIR)/ble.asd
BIN := bin/ud18

.PHONY: all test clean help
.DEFAULT_GOAL := all

all: $(BIN)

$(BIN): $(SRC)
	@mkdir -p bin
	$(SBCL) $(SBCL_FLAGS) $(BOOT) --eval "(asdf:make :ud18/cli)" --eval "(sb-ext:exit)"
	@ls -lh $(BIN)

test:
	$(SBCL) $(SBCL_FLAGS) $(BOOT) \
	  --eval "(asdf:test-system :ud18/core)" --eval "(sb-ext:exit)"

clean:
	rm -rf bin
	rm -rf $(HOME)/.cache/common-lisp/*/$(subst /,_,$(CURDIR))

help:
	@grep -E '^#   ' Makefile | sed 's/^#   //'
