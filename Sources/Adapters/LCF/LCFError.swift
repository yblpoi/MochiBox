//
//  LCFError.swift
//  MochiBox
//
//  LCF 数据层的错误类型。**故意不放进 `#if !MOCHI_NO_LCF`**：没有 liblcf 的机器上
//  LCFDatabase 会被编译为空，但 LCFTextCodec 仍然可用，它也要抛同一套错误。
//
//  code 与 ErrorCode 的命名风格一致（snake_case），但**不复用** ErrorCode：
//  那张表是"后端 / 网络"语义的穷尽表（每个 case 都要填 retryable 与兜底文案），
//  把数据格式错误塞进去会让每个使用方都多一条与己无关的分支。
//

import Foundation

enum LCFError: Error, LocalizedError, CustomStringConvertible {
    /// 文件不存在或不可读。
    case openFailed(path: String, reason: String)
    /// 文件存在但不是合法 LCF（截断 / 不是 RPG_RT.ldb / 加密）。
    case parseFailed(path: String)
    /// 字段路径不存在（拼错、或该字段只有 2003 才有）。
    case unknownPath(String)
    /// 保存失败（目录不可写 / 磁盘满）。
    case writeFailed(path: String)
    /// 字节序列在目标编码下无法表示。
    case encodeFailed(encoding: String)

    var code: String {
        switch self {
        case .openFailed: return "lcf_open_failed"
        case .parseFailed: return "lcf_parse_failed"
        case .unknownPath: return "lcf_unknown_path"
        case .writeFailed: return "lcf_write_failed"
        case .encodeFailed: return "lcf_encode_failed"
        }
    }

    var errorDescription: String? {
        switch self {
        case let .openFailed(path, reason):
            return "打不开 LCF 数据库：\(path)（\(reason)）"
        case let .parseFailed(path):
            return "不是合法的 RPG Maker 2000/2003 数据库：\(path)"
        case let .unknownPath(path):
            return "数据库里没有这个字段：\(path)"
        case let .writeFailed(path):
            return "写入 LCF 数据库失败：\(path)"
        case let .encodeFailed(encoding):
            return "文本无法用 \(encoding) 表示（含该编码不支持的字符）"
        }
    }

    var description: String { "LCFError(\(code)): \(errorDescription ?? "")" }
}
