CC ?= cc
PKG_CONFIG ?= pkg-config
WEBKIT_PKGS := gtk+-3.0 webkit2gtk-4.1

HAS_WEBKIT := $(shell $(PKG_CONFIG) --exists $(WEBKIT_PKGS) 2>/dev/null && echo 1 || echo 0)

CFLAGS := -std=gnu11 -O2 -Wall -Wextra -Werror
LDFLAGS :=

ifeq ($(HAS_WEBKIT),1)
  CFLAGS += -DORB_HAS_WEBKITGTK $(shell $(PKG_CONFIG) --cflags $(WEBKIT_PKGS))
  LDFLAGS += $(shell $(PKG_CONFIG) --libs $(WEBKIT_PKGS))
endif

orb-desktop: main.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

test: orb-desktop
	./orb-desktop --self-test

clean:
	rm -f orb-desktop

.PHONY: test clean
