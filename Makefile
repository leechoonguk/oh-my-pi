# oh-my-pi 포크 관리 — main 브랜치 하나에 옵트인 패치를 두고, upstream/main 을 머지해 따라간다. 지금 HEAD 소스로 빌드해 쓴다.
# 설치판 omp(~/.bun/bin/omp)는 건드리지 않는다. 빌드 산출물은 packages/coding-agent/dist/omp(+.rev)와 루트 dist/ 심링크,
# 설치는 앱 이름 하나(~/.local/bin/$(APP_NAME))다(fork/install.sh). 바이너리 자신의 앱 이름도 $(APP_NAME) 이다.
# 흐름: 패치 추가 → make install(verify 포함) / upstream 따라가기 → make merge → make install
# 저장소는 bun ≥ 1.4.4 를 요구한다 — 전역 bun 이 낮으면 `make bun` 으로 저장소 안(.bun-local)에 받는다.
.PHONY: help bun deps natives build test typecheck contract check-build verify install installed smoke status fetch merge push clean

BUN_LOCAL  := $(CURDIR)/.bun-local/bin/bun
BUN        := $(if $(wildcard $(BUN_LOCAL)),$(BUN_LOCAL),bun)
BUN_MIN    := 1.4.4
VERSION    := $(shell sed -n 's/^[[:space:]]*"version": "\([^"]*\)".*/\1/p' packages/coding-agent/package.json | head -1)
ARCH       := darwin-arm64
NATIVE_PKG := @oh-my-pi/pi-natives-$(ARCH)
NATIVE_DST := packages/natives/native/pi_natives.$(ARCH).node
DIST       := packages/coding-agent/dist/omp
# 빌드가 다시 쓰는 추적 파일(번들 해시) — 바이너리에 이미 실렸으니 빌드 뒤 되돌려 출처의 dirty 를 빌드 전 상태로 둔다.
GENERATED  := packages/coding-agent/src/export/html/viewer.generated.json
# 따라가는 upstream 브랜치 — 우리 커밋은 `$(UPSTREAM_REF)..HEAD`(머지 커밋 제외)다.
export UPSTREAM_REF ?= upstream/main
BRANCH     := $(shell git rev-parse --abbrev-ref HEAD)
export PREFIX ?= $(HOME)/.local
# 벤치 스모크가 쓰는 트리·모델 — 바깥 워크스페이스의 피험자 트리다.
SANDBOX    ?= $(HOME)/Workspace/local-llm/sandbox
MODEL      ?= omlx/Qwen3.6-35B-A3B-oQ4e-mtp
TOOLS      ?= read,bash,edit,write,grep,glob,todo,progress_note
# 이 포크가 더한 설정 키(전부 기본 off)와 테스트 — 패치를 더하면 두 목록에 같이 적는다(make contract 가 강제).
FORK_KEYS  := todo.compactResults tools.recoverPathVariants compaction.foldKeptToolResults
FORK_TESTS := packages/coding-agent/test/tools/todo-compact-results.test.ts \
              packages/coding-agent/test/tools/path-variant-recovery.test.ts \
              packages/agent/test/compaction-fold-kept-tool-results.test.ts \
              packages/coding-agent/test/cli/fork-app-name.test.ts
# 빌드 define(설정 키가 아닌 패치 — 값 없이 빌드하면 upstream 동작). APP_NAME 은 포크 바이너리의 앱 이름이다:
# 사용법 문구·--version 배너·프로세스 제목이 바뀌고(로그 파일 이름은 omp. 그대로) 셀프 업데이트를 거부한다. 설정 루트(~/.omp, 프로젝트 .omp/)는 그대로다.
FORK_DEFINES := PI_FORK_APP_NAME
export APP_NAME ?= ompx

help: ## 타깃 목록
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo "  bun=$(BUN)  version=$(VERSION)  branch=$(BRANCH)  app=$(APP_NAME)  upstream=$(UPSTREAM_REF)"

bun: ## 저장소 안에 bun $(BUN_MIN) 받기(전역 bun 이 낮을 때)
	@test -x $(BUN_LOCAL) && { echo "already: $$($(BUN_LOCAL) --version)"; exit 0; }; \
	curl -fsSL https://bun.sh/install | BUN_INSTALL=$(CURDIR)/.bun-local bash -s "bun-v$(BUN_MIN)"

deps: ## 의존성 설치(bun install)
	$(BUN) install

