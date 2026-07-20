# Makefile pre OsobnyPomocnik
# --------------------------------------------------
# make          → debug build + .app bundle
# make run      → build + spusti app
# make release  → optimalizovaný build
# make clean    → vymaž .app bundle
# make purge    → vymaž .app + swift build cache

APP = OsobnyPomocnik.app
SCRIPT = build-app.sh

.PHONY: all build run release clean purge

all: build

build:
	@bash $(SCRIPT) debug

run: build
	@echo "🚀 Spúšťam $(APP)…"
	@pkill -x OsobnyPomocnik 2>/dev/null || true
	@sleep 0.3
	@open "$(APP)"

release:
	@bash $(SCRIPT) release

clean:
	@rm -rf $(APP)
	@echo "🗑  $(APP) vymazaný"

purge: clean
	@swift package clean
	@echo "🗑  Swift build cache vymazaný"
