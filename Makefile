# Only if the caller hasn't already chosen a toolchain (`$DEVELOPER_DIR`, or
# `sudo xcode-select -s`) and the standard path actually exists — exporting a
# path that isn't there breaks every target with `xcrun: missing DEVELOPER_DIR`
# on a machine that only has the Command Line Tools installed.
ifeq (,$(DEVELOPER_DIR))
ifneq (,$(wildcard /Applications/Xcode.app/Contents/Developer))
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif
endif

PROJECT := Siggy.xcodeproj
SCHEME  := Siggy
RESOLVED_PACKAGES := $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
ARCH    ?= $(shell uname -m)
DEST    ?= platform=macOS,arch=$(ARCH)

# Debug signs itself when the maintainer's Developer ID certificate isn't in
# the keychain, which is every machine but the maintainer's — so a contributor
# can `make build`/`make test`/`make run` with no Apple account at all, per
# CONTRIBUTING.md. On the maintainer's own machine this is empty and changes
# nothing: project.yml's stable identity is what keeps a keychain "Always
# Allow" grant alive across rebuilds, and forcing another one there would throw
# that away and bring the prompt back on every `make run`.
#
# `grep`, not `grep -c`: `-c` prints "0" rather than nothing when it matches
# nothing, so `ifeq (,...)` was never true and a machine *without* the
# certificate fell through to signing with an identity it does not have —
# "Signing for Siggy requires a development team", on every target.
HAS_DEVELOPER_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application")

# A personal "Apple Development" certificate, where there is one, is preferred
# over ad-hoc for exactly the reason the maintainer's identity is: it is
# stable, so a keychain "Always Allow" grant survives the next rebuild, and
# working on the credential-reading paths does not mean re-granting after every
# build. Read its team from a valid signing identity: a certificate can remain
# in the keychain without its private key, and choosing it would fail the
# build. With nothing parsed, ad-hoc is the fallback and needs no Apple account.
# The team is the certificate subject's OU, not the bracketed value in the CN
# — that bracketed value is the developer's own id, which only coincides with
# the Team ID on some accounts. On a personal team it does not, so reading it
# had Xcode look for a certificate of a team that does not exist.
DEV_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null \
	| sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
DEV_TEAM := $(if $(DEV_IDENTITY),$(shell security find-certificate -c "$(DEV_IDENTITY)" -p 2>/dev/null \
	| openssl x509 -noout -subject -nameopt sep_multiline 2>/dev/null \
	| sed -n 's/^ *OU=\([A-Z0-9]*\)$$/\1/p' | head -1))

ifeq (,$(HAS_DEVELOPER_ID))
ifeq (,$(DEV_TEAM))
DEV_SIGN := CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic
else
DEV_SIGN := CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual \
	DEVELOPMENT_TEAM="$(DEV_TEAM)" PROVISIONING_PROFILE_SPECIFIER=""
endif
endif

.PHONY: gen build test test-ci verify-deps run install clean

gen:
	xcodegen generate
	mkdir -p $(dir $(RESOLVED_PACKAGES))
	cp Package.resolved $(RESOLVED_PACKAGES)

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug $(DEV_SIGN) build

test: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug $(DEV_SIGN) test

# Continuous integration: no Developer ID identity exists on a CI runner, and
# unit tests need none — override the manual signing with plain unsigned
# builds rather than asking every contributor to hold a certificate.
test-ci: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug test \
		CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

verify-deps:
	rm -rf $(PROJECT)
	$(MAKE) gen
	xcodebuild -resolvePackageDependencies -project $(PROJECT) -scheme $(SCHEME)
	@diff -u Package.resolved $(RESOLVED_PACKAGES) || { \
		echo "SwiftPM resolution drifted; intentionally update Package.resolved and commit it if dependencies changed."; \
		exit 1; \
	}

run: build
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/Siggy.app; \
	pkill -x Siggy 2>/dev/null; sleep 0.5; \
	open "$$APP"

# Build a Release .app, sign it with whatever identity is available (Developer
# ID, Apple Development, or ad-hoc — the same auto-detection as `DEV_SIGN`),
# and copy it to /Applications. For a contributor who wants a permanent copy
# without the notarized release path. Gatekeeper may ask for a one-time
# right-click → Open on the first launch when the build is not Developer ID
# signed.
install: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Release $(DEV_SIGN) build
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Release -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/Siggy.app; \
	pkill -x Siggy || true; \
	cp -R "$$APP" /Applications/; \
	open /Applications/Siggy.app

clean:
	rm -rf build DerivedData $(PROJECT)

