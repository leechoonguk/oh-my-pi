#!/usr/bin/env bash
# 로컬 설치 채널 — 빌드한 포크 바이너리를 버전별 사본으로 두고 `omp-local` 하나로 가리킨다.
# 설치판 omp(~/.bun/bin/omp)는 건드리지 않는다. 레이아웃(PREFIX 기본 ~/.local):
#   $PREFIX/share/omp-local/releases/<version>-<sha>/{omp,omp.rev}
#   $PREFIX/share/omp-local/{current,previous} -> releases/<…>
#   $PREFIX/bin/omp-local -> ../share/omp-local/current/omp
# omp.rev 는 빌드가 남긴 출처(base 태그·HEAD·packages/ 트리 해시·dirty)다 — 바이너리에 들어가는 것은 packages/ 뿐이라
# 트리 해시가 같으면 Makefile·fork/ 만 바뀐 커밋에서도 같은 빌드로 본다.
# usage: fork/channel.sh stamp <dist> | check <dist> | release <dist> | rollback | installed | prune <keep>
set -euo pipefail
PREFIX=${PREFIX:-$HOME/.local}
ROOT=$PREFIX/share/omp-local
LINK=$PREFIX/bin/omp-local
die() { echo "FAIL: $*" >&2; exit 1; }
field() { sed -n "s/^$1=//p" "$2"; }

stamp() {
  local dist=$1 dirty=0
  [ -n "$(git status --porcelain -- packages)" ] && dirty=1
  { echo "version=$("$dist" --version | awk '{print $NF}' | sed 's|.*/||')"
    echo "base=$(git describe --tags --abbrev=0)"
    echo "head=$(git rev-parse HEAD)"
    echo "packages=$(git rev-parse HEAD:packages)"
    echo "dirty=$dirty"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } >"$dist.rev"
  cat "$dist.rev"
}

# 빌드가 지금 HEAD 의 packages/ 그대로인지
check() {
  local dist=$1 rev=$1.rev
  [ -x "$dist" ] || die "$dist 없음 — make build"
  [ -f "$rev" ] || die "$rev 없음 — make build 로 다시 빌드"
  [ "$(field dirty "$rev")" = 0 ] || die "커밋하지 않은 packages/ 변경으로 빌드됐다 — 커밋 후 make build"
  [ -z "$(git status --porcelain -- packages)" ] || die "packages/ 에 커밋하지 않은 변경이 있다"
  [ "$(field packages "$rev")" = "$(git rev-parse HEAD:packages)" ] || die "빌드 이후 packages/ 가 바뀌었다 — make build"
  [ "$("$dist" --version | awk '{print $NF}' | sed 's|.*/||')" = "$(field version "$rev")" ] || die "바이너리 버전이 $rev 와 다르다"
  echo "build: OK ($(field version "$rev") @ $(git rev-parse --short "$(field head "$rev")"))"
}

release() {
  local dist=$1; check "$dist" >/dev/null
  local rev=$dist.rev name; name="$(field version "$rev")-$(git rev-parse --short=10 "$(field head "$rev")")"
  local dir=$ROOT/releases/$name
  if [ -d "$dir" ]; then echo "already released: $name"
  else
    mkdir -p "$ROOT/releases" "$PREFIX/bin"
    rm -rf "$dir.tmp" && mkdir "$dir.tmp" && cp "$dist" "$dist.rev" "$dir.tmp/" && mv "$dir.tmp" "$dir" || die "릴리스 사본을 만들지 못했다: $dir"
  fi
  local cur; cur=$(readlink "$ROOT/current" 2>/dev/null || true)
  if [ "$cur" != "releases/$name" ]; then
    [ -n "$cur" ] && ln -sfn "$cur" "$ROOT/previous"
    ln -sfn "releases/$name" "$ROOT/current"
  fi
  ln -sfn ../share/omp-local/current/omp "$LINK"
  installed
}

rollback() {
  local cur prev; cur=$(readlink "$ROOT/current" 2>/dev/null || true); prev=$(readlink "$ROOT/previous" 2>/dev/null || true)
  [ -n "$prev" ] && [ -d "$ROOT/$prev" ] || die "되돌릴 이전 릴리스가 없다"
  ln -sfn "$prev" "$ROOT/current"; ln -sfn "$cur" "$ROOT/previous"
  installed
}

installed() {
  [ -L "$LINK" ] || die "$LINK 없음 — make release"
  echo "link:     $LINK -> current -> $(readlink "$ROOT/current")"
  echo "previous: $(readlink "$ROOT/previous" 2>/dev/null || echo '(none)')"
  echo "version:  $("$LINK" --version)"
  sed 's/^/rev:      /' "$ROOT/current/omp.rev"
}

# current·previous 를 빼고 최근 것부터 <keep> 개만 남긴다
prune() {
  local keep=$1 cur prev n=0
  cur=$(readlink "$ROOT/current" 2>/dev/null || true); prev=$(readlink "$ROOT/previous" 2>/dev/null || true)
  for d in $(ls -1t "$ROOT/releases"); do
    [ "releases/$d" = "$cur" ] || [ "releases/$d" = "$prev" ] && continue
    n=$((n + 1)); [ $n -le "$keep" ] && continue
    rm -rf "${ROOT:?}/releases/$d" && echo "pruned: $d"
  done
}

cmd=${1:-}; shift || true
case $cmd in stamp|check|release) "$cmd" "$1" ;; rollback|installed) "$cmd" ;; prune) prune "${1:-3}" ;; *) die "usage: $0 stamp|check|release <dist> | rollback | installed | prune <keep>" ;; esac
