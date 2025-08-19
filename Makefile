PREFIX?=/usr/local
BINDIR?=$(PREFIX)/bin
MANDIR?=$(PREFIX)/share/man
SCDOC=scdoc
.DEFAULT_GOAL=all

c3l.1: c3l.1.scd
	$(SCDOC) < $< > $@

all: c3l c3l.1

test: test.sh
	./test.sh

clean:
	rm c3l.1

install: all
	mkdir -p $(BINDIR) $(MANDIR)/man1
	install -m755 c3l $(BINDIR)/c3l
	install -m644 c3l.1 $(MANDIR)/man1/c3l.1

uninstall:
	rm -f $(BINDIR)/c3l
	rm -f $(MANDIR)/man1/c3l.1

.PHONY: all clean install uninstall test
