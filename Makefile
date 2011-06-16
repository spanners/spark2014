.PHONY: clean doc install-doc gnat1why gnat2why gnatprove stdlib install-stdlib

ADAINCLUDE=$(shell gnatls -v | grep adainclude)
GNAT_ROOT=$(shell echo $(ADAINCLUDE) | sed -e 's!\(.*\)/lib/gcc/\(.*\)!\1!')
DOC=install/share/doc/gnatprove
TMP=stdlib_tmp

all: gnat2why gnatprove

all-nightly: gnat1why gnatprove stdlib install-stdlib

doc:
	$(MAKE) -C docs/ug latexpdf
	$(MAKE) -C docs/ug html

install-doc:
	mkdir -p $(DOC)/pdf
	cp -p docs/ug/_build/latex/gnatprove_ug.pdf $(DOC)/pdf
	cp -pr docs/ug/_build/html $(DOC)
	$(MAKE) -C docs/ug clean

gnat1why:
	$(MAKE) -C gnat_backends/why gnat1 gnat2why

gnat2why:
	$(MAKE) -C gnat_backends/why

gnatprove:
	$(MAKE) -C gnatprove

stdlib:
	rm -rf $(TMP)
	mkdir -p $(TMP)
	cp Makefile.libprove $(TMP)
	$(MAKE) -C $(TMP) -f Makefile.libprove ROOT=$(GNAT_ROOT) \
           GNAT2WHY=../install/bin/gnat2why

install-stdlib:
	cp $(TMP)/*.ali $(TMP)/*__types_vars_spec.mlw \
           $(TMP)/*__types_vars_body.mlw $(TMP)/*__subp_spec.mlw $(WHYLIB)

clean:
	$(MAKE) -C gnat_backends/why clean
	$(MAKE) -C gnatprove clean
	$(MAKE) -C docs/ug clean
