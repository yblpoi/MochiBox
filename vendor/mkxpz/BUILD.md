# 内置 mkxp-z 的构建记录

分发的 `vendor/runtime/mkxp-z`（→ `Contents/Resources/runtime/mkxp-z`）**不是**上游
Release 的现成二进制，而是按下面的参数现场编的。改动理由见 `Scripts/fetch-mkxpz.sh` 头部。

## 上游

- 仓库: https://github.com/mkxp-z/mkxp-z
- commit: `f02d586624dc53de373889cc16d9b1516da0a3a5`
  （`Merge pull request #390 from Splendide-Imaginarius/mkxp-z-meson-options`）

## 构建

```sh
meson setup builddir . \
  --buildtype=release \
  -Dworkdir_current=true \
  -Diconv_system=enabled \
  -Dwrap_mode=forcefallback \
  -Dc_args=-mmacosx-version-min=13.0 \
  -Dcpp_args=-mmacosx-version-min=13.0 \
  -Dobjcpp_args=-mmacosx-version-min=13.0 \
  -Dc_link_args=-mmacosx-version-min=13.0 \
  -Dcpp_link_args=-mmacosx-version-min=13.0 \
  -Dobjcpp_link_args=-mmacosx-version-min=13.0
ninja -C builddir
```

- `-Dworkdir_current=true` 是**硬要求**：默认构建会把 cwd 改成可执行文件所在目录，
  游戏目录挂不上（`Scripts/fetch-mkxpz.sh` 会核对这一项）。
- 只装了 Command Line Tools 的机器没有 `ibtool`（`macos/views/settingsmenu.nib` 步骤）。
  用一个只写桩文件的 `ibtool` 顶掉即可 —— 该 nib 只是设置菜单的界面资源，
  以 `FAKE-NIB` 桩嵌入后设置菜单不可用，游戏启动不受影响：

  ```sh
  # /tmp/fakebin/ibtool：把 --compile 的目标写成一个 8 字节桩
  PATH=/tmp/fakebin:$PATH meson setup ... 
  ```

## 本地补丁（GPL-2.0-or-later 合规所需）

`mochibox-macos-fixes.patch` 是相对上面的 commit 的全部改动：

1. `src/filesystem/filesystem.cpp` — `iconv_open("utf-8-mac")` 失败时
   `(iconv_t)-1` 被直接喂给 `iconv()`，`createPathCache` 阶段 SIGSEGV；
   同时给 `PHYSFS_stat` 补失败分支。**这是"接上就崩"的根因。**
2. `src/filesystem/filesystemImplApple.mm` — 路径归一化在 `/tmp → /private/tmp`
   这类符号链接下会漏掉 cwd 前缀。
3. `src/display/font.cpp` — 字体回退（缺 MS Gothic 等日文字体时不再整段丢字）。

分发二进制时必须能拿到这份补丁 + 上述 build recipe —— 就是本文件。
