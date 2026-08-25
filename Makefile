# Build and test ud18.
#
#   make        -- build bin/ud18 (embeds the SBCL core, ~50 MB)
#   make test   -- run the portable protocol suite (no BLE stack needed)
#   make deploy -- copy this tree to a Linux box with a radio and rebuild
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

# Where the radio is. Overridable: make deploy HOST=pi@other
HOST ?= pi@rpi4
DEST ?= ~/ud18/

SRC := $(wildcard src/*.lisp) $(wildcard cli/*.lisp) ud18.asd \
       $(wildcard $(BLE_DIR)/src/*.lisp) $(BLE_DIR)/ble.asd
BIN := bin/ud18

.PHONY: all test deploy clean help
.DEFAULT_GOAL := all

all: $(BIN)

$(BIN): $(SRC)
	@mkdir -p bin
	$(SBCL) $(SBCL_FLAGS) $(BOOT) --eval "(asdf:make :ud18/cli)" --eval "(sb-ext:exit)"
	@ls -lh $(BIN)

test:
	$(SBCL) $(SBCL_FLAGS) $(BOOT) \
	  --eval "(asdf:test-system :ud18/core)" --eval "(sb-ext:exit)"

# Everything that touches an adapter is Linux-only, so it is developed here
# and run there. Two things make a plain rsync the wrong tool.
#
# The first is the two directories that must survive --delete. ocicl/ holds
# the vendored dependencies the remote restored with `ocicl install', and a
# --delete that includes it costs minutes of rebuilding on a Pi, ironclad
# most of all. captures/ holds recordings, and the recordings are made on the
# Pi -- that is where the radio is -- so a --delete would throw away data
# that exists nowhere else. Both are excluded from the delete pass and synced
# separately, which still delivers the tracked fixture the suite asserts
# against without touching what the Pi has accumulated.
#
# The second is why this target exists at all. rsync -a preserves mtimes, so
# a file edited on a Mac arrives older than the fasl ASDF already built from
# its previous contents, ASDF decides it is current, and the remote silently
# runs the OLD code. That is indistinguishable from a fix that did not work,
# and it cost two rounds of "verified" that had tested nothing.
deploy:
	rsync -a --delete --exclude .git --exclude ocicl --exclude captures \
	      --exclude bin ./ $(HOST):$(DEST)
	rsync -a --exclude .git ./ocicl/ $(HOST):$(DEST)ocicl/
	rsync -a ./captures/ $(HOST):$(DEST)captures/
	@# sudo -n for both caches: running sbcl under `sudo -E' leaves HOME as
	@# the user's, so root-owned fasls land in the user's cache and a plain
	@# rm cannot shift them.
	@# Only ours. Clearing the whole cache throws away the vendored deps too.
	ssh $(HOST) 'sudo -n find ~/.cache/common-lisp /root/.cache/common-lisp \
	               \( -path "*/ud18/src/*" -o -path "*/ud18/cli/*" \
	                  -o -path "*/ud18/tests/*" \) \
	               -delete 2>/dev/null; exit 0'
	@# Verified, not assumed: a cache that silently survives is the whole
	@# failure this target exists to prevent.
	ssh $(HOST) 'test -z "$$(find ~/.cache/common-lisp /root/.cache/common-lisp \
	               -path "*/ud18/src/*" -name "*.fasl" 2>/dev/null | head -1)"' \
	  && echo "==> deployed to $(HOST):$(DEST), stale fasls for ud18 cleared" \
	  || (echo "deploy: remote fasl cache NOT cleared" >&2; exit 1)
	@# `ble' is a separate checkout with its own deploy target; this does not
	@# push it. If you changed both, run `make deploy' there too.

clean:
	rm -rf bin
	rm -rf $(HOME)/.cache/common-lisp/*/$(subst /,_,$(CURDIR))

help:
	@grep -E '^#   ' Makefile | sed 's/^#   //'
