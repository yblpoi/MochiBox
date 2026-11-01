//
//  lcf_shim.h
//  MochiBox
//
//  liblcf 的最小 C 接口：加载 RPG_RT.ldb、按「字段路径」读写文本、整库保存。
//
//  设计口径（为什么要这么薄）:
//    · **不做任何编码转换**：本仓库的 liblcf 是 -DLIBLCF_WITH_ICU=OFF 构建的，
//      此时 liblcf 的 DetectEncodings() 会硬编码返回 {"windows-1252"}。一旦让它
//      自动检测，Shift-JIS / GBK 文本会被按 cp1252 转码而**静默损坏**。所以
//      这里一律以 encoding="" 加载 —— 字段原样保留原始字节，转码交给 Swift 侧
//      LCFTextCodec，调用方才知道自己这份数据是日文还是简体中文。
//    · **路径即身份**：文本字段用反射得到的路径寻址（actors[0].name、
//      commonevents[0].event_commands[1].string），不另建一套 id。
//    · **原始字节进出**：回调给的是 bytes+len，不是以 NUL 结尾的 UTF-8 串 ——
//      半个字符或内嵌 0x00 都不会被截断。
//
//  线程：所有函数都在调用线程同步执行，lcf_db 实例不保证线程安全（调用方自己串行化）。
//  生命周期：get_bytes 返回的指针由 lcf_db 持有，下一次对同一实例的调用即失效。
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

/// 不透明句柄（内部持有 lcf::rpg::Database）。
typedef struct lcf_db lcf_db;

/// 遍历回调：path 是字段路径（UTF-8，NUL 结尾），bytes/len 是该字段的**原始字节**。
/// 指针只在回调期间有效，回调内不要保存。
typedef void (*lcf_string_cb)(void* userdata, const char* path, const char* bytes, int len);

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
/// @return 成功 1，失败 0。
LCF_EXPORT int lcf_db_save(lcf_db* db, const char* path_utf8, const char* encoding);

/// 角色 / 道具条数（用于确认结构确实读进来了，而不是读到一个空壳）。
LCF_EXPORT int lcf_db_actor_count(const lcf_db* db);
LCF_EXPORT int lcf_db_item_count(const lcf_db* db);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // MOCHIBOX_LCF_SHIM_H
