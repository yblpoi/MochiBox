//
//  LCFMapTree.swift
//  MochiBox
//
//  RPG_RT.lmt（地图树）的只读封装。
//
//  两个用途，都不能省：
//    · mapIDs —— EasyRPG 的 mapNNNN.po 编号取的是**地图树里的 ID 顺序**，
//      不是文件名序号。差一就会整张地图的译文不生效，所以这里把 ID 原样给出来。
//    · strings —— 地图名（maps[i].name）与背景名（maps[i].background_name），
//      是 rpg_rt.lmt.po 的全部来源。
//
//  只读：地图树的结构（拖动节点、改名之外的父子关系）属于编辑器行为，不在翻译链路里。
//
//  本文件不得 import SwiftUI / AppKit（Scripts/build.sh 的分层门禁）。
//

#if !MOCHI_NO_LCF

import Foundation

/// 一次 LMT 读取的全部结果。
struct LCFMapTreeInfo: Equatable {
    /// 地图树里的条目 ID，顺序与文件一致（含 0 号 root 节点）。
    let mapIDs: [Int]
    /// 地图树里的文本字段（`maps[i].name`、`maps[i].background_name`）。
    let strings: [LCFStringEntry]

    /// 读 .lmt。失败抛 LCFError。
    static func load(contentsOf url: URL) throws -> LCFMapTreeInfo {
        let path = url.path
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw LCFError.openFailed(path: path, reason: "文件不存在或不可读")
        }
        guard let handle = lcf_tree_load(path, "") else {
            throw LCFError.parseFailed(path: path)
        }
        defer { lcf_tree_free(handle) }

        let count = Int(lcf_tree_map_count(handle))
        var ids: [Int] = []
        ids.reserveCapacity(max(count, 0))
        for index in 0..<max(count, 0) {
            ids.append(Int(lcf_tree_map_id_at(handle, Int32(index))))
        }

        let collector = LCFStringCollector()
        _ = lcf_tree_for_each_string(handle, lcfAppendString,
                                     Unmanaged.passUnretained(collector).toOpaque())
        return LCFMapTreeInfo(mapIDs: ids, strings: collector.entries)
    }
}

#endif
