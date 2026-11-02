PREFIX?=/usr/local
BINDIR?=$(PREFIX)/bin
MANDIR?=$(PREFIX)/share/man
C3C?=c3c
SCDOC=scdoc
.DEFAULT_GOAL=all

all: c3l build/c3l

build/c3l: project.json c3l.lock $(wildcard src/*.c3 src/*/*.c3) $(wildcard vendor/*.c3l)
	$(C3C) build c3l

c3l.1: c3l.1.scd
	$(SCDOC) < $< > $@

doc: c3l.1

test:
	./test/run.sh

gitconfig:
	ln -s ../../contrib/pre-commit .git/hooks/pre-commit

clean:
	rm -rf build c3l.1

install: all
	mkdir -p $(BINDIR) $(MANDIR)/man1
	install -m755 c3l $(BINDIR)/c3l
	if [ -f c3l.1 ]; then install -m644 c3l.1 $(MANDIR)/man1/c3l.1; fi

uninstall:
	rm -f $(BINDIR)/c3l
	rm -f $(MANDIR)/man1/c3l.1

.PHONY: all clean doc gitconfig install uninstall test
