//
//  probe_store.swift
//  MochiBox · E2E 领域层探针（持久化 / 脱敏 / 日志 / 缓存容量）
//
//  一支探针覆盖 D1 / D2 / D3 / D4 / D7，用 --only Dn 只跑对应段：
//  domain 层的每个 case 都是独立子进程，只跑自己那一段，编号互不干扰。
//
//  依据（期望值一律来自这里，不是"跑出来是什么就写什么"）：
//   · P0-04  library.json 字段不变、missing、损坏改名 library.json.bak-<ts>
//   · P0-20  settings.json 原子写、字段缺失/类型非法回落默认、写失败不破坏旧文件
//   · P0-12  apiKey 脱敏为 sk-…后4位；settings.json/credentials.json 0600
//   · P0-19  logs/session-yyyyMMdd-HHmmss.log；保留份数 = K.logRetentionCount
//   · P0-10  缓存超限按最久未用淘汰并把条数写进日志；命中率 = 命中/(命中+新译)
//
//  不验：目录移走后自动打 missing 由 SessionController.refreshMissingFlags()（private，
//  需 AppState）实现，本层无法驱动 —— 见 COVERAGE.md 的 GAP-P0-04。
//

import Foundation

@main
struct DomainStoreProbe {
    static func main() async {
        let args = ProbeArgs()
        let root = args.root
        Fs.make(root)

        switch args.only {
        case "D1": await d1(root)
        case "D2": d2(root)
        case "D3": d3(root)
        case "D4": d4(root)
        case "D7": await d7(root)
        default: TAP.ok("probe", "未知 --only 参数", false, "only=\(args.only)")
        }
        exit(TAP.finish())
    }

    // MARK: - D1 库持久化（P0-04）

