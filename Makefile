# $Id$


include vsn.mk
VSN = $(IDX-TSUNAMI_VSN)
TSUNAMIPATH = .
TARDIR = idx-tsunami-$(VSN)
PA = -pa ./ebin -pa ./src -pa . -pa ./system -pa ../ebin -pa .. -pa ../system -pa ../src

prefix = /usr/local/idx-tsunami

# export ERLC_EMULATOR to fix a bug in R9B with native compilation
ERLC_EMULATOR=/usr/bin/erl
export ERLC_EMULATOR
ERL_COMPILER_OPTIONS="[warn_unused_vars]"
export ERL_COMPILER_OPTIONS
OPTIONS:=+debug_info
#OPTIONS:=+native +\{hipe,\[o3\]\}
#OPTIONS:=+export_all
#OPTIONS:=
INC = ./include
ERLC = erlc $(OPTIONS) -I $(INC)
OUTDIR = ebin
ALLERLS:= $(wildcard src/*.erl)
ALLBEAMS:=$(patsubst src/%.erl,$(OUTDIR)/%.beam, $(ALLERLS))

all:	tsunami.boot tsunami_controller.boot tsunami_recorder.boot

show:
	@echo "sources: $(ALLERLS)"
	@echo "beam: $(ALLBEAMS)"

tarball: 
	mkdir -p $(TARDIR)
	tar zcf tmp.tgz src/*.erl src/*.src include/*.hrl doc/*.txt doc/*.fig doc/*.png LISEZMOI README CONTRIBUTORS COPYING  idx-tsunamirc TODO Makefile vsn.mk src/analyse_msg.pl.src FAQ CHANGES
	tar -C $(TARDIR) -zxf tmp.tgz
	mkdir $(TARDIR)/ebin
	tar zvcf  idx-tsunami-$(VSN).tar.gz $(TARDIR)
	rm -fr $(TARDIR)
	rm -fr tmp.tgz


clean:
	rm -f $(ALLBEAMS) tsunami.boot tsunami.script ebin/tsunami*.app ebin/tsunami*.rel  ebin/analyse_msg.pl

tsunami.boot:	 ebin $(ALLBEAMS) $(UTILS) src/tsunami.rel.src src/tsunami.app.src src/analyse_msg.pl.src  Makefile
	sed -e 's@%VSN%@$(VSN)@;s@%prefix%@$(prefix)@' ./src/tsunami.app.src > ./ebin/tsunami.app
	sed -e 's;%VSN%;$(VSN);' ./src/tsunami.rel.src > ./ebin/tsunami.rel
	sed -e 's;%VSN%;$(VSN);' ./src/analyse_msg.pl.src > ./ebin/analyse_msg.pl
	erl -noshell $(PA) ./src -s make_boot make_boot tsunami

tsunami_controller.boot:	 ebin $(ALLBEAMS) $(UTILS) src/tsunami_controller.rel.src src/tsunami_controller.app.src Makefile idx-tsunami.sh
	sed -e 's@%VSN%@$(VSN)@;s@%prefix%@$(prefix)@' ./src/tsunami_controller.app.src > ./ebin/tsunami_controller.app
	sed -e 's;%VSN%;$(VSN);' ./src/tsunami_controller.rel.src > ./ebin/tsunami_controller.rel
	erl -noshell $(PA) ./src -s make_boot make_boot tsunami_controller
	sed -e 's@%VSN%@$(VSN)@;s@%prefix%@$(prefix)@g' ./idx-tsunami.sh > ./ebin/idx-tsunami

tsunami_recorder.boot:	 ebin $(ALLBEAMS) $(UTILS) src/tsunami_recorder.rel.src src/tsunami_recorder.app.src Makefile idx-tsunami.sh
	sed -e 's@%VSN%@$(VSN)@;s@%prefix%@$(prefix)@' ./src/tsunami_recorder.app.src > ./ebin/tsunami_recorder.app
	sed -e 's;%VSN%;$(VSN);' ./src/tsunami_recorder.rel.src > ./ebin/tsunami_recorder.rel
	erl -noshell $(PA) ./src -s make_boot make_boot tsunami_recorder

ebin:
	mkdir ebin

$(OUTDIR)/%.beam: ebin/%.erl
	$(ERLC) -o $(OUTDIR) $<

$(OUTDIR)/%.beam: src/%.erl include/*.hrl
	$(ERLC) -o $(OUTDIR) $<

install: tsunami.boot tsunami_controller.boot tsunami_recorder.boot
	mkdir -p $(prefix)
	mkdir -p $(prefix)/bin
	mkdir -p $(prefix)/log
	mkdir -p $(prefix)/etc
	mkdir -p $(prefix)/erlang/tsunami-$(VSN)/src
	install -m 0644 tsunami.boot $(prefix)/bin
	install -m 0644 tsunami_controller.boot $(prefix)/bin
	install -m 0644 tsunami_recorder.boot $(prefix)/bin
	install -m 0644 idx-tsunami.xml $(prefix)/etc/idx-tsunami_default.xml
	install ebin/analyse_msg.pl ${prefix}/bin
	install ebin/idx-tsunami ${prefix}/bin
	mkdir -p $(prefix)
	mkdir -p $(prefix)/erlang
	mkdir -p $(prefix)/erlang/tsunami-$(VSN)
	mkdir -p $(prefix)/erlang/tsunami-$(VSN)/ebin
	install $(ALLBEAMS) $(prefix)/erlang/tsunami-$(VSN)/ebin
	install ebin/*.app $(prefix)/erlang/tsunami-$(VSN)/ebin
	install src/*.erl $(prefix)/erlang/tsunami-$(VSN)/src

%:%.sh
# Override makefile default implicit rule
