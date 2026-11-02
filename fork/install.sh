#!/usr/bin/env bash
# 포크 바이너리 설치 — 지금 HEAD 소스로 빌드한 dist 를 앱 이름(APP_NAME, 기본 ompx) 하나로 설치한다. 버전별 사본은 두지 않는다
# (되돌리기는 git 으로: 원하는 커밋에서 다시 빌드·설치). 설치판 omp(~/.bun/bin/omp)는 건드리지 않는다.
#   $PREFIX/share/$APP_NAME/{$APP_NAME,$APP_NAME.rev}   $PREFIX/bin/$APP_NAME -> ../share/$APP_NAME/$APP_NAME
# <앱 이름>.rev 는 빌드가 남긴 출처(앱 이름·버전·HEAD·upstream 머지 지점·packages/ 트리 해시·dirty)다 — 바이너리에 들어가는 것은
# packages/ 뿐이라 트리 해시가 같으면 Makefile·fork/ 만 바뀐 커밋에서도 같은 빌드로 본다.
# 교체는 tmp 복사 후 mv(새 inode) — 도는 셀은 옛 inode 를 쥐고 끝까지 간다.
# usage: fork/install.sh stamp <dist> | check <dist> | install <dist> | installed
set -euo pipefail
PREFIX=${PREFIX:-$HOME/.local}
APP=${APP_NAME:-ompx}
ROOT=$PREFIX/share/$APP
LINK=$PREFIX/bin/$APP
UPSTREAM_REF=${UPSTREAM_REF:-upstream/main}
die() { echo "FAIL: $*" >&2; exit 1; }
field() { sed -n "s/^$1=//p" "$2"; }
# `--version` 배너는 `<앱 이름>/<버전>` 이다
banner() { "$1" --version | awk '{print $NF}'; }

stamp() {
  local dist=$1 dirty=0 b; b=$(banner "$dist")
  [ -n "$(git status --porcelain -- packages)" ] && dirty=1
  { echo "app=${b%%/*}"
    echo "version=${b##*/}"
    echo "head=$(git rev-parse HEAD)"
    echo "upstream=$(git merge-base HEAD "$UPSTREAM_REF")"
    echo "packages=$(git rev-parse HEAD:packages)"
    echo "dirty=$dirty"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } >"$dist.rev"
  cat "$dist.rev"
}

# 빌드가 지금 HEAD 의 packages/ 그대로인지
check() {
  local dist=$1 rev=$1.rev b
  [ -x "$dist" ] || die "$dist 없음 — make build"
  [ -f "$rev" ] || die "$rev 없음 — make build 로 다시 빌드"
  [ "$(field dirty "$rev")" = 0 ] || die "커밋하지 않은 packages/ 변경으로 빌드됐다 — 커밋 후 make build"
  [ -z "$(git status --porcelain -- packages)" ] || die "packages/ 에 커밋하지 않은 변경이 있다"
  [ "$(field packages "$rev")" = "$(git rev-parse HEAD:packages)" ] || die "빌드 이후 packages/ 가 바뀌었다 — make build"
  b=$(banner "$dist")
  [ "${b##*/}" = "$(field version "$rev")" ] || die "바이너리 버전이 $rev 와 다르다"
  [ "${b%%/*}" = "$APP" ] || die "바이너리 앱 이름이 ${b%%/*} 다(기대 $APP) — make build"
  echo "build: OK ($b @ $(git rev-parse --short "$(field head "$rev")"))"
}

install() {
  local dist=$1; check "$dist" >/dev/null
  mkdir -p "$ROOT" "$PREFIX/bin"
  cp "$dist" "$ROOT/$APP.tmp" && cp "$dist.rev" "$ROOT/$APP.rev.tmp" && mv -f "$ROOT/$APP.tmp" "$ROOT/$APP" && mv -f "$ROOT/$APP.rev.tmp" "$ROOT/$APP.rev" \
    || die "설치 사본을 만들지 못했다: $ROOT"
  ln -sfn "../share/$APP/$APP" "$LINK"
  installed
}

installed() {
  [ -L "$LINK" ] || die "$LINK 없음 — make install"
  echo "link:    $LINK -> $(readlink "$LINK")"
  echo "version: $("$LINK" --version)"
  sed 's/^/rev:     /' "$ROOT/$APP.rev"
}

cmd=${1:-}; shift || true
case $cmd in stamp|check|install) "$cmd" "$1" ;; installed) "$cmd" ;; *) die "usage: $0 stamp|check|install <dist> | installed" ;; esac