    static func d1(_ root: URL) async {
        let dir = root.appendingPathComponent("library", isDirectory: true)
        Fs.make(dir)
        let url = dir.appendingPathComponent("library.json")
        let store = LibraryStore(url: url)

        let alpha = GameEntry(
            id: "id-a", name: "游戏甲", path: "/games/alpha", engine: .mv,
            engineConfidence: .high, engineEvidence: ["www/data", "js/rpg_core.js"],
            supportLevel: .p0, reason: nil, addedAt: 1_700_000_000_000,
            lastLaunchedAt: nil, launchCount: 3, missing: false
        )
        let beta = GameEntry(
            id: "id-b", name: "游戏乙", path: "/games/beta", engine: .mz,
            engineConfidence: .medium, engineEvidence: ["js/rmmz_core.js"],
            supportLevel: .p0, reason: .noSignatureMatched, addedAt: 1_700_000_100_000,
            lastLaunchedAt: nil, launchCount: 0, missing: false
        )

        do {
            try store.save(LibraryFile(games: [alpha, beta]))
            TAP.ok("D1", "保存两条记录后 library.json 存在", FileManager.default.fileExists(atPath: url.path), url.path)
        } catch {
            TAP.ok("D1", "保存两条记录后 library.json 存在", false, "\(error)")
        }

        // 字段名也要对得上：P0-04 点名的就是 id/name/path/engine/addedAt。
        let object = Fs.json(url) ?? [:]
        TAP.eqInt("D1", "落盘 JSON 顶层 schemaVersion=1", (object["schemaVersion"] as? Int) ?? -1, 1)
        let rawGames = (object["games"] as? [[String: Any]]) ?? []
        TAP.eqInt("D1", "落盘 JSON games 数组有 2 条", rawGames.count, 2)
        let firstKeys = Set(rawGames.first?.keys.map { $0 } ?? [])
        let required = Set(["id", "name", "path", "engine", "addedAt"])
        TAP.ok("D1", "落盘条目含 id/name/path/engine/addedAt 五个字段",
               required.isSubset(of: firstKeys), "实际键: \(firstKeys.sorted().joined(separator: ","))")
        TAP.eqInt("D1", "library.json 权限为 0644（LibraryStore.save 显式传入）", Fs.mode(url), 0o644)

        let reloaded = store.load()
        TAP.eqInt("D1", "重新加载后条目数 = 2", reloaded.games.count, 2)
        TAP.eq("D1", "重新加载后顺序稳定（id 依次 id-a,id-b）",
               reloaded.games.map { $0.id }.joined(separator: ","), "id-a,id-b")

        if reloaded.games.count == 2 {
            let a = reloaded.games[0]
            TAP.ok("D1", "第 1 条 id/name/path/engine/addedAt 逐字段不变",
                   a.id == alpha.id && a.name == alpha.name && a.path == alpha.path
                   && a.engine == alpha.engine && a.addedAt == alpha.addedAt,
                   "实际: \(a.id)|\(a.name)|\(a.path)|\(a.engine.rawValue)|\(a.addedAt)")
            let b = reloaded.games[1]
            TAP.ok("D1", "第 2 条 id/name/path/engine/addedAt 逐字段不变",
                   b.id == beta.id && b.name == beta.name && b.path == beta.path
                   && b.engine == beta.engine && b.addedAt == beta.addedAt,
                   "实际: \(b.id)|\(b.name)|\(b.path)|\(b.engine.rawValue)|\(b.addedAt)")
            TAP.eqInt("D1", "第 1 条 launchCount 一并往返（不丢字段）", a.launchCount, 3)
        }

        // 文件缺失（首次启动）
        let emptyURL = dir.appendingPathComponent("absent/library.json")
        let absentStore = LibraryStore(url: emptyURL)
        let absent = absentStore.load()
        TAP.eqInt("D1", "文件不存在时 load 返回空库（首启不崩）", absent.games.count, 0)
        TAP.eqInt("D1", "空库 schemaVersion 仍为 1", absent.schemaVersion, 1)

        // 损坏 1：截断
        let truncated = "{\"schemaVersion\":1,\"games\":["
        Fs.write(truncated, to: url)
        let beforeData = FileIO.readData(url) ?? Data()
        let afterTruncated = store.load()
        TAP.eqInt("D1", "library.json 截断 → 以空库启动", afterTruncated.games.count, 0)

        let names = Fs.names(dir)
        let backups = names.filter { $0.hasPrefix("library.json.bak-") }
        TAP.eqInt("D1", "截断损坏 → 生成 1 个 library.json.bak-<ts> 备份", backups.count, 1)
        if let backup = backups.first {
            let stamp = String(backup.dropFirst("library.json.bak-".count))
            TAP.ok("D1", "备份名时间戳形状为 yyyyMMdd-HHmmss",
                   stamp.range(of: "^[0-9]{8}-[0-9]{6}$", options: .regularExpression) != nil, "stamp=\(stamp)")
            let backupData = FileIO.readData(dir.appendingPathComponent(backup)) ?? Data()
            TAP.ok("D1", "备份内容 = 损坏前的原始字节（保留证据，不静默丢弃）",
                   backupData == beforeData, "备份 \(backupData.count) 字节，原始 \(beforeData.count) 字节")
        }
        TAP.ok("D1", "损坏后原路径 library.json 已被移走", !FileManager.default.fileExists(atPath: url.path))

        // 损坏 2：非法 JSON。备份名只精确到秒（Timestamp.fileStamp），
        // 等过一秒再制造第二次损坏，才是"两次损坏各留一份备份"的 PRD 语义；
        // 同秒两次会命中同名备份并覆盖（已作为缺陷 F-2 记录，不在此断言）。
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        Fs.write("this is definitely not json", to: url)
        let afterGarbage = store.load()
        TAP.eqInt("D1", "非法 JSON → 以空库启动", afterGarbage.games.count, 0)
        TAP.eqInt("D1", "非法 JSON → 又生成 1 个备份（累计 2）",
                  Fs.names(dir).filter { $0.hasPrefix("library.json.bak-") }.count, 2)

        // 同秒内连续两次损坏：每一次都要留下一份证据，备份名不得互相覆盖。
        // （旧实现先 removeItem 再 moveItem，同秒第二次会删掉上一份备份。）
        let rapidDir = root.appendingPathComponent("library-rapid", isDirectory: true)
        Fs.make(rapidDir)
        let rapidURL = rapidDir.appendingPathComponent("library.json")
        let rapidStore = LibraryStore(url: rapidURL)
        Fs.write("rapid-corrupt-A", to: rapidURL)
        TAP.eqInt("D1", "同秒损坏 #1 → 空库启动", rapidStore.load().games.count, 0)
        Fs.write("rapid-corrupt-B", to: rapidURL)
        TAP.eqInt("D1", "同秒损坏 #2 → 空库启动", rapidStore.load().games.count, 0)
        let rapidBackups = Fs.names(rapidDir).filter { $0.hasPrefix("library.json.bak-") }
        TAP.eqInt("D1", "同秒连续两次损坏 → 留 2 份备份（不覆盖）", rapidBackups.count, 2)
        let rapidContents = Set(rapidBackups.compactMap { name -> String? in
            FileIO.readData(rapidDir.appendingPathComponent(name)).flatMap { String(data: $0, encoding: .utf8) }
        })
        TAP.eq("D1", "两份备份内容分别是 A/B（第一份未被覆盖）",
               rapidContents.sorted().joined(separator: "|"), "rapid-corrupt-A|rapid-corrupt-B")

        // 目录被移走：条目必须还在（P0-04 前半句；自动打 missing 见 GAP-P0-04）
        let missingDir = root.appendingPathComponent("library-missing", isDirectory: true)
        Fs.make(missingDir)
        let missingURL = missingDir.appendingPathComponent("library.json")
        let missingStore = LibraryStore(url: missingURL)
        let goneDir = root.appendingPathComponent("games/gone", isDirectory: true)
        Fs.make(goneDir)
        let goneEntry = GameEntry(
            id: "id-gone", name: "已移走的游戏", path: goneDir.path, engine: .mz,
            engineConfidence: .high, engineEvidence: ["js/rmmz_core.js"],
            supportLevel: .p0, reason: nil, addedAt: 1_700_000_200_000
        )
        try? missingStore.save(LibraryFile(games: [goneEntry]))
        try? FileManager.default.removeItem(at: goneDir)
        let afterMove = missingStore.load()
        TAP.eqInt("D1", "游戏目录被移走后条目仍在（不自动删除）", afterMove.games.count, 1)
        TAP.eq("D1", "被移走的条目 id/path 原样保留",
               afterMove.games.first.map { $0.id + "|" + $0.path } ?? "-",
               "id-gone|" + goneDir.path)

        // missing 标记本身可落盘（UI 靠它置灰 + 禁止启动）
        var flagged = goneEntry
        flagged.missing = true
        try? missingStore.save(LibraryFile(games: [flagged]))
        let afterFlag = missingStore.load()
        TAP.ok("D1", "missing=true 经落盘/加载后保持",
               afterFlag.games.first?.missing == true, "实际: \(String(describing: afterFlag.games.first?.missing))")
        TAP.ok("D1", "missing=true 的条目 isLaunchable=false（P0-04 标记的可观测后果）",
               afterFlag.games.first?.isLaunchable == false)
    }

