//
//  lcf_shim.cpp
//  MochiBox
//
//  lcf_shim.h 的实现。全部细节都集中在两件事上：
//    1) 把 lcf::rpg::ForEachString 的反射上下文（Context<Parent, Parent>）摊平成
//       字符串路径 —— 与 liblcf 自带 tools/lcfstrings.cpp 同一口径；
//    2) 路径 → DBString* 的索引，避免每次 get/set 都全库扫一遍（否则按路径逐条
//       写回是 O(n²)，几千条文本就会明显卡）。
//
//  索引为什么可以缓存：set_bytes 只改字段内容，不增删数组元素，指针稳定；
//  结构一旦被 liblcf 重新解析就换一个新实例，缓存随之作废。
//

#include "lcf_shim.h"

#include <cstring>
#include <string>
#include <string_view>
#include <unordered_map>

#include <lcf/ldb/reader.h>
#include <lcf/rpg/database.h>

struct lcf_db {
    lcf::rpg::Database* db = nullptr;
    std::string encoding;
    // get_bytes 的返回缓冲（保证指针在下一次调用前有效）
    std::string scratch;
    // 延迟构建的 path -> 字段 索引
    std::unordered_map<std::string, lcf::DBString*> index;
    bool index_built = false;
};

namespace {

// 根上下文的 parent 是 void*（Context<void, void>），没有 name/index，到此为止。
void append_path(const void* /*ctx*/, std::string& /*out*/) {}

/// 递归拼出父级路径（actors[0]、commonevents[3].event_commands[1] …）。
template <typename Ctx>
void append_path(const Ctx* ctx, std::string& out) {
    if (ctx == nullptr) { return; }
    append_path(ctx->parent, out);
    if (!out.empty()) { out += '.'; }
    out.append(ctx->name.data(), ctx->name.size());
    if (ctx->index != -1) {
        out += '[';
        out += std::to_string(ctx->index);
        out += ']';
    }
}

template <typename Ctx>
std::string make_path(const Ctx& ctx) {
    std::string path;
    append_path(ctx.parent, path);
    if (!path.empty()) { path += '.'; }
    path.append(ctx.name.data(), ctx.name.size());
    return path;
}

/// 构建索引（一次全库遍历）。同一路径出现两次说明反射有重复，保留第一个。
void build_index(lcf_db* handle) {
    if (handle->index_built) { return; }
    handle->index.reserve(4096);
    lcf::rpg::ForEachString(*handle->db, [&](lcf::DBString& field, const auto& ctx) {
        handle->index.emplace(make_path(ctx), &field);
    });
    handle->index_built = true;
}

}  // namespace

extern "C" {

lcf_db* lcf_db_load(const char* path_utf8, const char* encoding) {
    if (path_utf8 == nullptr) { return nullptr; }
    // 只有 "" 是"原始字节直通"。NULL 也按 "" 处理：本构建没有 ICU，
    // 自动检测只会退化成 cp1252 而损坏数据。
    std::string enc = (encoding != nullptr) ? encoding : "";

    auto database = lcf::LDB_Reader::Load(path_utf8, enc);
    if (!database) { return nullptr; }

    auto* handle = new lcf_db();
    handle->db = database.release();
    handle->encoding = enc;
    return handle;
}

void lcf_db_free(lcf_db* db) {
    if (db == nullptr) { return; }
    delete db->db;
    delete db;
}

const char* lcf_db_encoding(const lcf_db* db) {
    return (db != nullptr) ? db->encoding.c_str() : "";
}

int lcf_db_for_each_string(lcf_db* db, lcf_string_cb cb, void* userdata) {
    if (db == nullptr || db->db == nullptr || cb == nullptr) { return 0; }
    int count = 0;
    lcf::rpg::ForEachString(*db->db, [&](lcf::DBString& field, const auto& ctx) {
        std::string path = make_path(ctx);
        // 空串时 data() 可能是 nullptr，给个稳定的非空指针，Swift 侧才好构造 Data。
        const char* bytes = (field.size() > 0) ? field.data() : "";
        cb(userdata, path.c_str(), bytes, static_cast<int>(field.size()));
        ++count;
    });
    return count;
}

const char* lcf_db_get_bytes(lcf_db* db, const char* path, int* out_len) {
    if (db == nullptr || db->db == nullptr || path == nullptr) { return nullptr; }
    build_index(db);
    auto it = db->index.find(path);
    if (it == db->index.end()) { return nullptr; }
    const lcf::DBString& field = *it->second;
    if (field.size() > 0) {
        db->scratch.assign(field.data(), field.size());
    } else {
        // assign(nullptr, 0) 是 UB；空串单独处理。
        db->scratch.clear();
    }
    if (out_len != nullptr) { *out_len = static_cast<int>(field.size()); }
    return (field.size() > 0) ? db->scratch.data() : "";
}

int lcf_db_set_bytes(lcf_db* db, const char* path, const char* bytes, int len) {
    if (db == nullptr || db->db == nullptr || path == nullptr) { return 0; }
    if (bytes == nullptr && len > 0) { return 0; }
    build_index(db);
    auto it = db->index.find(path);
    if (it == db->index.end()) { return 0; }
    const char* source = (bytes != nullptr) ? bytes : "";
    *it->second = lcf::DBString(std::string_view(source, static_cast<size_t>(len)));
    return 1;
}

int lcf_db_save(lcf_db* db, const char* path_utf8, const char* encoding) {
    if (db == nullptr || db->db == nullptr || path_utf8 == nullptr) { return 0; }
    std::string enc = (encoding != nullptr) ? encoding : db->encoding;
    return lcf::LDB_Reader::Save(path_utf8, *db->db, enc) ? 1 : 0;
}

int lcf_db_actor_count(const lcf_db* db) {
    return (db != nullptr && db->db != nullptr) ? static_cast<int>(db->db->actors.size()) : 0;
}

int lcf_db_item_count(const lcf_db* db) {
    return (db != nullptr && db->db != nullptr) ? static_cast<int>(db->db->items.size()) : 0;
}

}  // extern "C"
