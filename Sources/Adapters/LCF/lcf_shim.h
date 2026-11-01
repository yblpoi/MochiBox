//
//  lcf_shim.h
//  MochiBox
//
//  liblcf 的最小 C 接口：加载 RPG Maker 2000/2003 的 RPG_RT.ldb / .lmu / .lmt，
//  按「字段路径」读写文本，整库保存。
//
//  设计口径（为什么要这么薄）:
//    · **不做任何编码转换**：本仓库的 liblcf 是 -DLIBLCF_WITH_ICU=OFF 构建的，
//      此时 liblcf 的 DetectEncodings() 会硬编码返回 {"windows-1252"}。一旦让它
//      自动检测，Shift-JIS / GBK 文本会被按 cp1252 转码而**静默损坏**。所以
//      这里一律以 encoding="" 加载 —— 字段原样保留原始字节，转码交给 Swift 侧
//      LCFTextCodec，调用方才知道自己这份数据是日文还是简体中文。
//    · **路径即身份**：文本字段用反射得到的路径寻址（actors[0].name、
//      events[2].pages[0].event_commands[5].string），不另建一套 id。三种文件共用同一套
//      路径口径，因为 liblcf 的反射上下文是同一种拼法。
//    · **原始字节进出**：回调给的是 bytes+len，不是以 NUL 结尾的 UTF-8 串 ——
//      半个字符或内嵌 0x00 都不会被截断。
//
//  线程：所有函数都在调用线程同步执行，句柄实例不保证线程安全（调用方自己串行化）。
//  生命周期：get_bytes 返回的指针由句柄持有，下一次对同一实例的调用即失效。
//

#ifndef MOCHIBOX_LCF_SHIM_H
#define MOCHIBOX_LCF_SHIM_H

#include <stddef.h>

// 编译带 -fvisibility=hidden 时，导出符号必须显式标回来，否则 Swift 侧链接期
// 报 "Undefined symbols: _lcf_db_load"。
#if defined(_WIN32)
#  define LCF_EXPORT __declspec(dllexport)
#elif defined(__GNUC__) || defined(__clang__)
#  define LCF_EXPORT __attribute__((visibility("default")))
#else
#  define LCF_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// 不透明句柄：数据库（RPG_RT.ldb）。
typedef struct lcf_db lcf_db;
/// 不透明句柄：单张地图（MapNNNN.lmu）。
typedef struct lcf_map lcf_map;
/// 不透明句柄：地图树（RPG_RT.lmt）。
typedef struct lcf_tree lcf_tree;

/// 遍历回调：path 是字段路径（UTF-8，NUL 结尾），bytes/len 是该字段的**原始字节**。
/// 指针只在回调期间有效，回调内不要保存。
typedef void (*lcf_string_cb)(void* userdata, const char* path, const char* bytes, int len);

// ---------------------------------------------------------------------------
// 数据库 / RPG_RT.ldb
// ---------------------------------------------------------------------------

/// 加载 .ldb。
///
/// @param path_utf8  文件路径（UTF-8）。
/// @param encoding   必须传 ""（或 NULL）：原始字节直通，不做任何转码。
///                   传具体编码名会走 liblcf 的转码器，无 ICU 构建下不可用。
/// @return 成功返回句柄，失败返回 NULL（文件不存在 / 不是合法 LCF）。
LCF_EXPORT lcf_db* lcf_db_load(const char* path_utf8, const char* encoding);

/// 释放句柄（NULL 安全）。
LCF_EXPORT void lcf_db_free(lcf_db* db);

/// 实际使用的编码名（即 load 时传入的值；NULL 句柄返回 ""）。
LCF_EXPORT const char* lcf_db_encoding(const lcf_db* db);

/// 遍历全部文本字段，返回遍历到的条数（cb 为 NULL 或 db 无效时返回 0）。
LCF_EXPORT int lcf_db_for_each_string(lcf_db* db, lcf_string_cb cb, void* userdata);

/// 按路径取原始字节；out_len 写入长度（可为 NULL）。路径不存在返回 NULL。
LCF_EXPORT const char* lcf_db_get_bytes(lcf_db* db, const char* path, int* out_len);

/// 按路径写原始字节；成功返回 1，路径不存在返回 0。
LCF_EXPORT int lcf_db_set_bytes(lcf_db* db, const char* path, const char* bytes, int len);

