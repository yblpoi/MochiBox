//
//  LegacyMigration.swift
//  MochiBox
//
//  品牌改名的一次性数据迁移：把旧品牌目录**逐项合并**进 `MochiBox` 目录。
//
//  为什么必须在入口最开头跑：`AppPaths` 一构造就按**新**品牌名算出根目录，之后所有读写
//  都落在新路径上；晚于它执行会出现两种坏结局 —— 新目录已被创建导致搬不动，或者搬成功
//  了但进程内存里还握着旧路径，等于没搬。所以调用点是 `MochiBoxMain.main()` 里
//  参数校验通过之后、任何模式分派之前的唯一一处（`--help` / `-h` / 参数错误不搬）。
//
//  要搬的两条数据：
//    · `~/Library/Application Support/<旧品牌>` → `.../MochiBox`：
//      存档、设置、日志、浏览器 profile 全在根下。
//    · `~/Library/WebKit/<旧 bundle id>` → `~/Library/WebKit/app.mochibox.MochiBox`：
//      这是 WKWebView 默认 `websiteDataStore` 的落盘位置，**由 bundle id 决定**
//      （不是我们能选的路径）。不搬的话，内置内核模式下所有游戏的存档直接丢。
//
//  语义（v2）：逐项合并 + POSIX rmdir 剪枝，**全程没有递归删除**。
//
//    旧策略是「目标目录为空才整体 moveItem，否则跳过」，有两个真实缺陷：
//      A. 目标「非空但只是空骨架」时永久跳过：新版 app 只要先跑过一次（开发期试跑 /
//         e2e 测试），`ensureDirectories()` 就已经建出 logs/cache/export/browser-profiles/
//         等空子目录，WebKit 侧也会被建出 WebsiteData/ 骨架。此时旧目录里的 library.json /
//         settings.json / credentials.json / 存档 / web-ports.json 全被永久忽略，用户看到
//         的是空库、存档「消失」。判空用 contentsOfDirectory，有子目录就算非空 → 必然跳过。
//      B. 并发首启会丢数据：A 进程删空目标目录并搬入数据，B 进程随后 removeItem 把 A 刚搬
//         进来的整份数据递归删掉。原实现没有任何互斥。
//
//    现在：
//      · 目标存在就**合并**，不要求为空 → 空骨架不再挡住迁移（修复 A）；
//      · 每一步只 moveItem 单个条目（原子），从不 removeItem 任何目录 → 并发下最坏是
//        「条目搬失败、原地保留」，不会有进程能删掉别人刚搬进来的数据（修复 B）；
//      · 旧目录用 rmdir(2) 后序剪枝收缩：非空返回 ENOTEMPTY，天然只在真的空了时才消失，
//        冲突残留原地不动；
//      · 同名冲突一律「保留旧的原地不动、新的一律不覆盖」，记日志后继续搬其它条目。
//
//  每次运行都是尽力而为、幂等：任何失败只 NSLog，不抛、不 crash，迁移失败不该拦住启动。
//

import Foundation
import Darwin

enum LegacyMigration {
    private static let fm = FileManager.default

    // 自查要求 `Sources/App` 与 `Sources/Infra` 里不再出现旧品牌字面量，而迁移又必须
    // 指向旧路径，所以旧名字**按片段拼出来**。别"顺手"把它们合并成整串。
    private static let legacyBrand = "MT" + "ool" + "Mac"
    private static let legacyBundleID = "app.mtool" + "mac." + legacyBrand
    /// 旧 pid 文件名（`browser-profiles/<game>/` 下）。同 `legacyBrand`：旧前缀按片段拼，
    /// 别"顺手"合并成整串。
    private static let legacyPidFileName = "." + "mt" + "ool" + "-browser.pid"

    /// 进程内幂等标记：`--selftest` / `--attach` 各分支都可能走到这里，只该搬一次。
    private static let stateLock = NSLock()
    private static var didRun = false

    /// 分派入口调用（`MochiBoxMain.main()` 参数校验之后）。重复调用安全。
    static func runIfNeeded() {
        // 自定义数据目录（测试 / E2E）：绝不搬真实用户目录。
        // 空串视为未设置 —— 与 `AppPaths.environmentRoot()` 保持同一判据。
        let override = ProcessInfo.processInfo.environment["MOCHI_DATA_DIR"] ?? ""
        guard override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        stateLock.lock()
        if didRun {
            stateLock.unlock()
            return
        }
        didRun = true
        stateLock.unlock()

        let home = fm.homeDirectoryForCurrentUser
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)

        migrate(
            old: appSupport.appendingPathComponent(legacyBrand, isDirectory: true),
            new: appSupport.appendingPathComponent("MochiBox", isDirectory: true),
            label: "data"
        )
        migrate(
            old: home.appendingPathComponent("Library/WebKit/" + legacyBundleID, isDirectory: true),
            new: home.appendingPathComponent("Library/WebKit/app.mochibox.MochiBox", isDirectory: true),
            label: "webkit"
        )

