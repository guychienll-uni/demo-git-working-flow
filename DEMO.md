# Demo：混用 squash / merge commit 為什麼會讓 master、develop 打架

給 Roger 的重現腳本。結論先講：

> **只要「同一份改動」在 master 和 develop 上是透過兩個不同的 commit（例如一邊 squash、一邊 merge commit）分別進去的，
> 這兩個 branch 的 `merge-base` 就不會往前推進。**
> 之後即使兩邊內容當下看起來完全一樣，下一次正常的同步都可能在同一個地方炸出衝突。

目前的規則：

- feature → develop：**Squash merge**（方便之後在 master 針對單一 feature 精準退版）
- develop → master：**Create a merge commit**（no-ff）

這兩個規則各自都合理，但混在一起用在 **hotfix** 身上時會出問題。

## 跑一次看看

```bash
./demo.sh
```

腳本會自動建立 `master` / `develop` / `feature/A` / `hotfix/revert-A` / `feature/B`，
模擬到「下一次正常同步」時，直接讓你看到真實的 git conflict。

看完後執行 `git merge --abort` 復原 `master`。

## 情境重現（腳本做的事）

```
Step 0   master == develop，共同基礎
           master/develop:  line1 / line2

Step 1~2 feature/A 改 line2，squash 進 develop
           develop:  line1 / line2-featureA        (commit S，母節點是 base，不是 feature/A！)

Step 3   develop --merge commit--> master
           master:  line1 / line2-featureA
           merge-base(master, develop) = S   ✅ 這時候還是一致的

Step 4~5 production 出包，從 master 開 hotfix revert S，PR 回 master（merge commit）
           master:  line1 / line2            (commit R_master)

Step 6   ⚠️ 舊習慣：hotfix 也「另外」squash 回 develop
           develop:  line1 / line2            (commit R_dev，內容跟 R_master 一樣，但是不同 SHA！)

           此時 master 內容 == develop 內容，但是：
           merge-base(master, develop) 仍然停在 Step2 的 S，完全沒有推進。
           因為 R_master 跟 R_dev 是兩個獨立的 commit，誰也不是誰的祖先。

Step 7   develop 上照常開發 feature/B，剛好也動到同一行，squash 進 develop
           develop:  line1 / line2-featureB

Step 8   💥 下一次「看起來很平常」的 develop -> master 同步
           git merge base 只能抓到 Step2 的 S
           master 相對 S 的變化：  line2-featureA -> line2
           develop 相對 S 的變化： line2-featureA -> line2-featureB
           兩邊都改了同一行、卻是相對同一個舊 base 的不同結果 -> CONFLICT
```

實際跑出來的衝突畫面：

```
<<<<<<< HEAD
line2
||||||| <Step2 squash commit>
line2-featureA
=======
line2-featureB
>>>>>>> develop
```

關鍵：**Step 6 結束的那一刻，master 和 develop 根本沒有衝突、內容也一致**，
問題是潛伏的——`merge-base` 沒有跟著推進，衝突只會在未來某次「完全正常」的同步時，
在 hotfix 曾經動過的那一行突然冒出來，很難聯想到根因是 squash。

## 為什麼會這樣

- Squash merge 會產生一個新 commit，**父節點是 squash 前的分支頂端，不是原本 feature branch 上的任何 commit**。
  也就是說 squash 出來的 commit，跟原本改動的來源在 commit graph 上是斷開的。
- `git merge` 判斷衝突用的是三方合併（3-way merge），依據的 base 是兩個分支的 **merge-base**（最近共同祖先）。
- 只要 master、develop 對同一份改動各自產生了「內容一樣、SHA 不同」的 commit，
  git 就永遠找不到比舊 base 更新的共同祖先，未來任何疊加在那份改動附近的修改，
  都可能在同步時被迫用那個過舊的 base 做三方合併 → 衝突。
- 這跟改動本身是不是 revert 沒有絕對關係，revert 只是最容易踩到的情境
  （因為 revert 剛好会跟 squash 進去的內容完全對沖，最容易被忽略掉「這其實是兩個不同 commit」這件事）。

## 解法（目前團隊決議的新流程）

Hotfix 不要「各自」回 master 跟 develop，改成：

1. 從 **master** 開 hotfix branch，修正後 PR 回 **master**。
2. 再開一條 **master → develop** 的同步 PR，
   **這條 PR 一定要選「Create a merge commit」，不要 squash。**

這樣 develop 上引入的 hotfix commit 會跟 master 上的是**同一個 SHA**（透過 merge commit 直接帶進去，
而不是用 squash 重造一個新的），`merge-base(master, develop)` 就會確實推進到 hotfix 那個點，
不會再卡在舊的位置，後續同步也就不會在該處衝突。

> 換句話說：develop 對 **feature** 可以繼續用 squash（那是單向、只往 develop 推進，不需要跟 master 對齊 SHA）；
> 但只要是「需要在 master 和 develop 兩邊都存在、且未來還要互相同步」的改動（也就是 hotfix），
> 就必須讓兩邊用同一個 commit，不能各自 squash 一份。
