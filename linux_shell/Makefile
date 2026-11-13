ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

orb-desktop: $(wildcard $(ROOT_DIR)/c/*.c $(ROOT_DIR)/c/*.h $(ROOT_DIR)/lean/LeanUI/**/*.lean $(ROOT_DIR)/lean/OrbDesktop/*.lean $(ROOT_DIR)/lean/lakefile.lean)
	"$(ROOT_DIR)/scripts/build_orb_bins.sh" --out-dir "$(CURDIR)" --only orb-desktop

test: orb-desktop
	./orb-desktop --self-test

clean:
	rm -f orb-desktop

.PHONY: test clean
