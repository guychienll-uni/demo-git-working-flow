#!/usr/bin/env bash
#
# Demo: 為什麼 develop 用 squash、master 用 merge commit 混用，
#       會讓「看似已經同步」的 master/develop 在下一次 sync 時爆衝突。
#
# 用法: ./demo.sh
#   會清掉舊的 demo 分支重新跑一次，最後停在一個「真的衝突」的 merge 現場，
#   讓你用 `git status` / `cat feature.txt` 檢查，看完後執行:
#     git merge --abort
#   即可復原。
#
set -euo pipefail
cd "$(dirname "$0")"

section() { echo; echo "========================================"; echo "$1"; echo "========================================"; }

section "清理舊的 demo 分支"
git checkout -q main
for b in master develop feature/A feature/B hotfix/revert-A; do
  git branch -D "$b" >/dev/null 2>&1 || true
done
rm -f feature.txt

section "Step 0: 建立 master / develop 共同基礎"
git checkout -q -b master
printf 'line1\nline2\n' > feature.txt
git add feature.txt
git commit -q -m "base: init feature.txt"
git branch develop master
cat feature.txt

section "Step 1: feature/A 從 develop 開分支開發"
git checkout -q develop
git checkout -q -b feature/A
sed -i '' 's/line2/line2-featureA/' feature.txt
git commit -q -am "feature/A: implement feature A"
cat feature.txt

section "Step 2: feature/A 用 SQUASH merge 進 develop（目前的規則）"
git checkout -q develop
git merge --squash feature/A -q
git commit -q -m "feat: feature A (squash into develop)"
echo "develop 內容:"; cat feature.txt
echo -n "feature/A 是否仍是 develop 的祖先? (squash 後應該是 no) -> "
git merge-base --is-ancestor feature/A develop && echo yes || echo no
SQUASH_A=$(git rev-parse develop)

section "Step 3: develop 同步進 master，用 MERGE COMMIT（目前的規則）"
git checkout -q master
git merge --no-ff develop -q -m "sync: develop -> master"
echo "master 內容:"; cat feature.txt
echo "merge-base(master, develop) = $(git merge-base master develop)"

section "Step 4: production 發現 feature A 有 bug，從 master 開 hotfix 做 revert"
git checkout -q master
git checkout -q -b hotfix/revert-A
git revert --no-edit "$SQUASH_A" >/dev/null
echo "hotfix/revert-A 內容:"; cat feature.txt

section "Step 5: hotfix PR 回 master（merge commit)"
git checkout -q master
git merge --no-ff hotfix/revert-A -q -m "hotfix: revert feature A"
echo "master 內容:"; cat feature.txt

section "Step 6【問題根源】: 舊習慣 - hotfix 另外用 SQUASH 方式回 develop"
git checkout -q develop
git merge --squash hotfix/revert-A -q
git commit -q -m "hotfix: revert feature A (squash back into develop)"
echo "develop 內容:"; cat feature.txt
echo "此時 master 和 develop 內容一致，但..."
echo "merge-base(master, develop) 仍然是: $(git merge-base master develop)"
echo "  <-- 還停在 Step2 的 squash commit，完全沒有推進！(master/develop 真正的 SHA 分歧從這裡開始)"

section "Step 7: develop 上繼續正常開發 feature/B，剛好也動到同一行"
git checkout -q develop
git checkout -q -b feature/B
sed -i '' 's/line2/line2-featureB/' feature.txt
git commit -q -am "feature/B: implement feature B"
git checkout -q develop
git merge --squash feature/B -q
git commit -q -m "feat: feature B (squash)"
echo "develop 內容:"; cat feature.txt

section "Step 8: 下一次『看起來很平常』的 develop -> master 同步"
git checkout -q master
set +e
git merge --no-ff develop -m "sync: develop -> master"
CODE=$?
set -e

if [ $CODE -ne 0 ]; then
  echo
  echo "💥 衝突發生了 —— 這就是問題重現！"
  echo
  git status
  echo
  echo "衝突內容 (feature.txt):"
  cat feature.txt
  echo
  echo "沒有人在這個時間點動了『新的』東西，master 跟 develop 在剛才 Step6 結束時內容還一致，"
  echo "但因為 hotfix 是分別用兩個不同 SHA (squash) 進到 develop 跟 master，"
  echo "merge-base 卡在很舊的地方，git 只能用那個舊 base 去做三方合併，"
  echo "才會在這行炸出衝突。"
  echo
  echo "看完後執行: git merge --abort  來復原 master。"
else
  echo "沒有衝突（環境或步驟跟預期不同，請檢查腳本輸出）"
fi
