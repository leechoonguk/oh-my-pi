# oh-my-pi 포크 관리 — upstream 태그 위에 옵트인 패치를 한 줄로 쌓고(local/<버전> 브랜치), 빌드·검증·설치 채널을 한 곳에서.
# 설치판 omp(~/.bun/bin/omp)는 건드리지 않는다. 빌드 산출물은 packages/coding-agent/dist/omp(+.rev)와 루트 dist/ 심링크,
# 설치는 버전별 사본 + ~/.local/bin/omp-local 심링크다(fork/channel.sh).
# 흐름: 패치 추가 → make verify → make release / upstream 새 태그 → make sync TAG=vX.Y.Z → make verify → make release
# 저장소는 bun ≥ 1.4.4 를 요구한다 — 전역 bun 이 낮으면 `make bun` 으로 저장소 안(.bun-local)에 받는다.
.PHONY: help bun install natives build test typecheck contract check-build verify smoke release installed rollback prune version status fetch sync push clean

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
BASE       := $(shell git describe --tags --abbrev=0 2>/dev/null)
export PREFIX ?= $(HOME)/.local
# 벤치 스모크가 쓰는 트리·모델 — 바깥 워크스페이스의 피험자 트리다.
SANDBOX    ?= $(HOME)/Workspace/local-llm/sandbox
MODEL      ?= omlx/Qwen3.6-35B-A3B-oQ4e-mtp
TOOLS      ?= read,bash,edit,write,grep,glob,todo,progress_note
# 이 포크가 더한 설정 키(전부 기본 off)와 테스트 — 패치를 더하면 두 목록에 같이 적는다(make contract 가 강제).
FORK_KEYS  := todo.compactResults tools.recoverPathVariants compaction.foldKeptToolResults
FORK_TESTS := packages/coding-agent/test/tools/todo-compact-results.test.ts \
              packages/coding-agent/test/tools/path-variant-recovery.test.ts \
              packages/agent/test/compaction-fold-kept-tool-results.test.ts

help: ## 타깃 목록
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo "  bun=$(BUN)  version=$(VERSION)  branch=$(BRANCH)  base=$(BASE)"

bun: ## 저장소 안에 bun $(BUN_MIN) 받기(전역 bun 이 낮을 때)
	@test -x $(BUN_LOCAL) && { echo "already: $$($(BUN_LOCAL) --version)"; exit 0; }; \
	curl -fsSL https://bun.sh/install | BUN_INSTALL=$(CURDIR)/.bun-local bash -s "bun-v$(BUN_MIN)"

install: ## 의존성 설치(bun install)
	$(BUN) install