natives: ## 네이티브 애드온 — Rust 빌드 대신 같은 버전의 npm 프리빌트를 둔다(gitignore 대상, 버전이 바뀌면 다시 받는다)
	@test -f $(NATIVE_DST) && test "$$(cat $(NATIVE_DST).version 2>/dev/null)" = "$(VERSION)" && exit 0; \
	tmp=$$(mktemp -d) && cd $$tmp && npm pack $(NATIVE_PKG)@$(VERSION) >/dev/null && tar xzf *.tgz && \
	cp package/*.node $(CURDIR)/$(NATIVE_DST) && echo $(VERSION) >$(CURDIR)/$(NATIVE_DST).version && rm -rf $$tmp && \
	echo "natives: $(NATIVE_DST) ($(VERSION))"

build: natives ## 단일 바이너리 빌드 → $(DIST) + 출처 $(DIST).rev, 루트 dist/ 심링크(이 바이너리로 도는 프로세스가 있으면 거부)
	@! pgrep -f "^($(CURDIR)/)?(dist/|$(dir $(DIST)))omp( |$$)" >/dev/null || { echo "FAIL: $(DIST) 로 도는 omp 가 있다 — 끝난 뒤 빌드(설치본은 사본이라 무관)"; exit 1; }
	cd packages/coding-agent && PI_FORK_APP_NAME=$(APP_NAME) $(BUN) scripts/build-binary.ts
	@git checkout -- $(GENERATED)
	@fork/install.sh stamp $(DIST)
	@mkdir -p dist && ln -sfn ../$(DIST) dist/omp && ln -sfn ../$(DIST).rev dist/omp.rev

test: ## 포크가 더한 테스트만(전체 스위트가 아니라 패치의 경계)
	$(BUN) test $(FORK_TESTS)

typecheck: ## 패치가 닿은 패키지의 타입 검사
	cd packages/coding-agent && $(BUN) run check:types
	cd packages/agent && $(BUN) run check:types

contract: ## 패치 계약 — 커밋마다 설정 키(또는 빌드 define)·테스트·docs, 키마다 기본 off, define 마다 upstream 폴백
	@fork/contract.sh "$(FORK_KEYS)" "$(FORK_TESTS)" "$(FORK_DEFINES)"

check-build: ## 빌드가 지금 HEAD 의 packages/ 그대로인지(.rev 대조)
	@fork/install.sh check $(DIST)

verify: contract test typecheck check-build ## 설치 전 게이트

install: verify ## 검증한 빌드를 $(PREFIX)/bin/$(APP_NAME) 로 설치(교체는 새 inode — 도는 셀은 옛 사본으로 끝난다)
	@fork/install.sh install $(DIST)

installed: ## 설치본의 버전과 출처
	@fork/install.sh installed

smoke: ## 설치본으로 피험자 트리에서 한 턴(oMLX 가 떠 있어야 한다) + 프로젝트 설정의 포크 키 로드 확인
	@test -x $(PREFIX)/bin/$(APP_NAME) || { echo "no $(APP_NAME) — make install"; exit 1; }
	cd $(SANDBOX) && $(PREFIX)/bin/$(APP_NAME) --version && for k in $(FORK_KEYS); do printf '%s = ' $$k; $(PREFIX)/bin/$(APP_NAME) config get $$k; done && \
	$(PREFIX)/bin/$(APP_NAME) -p "say ok" --model $(MODEL) --tools $(TOOLS) </dev/null

status: fetch ## 우리 커밋과 아직 머지하지 않은 upstream 커밋 수
	@echo "fork commits over $(UPSTREAM_REF):"; git log --oneline --no-merges $(UPSTREAM_REF)..HEAD
	@echo "upstream commits not merged: $$(git rev-list --count HEAD..$(UPSTREAM_REF)) ($$(git describe --tags --abbrev=0 $(UPSTREAM_REF)))"

fetch: ## upstream 가져오기
	@git fetch -q $(word 1,$(subst /, ,$(UPSTREAM_REF))) --tags

merge: fetch ## upstream 을 머지한다(충돌은 해결 후 git commit → make deps install)
	@test -z "$$(git status --porcelain)" || { echo "FAIL: 작업 트리가 깨끗하지 않다"; exit 1; }
	git merge --no-edit $(UPSTREAM_REF) || { echo "충돌: 해결 후 git commit → make deps install (중단은 git merge --abort)"; exit 1; }
	$(MAKE) deps build verify

push: ## 현재 브랜치를 origin 에(추적 설정)
	git push -u origin $(BRANCH)

clean: ## 빌드 산출물 제거(의존성·.bun-local·설치본은 남긴다)
	rm -rf packages/coding-agent/dist dist
