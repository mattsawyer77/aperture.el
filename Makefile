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
# Written by `make deps'; appends, so it never fights local.mk.
-include .deps.mk

# load-prefer-newer everywhere: a stale .elc left by `make compile' otherwise
# shadows the source, and the failure looks like a missing function.
NEWER := --eval '(setq load-prefer-newer t)'

BATCH := $(EMACS) -Q --batch $(NEWER) -L . -L test $(DEPS)

SRCS := aperture.el aperture-previewers.el aperture-vertico.el aperture-consult.el \
        aperture-child-frame.el

.PHONY: all check deps compile test lint package-lint clean try try-child-frame spike

all: compile test

# What CI runs, in one target, so the build cannot drift from the build.
check: compile test lint package-lint

# Installs into .deps/ and writes .deps.mk.  Needs the network.
deps:
	@$(EMACS) -Q --batch -l dev/ci-deps.el

# `byte-compile-error-on-warn' because section 6 promises a clean compile, and
# `batch-byte-compile' exits 0 on warnings, so without this CI would not
# notice one.
compile:
	@$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SRCS)

# The core deliberately has no load-time dependency on vertico or consult, so
# the test suite runs with no DEPS at all.  Keep it that way.
test:
	@$(EMACS) -Q --batch $(NEWER) -L . -L test -l ert -l test/aperture-test.el \
	  -f ert-run-tests-batch-and-exit

# One line on purpose: a backslash continuation inside the recipe is passed
# through to Emacs as a literal `\' and the form fails to read.
lint:
	@$(BATCH) --eval '(progn (require (quote checkdoc)) (dolist (f (list $(patsubst %,"%",$(SRCS)))) (checkdoc-file f)))'

# aperture is a multi-file package: without `package-lint-main-file' every file
# is linted as though it were its own package, and the prefix and dependency
# checks all report against the wrong name.  Needs `make deps' (package-lint
# itself, and the archive contents it validates dependencies against).
package-lint:
	@$(BATCH) --eval '(progn (require (quote package)) (setq package-user-dir (expand-file-name ".deps")) (package-initialize))' \
	  -l package-lint --eval '(setq package-lint-main-file "aperture.el")' \
	  -f package-lint-batch-and-exit $(SRCS)

# Interactive smoke test in a clean Emacs.  Needs DEPS.  $(NEWER) matters most
# here: this is where a stale .elc would be hardest to spot, since the symptom
# is a preview behaving like an older revision rather than an error.
try:
	@$(EMACS) -nw -Q $(NEWER) -L . $(DEPS) -l dev/try.el

# `try' for the child-frame layout (docs/DESIGN.md section 3.4b).  GUI on
# purpose -- no -nw -- because child frames need a display.
try-child-frame:
	@APERTURE_DISPLAY=child-frame $(EMACS) -Q $(NEWER) -L . $(DEPS) -l dev/try.el

# Child-frame layout spike (docs/DESIGN.md section 3.4b).  GUI Emacs on
# purpose: child frames need a display, which is also why nothing here can run
# in CI.  Unlike `try', this must NOT use -nw.
spike:
	@$(EMACS) -Q $(NEWER) -L . $(DEPS) -l dev/spike-posframe.el

clean:
	@rm -f *.elc test/*.elc