/// 保存为 .ldb。encoding 传 ""（或 NULL）表示原样写回。
///
/// 版本由库里的 system.ldb_id 决定（liblcf 的 GetEngineVersion）：本函数把
/// **同一个** Database 原样存回去，所以 ldb_id 随文件带过来，2003 的
/// battlecommands/classes/battleranimations 不会被丢。**不要**改成"新建空
/// Database 再填字段再 Save" —— 那样 ldb_id = 0，上述 2003 专有 chunk 会被
/// 当成 2k 数据静默丢弃，而 Save 仍然返回 true。
///
/// @return 成功 1，失败 0。
LCF_EXPORT int lcf_db_save(lcf_db* db, const char* path_utf8, const char* encoding);

/// 角色 / 道具条数（用于确认结构确实读进来了，而不是读到一个空壳）。
LCF_EXPORT int lcf_db_actor_count(const lcf_db* db);
LCF_EXPORT int lcf_db_item_count(const lcf_db* db);

/// 版本判据：system.ldb_id（2000 的库里是 0，2003 的库里是 2003）。
///
/// 这个字段是 int32，不在 ForEachString 的文本字段里，所以必须单独暴露；
/// 走 get_bytes("system.ldb_id") 是拿不到的。
LCF_EXPORT int lcf_db_ldb_id(const lcf_db* db);

// ---------------------------------------------------------------------------
// 地图 / MapNNNN.lmu
// ---------------------------------------------------------------------------

/// 加载 .lmu。encoding 口径同 lcf_db_load（传 ""）。
LCF_EXPORT lcf_map* lcf_map_load(const char* path_utf8, const char* encoding);

/// 释放句柄（NULL 安全）。
LCF_EXPORT void lcf_map_free(lcf_map* map);

/// 保存时用哪一版格式写（0 = 2000 / e2k，非 0 = 2003 / e2k3），默认 0。
///
/// 为什么不能让 shim 自己判断：.lmu 文件里没有版本标记，liblcf 的 LMU_Reader::Save
/// 要求调用方传 EngineVersion（它没有 GetEngineVersion 那种从 ldb_id 推的入口）。
/// 调用方知道版本（从同一个游戏的 RPG_RT.ldb 读），所以由它显式告知；
/// 默认 2000 是为了"不知道版本时按最保守的格式写"，不是猜。
LCF_EXPORT void lcf_map_set_engine(lcf_map* map, int use_2003);

/// 遍历地图里的文本字段，返回条数。路径形如
/// `events[2].pages[0].list[5].string`、`parallax_name`。
LCF_EXPORT int lcf_map_for_each_string(lcf_map* map, lcf_string_cb cb, void* userdata);

/// 按路径取原始字节；路径不存在返回 NULL。
LCF_EXPORT const char* lcf_map_get_bytes(lcf_map* map, const char* path, int* out_len);

/// 按路径写原始字节；成功 1，路径不存在 0。
LCF_EXPORT int lcf_map_set_bytes(lcf_map* map, const char* path, const char* bytes, int len);

/// 保存为 .lmu（按 lcf_map_set_engine 设定的版本）。成功 1，失败 0。
LCF_EXPORT int lcf_map_save(lcf_map* map, const char* path_utf8, const char* encoding);

// ---------------------------------------------------------------------------
// 地图树 / RPG_RT.lmt
// ---------------------------------------------------------------------------

/// 加载 .lmt。encoding 口径同 lcf_db_load（传 ""）。
LCF_EXPORT lcf_tree* lcf_tree_load(const char* path_utf8, const char* encoding);

/// 释放句柄（NULL 安全）。
LCF_EXPORT void lcf_tree_free(lcf_tree* tree);

/// 地图树里的条目数（含 root / area 节点，与 .ldb 的 map 列表不是一回事）。
LCF_EXPORT int lcf_tree_map_count(const lcf_tree* tree);

/// 第 index 个条目的 map ID；越界返回 -1。
///
/// 用途：EasyRPG 的 mapNNNN.po 编号取的是这里的 ID 顺序，不是文件名序号。
LCF_EXPORT int lcf_tree_map_id_at(const lcf_tree* tree, int index);

/// 遍历地图树里的文本字段（`maps[i].name`、`maps[i].background_name`）。
LCF_EXPORT int lcf_tree_for_each_string(lcf_tree* tree, lcf_string_cb cb, void* userdata);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // MOCHIBOX_LCF_SHIM_H
