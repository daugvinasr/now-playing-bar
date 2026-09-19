PREFIX ?= /usr/local
SWIFTC ?= swiftc
SWIFTFLAGS ?= -O

.PHONY: all clean install

all: now-playing-bar

now-playing-bar: main.swift
	$(SWIFTC) $(SWIFTFLAGS) main.swift -o now-playing-bar

clean:
	rm -f now-playing-bar

install: now-playing-bar
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 now-playing-bar $(DESTDIR)$(PREFIX)/bin/now-playing-bar
