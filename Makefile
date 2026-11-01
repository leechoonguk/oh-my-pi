# oh-my-pi 포크 관리 — 벤치 브랜치(bench/<upstream 태그>)의 빌드·검증·동기화를 한 곳에서.
# 설치판 omp(~/.bun/bin/omp)는 건드리지 않는다. 산출물은 packages/coding-agent/dist/omp 와 루트 dist/omp 심링크다.
# 저장소는 bun ≥ 1.4.4 를 요구한다 — 전역 bun 이 낮으면 `make bun` 으로 저장소 안(.bun-local)에 받는다.
.PHONY: help bun install natives build dist test typecheck smoke version status fetch rebase push clean

BUN_LOCAL  := $(CURDIR)/.bun-local/bin/bun
BUN        := $(if $(wildcard $(BUN_LOCAL)),$(BUN_LOCAL),bun)
BUN_MIN    := 1.4.4
VERSION    := $(shell sed -n 's/^[[:space:]]*"version": "\([^"]*\)".*/\1/p' packages/coding-agent/package.json | head -1)
ARCH       := darwin-arm64
NATIVE_PKG := @oh-my-pi/pi-natives-$(ARCH)
NATIVE_DST := packages/natives/native/pi_natives.$(ARCH).node
DIST       := packages/coding-agent/dist/omp
UPSTREAM   := upstream
BRANCH     := $(shell git rev-parse --abbrev-ref HEAD)
# 벤치 스모크가 쓰는 트리·모델 — 바깥 워크스페이스의 피험자 트리다.
SANDBOX    ?= $(HOME)/Workspace/local-llm/sandbox
MODEL      ?= omlx/Qwen3.6-35B-A3B-oQ4e-mtp
TOOLS      ?= read,bash,edit,write,grep,glob,todo,progress_note
# 이 포크가 더한 테스트 — 전체 스위트(수십 분)가 아니라 패치의 경계만 돈다.
FORK_TESTS := packages/coding-agent/test/tools/todo-compact-results.test.ts \
              packages/coding-agent/test/tools/path-variant-recovery.test.ts \
              packages/agent/test/compaction-fold-kept-tool-results.test.ts

help: ## 타깃 목록
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo "  bun=$(BUN)  version=$(VERSION)  branch=$(BRANCH)"

bun: ## 저장소 안에 bun $(BUN_MIN) 받기(전역 bun 이 낮을 때)
	@test -x $(BUN_LOCAL) && { echo "already: $$($(BUN_LOCAL) --version)"; exit 0; }; \
	curl -fsSL https://bun.sh/install | BUN_INSTALL=$(CURDIR)/.bun-local bash -s "bun-v$(BUN_MIN)"

install: ## 의존성 설치(bun install)
	$(BUN) install

natives: $(NATIVE_DST) ## 네이티브 애드온 — Rust 빌드 대신 같은 버전의 npm 프리빌트를 둔다(gitignore 대상)
$(NATIVE_DST):
	@tmp=$$(mktemp -d) && cd $$tmp && npm pack $(NATIVE_PKG)@$(VERSION) >/dev/null && tar xzf *.tgz && \
	cp package/*.node $(CURDIR)/$(NATIVE_DST) && rm -rf $$tmp && echo "natives: $(NATIVE_DST) ($(VERSION))"

build: natives ## 단일 바이너리 빌드 → $(DIST), 루트 dist/omp 심링크
	cd packages/coding-agent && $(BUN) scripts/build-binary.ts
	@mkdir -p dist && ln -sfn ../$(DIST) dist/omp && ./dist/omp --version

dist: build ## build 의 별칭

test: ## 포크가 더한 테스트만
	$(BUN) test $(FORK_TESTS)

typecheck: ## 패치가 닿은 패키지의 타입 검사
	cd packages/coding-agent && $(BUN) run check:types
	cd packages/agent && $(BUN) run check:types

smoke: ## 빌드한 바이너리로 피험자 트리에서 한 턴(oMLX 가 떠 있어야 한다) + 프로젝트 설정 로드 확인
	@test -x $(DIST) || { echo "no $(DIST) — make build"; exit 1; }
	cd $(SANDBOX) && $(CURDIR)/$(DIST) config get read.defaultLimit && \
	$(CURDIR)/$(DIST) -p "say ok" --model $(MODEL) --tools $(TOOLS) </dev/null

version: ## 패키지 버전·바이너리 버전·분기 기준 태그
	@echo "package: $(VERSION)"; test -x $(DIST) && echo "binary:  $$($(DIST) --version)" || echo "binary:  (not built)"
	@echo "base:    $$(git describe --tags --abbrev=0 2>/dev/null)  ($$(git rev-list --count $$(git describe --tags --abbrev=0)..HEAD) fork commits)"

status: ## upstream 대비 이 브랜치의 커밋과 upstream 의 새 태그
	@git fetch -q $(UPSTREAM) --tags; echo "fork commits since $$(git describe --tags --abbrev=0):"; \
	git log --oneline $$(git describe --tags --abbrev=0)..HEAD; \
	echo "newer upstream tags:"; git tag --sort=-v:refname | grep -E '^v[0-9]' | head -5

fetch: ## upstream 태그·브랜치 가져오기
	git fetch $(UPSTREAM) --tags

rebase: fetch ## 포크 커밋을 새 upstream 태그 위로 옮긴다(usage: make rebase TAG=v18.15.0 → 새 브랜치 bench/18.15.0)
	@test -n "$(TAG)" || { echo "usage: make rebase TAG=vX.Y.Z"; exit 2; }
	git checkout -b bench/$(patsubst v%,%,$(TAG)) && git rebase --onto $(TAG) $$(git describe --tags --abbrev=0) && echo "now on bench/$(patsubst v%,%,$(TAG)) — make install build test"

push: ## 현재 브랜치를 origin 에(추적 설정)
	git push -u origin $(BRANCH)

clean: ## 빌드 산출물 제거(의존성·.bun-local 은 남긴다)
	rm -rf packages/coding-agent/dist dist
