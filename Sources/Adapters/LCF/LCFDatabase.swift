//
//  LCFDatabase.swift
//  MochiBox
//
//  RPG Maker 2000/2003 数据库（RPG_RT.ldb）的 Swift 封装：按「字段路径」读写文本、整库保存。
//
//  口径（与本仓库的经典 RM 路线一致）:
//    · **本层不做编码判断**。liblcf 以 encoding="" 加载，字段保持原始字节；调用方拿
//      raw 之后自己决定是 Shift-JIS 还是 GBK（LCFTextCodec 提供猜测入口）。
//      理由：一份 .ldb 里同时混着日文原文与汉化文本是常态，在数据库层"统一转码"
//      会把还没翻译的字段也一起改坏，且往返保存无法逐字节还原。
//    · **路径是可寻址身份**：`actors[0].name`、`commonevents[0].event_commands[1].string`。
//      路径由 liblcf 的反射上下文摊平，与上游 tools/lcfstrings.cpp 同口径。
//    · **只读不改结构**：setBytes 只换字段内容，不增删角色/事件；需要改结构时说明
//      走的是另一条路（不是本文件的范围）。
//
//  构建降级：没跑过 Scripts/build-liblcf.sh 的机器上，Scripts/build.sh 会定义
//  MOCHI_NO_LCF，本文件整体编译为空 —— 产物照常可用，只是经典 RM 数据层不可用。
//  所以**不要**去掉外面的 `#if !MOCHI_NO_LCF`。
//
//  本文件不得 import SwiftUI / AppKit（Scripts/build.sh 的分层门禁）。
//

#if !MOCHI_NO_LCF

import Foundation

/// 一条文本字段：路径 + 原始字节（未解码）。
struct LCFStringEntry: Equatable {
    let path: String
    let raw: Data
}

/// 引擎版本。判据是 liblcf 的 `db.system.ldb_id == 2003`（src/saveopt.cpp 的
/// GetEngineVersion）——不是文件名、不是目录结构，也不是"有没有 classes"。
enum RMEasyRPGVersion: String, CaseIterable {
    case rm2000 = "2000"
    case rm2003 = "2003"
}

/// C 回调只能是无捕获函数指针，所以收集器必须是独立对象（三张表共用同一个）。
final class LCFStringCollector {
    var entries: [LCFStringEntry] = []
}

/// 直接作为 lcf_*_for_each_string 的 cbfunc 传入。
///
/// 为什么是**全局函数**而不是 `LCFStringCollector.append`：Swift 只允许用
/// `func` 或字面量闭包构成 C 函数指针，静态方法引用会报
/// "a C function pointer can only be formed from a reference to a 'func'"。
func lcfAppendString(
    userdata: UnsafeMutableRawPointer?,
    path: UnsafePointer<CChar>?,
    bytes: UnsafePointer<CChar>?,
    len: Int32
) {
    guard let userdata, let path else { return }
    let collector = Unmanaged<LCFStringCollector>.fromOpaque(userdata).takeUnretainedValue()
    let raw: Data
    if let bytes, len > 0 {
        raw = Data(bytes: bytes, count: Int(len))
    } else {
        raw = Data()
    }
    collector.entries.append(LCFStringEntry(path: String(cString: path), raw: raw))
}

/// 一个已加载的 RPG_RT.ldb。生命周期内持有 liblcf 的 Database 实例。
///
/// 线程：非线程安全（底层句柄内部有缓存缓冲）。一个实例同一时刻只在一个线程上用。
final class LCFDatabase {

    private var handle: OpaquePointer?