# --- Release -----------------------------------------------------------------
# The path to a notarized .dmg. Run `make release` for the whole thing, or the
# steps one at a time while something is going wrong.
#
# Needs your own Developer ID certificate and Team ID:
#
#   make release TEAM_ID=<your-team-id>
#
# One-time setup, which you have to run yourself because it takes a password:
#
#   xcrun notarytool store-credentials Siggy \
#       --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>
#
# The app-specific password comes from appleid.apple.com → Sign-In and Security
# → App-Specific Passwords. Not your Apple ID password.

RELEASE_DIR := build/release
APP_NAME    := Siggy
# The label of the stored notarytool credential in the login keychain.
NOTARY_PROFILE ?= Siggy
TEAM_ID ?=
DMG := $(RELEASE_DIR)/$(APP_NAME).dmg

.PHONY: archive dmg notarize release verify-release publish

# Release configuration, exported with the Developer ID identity. `xcodebuild
# archive` + `-exportArchive` rather than a plain build: it re-signs the bundle
# as a distributable, which a Debug build is not.
archive: gen
	@test -n "$(TEAM_ID)" || (echo "Set TEAM_ID to your Apple Developer Team ID" && exit 1)
	rm -rf $(RELEASE_DIR)
	mkdir -p $(RELEASE_DIR)
	@# Spotlight indexes build output as installed applications, so every
	@# release leaves extra "Siggy" entries in app search next to the
	@# real one in /Applications. This stops the whole tree being indexed.
	@touch build/.metadata_never_index
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Release -archivePath $(RELEASE_DIR)/$(APP_NAME).xcarchive \
		CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM="$(TEAM_ID)" archive
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>method</key><string>developer-id</string>' \
		'<key>teamID</key><string>$(TEAM_ID)</string>' \
		'<key>signingStyle</key><string>manual</string>' \
		'<key>signingCertificate</key><string>Developer ID Application</string>' \
		'</dict></plist>' > $(RELEASE_DIR)/ExportOptions.plist
	xcodebuild -exportArchive \
		-archivePath $(RELEASE_DIR)/$(APP_NAME).xcarchive \
		-exportOptionsPlist $(RELEASE_DIR)/ExportOptions.plist \
		-exportPath $(RELEASE_DIR)

# A plain drag-to-Applications disk image. `create-dmg` writes it read-only and
# compressed, which is what notarization expects.
dmg: archive
	@command -v create-dmg >/dev/null || (echo "brew install create-dmg" && exit 1)
	rm -f $(DMG)
	rm -rf $(RELEASE_DIR)/stage
	mkdir -p $(RELEASE_DIR)/stage
	cp -R $(RELEASE_DIR)/$(APP_NAME).app $(RELEASE_DIR)/stage/
	create-dmg \
		--volname "$(APP_NAME)" \
		--window-pos 400 300 \
		--window-size 604 404 \
		--icon-size 128 \
		--icon "$(APP_NAME).app" 150 200 \
		--app-drop-link 450 200 \
		--hide-extension "$(APP_NAME).app" \
		--background "docs/design/dmg-background.png" \
		$(DMG) $(RELEASE_DIR)/stage
	codesign --force --sign "Developer ID Application" --timestamp $(DMG)
	@# The app is inside the dmg now. Leaving the loose copies around is how
	@# three spare "Siggy" entries end up in Spotlight; everything
	@# downstream (notarize, verify) works from the dmg alone.
	rm -rf $(RELEASE_DIR)/stage $(RELEASE_DIR)/$(APP_NAME).app

# Submits and waits. `--wait` blocks until Apple answers, which is usually a
# couple of minutes; on rejection, the log says which binary failed and why.
notarize: dmg
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)

release: notarize verify-release
	@echo "Notarized: $(DMG)"

# Attaches the notarized dmg to a GitHub release. There is no update feed:
# Siggy never updates itself, so a new version is always a manual install.
#
# Deliberately not part of `release`: every other target here is local, and
# this one writes to the remote. Run it once `make release` has finished and
# the tag exists.
VERSION := $(shell awk -F'"' '/MARKETING_VERSION:/ {print $$2}' project.yml)
TAG     ?= v$(VERSION)

publish: $(DMG)
	@test -n "$(VERSION)" || (echo "No MARKETING_VERSION in project.yml" && exit 1)
	@# --clobber so re-running after a rebuild replaces the asset instead of
	@# failing on the name already being taken.
	gh release upload $(TAG) $(DMG) --clobber
	@echo "Attached $(DMG) to $(TAG)."

