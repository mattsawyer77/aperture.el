EMACS ?= emacs

# Dependency load path for compiling and for `make try'.
#
# aperture needs vertico (and optionally consult) on the load path.  Point
# DEPS at wherever your package manager keeps them, e.g.
#
#   make compile DEPS="-L ~/.emacs.d/elpa/vertico-1.7 -L ~/.emacs.d/elpa/consult-1.8"
#
# or put it once in local.mk, which is not tracked:
#
#   DEPS := -L /path/to/vertico -L /path/to/vertico/extensions -L /path/to/consult
DEPS ?=
-include local.mk

# load-prefer-newer everywhere: a stale .elc left by `make compile' otherwise
# shadows the source, and the failure looks like a missing function.
NEWER := --eval '(setq load-prefer-newer t)'

BATCH := $(EMACS) -Q --batch $(NEWER) -L . -L test $(DEPS)

SRCS := aperture.el aperture-previewers.el aperture-vertico.el aperture-consult.el

.PHONY: all compile test lint clean try

all: compile test

compile:
	@$(BATCH) -f batch-byte-compile $(SRCS)

# The core deliberately has no load-time dependency on vertico or consult, so
# the test suite runs with no DEPS at all.  Keep it that way.
test:
	@$(EMACS) -Q --batch $(NEWER) -L . -L test -l ert -l test/aperture-test.el \
	  -f ert-run-tests-batch-and-exit

# One line on purpose: a backslash continuation inside the recipe is passed
# through to Emacs as a literal `\' and the form fails to read.
lint:
	@$(BATCH) --eval '(progn (require (quote checkdoc)) (dolist (f (list $(patsubst %,"%",$(SRCS)))) (checkdoc-file f)))'

# Interactive smoke test in a clean Emacs.  Needs DEPS.
try:
	@$(EMACS) -nw -Q -L . $(DEPS) -l dev/try.el

clean:
	@rm -f *.elc test/*.elc