    /// 加载 .ldb。失败抛 LCFError。
    init(contentsOf url: URL) throws {
        let path = url.path
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw LCFError.openFailed(path: path, reason: "文件不存在或不可读")
        }
        // 第二个参数必须是 ""：原始字节直通。传编码名会走 liblcf 的转码器，
        // 而本仓库的 liblcf 是无 ICU 构建，转码路径只会损坏数据。
        guard let loaded = lcf_db_load(path, "") else {
            throw LCFError.parseFailed(path: path)
        }
        handle = loaded
    }

    deinit {
        if let handle { lcf_db_free(handle) }
    }

    /// 实际使用的编码（恒为 ""，即原始字节直通）。保留给日志/自检用。
    var encoding: String {
        guard let handle else { return "" }
        return String(cString: lcf_db_encoding(handle))
    }

    var actorCount: Int { Int(lcf_db_actor_count(handle)) }
    var itemCount: Int { Int(lcf_db_item_count(handle)) }

    /// 版本判定：读 system.ldb_id（2003 的库是 2003，2000 的库是 0）。
    ///
    /// 这个字段是 int32，不在 ForEachString 的文本字段里，所以走的是专门的 C 函数，
    /// 不是 bytes(at: "system.ldb_id")（那条路径永远拿不到东西）。
    func rmVersion() -> RMEasyRPGVersion {
        return lcf_db_ldb_id(handle) == 2003 ? .rm2003 : .rm2000
    }

    /// 遍历全部文本字段。顺序由 liblcf 反射决定（稳定：按结构体字段声明序 + 数组下标）。
    func allStrings() -> [LCFStringEntry] {
        guard let handle else { return [] }
        let collector = LCFStringCollector()
        _ = lcf_db_for_each_string(handle, lcfAppendString,
                                   Unmanaged.passUnretained(collector).toOpaque())
        return collector.entries
    }

    /// 按路径取原始字节；路径不存在返回 nil（空字符串返回空 Data，两者要分开）。
    func bytes(at path: String) -> Data? {
        guard let handle else { return nil }
        var length: Int32 = 0
        guard let pointer = lcf_db_get_bytes(handle, path, &length) else { return nil }
        return Data(bytes: pointer, count: Int(length))
    }

    /// 按路径写原始字节；路径不存在抛 unknownPath。
    func setBytes(_ data: Data, at path: String) throws {
        guard let handle else { throw LCFError.unknownPath(path) }
        let written: Int32 = data.withUnsafeBytes { buffer in
            lcf_db_set_bytes(handle, path, buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count))
        }
        guard written == 1 else { throw LCFError.unknownPath(path) }
    }

    /// 保存到指定路径（原样写回，不做编码转换）。
    ///
    /// **ldb_id 保护**：这里存的是**同一个**已加载的 Database，system.ldb_id 随文件
    /// 带过来，所以 2003 的 battlecommands / classes / battleranimations 不会被丢。
    /// 绝对不要改成"新建空 Database → 填字段 → Save"：那样 ldb_id = 0，2003 专有
    /// chunk 会被当作 2k 数据**静默丢弃**，而 Save 仍然返回 true（无任何报错）。
    func save(to url: URL) throws {
        guard let handle else { throw LCFError.writeFailed(path: url.path) }
        guard lcf_db_save(handle, url.path, "") == 1 else {
            throw LCFError.writeFailed(path: url.path)
        }
    }
}

// ---------------------------------------------------------------------------
// 下一步：PO 导出（**尚未实现**，这里只留接口口径）
//
// EasyRPG 上游自带 gettext 运行时替换：--language <LANG> --language-path <PATH>
// 会在内存里改写数据库，零写盘。所以给经典 RM 做汉化的出口是「翻译根目录 + PO」，
// 而不是改 LDB。分组形状（rea 从 .so 的帮助串实测）：
//
//   PATH/<LANG>/meta.ini                  Name / Code / Term / GameTitle / Font（顶层键，无 section）
//   PATH/<LANG>/rpg_rt.ldb.po             数据库词条（actors/skills/items/…）
//   PATH/<LANG>/rpg_rt.ldb.common.po      公共事件（commonevents[N]…）
//   PATH/<LANG>/rpg_rt.ldb.battle.po      战斗事件（troops[N]…）
//   PATH/<LANG>/rpg_rt.lmt.po             地图名（maps[N].name / background_name）
//   PATH/<LANG>/mapNNNN.po                逐地图事件（NNNN 取 LCFMapTreeInfo.mapIDs 的顺序）
//
// **分组标识不要塞进 FullTextEntry.source**：source 会被
// TranslationCategory.inferred(source:path:) 用来推 category，而 category 决定
// 提示词规则与 Segmenter 的 cacheKey profile —— 同一句原文出现在地图与公共事件里
// 会拿到两个缓存键（重复计费、译文风格不一致）。分组只能从 path 前缀推导，
// 或者另开一个 optional 字段。
//
// 另外两条已核过的语义（写 meta.ini 时用得上）：
//   · ini 的键大小写不敏感（liblcf inireader 里整体 tolower），值不做处理；
//   · 空值等于没写（GetString 取到空串返回默认值），不要写 "Font=" 期望覆盖默认。
// ---------------------------------------------------------------------------

#endif