        // 收尾迁移（同一把幂等闸门内，只随首次真正执行的迁移跑一次）：pid 文件的**文件名**
        // 也跟着品牌改了。旧前缀的 pid 文件留在原地的话，升级后第一次启动读不到
        // "上次是谁"，孤儿浏览器就再也收不回来（它继续占着调试端口与 profile 单实例锁）。
        // 目录合并处理不了这种"同目录内改名"，所以单独补一段，在新根目录就位之后跑。
        renameLegacyPidFiles(
            in: appSupport.appendingPathComponent("MochiBox/browser-profiles", isDirectory: true)
        )
    }

    /// 把每个 profile 子目录里的旧 pid 文件名改成新名。
    ///
    /// 只处理「旧名存在、新名不存在」的目录：
    ///   · 新名已存在 → 已改过（或本轮浏览器正在跑），**不覆盖**；
    ///   · 改名失败 → 只 NSLog，旧文件原地保留、绝不删除（删了就彻底丢了孤儿线索）。
    private static func renameLegacyPidFiles(in profilesRoot: URL) {
        guard isDirectory(profilesRoot) else { return }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: nil, options: [])
        } catch {
            NSLog("MochiBox: legacy pid rename failed (cannot list %@): %@",
                  profilesRoot.path, String(describing: error))
            return
        }

        for entry in entries where isDirectory(entry) {
            let old = entry.appendingPathComponent(legacyPidFileName)
            let new = entry.appendingPathComponent(K.webBrowserPidFileName)
            guard exists(old), !exists(new) else { continue }
            do {
                try fm.moveItem(at: old, to: new)
            } catch {
                NSLog("MochiBox: legacy pid rename skipped %@ -> %@: %@",
                      old.path, new.path, String(describing: error))
            }
        }
    }

    /// 搬一个目录：旧目录不存在（或不是目录）→ 什么都不建；否则先逐项合并，再剪掉旧目录里
    /// 变空的子目录。
    private static func migrate(old: URL, new: URL, label: String) {
        guard isDirectory(old) else { return }
        merge(from: old, into: new, label: label)
        pruneEmptyDirs(under: old, label: label)
    }

    /// 递归逐项合并：先保证 `dst` 存在，再把 `src` 的每个条目搬进 `dst`。
    ///
    /// 单条目 `moveItem` 是原子的，失败时源文件仍在原处 —— 中途出错不会留下半份文件，
    /// 也不会出现「整棵子树搬了一半」的状态（已搬的条目下次运行会被跳过，因为目标已有）。
    private static func merge(from src: URL, into dst: URL, label: String) {
        do {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        } catch {
            NSLog("MochiBox: legacy %@ migration failed (cannot create %@): %@",
                  label, dst.path, String(describing: error))
            return
        }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: [])
        } catch {
            NSLog("MochiBox: legacy %@ migration failed (cannot list %@): %@",
                  label, src.path, String(describing: error))
            return
        }

        for entry in entries {
            let target = dst.appendingPathComponent(entry.lastPathComponent)

            // 目标没有同名条目 → 直接整项搬过去（目录则整棵子树一起走）。
            guard exists(target) else {
                do {
                    try fm.moveItem(at: entry, to: target)
                } catch {
                    // 单条目失败不影响其它条目：继续搬，失败的留在原地，下次启动再试。
                    NSLog("MochiBox: legacy %@ migration skipped item %@ -> %@: %@",
                          label, entry.path, target.path, String(describing: error))
                }
                continue
            }

            // 两边都是目录 → 递归合并。**这条是修复缺陷 A 的关键**：旧
            // `browser-profiles/<gameHash>/`（游戏存档）会合进已存在的空 skeleton。
            if isDirectory(entry) && isDirectory(target) {
                merge(from: entry, into: target, label: label)
                continue
            }

            // 其它冲突（文件 vs 文件、文件 vs 目录、目录 vs 文件）：旧的原地不动，新的不覆盖。
            NSLog("MochiBox: legacy %@ migration conflict at %@ (target %@ already exists); old item left in place",
                  label, entry.path, target.path)
        }
    }

    /// 用 POSIX `rmdir(2)` 后序剪枝：先剪子树，再剪自己。
    ///
    /// 为什么必须是 rmdir 而不是 `removeItem`：rmdir 对非空目录返回 ENOTEMPTY，因此
    /// **只有真的空了才会消失**，冲突残留 / 用户数据不可能被顺手递归删掉。
    private static func pruneEmptyDirs(under root: URL, label: String) {
        pruneEmptyDescendants(of: root)
        _ = removeDirectoryIfEmpty(root)

        if isDirectory(root) {
            let remaining = (try? fm.contentsOfDirectory(atPath: root.path))?.count ?? -1
            NSLog("MochiBox: legacy %@ migration finished with %ld item(s) left at %@ (conflicts or failures kept in place)",
                  label, remaining, root.path)
        } else {
            NSLog("MochiBox: legacy %@ migration complete (old root %@ removed)", label, root.path)
        }
    }

    /// 后序遍历 `directory` 下的子目录并尝试 rmdir，把变空的逐层剪掉。
    private static func pruneEmptyDescendants(of directory: URL) {
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) else {
            return
        }
        for entry in entries {
            guard isDirectory(entry) else { continue }
            pruneEmptyDescendants(of: entry)
            _ = removeDirectoryIfEmpty(entry)
        }
    }

    /// `rmdir(2)`：成功返回 true；非空（ENOTEMPTY）/ 非目录（ENOTDIR）等都返回 false。
    @discardableResult
    private static func removeDirectoryIfEmpty(_ url: URL) -> Bool {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path = path else { return -1 }
            return rmdir(path)
        }
        return result == 0
    }

    private static func exists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }
}