    // MARK: - D2 设置持久化（P0-20 / P0-12）

    static func d2(_ root: URL) {
        let dir = root.appendingPathComponent("settings", isDirectory: true)
        Fs.make(dir)
        let settingsURL = dir.appendingPathComponent("settings.json")
        let credentialsURL = dir.appendingPathComponent("credentials.json")
        let log = SessionLog(directory: dir.appendingPathComponent("logs"), sessionId: "d2probe01")
        let store = SettingsStore(settingsURL: settingsURL, credentialsURL: credentialsURL, log: log)

        var settings = Settings()
        settings.fontScale = 1.25
        settings.model = "gpt-x"
        settings.endpoint = "http://127.0.0.1:9"
        settings.maxBatch = 7
        settings.timeoutSec = 20
        settings.dataPatchNames = false
        do {
            try store.saveSettings(settings)
            TAP.ok("D2", "saveSettings 后 settings.json 存在", FileManager.default.fileExists(atPath: settingsURL.path))
        } catch {
            TAP.ok("D2", "saveSettings 后 settings.json 存在", false, "\(error)")
        }

        let object = Fs.json(settingsURL) ?? [:]
        TAP.ok("D2", "settings.json 是可完整解析的 JSON 对象", !object.isEmpty)
        TAP.eq("D2", "settings.json 写入 model/maxBatch/fontScale",
               "\(object["model"] as? String ?? "-")|\(object["maxBatch"] as? Int ?? -1)|\(object["fontScale"] as? Double ?? -1)",
               "gpt-x|7|1.25")
        TAP.ok("D2", "原子写不残留 *.tmp-* 临时文件", !Fs.hasTempResidue(dir), Fs.names(dir).joined(separator: ","))

        let roundTrip = store.loadSettings()
        TAP.eq("D2", "保存 → 加载：fontScale/model/endpoint/maxBatch/timeoutSec 不变",
               "\(roundTrip.fontScale)|\(roundTrip.model)|\(roundTrip.endpoint)|\(roundTrip.maxBatch)|\(roundTrip.timeoutSec)",
               "1.25|gpt-x|http://127.0.0.1:9|7|20")
        TAP.ok("D2", "保存 → 加载：dataPatchNames=false 原样保留、dataPatchEnabled=true",
               roundTrip.dataPatchNames == false && roundTrip.dataPatchEnabled == true,
               "names=\(roundTrip.dataPatchNames) enabled=\(roundTrip.dataPatchEnabled)")

        // 字段缺失
        Fs.write("{\"fontScale\":1.1}", to: settingsURL)
        let partial = store.loadSettings()
        TAP.eq("D2", "字段缺失：存在的 fontScale 保留 1.1", "\(partial.fontScale)", "1.1")
        TAP.eq("D2", "字段缺失：model 回落默认 gpt-4o-mini", partial.model, "gpt-4o-mini")
        TAP.eqInt("D2", "字段缺失：timeoutSec 回落默认 15", partial.timeoutSec, K.requestTimeoutSec)
        TAP.ok("D2", "字段缺失：backendType 回落 passthrough", partial.backendType == .passthrough)
        TAP.eq("D2", "字段缺失：srcLang 仍为 ja（P0 固定）", partial.srcLang, K.fixedSrcLang)
        // 老 settings.json 没有数据回写开关：必须当 true 处理，不能因为缺键让整份设置解码失败。
        TAP.ok("D2", "字段缺失：dataPatchEnabled／dataPatchNames 缺键回落 true",
               partial.dataPatchEnabled == true && partial.dataPatchNames == true,
               "enabled=\(partial.dataPatchEnabled) names=\(partial.dataPatchNames)")

        // 类型非法
        Fs.write("{\"fontScale\":\"abc\",\"maxBatch\":\"abc\",\"agentEnabled\":\"yes\",\"endpoint\":123}", to: settingsURL)
        let invalid = store.loadSettings()
        TAP.eq("D2", "fontScale 类型非法 → 回落 1.0（不抛错）", "\(invalid.fontScale)", "1.0")
        TAP.eqInt("D2", "maxBatch 类型非法 → 回落默认（K.maxBatch）", invalid.maxBatch, K.maxBatch)
        TAP.ok("D2", "agentEnabled 类型非法 → 回落 true", invalid.agentEnabled == true)
        TAP.eq("D2", "endpoint 类型非法 → 回落空串", invalid.endpoint, "")

        // 存量迁移（schemaVersion < 2）：旧文件写死的 20/2 必须迁到新默认，
        // 否则"只改声明默认值"对已有用户提速为 0（他们文件里存的就是旧值）。
        Fs.write("{\"schemaVersion\":1,\"maxBatch\":7,\"maxConcurrent\":2}", to: settingsURL)
        let migrated = store.loadSettings()
        TAP.eqInt("D2", "schemaVersion=1 → 版本抬到 2", migrated.schemaVersion, 2)
        TAP.eqInt("D2", "schemaVersion=1 → maxBatch 迁到新默认", migrated.maxBatch, K.maxBatch)
        TAP.eqInt("D2", "schemaVersion=1 → maxConcurrent 迁到新默认", migrated.maxConcurrent, K.maxConcurrent)

        // 新 schema 下用户自己改过的值必须原样保留（迁移只发生一次）。
        Fs.write("{\"schemaVersion\":2,\"maxBatch\":7,\"maxConcurrent\":3}", to: settingsURL)
        let keptValues = store.loadSettings()
        TAP.eq("D2", "schemaVersion=2 保留用户值（7|3）",
               "\(keptValues.maxBatch)|\(keptValues.maxConcurrent)", "7|3")

        // 缺 schemaVersion = v1 之前的旧文件：必须当 1 处理并执行迁移。
        // 若沿用 tolerantValue 的默认 2，缺键文件会被误判为"已迁移"，写死的 20/2 原样留下。
        Fs.write("{\"maxBatch\":20,\"maxConcurrent\":2}", to: settingsURL)
        let versionless = store.loadSettings()
        TAP.eqInt("D2", "无 schemaVersion → 视为 1 并抬到 2", versionless.schemaVersion, 2)
        TAP.eq("D2", "无 schemaVersion（20|2）→ 迁到 60|4",
               "\(versionless.maxBatch)|\(versionless.maxConcurrent)",
               "\(K.maxBatch)|\(K.maxConcurrent)")

        // 迁移只碰 maxBatch/maxConcurrent，同一份旧文件里的其它自定义值必须原样保留。
        Fs.write("{\"maxBatch\":20,\"maxConcurrent\":2,\"model\":\"my-model\",\"timeoutSec\":33}", to: settingsURL)
        let versionlessKept = store.loadSettings()
        TAP.eq("D2", "无 schemaVersion + 自定义 model/timeout → 原样保留",
               "\(versionlessKept.model)|\(versionlessKept.timeoutSec)|\(versionlessKept.maxBatch)|\(versionlessKept.maxConcurrent)",
               "my-model|33|\(K.maxBatch)|\(K.maxConcurrent)")

        // 新字段：缺失回落 4000/0，越界按 normalized() 夹取。
        Fs.write("{\"schemaVersion\":2,\"batchCharBudget\":1,\"maxOutputTokens\":99999}", to: settingsURL)
        let clampedNew = store.loadSettings()
        TAP.eq("D2", "batchCharBudget=1 → 500；maxOutputTokens=99999 → 32768",
               "\(clampedNew.batchCharBudget)|\(clampedNew.maxOutputTokens)", "500|32768")
        Fs.write("{\"schemaVersion\":2}", to: settingsURL)
        let defaultNew = store.loadSettings()
        TAP.eq("D2", "新字段缺失 → 回落 4000|0",
               "\(defaultNew.batchCharBudget)|\(defaultNew.maxOutputTokens)", "4000|0")

        // 越界回落 + 告警日志（P0-20：「记一条日志」）
        Fs.write("{\"fontScale\":9.0,\"timeoutSec\":9999,\"maxCacheEntries\":5}", to: settingsURL)
        let clamped = store.loadSettings()
        TAP.eq("D2", "fontScale=9.0 越界 → 1.3", "\(clamped.fontScale)", "1.3")
        TAP.eqInt("D2", "timeoutSec=9999 越界 → 120", clamped.timeoutSec, 120)
        TAP.eqInt("D2", "maxCacheEntries=5 越界 → 100（normalized 下限）", clamped.maxCacheEntries, 100)
        let logPath = log.fileURL ?? dir.appendingPathComponent("none")
        log.close()
        let logText = Fs.text(logPath)
        TAP.ok("D2", "越界回落写进会话日志（fontScale=9.0）", logText.contains("fontScale=9.0"),
               logText.split(separator: "\n").suffix(6).joined(separator: " / "))
        TAP.ok("D2", "越界回落写进会话日志（timeoutSec=9999）", logText.contains("timeoutSec=9999"))

        // config 信封：两个新开关必须真的随 config 下发（Agent 只认信封里的字段，
        // 光在 AgentConfig 上加属性而漏掉 jsonText 的 payload，等于永远不下发）。
        let cfg = AgentConfig(enabled: true, dataPatchEnabled: false, dataPatchNames: false)
        let cfgJSON = (try? HostCommand.config(cfg).jsonText()) ?? ""
        TAP.ok("D2", "config 信封带上 dataPatchEnabled／dataPatchNames",
               cfgJSON.contains("\"dataPatchEnabled\":false") && cfgJSON.contains("\"dataPatchNames\":false"),
               cfgJSON)

        // 文件损坏
        Fs.write("not json", to: settingsURL)
        let corrupt = store.loadSettings()
        TAP.ok("D2", "settings.json 损坏 → 用默认值且不抛错",
               corrupt.fontScale == 1.0 && corrupt.model == "gpt-4o-mini" && corrupt.backendType == .passthrough,
               "fontScale=\(corrupt.fontScale) model=\(corrupt.model)")

        // 写失败（目录只读）：旧文件不能被破坏
        let readonly = root.appendingPathComponent("settings-readonly", isDirectory: true)
        Fs.make(readonly)
        let roURL = readonly.appendingPathComponent("settings.json")
        let roStore = SettingsStore(settingsURL: roURL, credentialsURL: readonly.appendingPathComponent("credentials.json"))
        var good = Settings()
        good.fontScale = 1.15
        good.model = "keep-me"
        try? roStore.saveSettings(good)

        if getuid() == 0 {
            TAP.skip("D2", "目录只读时写失败不破坏旧文件", "以 root 运行，chmod 拦不住写入")
        } else {
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonly.path)
            var bad = Settings()
            bad.fontScale = 1.3
            bad.model = "should-not-land"
            var code = ""
            do {
                try roStore.saveSettings(bad)
            } catch let error as MochiBoxError {
                code = error.code.rawValue
            } catch {
                code = "非 MochiBoxError: \(error)"
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonly.path)
            TAP.eq("D2", "目录只读时 saveSettings 抛 io_error", code, "io_error")
            let kept = roStore.loadSettings()
            TAP.eq("D2", "写失败后旧 settings.json 仍可读且内容未变（model=keep-me）", kept.model, "keep-me")
            TAP.eq("D2", "写失败后旧 settings.json 的 fontScale 仍为 1.15", "\(kept.fontScale)", "1.15")
            TAP.ok("D2", "写失败不残留临时文件", !Fs.hasTempResidue(readonly), Fs.names(readonly).joined(separator: ","))
        }
    }

    // MARK: - D3 脱敏（P0-12）

    static func d3(_ root: URL) {
        let masked = SecretMask.mask("apiKey=sk-abcdef123456")
        TAP.eq("D3", "sk-abcdef123456 脱敏为 sk-…3456", masked, "apiKey=sk-…3456")
        // 短 key：sk- 后不足 8 字符也必须脱敏（正则不再要求 ≥8，兜底 *** 才走得到）。
        TAP.eq("D3", "短 sk- key 一律脱敏（sk-abc → ***）",
               SecretMask.mask("apiKey=sk-abc"), "apiKey=***")
        TAP.eq("D3", "短 sk- key 出现在句首同样脱敏", SecretMask.mask("sk-abc"), "***")
        TAP.ok("D3", "短 key 的原文片段不出现",
               !SecretMask.mask("apiKey=sk-abc").contains("sk-abc"))
        // 左边界：放开长度下限不能把普通单词里的 "sk-" 误伤成凭据。
        TAP.eq("D3", "普通单词 task-manager 不被打码（sk- 左边界）",
               SecretMask.mask("task-manager risk-list"), "task-manager risk-list")
        TAP.ok("D3", "脱敏后原文 key 片段不出现", !masked.contains("abcdef123456"), masked)
        TAP.ok("D3", "脱敏后完整 token 不出现", !masked.contains("sk-abcdef123456"), masked)

        TAP.eq("D3", "Bearer token 脱敏为 sk-…后4位（maskToken 同一出口）",
               SecretMask.mask("Authorization: Bearer abcdefghijklmnop"),
               "Authorization: sk-…mnop")
        TAP.eq("D3", "DeepL-Auth-Key 脱敏为 sk-…后4位",
               SecretMask.mask("Authorization: DeepL-Auth-Key 1234abcd"),
               "Authorization: sk-…abcd")
        TAP.eq("D3", "无触发词的文本原样返回", SecretMask.mask("hello 世界"), "hello 世界")
        TAP.eq("D3", "空串原样返回", SecretMask.mask(""), "")
        TAP.eq("D3", "mask 幂等（二次脱敏不再变化）",
               SecretMask.mask(SecretMask.mask("sk-abcdef123456")),
               SecretMask.mask("sk-abcdef123456"))

        // rawSnippet 在 MochiBoxError 构造时就脱敏（P0-12「导出诊断中 apiKey 一律脱敏」）
        let error = MochiBoxError(code: .badResponse, rawSnippet: "Authorization: Bearer abcdefghijklmnop")
        TAP.eq("D3", "MochiBoxError.rawSnippet 构造时已脱敏", error.rawSnippet ?? "-", "Authorization: sk-…mnop")

        // 日志落盘同样脱敏
        let dir = root.appendingPathComponent("mask", isDirectory: true)
        Fs.make(dir)
        let log = SessionLog(directory: dir, sessionId: "d3probe01")
        log.info("HTTP", "Authorization: Bearer abcdefghijklmnop apiKey=sk-abcdef123456")
        let logPath = log.fileURL ?? dir.appendingPathComponent("none")
        log.close()
        let text = Fs.text(logPath)
        TAP.ok("D3", "会话日志里出现脱敏后的 sk-…3456", text.contains("sk-…3456"), text)
        TAP.ok("D3", "会话日志里不出现明文 apiKey", !text.contains("abcdef123456"), text)
        TAP.ok("D3", "会话日志里不出现明文 Bearer token", !text.contains("abcdefghijklmnop"), text)

        // 权限落盘（P0-12）：文件由产品写，mode 由 case 侧用 stat 断言（见 03_secret_mask.mjs）。
        let permDir = root.appendingPathComponent("perm", isDirectory: true)
        Fs.make(permDir)
        let store = SettingsStore(
            settingsURL: permDir.appendingPathComponent("settings.json"),
            credentialsURL: permDir.appendingPathComponent("credentials.json")
        )
        try? store.saveCredentials(Credentials(apiKey: "sk-abcdef123456", deeplApiKey: "deepl-key-1234"))
        try? store.saveSettings(Settings())
        TAP.ok("D3", "settings.json / credentials.json 已写入（0600 由 case 侧 stat 断言）",
               FileManager.default.fileExists(atPath: permDir.appendingPathComponent("settings.json").path)
               && FileManager.default.fileExists(atPath: permDir.appendingPathComponent("credentials.json").path))
    }

    // MARK: - D4 会话日志（P0-19）

    static func d4(_ root: URL) {
        let dir = root.appendingPathComponent("logs", isDirectory: true)
        Fs.make(dir)

        // 造 55 份旧会话（名字必须能过 isSessionLogName），再起一次真实会话。
        for index in 1...55 {
            let name = String(format: "session-20240101-%06d.log", index)
            Fs.write("old " + String(index) + "\n", to: dir.appendingPathComponent(name))
        }
        Fs.write("user notes\n", to: dir.appendingPathComponent("notes.txt"))
        Fs.write("backup\n", to: dir.appendingPathComponent("session-backup.log"))

        let log = SessionLog(directory: dir, sessionId: "d4probe01")
        log.info("Test", "hello")
        guard let current = log.fileURL else {
            TAP.ok("D4", "会话日志文件已创建", false, "fileURL 为 nil")
            return
        }
        let currentName = current.lastPathComponent
        TAP.ok("D4", "文件名为 session-yyyyMMdd-HHmmss.log",
               currentName.range(of: "^session-[0-9]{8}-[0-9]{6}\\.log$", options: .regularExpression) != nil,
               currentName)
        TAP.ok("D4", "isSessionLogName 接受当前文件名", SessionLog.isSessionLogName(currentName), currentName)
        TAP.ok("D4", "isSessionLogName 拒绝 notes.txt", !SessionLog.isSessionLogName("notes.txt"))
        TAP.ok("D4", "isSessionLogName 拒绝 session-backup.log", !SessionLog.isSessionLogName("session-backup.log"))
        TAP.ok("D4", "isSessionLogName 拒绝全角数字",
               !SessionLog.isSessionLogName("session-２０２４0101-000000.log"))
        TAP.eqInt("D4", "日志文件权限 0600", Fs.mode(current), 0o600)

        let names = Fs.names(dir)
        let sessions = names.filter(SessionLog.isSessionLogName)
        TAP.eqInt("D4", "轮转后份数 = K.logRetentionCount(50)", sessions.count, K.logRetentionCount)
        let oldest = (1...6).map { String(format: "session-20240101-%06d.log", $0) }
        TAP.ok("D4", "最旧的 6 份被删除（20240101-000001…000006）",
               oldest.allSatisfy { !names.contains($0) },
               "仍存在: " + oldest.filter { names.contains($0) }.joined(separator: ","))
        TAP.ok("D4", "第 7 旧的仍在（只删超额部分）", names.contains("session-20240101-000007.log"))
        TAP.ok("D4", "非会话文件（notes.txt）不被轮转删除", names.contains("notes.txt"))
        TAP.ok("D4", "非会话文件（session-backup.log）不被轮转删除", names.contains("session-backup.log"))
        TAP.ok("D4", "最新的当前会话文件存在且可读",
               FileManager.default.isReadableFile(atPath: current.path))

        log.info("Test", "after-rotate")
        log.close()
        let text = Fs.text(current)
        TAP.ok("D4", "首行是 userAttestsOwnership=true（PRD §7.3）",
               text.components(separatedBy: "\n").first?.contains("userAttestsOwnership=true") == true,
               text.components(separatedBy: "\n").first ?? "-")
        TAP.ok("D4", "轮转把淘汰条数写进日志（deleted=6）", text.contains("rotate") && text.contains("deleted=6"), text)
        TAP.ok("D4", "轮转日志同时记录保留份数（kept=50）", text.contains("kept=50"), text)

        // 级别过滤
        let warnDir = root.appendingPathComponent("logs-warn", isDirectory: true)
        Fs.make(warnDir)
        let warnLog = SessionLog(directory: warnDir, sessionId: "d4warn01", minLevel: .warn)
        warnLog.debug("T", "debug-should-disappear")
        warnLog.info("T", "info-should-disappear")
        warnLog.warn("T", "warn-should-stay")
        let warnPath = warnLog.fileURL ?? warnDir.appendingPathComponent("none")
        warnLog.close()
        let warnText = Fs.text(warnPath)
        TAP.ok("D4", "minLevel=.warn 过滤掉 DEBUG", !warnText.contains("debug-should-disappear"), warnText)
        TAP.ok("D4", "minLevel=.warn 过滤掉 INFO", !warnText.contains("info-should-disappear"), warnText)
        TAP.ok("D4", "minLevel=.warn 保留 WARN", warnText.contains("warn-should-stay"), warnText)

        // 单份大小不触发滚动：实现按"份数"而不是 PRD 的 5×2MB（见 COVERAGE GAP-P0-19）
        let bigLog = SessionLog(directory: dir, sessionId: "d4big001")
        bigLog.close()
        if let bigURL = bigLog.fileURL {
            let chunk = String(repeating: "x", count: 1_024)
            var payload = ""
            for _ in 0..<3000 { payload += chunk }
            Fs.write(payload, to: bigURL)
            let afterBig = Fs.names(dir).filter(SessionLog.isSessionLogName).count
            TAP.eqInt("D4", "单份超过 2MB 不触发按大小滚动（实现按份数保留，PRD 偏差见 GAP-P0-19）",
                      afterBig, K.logRetentionCount)
        }
    }

    // MARK: - D7 缓存容量与命中率（P0-10）

    static func d7(_ root: URL) async {
        let dir = root.appendingPathComponent("cache", isDirectory: true)
        Fs.make(dir)
        let url = dir.appendingPathComponent("cache.ja-zh-Hans.jsonl")
        let logDir = root.appendingPathComponent("cache-logs", isDirectory: true)
        Fs.make(logDir)
        let log = SessionLog(directory: logDir, sessionId: "d7probe01")
        let cache = TranslationCache(url: url, maxEntries: 3, log: log)
        await cache.load()

        TAP.eqInt("D7", "Settings 默认 maxCacheEntries = K.maxCacheEntries(100000)",
                  Settings().maxCacheEntries, K.maxCacheEntries)
        TAP.eqInt("D7", "K.maxCacheEntries = 100000", K.maxCacheEntries, 100_000)

        await cache.put(key: "k1", text: "一", translatedText: "壹", backend: "openai")
        try? await Task.sleep(nanoseconds: 5_000_000)
        await cache.put(key: "k2", text: "二", translatedText: "贰", backend: "openai")
        try? await Task.sleep(nanoseconds: 5_000_000)
        await cache.put(key: "k3", text: "三", translatedText: "叁", backend: "openai")
        try? await Task.sleep(nanoseconds: 5_000_000)
        await cache.put(key: "k4", text: "四", translatedText: "肆", backend: "openai")

        TAP.eqInt("D7", "写入 4 条后内存条目 = maxEntries(3)", await cache.stats().entries, 3)
        TAP.ok("D7", "最久未用（最早写入的 k1）被淘汰", await cache.get("k1") == nil, "k1 仍可命中")
        TAP.ok("D7", "最新写入的 k4 仍可命中", await cache.get("k4") != nil)
        let hasK2 = await cache.get("k2") != nil
        let hasK3 = await cache.get("k3") != nil
        TAP.ok("D7", "中间条目 k2/k3 保留", hasK2 && hasK3)
        TAP.eqInt("D7", "stats.stores 累计 4 次新译", await cache.stats().stores, 4)
        TAP.eqInt("D7", "磁盘 jsonl 追加了 4 行（淘汰只动内存，不重写文件）", Fs.lineCount(url), 4)

        await cache.noteHit("k2")
        TAP.eqInt("D7", "noteHit 计入 stats.hits", await cache.stats().hits, 1)
        TAP.eq("D7", "命中率 1/(1+4) = 20%", await cache.stats().hitRatePercentText, "20%")
        await cache.noteHit("k2")
        await cache.noteHit("k3")
        await cache.noteHit("k4")
        TAP.eq("D7", "命中率 4/(4+4) = 50%", await cache.stats().hitRatePercentText, "50%")
        await cache.flush()
        let logPath = log.fileURL ?? logDir.appendingPathComponent("none")
        log.close()
        TAP.ok("D7", "淘汰条数写进日志（evicted=1）",
               Fs.text(logPath).contains("evicted=1"), Fs.text(logPath))

        // 纯公式分支：命中/(命中+新译)，分母为 0 时不崩
        TAP.eq("D7", "零样本命中率 = 0%", CacheStats(hits: 0, stores: 0).hitRatePercentText, "0%")
        TAP.eq("D7", "全命中命中率 = 100%", CacheStats(hits: 5, stores: 0).hitRatePercentText, "100%")
        TAP.eq("D7", "零命中命中率 = 0%", CacheStats(hits: 0, stores: 5).hitRatePercentText, "0%")
        TAP.eq("D7", "混合 3/4 命中率 = 75%", CacheStats(hits: 3, stores: 1).hitRatePercentText, "75%")

        // 重启：同一文件重新加载后仍按 ts 淘汰到上限
        let reloaded = TranslationCache(url: url, maxEntries: 3, log: nil)
        await reloaded.load()
        TAP.eqInt("D7", "重新加载后条目仍被裁到 maxEntries(3)", await reloaded.stats().entries, 3)
        TAP.ok("D7", "重新加载后最早写入的 k1 仍不在", await reloaded.get("k1") == nil)
        let reloadedK2 = await reloaded.get("k2") != nil
        let reloadedK3 = await reloaded.get("k3") != nil
        let reloadedK4 = await reloaded.get("k4") != nil
        TAP.ok("D7", "重新加载后 k2/k3/k4 均可命中", reloadedK2 && reloadedK3 && reloadedK4)
        TAP.eqInt("D7", "缓存文件权限 0600", Fs.mode(url), 0o600)

        // LRU 语义：命中要刷新"使用时刻"，淘汰按最久未用、不是最早写入。
        // k1 写入最早，但在超限前被命中过一次 —— 该被淘汰的是 k2。
        let lruDir = root.appendingPathComponent("cache-lru", isDirectory: true)
        Fs.make(lruDir)
        let lruURL = lruDir.appendingPathComponent("cache.ja-zh-Hans.jsonl")
        let lru = TranslationCache(url: lruURL, maxEntries: 3, log: nil)
        await lru.load()
        await lru.put(key: "k1", text: "一", translatedText: "壹", backend: "openai")
        try? await Task.sleep(nanoseconds: 5_000_000)
        await lru.put(key: "k2", text: "二", translatedText: "贰", backend: "openai")
        try? await Task.sleep(nanoseconds: 5_000_000)
        await lru.put(key: "k3", text: "三", translatedText: "叁", backend: "openai")
        try? await Task.sleep(nanoseconds: 5_000_000)
        TAP.ok("D7", "LRU 前置：超限前先命中最早写入的 k1", await lru.get("k1") != nil)
        try? await Task.sleep(nanoseconds: 5_000_000)
        await lru.put(key: "k4", text: "四", translatedText: "肆", backend: "openai")
        TAP.ok("D7", "命中刷新使用时刻：淘汰最久未用的 k2（不是最早写入的 k1）",
               await lru.get("k2") == nil, "k2 仍可命中（说明按写入时刻 FIFO 淘汰）")
        TAP.ok("D7", "被命中的 k1 仍在（LRU 而非 FIFO）", await lru.get("k1") != nil, "k1 被淘汰")

        // 重启后的 LRU 起点：命中会落盘一条更高 seq 的记录（flush），load() 合并同一
        // key 的多条记录时 lastUsed 必须跟到最新那条的写入时刻。停在最早一条会让
        // 热句在重启后按"最早写入"参与淘汰，先于真正的冷句被清掉。
        let restartDir = root.appendingPathComponent("cache-restart-lru", isDirectory: true)
        Fs.make(restartDir)
        let restartURL = restartDir.appendingPathComponent("cache.ja-zh-Hans.jsonl")
        let before = TranslationCache(url: restartURL, maxEntries: 2, log: nil)
        await before.load()
        await before.put(key: "k1", text: "一", translatedText: "壹", backend: "openai")
        try? await Task.sleep(nanoseconds: 5_000_000)
        await before.put(key: "k2", text: "二", translatedText: "贰", backend: "openai")
        try? await Task.sleep(nanoseconds: 5_000_000)
        TAP.ok("D7", "重启 LRU 前置：命中 k1 并落盘命中记录", await before.get("k1") != nil)
        await before.noteHit("k1")
        await before.flush()
        try? await Task.sleep(nanoseconds: 5_000_000)
        let after = TranslationCache(url: restartURL, maxEntries: 2, log: nil)
        await after.load()
        try? await Task.sleep(nanoseconds: 5_000_000)
        await after.put(key: "k3", text: "三", translatedText: "叁", backend: "openai")
        TAP.ok("D7", "重启后 lastUsed 跟到命中记录：淘汰的是 k2",
               await after.get("k2") == nil, "k2 被保留（lastUsed 停在最早写入时刻）")
        TAP.ok("D7", "重启后被命中的 k1 仍在（命中记录刷新了使用时刻）",
               await after.get("k1") != nil, "k1 被淘汰")
    }
}
