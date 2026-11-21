FLUTTER_BIN ?= $(if $(wildcard .fvm/flutter_sdk/bin/flutter),$(abspath .fvm/flutter_sdk/bin/flutter),flutter)
DART_BIN ?= $(if $(wildcard .fvm/flutter_sdk/bin/dart),$(abspath .fvm/flutter_sdk/bin/dart),dart)

.PHONY: bootstrap check check-mobile backend mobile preview-mobile gallery-mobile

bootstrap:
	npm ci
	cd packages/game_core && $(DART_BIN) pub get
	cd apps/mobile && $(FLUTTER_BIN) pub get

check:
	npm run check
	$(MAKE) check-mobile

check-mobile:
	$(DART_BIN) format --output=none --set-exit-if-changed packages/game_core packages/game-content/lib apps/mobile/lib apps/mobile/test apps/mobile/integration_test apps/mobile/tool
	cd packages/game_core && $(DART_BIN) analyze --fatal-infos && $(DART_BIN) test
	cd apps/mobile && $(FLUTTER_BIN) analyze --fatal-infos && $(FLUTTER_BIN) test

backend:
	npm run dev:backend

mobile:
	cd apps/mobile && $(FLUTTER_BIN) run

preview-mobile:
	cd apps/mobile && $(FLUTTER_BIN) build web --release --no-web-resources-cdn --pwa-strategy=none
	python3 -m http.server 8716 --bind 127.0.0.1 --directory apps/mobile/build/web

gallery-mobile:
	cd apps/mobile && $(FLUTTER_BIN) run -d web-server --web-hostname 127.0.0.1 --web-port 8717 --dart-define=DESIGN_GALLERY=true