natives: ## 네이티브 애드온 — Rust 빌드 대신 같은 버전의 npm 프리빌트를 둔다(gitignore 대상, 버전이 바뀌면 다시 받는다)
	@test -f $(NATIVE_DST) && test "$$(cat $(NATIVE_DST).version 2>/dev/null)" = "$(VERSION)" && exit 0; \
	tmp=$$(mktemp -d) && cd $$tmp && npm pack $(NATIVE_PKG)@$(VERSION) >/dev/null && tar xzf *.tgz && \
	cp package/*.node $(CURDIR)/$(NATIVE_DST) && echo $(VERSION) >$(CURDIR)/$(NATIVE_DST).version && rm -rf $$tmp && \
	echo "natives: $(NATIVE_DST) ($(VERSION))"

build: natives ## 단일 바이너리 빌드 → $(DIST) + 출처 $(DIST).rev, 루트 dist/ 심링크(이 바이너리로 도는 프로세스가 있으면 거부)
	@! pgrep -f "^($(CURDIR)/)?(dist/|$(dir $(DIST)))omp( |$$)" >/dev/null || { echo "FAIL: $(DIST) 로 도는 omp 가 있다 — 끝난 뒤 빌드(설치 채널은 사본이라 무관)"; exit 1; }
	cd packages/coding-agent && $(BUN) scripts/build-binary.ts
	@fork/channel.sh stamp $(DIST)
	@mkdir -p dist && ln -sfn ../$(DIST) dist/omp && ln -sfn ../$(DIST).rev dist/omp.rev

test: ## 포크가 더한 테스트만(전체 스위트가 아니라 패치의 경계)
	$(BUN) test $(FORK_TESTS)

typecheck: ## 패치가 닿은 패키지의 타입 검사
	cd packages/coding-agent && $(BUN) run check:types
	cd packages/agent && $(BUN) run check:types

contract: ## 패치 계약 — 커밋마다 설정 키·테스트·docs, 키마다 기본 off
	@fork/contract.sh "$(FORK_KEYS)" "$(FORK_TESTS)"

check-build: ## 빌드가 지금 HEAD 의 packages/ 그대로인지(.rev 대조)
	@fork/channel.sh check $(DIST)

verify: contract test typecheck check-build ## 릴리스 전 게이트

smoke: ## 설치 채널 바이너리로 피험자 트리에서 한 턴(oMLX 가 떠 있어야 한다) + 프로젝트 설정의 포크 키 로드 확인
	@test -x $(PREFIX)/bin/omp-local || { echo "no omp-local — make release"; exit 1; }
	cd $(SANDBOX) && for k in $(FORK_KEYS); do printf '%s = ' $$k; $(PREFIX)/bin/omp-local config get $$k; done && \
	$(PREFIX)/bin/omp-local -p "say ok" --model $(MODEL) --tools $(TOOLS) </dev/null

release: verify ## 검증한 빌드를 버전별 사본으로 설치하고 omp-local 을 넘긴다(이전 것은 previous)
	@fork/channel.sh release $(DIST)

installed: ## 설치 채널이 가리키는 릴리스와 출처
	@fork/channel.sh installed

rollback: ## omp-local 을 직전 릴리스로 되돌린다(current ↔ previous)
	@fork/channel.sh rollback

prune: ## 오래된 릴리스 사본 정리(current·previous 외 KEEP 개, 기본 3)
	@fork/channel.sh prune $(or $(KEEP),3)

version: ## 패키지 버전·빌드 출처·분기 기준 태그
	@echo "package: $(VERSION)"; test -f $(DIST).rev && sed 's/^/build:   /' $(DIST).rev || echo "build:   (not built)"
	@echo "base:    $(BASE)  ($$(git rev-list --count $(BASE)..HEAD) fork commits)"

status: fetch ## upstream 대비 이 브랜치의 커밋과 기준 태그보다 새 upstream 태그
	@echo "fork commits on $(BASE):"; git log --oneline $(BASE)..HEAD
	@echo "newer upstream tags:"; git tag --sort=-v:refname --contains $(BASE) | grep -E '^v[0-9]' | grep -vx '$(BASE)' | head -5 || echo "  (none)"

fetch: ## upstream 태그·브랜치 가져오기
	@git fetch -q $(UPSTREAM) --tags

sync: fetch ## 패치 스택을 새 upstream 태그 위로 옮긴다(usage: make sync TAG=v18.15.0 → 새 브랜치 local/18.15.0, 옛 브랜치는 남는다)
	@test -n "$(TAG)" || { echo "usage: make sync TAG=vX.Y.Z"; exit 2; }
	@test -z "$$(git status --porcelain)" || { echo "FAIL: 작업 트리가 깨끗하지 않다"; exit 1; }
	git checkout -b local/$(patsubst v%,%,$(TAG))
	git rebase --onto $(TAG) $(BASE) || { echo "충돌: 해결 후 git rebase --continue → make install verify (중단은 git rebase --abort && git checkout $(BRANCH))"; exit 1; }
	$(MAKE) install build verify

push: ## 현재 브랜치를 origin 에(추적 설정)
	git push -u origin $(BRANCH)

clean: ## 빌드 산출물 제거(의존성·.bun-local·설치 채널은 남긴다)
	rm -rf packages/coding-agent/dist dist
