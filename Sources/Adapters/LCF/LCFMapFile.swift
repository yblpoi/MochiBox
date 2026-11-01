//
//  LCFMapFile.swift
//  MochiBox
//
//  RPG Maker 2000/2003 单张地图（MapNNNN.lmu）的 Swift 封装。
//
//  与 LCFDatabase 同形：按字段路径读写文本、原始字节进出、不做编码判断。
//  事件指令的文本在 `events[N].pages[M].list[K].string` —— 也就是对话、选项、
//  文字显示这些真正要翻译的内容；`parallax_name` 之类是素材名（一般不翻，
//  但调用方要能看见，由它自己决定）。
//
//  ⚠️ 保存要显式给版本（save(to:engine:)）。.lmu 里没有版本标记，liblcf 的
//  LMU_Reader::Save 要求调用方传 EngineVersion；版本的真实来源是同一个游戏的
//  RPG_RT.ldb（LCFDatabase.rmVersion()）。**不给默认值**是刻意的：默认成 2000
//  会把 2003 地图按 2k 格式写，属于静默损坏，宁可让调用点必须写清楚。
//
//  本文件不得 import SwiftUI / AppKit（Scripts/build.sh 的分层门禁）。
//

#if !MOCHI_NO_LCF

import Foundation

/// 一张已加载的 .lmu。生命周期内持有 liblcf 的 Map 实例。
///
/// 线程：非线程安全（底层句柄内部有缓存缓冲）。
final class LCFMapFile {

    private var handle: OpaquePointer?

    /// 加载 .lmu。失败抛 LCFError。
    init(contentsOf url: URL) throws {
        let path = url.path
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw LCFError.openFailed(path: path, reason: "文件不存在或不可读")
        }
        guard let loaded = lcf_map_load(path, "") else {
            throw LCFError.parseFailed(path: path)
        }
        handle = loaded
    }

    deinit {
        if let handle { lcf_map_free(handle) }
    }

    /// 遍历地图里的文本字段。
    func allStrings() -> [LCFStringEntry] {
        guard let handle else { return [] }
        let collector = LCFStringCollector()
        _ = lcf_map_for_each_string(handle, lcfAppendString,
                                    Unmanaged.passUnretained(collector).toOpaque())
        return collector.entries
    }

    /// 遍历地图里的消息块（10110 + 20110 拼接，口径同 LCFDatabase.allMessages）。
    func allMessages() -> [LCFMessageEntry] {
        guard let handle else { return [] }
        let collector = LCFMessageCollector()
        _ = lcf_map_for_each_message(handle, lcfAppendMessage,
                                     Unmanaged.passUnretained(collector).toOpaque())
        return collector.entries
    }

    /// 按路径取原始字节；路径不存在返回 nil。
    func bytes(at path: String) -> Data? {
        guard let handle else { return nil }
        var length: Int32 = 0
        guard let pointer = lcf_map_get_bytes(handle, path, &length) else { return nil }
        return Data(bytes: pointer, count: Int(length))
    }

    /// 按路径写原始字节；路径不存在抛 unknownPath。
    func setBytes(_ data: Data, at path: String) throws {
        guard let handle else { throw LCFError.unknownPath(path) }
        let written: Int32 = data.withUnsafeBytes { buffer in
            lcf_map_set_bytes(handle, path, buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buffer.count))
        }
        guard written == 1 else { throw LCFError.unknownPath(path) }
    }

    /// 保存为 .lmu。engine 决定按 2k 还是 2k3 的格式写（见文件头）。
    func save(to url: URL, engine: RMEasyRPGVersion) throws {
        guard let handle else { throw LCFError.writeFailed(path: url.path) }
        lcf_map_set_engine(handle, engine == .rm2003 ? 1 : 0)
        guard lcf_map_save(handle, url.path, "") == 1 else {
            throw LCFError.writeFailed(path: url.path)
        }
    }
}

#endif
