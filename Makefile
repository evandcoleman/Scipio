#!/usr/bin/xcrun make -f

SCIPIO_TEMPORARY_FOLDER?=/tmp/Scipio.dst
PREFIX?=/usr/local

INTERNAL_PACKAGE=ScipioApp.pkg
OUTPUT_PACKAGE=Scipio.pkg

SCIPIO_EXECUTABLE=./.build/release/scipio
BINARIES_FOLDER=$(PREFIX)/bin

SWIFT_BUILD_FLAGS=--configuration release -Xswiftc -suppress-warnings

SWIFTPM_DISABLE_SANDBOX_SHOULD_BE_FLAGGED:=$(shell test -n "$${HOMEBREW_SDKROOT}" && echo should_be_flagged)
ifeq ($(SWIFTPM_DISABLE_SANDBOX_SHOULD_BE_FLAGGED), should_be_flagged)
SWIFT_BUILD_FLAGS+= --disable-sandbox
endif
SWIFT_STATIC_STDLIB_SHOULD_BE_FLAGGED:=$(shell test -d $$(dirname $$(xcrun --find swift))/../lib/swift_static/macosx && echo should_be_flagged)
ifeq ($(SWIFT_STATIC_STDLIB_SHOULD_BE_FLAGGED), should_be_flagged)
SWIFT_BUILD_FLAGS+= -Xswiftc -static-stdlib
endif

# ZSH_COMMAND · run single command in `zsh` shell, ignoring most `zsh` startup files.
ZSH_COMMAND := ZDOTDIR='/var/empty' zsh -o NO_GLOBAL_RCS -c
# RM_SAFELY · `rm -rf` ensuring first and only parameter is non-null, contains more than whitespace, non-root if resolving absolutely.
RM_SAFELY := $(ZSH_COMMAND) '[[ ! $${1:?} =~ "^[[:space:]]+\$$" ]] && [[ $${1:A} != "/" ]] && [[ $${\#} == "1" ]] && noglob rm -rf $${1:A}' --

VERSION_STRING=$(shell git describe --abbrev=0 --tags)
DISTRIBUTION_PLIST=Source/scipio/Distribution.plist

RM=rm -f
MKDIR=mkdir -p
SUDO=sudo
CP=cp

ifdef DISABLE_SUDO
override SUDO:=
endif

.PHONY: all clean install package test uninstall

all: installables

clean:
	swift package clean

test:
	swift build --build-tests -Xswiftc -suppress-warnings
	swift test --skip-build

installables:
	swift build $(SWIFT_BUILD_FLAGS)

package: installables
	$(MKDIR) "$(SCIPIO_TEMPORARY_FOLDER)$(BINARIES_FOLDER)"
	$(CP) "$(SCIPIO_EXECUTABLE)" "$(SCIPIO_TEMPORARY_FOLDER)$(BINARIES_FOLDER)"
	
	pkgbuild \
		--identifier "net.evancoleman.scipio" \
		--install-location "/" \
		--root "$(SCIPIO_TEMPORARY_FOLDER)" \
		--version "$(VERSION_STRING)" \
		"$(INTERNAL_PACKAGE)"

	productbuild \
	  	--distribution "$(DISTRIBUTION_PLIST)" \
	  	--package-path "$(INTERNAL_PACKAGE)" \
	   	"$(OUTPUT_PACKAGE)"

prefix_install: installables
	$(MKDIR) "$(BINARIES_FOLDER)"
	$(CP) -f "$(SCIPIO_EXECUTABLE)" "$(BINARIES_FOLDER)/"

install: installables
	if [ ! -d "$(BINARIES_FOLDER)" ]; then $(SUDO) $(MKDIR) "$(BINARIES_FOLDER)"; fi
	$(SUDO) $(CP) -f "$(SCIPIO_EXECUTABLE)" "$(BINARIES_FOLDER)"

uninstall:
	$(RM) "$(BINARIES_FOLDER)/scipio"