# What Gatekeeper on a customer's Mac will check. `spctl` accepting the app is
# the actual proof that the download will open without a right-click.
verify-release:
	xcrun stapler validate $(DMG)
	hdiutil attach $(DMG) -nobrowse -mountpoint $(RELEASE_DIR)/mnt
	codesign --verify --deep --strict --verbose=2 $(RELEASE_DIR)/mnt/$(APP_NAME).app
	spctl --assess --type execute --verbose=4 $(RELEASE_DIR)/mnt/$(APP_NAME).app
	hdiutil detach $(RELEASE_DIR)/mnt
# --- Unsigned builds -----------------------------------------------------------
# Everything above needs the maintainer's Developer ID certificate and the
# stored notarization credentials, so it can only ever run on one machine. This
# produces the same Release-configuration app from a GitHub runner or a fork,
# ad-hoc signed, so that trying a build no longer means installing Xcode and
# compiling it — `make dmg-ci`, or the Package workflow's artifact.
#
# Ad-hoc rather than unsigned: an arm64 binary carrying no signature at all will
# not execute. The download is not notarized, so macOS quarantines it until the
# user clears the flag by hand.
CI_DIR     := build/ci
CI_DERIVED := $(CI_DIR)/DerivedData
CI_APP     := $(CI_DERIVED)/Build/Products/Release/$(APP_NAME).app
CI_DMG     := $(CI_DIR)/$(APP_NAME)-$(VERSION)-unsigned.dmg
# Absolute: xcodebuild resolves CODE_SIGN_ENTITLEMENTS against the project
# directory, not the working directory.
CI_ENTITLEMENTS := $(CURDIR)/$(CI_DIR)/adhoc.entitlements

.PHONY: build-ci dmg-ci

# `build`, not `archive` + `-exportArchive`: exporting reads ExportOptions.plist
# and re-signs for distribution, which needs the Developer ID identity that is
# the one thing a runner does not have.
build-ci: gen
	rm -rf $(CI_DIR)
	mkdir -p $(CI_DIR)
	@# Same reason as `archive`: without this, every build leaves spare
	@# "Siggy" entries in Spotlight next to the installed app.
	@touch build/.metadata_never_index
	@# An explicit, near-empty entitlements file, so the re-sign below has
	@# something to replace Xcode's defaults with.
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'</dict></plist>' > $(CI_ENTITLEMENTS)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Release -derivedDataPath $(CI_DERIVED) \
		CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="" \
		CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
		CODE_SIGN_ENTITLEMENTS="$(CI_ENTITLEMENTS)" \
		build
	@# Xcode adds `com.apple.security.get-task-allow` to any non-distribution
	@# signature, which lets another process attach to the app. Not something
	@# to hand to a stranger who downloaded a build, so the signature is
	@# replaced here without it.
	codesign --force --options runtime --entitlements $(CI_ENTITLEMENTS) \
		--sign - $(CI_APP)
	@# Proof rather than assumption, because this is invisible until someone
	@# thinks to look: fail the build if the entitlement came back.
	@codesign -d --entitlements - --xml $(CI_APP) 2>/dev/null \
		| grep -q 'get-task-allow' \
		&& { echo "get-task-allow survived the re-sign"; exit 1; } || true

# A disk image for the same reason releases ship one, plus one specific to CI:
# GitHub's artifact upload zips whatever it is given and drops symlinks and the
# executable bit on the way, which takes an .app bundle apart. A dmg arrives as
# a single opaque file instead.
dmg-ci: build-ci
	@command -v create-dmg >/dev/null || (echo "brew install create-dmg" && exit 1)
	rm -rf $(CI_DIR)/stage
	mkdir -p $(CI_DIR)/stage
	cp -R $(CI_APP) $(CI_DIR)/stage/
	for i in 1 2 3; do \
		rm -f $(CI_DMG); \
		rm -f $(CI_DIR)/rw.*.dmg; \
		hdiutil detach "/Volumes/$(APP_NAME)" -force 2>/dev/null || true; \
		create-dmg \
			--volname "$(APP_NAME)" \
			--window-pos 400 300 \
			--window-size 604 404 \
			--icon-size 128 \
			--icon "$(APP_NAME).app" 150 200 \
			--app-drop-link 450 200 \
			--hide-extension "$(APP_NAME).app" \
			--background "docs/design/dmg-background.png" \
			--skip-jenkins \
			$(CI_DMG) $(CI_DIR)/stage && break || sleep 2; \
	done
	rm -rf $(CI_DIR)/stage
	@echo "Unsigned disk image: $(CI_DMG)"
