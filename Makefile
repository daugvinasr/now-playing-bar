PREFIX ?= /usr/local
SWIFTC ?= swiftc
SWIFTFLAGS ?= -O
COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

.PHONY: all clean install FORCE

all: now-playing-bar

now-playing-bar: main.swift version.swift
	$(SWIFTC) $(SWIFTFLAGS) main.swift version.swift -o now-playing-bar

# Rewritten only when the commit changes, so it doesn't force a rebuild.
version.swift: FORCE
	@printf 'let buildCommit = "%s"\n' "$(COMMIT)" > $@.tmp; cmp -s $@.tmp $@ || mv $@.tmp $@; rm -f $@.tmp

FORCE:

clean:
	rm -f now-playing-bar version.swift

install: now-playing-bar
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 now-playing-bar $(DESTDIR)$(PREFIX)/bin/now-playing-bar
