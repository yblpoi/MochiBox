# 内置 mkxp-z 的构建记录

分发的 `vendor/runtime/mkxp-z`（→ `Contents/Resources/runtime/mkxp-z`）**不是**上游
Release 的现成二进制，而是按下面的参数现场编的。改动理由见 `Scripts/fetch-mkxpz.sh` 头部。
重新取包/重建后，`Scripts/fetch-mkxpz.sh` 会自动 strip、ad-hoc 重签并更新
`vendor/runtime/mkxp-z.sha256`。

## 上游

- 仓库: https://github.com/mkxp-z/mkxp-z
- commit: `f02d586624dc53de373889cc16d9b1516da0a3a5`
  （`Merge pull request #390 from Splendide-Imaginarius/mkxp-z-meson-options`）
- 项目版本: `2.4.2`

## 工具链（这次实际用的）

| 项 | 值 |
| --- | --- |
| 机器 | Apple Silicon（arm64），macOS 27.2（26B123） |
| 编译器 | Apple clang 21.0.0（`clang-2100.4.1.1`），经 ccache 转发 |
| meson | 1.11.2 |
| ninja | 1.13.2 |
| 部署目标 | `minos 13.0`（所有 `*-args` 显式带 `-mmacosx-version-min=13.0`） |

只装 Command Line Tools 就能完成构建（不需要 Xcode），**唯一代价是设置菜单**，见下文。

## 标准构建

下面这组参数是唯一受支持的构建方式，记为「标准构建参数组」。

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

构建完成后从 `builddir/mkxp-z.aarch64` 取二进制。

- `-Dworkdir_current=true` 是**硬要求**：默认构建会把 cwd 改成可执行文件所在目录，
  游戏目录挂不上（`Scripts/fetch-mkxpz.sh` 会核对这一项）。
- `--buildtype=release` 已核实为 `optimization=3`、`debug=false`：**没有 `-g`，也没有 `-O0`**。
  其余最终值（读 `builddir/meson-info/intro-buildoptions.json` 得到）：
  `strip=false`、`b_ndebug=false`（断言保留）、`b_lto=false`、`iconv_system=enabled`。
- `-Dwrap_mode=forcefallback` 让 Ruby 3.1.3 / ANGLE / SDL2 / OpenSSL 等全部走 subprojects
  源码构建，产物 `otool -L` 里第三方 dylib 计数为 **0**。
- `-Dstrip=true` 是 meson 内置选项，但它**只在 `meson install` 时生效**；本仓库直接消费
  builddir 里的二进制，所以 strip 放在构建之后单独做（下一节）。

## 构建后处理：strip + ad-hoc 重签

上游产物带 **137,139 个符号**，`__LINKEDIT` 占 8,339,456 B（其中 `LC_SYMTAB` 6,777,728 B），
是分发体积里最大的一块非代码数据。构建后必须先 strip 再签名：

```sh
strip builddir/mkxp-z.aarch64          # 无参数 = 删掉 dyld 不需要的全部符号
codesign -s - --force --identifier org.mkxp-z.runtime builddir/mkxp-z.aarch64
```

实测（arm64，同一构建；后两行的字节数含 strip 后的 ad-hoc 重签）：

| 阶段 | 字节 | `__LINKEDIT` | 符号数（`nm -a`） | 备注 |
| --- | --- | --- | --- | --- |
| 未 strip | 42,075,536 | 8,339,456 | 137,139 | 上游 ninja 产物 |
| `strip -x -S` | 37,175,584 | 3,440,640 | 30,499 | 只去局部符号，保留全局符号名 |
| `strip`（全量） | **35,448,032** | 1,703,936 | 1,929 | 等价 Xcode 的 Strip Style = All Symbols |

- 分发用**全量 `strip`**：省 6,627,504 B（−15.8%）。`strip -x -S` 只省 4,899,952 B，
  多出来的 1.7 MB 是全局符号名；保留它们对运行没有帮助。
- `strip` 会作废已有签名（实测：strip 后不重签直接运行，进程立即消失、日志为空），
  所以顺序固定为 **strip → ad-hoc 重签**；`Scripts/fetch-mkxpz.sh` 已固化这两步。
- **不要用 upx**：macOS 上会破坏代码签名，且被杀软误报。
- stderr 里的 `strip: warning: changes being made to the file will invalidate the code signature`
  是预期的，不是失败。

复算方法（仓库根执行；把路径换成 `builddir/mkxp-z.aarch64` 即得上表「未 strip」一行）：

```sh
nm -a vendor/runtime/mkxp-z 2>/dev/null | wc -l    # 1929
size -m vendor/runtime/mkxp-z | grep __LINKEDIT    # Segment __LINKEDIT: 1703936
stat -f%z vendor/runtime/mkxp-z                    # 35448032
```

对未 strip 的产物，同样三条命令得到 `137139` / `Segment __LINKEDIT: 8339456` / `42075536`。
`size` 的 `-m` 不能省：只给 `-l` 时会打印 `__TEXT/__DATA/__OBJC/others` 汇总表，不列段名
（`-l` 只是 `-m` 的修饰符）；需要交叉核对时用 `size -m -l …` 会额外给出 fileoff。

## 设置菜单为什么不可用（假 `ibtool` 桩）

