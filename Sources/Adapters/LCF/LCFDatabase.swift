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

    /// 遍历全部文本字段。顺序由 liblcf 反射决定（稳定：按结构体字段声明序 + 数组下标）。
    func allStrings() -> [LCFStringEntry] {
        guard let handle else { return [] }
        let collector = Collector()
        _ = lcf_db_for_each_string(handle, { userdata, path, bytes, len in
            guard let userdata, let path else { return }
            let collector = Unmanaged<Collector>.fromOpaque(userdata).takeUnretainedValue()
            let raw: Data
            if let bytes, len > 0 {
                raw = Data(bytes: bytes, count: Int(len))
            } else {
                raw = Data()
            }
            collector.entries.append(LCFStringEntry(path: String(cString: path), raw: raw))
        }, Unmanaged.passUnretained(collector).toOpaque())
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
    func save(to url: URL) throws {
        guard let handle else { throw LCFError.writeFailed(path: url.path) }
        guard lcf_db_save(handle, url.path, "") == 1 else {
            throw LCFError.writeFailed(path: url.path)
        }
    }

    /// 回调里只允许无捕获的 C 函数指针，所以收集器必须是独立对象。
    private final class Collector {
        var entries: [LCFStringEntry] = []
    }
}

#endif
