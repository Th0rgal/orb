CC ?= $(shell command -v clang >/dev/null 2>&1 && echo clang || echo cc)
PKG_CONFIG ?= pkg-config
WEBKIT_PKGS := gtk+-3.0 webkit2gtk-4.1

HAS_WEBKIT := $(shell $(PKG_CONFIG) --exists $(WEBKIT_PKGS) 2>/dev/null && echo 1 || echo 0)
UNAME_S := $(shell uname -s)

CFLAGS := -std=gnu11 -O2 -Wall -Wextra -Werror -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE
LDFLAGS :=
ifeq ($(UNAME_S),Linux)
  LDFLAGS += -pie -Wl,-z,relro,-z,now
endif

ifeq ($(HAS_WEBKIT),1)
  CFLAGS += -DORB_HAS_WEBKITGTK $(shell $(PKG_CONFIG) --cflags $(WEBKIT_PKGS))
  LDFLAGS += $(shell $(PKG_CONFIG) --libs $(WEBKIT_PKGS))
endif

orb-desktop: main.c gtk_chrome.c gtk_icons.c gtk_chrome.h gtk_icons.h
	$(CC) $(CFLAGS) -o $@ main.c gtk_chrome.c gtk_icons.c $(LDFLAGS)

test: orb-desktop
	./orb-desktop --self-test

clean:
	rm -f orb-desktop

.PHONY: test clean
