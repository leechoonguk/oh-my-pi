#!/usr/bin/env bash
# 포크 패치 계약 — upstream 태그 위의 커밋 스택이 "옵트인·문서·테스트" 세 가지를 지키는지 본다.
#  1) packages/ 를 건드린 커밋은 제목에 백틱 키를 달고, 그 키는 FORK_KEYS(설정 키) 또는 FORK_DEFINES(빌드 define)에 있다
#  2) 그 커밋은 *.test.ts 와 docs/ 를 함께 바꾼다
#  3) FORK_KEYS 의 키마다 register({ id, … default: false|0 }) — 기본값은 upstream 과 같은 동작이다
#  4) FORK_TESTS 파일이 실재한다
#  5) FORK_DEFINES 의 이름마다 `process.env.<이름> ||` 폴백이 있다 — define 없이 빌드하면 upstream 과 같은 동작이다
# usage: fork/contract.sh "<FORK_KEYS>" "<FORK_TESTS>" ["<FORK_DEFINES>"]
set -uo pipefail
defines=${3:-}; keys=" $1 $defines "; tests=$2; fail=0
base=$(git describe --tags --abbrev=0)
err() { echo "FAIL: $*"; fail=1; }

for c in $(git rev-list --reverse "$base"..HEAD); do
  files=$(git diff-tree --no-commit-id --name-only -r "$c")
  grep -q '^packages/' <<<"$files" || continue
  subj=$(git log -1 --format=%s "$c"); short=$(git rev-parse --short "$c")
  key=$(sed -n 's/.*`\([A-Za-z0-9_.]*\)`.*/\1/p' <<<"$subj" | head -1)
  if [ -z "$key" ]; then err "$short '$subj' — 제목에 \`설정.키\` 가 없다"
  elif [[ "$keys" != *" $key "* ]]; then err "$short — 키 $key 가 FORK_KEYS·FORK_DEFINES 에 없다"; fi
  grep -q '\.test\.ts$' <<<"$files" || err "$short — 테스트(*.test.ts)를 함께 바꾸지 않았다"
  grep -q '^docs/' <<<"$files" || err "$short — docs/ 를 함께 바꾸지 않았다"
done

for k in $1; do
  hit=$(grep -rn --include='*.ts' -A6 "id: \"$k\"" packages/*/src | grep -m1 'default:')
  if [ -z "$hit" ]; then err "$k — packages/*/src 에 register 선언이 없다"
  elif ! grep -Eq 'default: (false|0),' <<<"$hit"; then err "$k — 기본값이 false/0 이 아니다: ${hit##*default:}"; fi
done

for d in $defines; do
  grep -rqF --include='*.ts' "process.env.$d ||" packages/*/src || err "$d — packages/*/src 에 \`process.env.$d ||\` 폴백이 없다"
done

for t in $tests; do [ -f "$t" ] || err "FORK_TESTS: $t 없음"; done
[ $fail = 0 ] && echo "contract: OK ($base + $(git rev-list --count "$base"..HEAD) commits, keys: $1${defines:+, defines: $defines})"
exit $fail