`macos/views/meson.build` 用 `ibtool --compile` 把 `settingsmenu.xib` 编成
`settingsmenu.nib`，再 xxd 成 `settingsmenu.nib.xxd` 嵌入二进制
（`mkxp_macos_settingsmenu_nib`）。`ibtool` **只有完整 Xcode 才有**，Command Line Tools 没有。

没有 Xcode 时的绕法：在 PATH 前面放一个假 `ibtool`，把 `--compile` 的目标写成 8 字节桩：

```sh
mkdir -p /tmp/fakebin
cat > /tmp/fakebin/ibtool <<'EOF'
#!/bin/sh
# 找到 --compile 后面的输出路径，写 8 字节桩
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "--compile" ] && out="$a"
  prev="$a"
done
[ -n "$out" ] && printf 'FAKE-NIB' > "$out"
exit 0
EOF
chmod +x /tmp/fakebin/ibtool
PATH=/tmp/fakebin:$PATH meson setup builddir . \
  ‹上面「标准构建」一节的完整 -D* 参数组，必须原样带上›
```

**别只写 `meson setup builddir .`。** 漏掉 `-Dworkdir_current=true` 会让产物把 cwd 改回
可执行文件所在目录，挂载根错位，启动即看不到游戏数据；`Scripts/fetch-mkxpz.sh` 的
`check_workdir_current()` 会拦下这种产物。

后果：`macos/views/SettingsMenuController.mm:96-100` 用
`[[NSNib alloc] initWithNibData:...]` 加载这 8 个字节，返回 nil 后抛
`could not load settingsmenu.nib`（`NSInternalInconsistencyException`）。
**游戏启动、渲染、输入、事件解释器都不受影响**；只有运行中按 **F1**（`settingsmenu.cpp`
里的 `SDL_SCANCODE_F1`）想调出 Keybindings 窗口时会失败。

自查一个二进制是不是桩版本：

```sh
strings builddir/mkxp-z.aarch64 | grep -c FAKE-NIB   # >0 = 桩版本
```

### 有真 Xcode 时怎么让设置菜单可用

1. 装完整 Xcode（不是 CLT），确认 `ibtool` 是真的：

   ```sh
   export PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH"
   which ibtool && ibtool --version     # 应打印 Xcode 的 ibtool 版本
   ```

   或者 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。

2. **删掉 builddir 重新 `meson setup`**。不能只 `ninja`：`settingsmenu.nib` 是
   `custom_target`，旧输出还在，且 `find_program('ibtool')` 的解析结果已固化进
   `build.ninja`。要重跑就得新建 builddir（或至少删掉
   `builddir/macos/views/settingsmenu.nib*` 后 `meson setup --reconfigure`）。

3. `ninja -C builddir`，然后确认桩已消失：

   ```sh
   strings builddir/mkxp-z.aarch64 | grep -c FAKE-NIB   # 必须是 0
   ```

4. 运行游戏，按 **F1** 应弹出标题为 `Keybindings` 的窗口（`SettingsMenuController.mm`
   里 `win.title = @"Keybindings"`）。这是唯一可靠的验收方式：nib 加载失败会抛异常，
   成功则窗口可见。

5. 把新二进制换进分发流程（会重新 strip + 重签 + 更新 `.sha256`）：

   ```sh
   MKXPZ_BINARY=/path/to/builddir/mkxp-z.aarch64 bash Scripts/fetch-mkxpz.sh --force
   ```

替代方案（未做）：在有 Xcode 的机器上生成一次 `settingsmenu.nib` 入库，把
`macos/views/meson.build` 里那个 `custom_target` 换成 `copy`，这样 CLT 机器也能编出
带可用设置菜单的二进制。

## 本地补丁（GPL-2.0-or-later 合规所需）

`mochibox-macos-fixes.patch` 是相对上面的 commit 的全部改动：

1. `src/filesystem/filesystem.cpp` — `iconv_open("utf-8-mac")` 失败时
   `(iconv_t)-1` 被直接喂给 `iconv()`，`createPathCache` 阶段 SIGSEGV；
   同时给 `PHYSFS_stat` 补失败分支。**这是"接上就崩"的根因。**
2. `src/filesystem/filesystemImplApple.mm` — 路径归一化在 `/tmp → /private/tmp`
   这类符号链接下会漏掉 cwd 前缀。
3. `src/display/font.cpp` — 字体回退（缺 MS Gothic 等日文字体时不再整段丢字）。

分发二进制时必须能拿到这份补丁 + 上述 build recipe —— 就是本文件。

## 复现与验收

```sh
# 1) 构建 + strip + 重签 + 写入 .sha256
MKXPZ_BINARY=/path/to/builddir/mkxp-z.aarch64 bash Scripts/fetch-mkxpz.sh --force

# 2) 体积与符号
stat -f%z vendor/runtime/mkxp-z                  # 35,448,032
nm -a vendor/runtime/mkxp-z | wc -l              # 1,929

# 3) 零第三方动态库
otool -L vendor/runtime/mkxp-z | grep -c /opt/homebrew   # 0

# 4) 签名
codesign --verify --strict vendor/runtime/mkxp-z

# 5) 真启动（app 侧）
./build/MochiBox.app/Contents/MacOS/MochiBox --play-native <XP 游戏目录> --duration 6
#   期望: play: backend=mkxpz pid=<n>，且 6 秒内不出现 backend_exit ... early=1
```
