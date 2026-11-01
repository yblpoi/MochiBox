//
//  lcf_shim.cpp
//  MochiBox
//
//  lcf_shim.h 的实现。三种文件（.ldb / .lmu / .lmt）走同一套机制，细节只在两件事上：
//    1) 把 lcf::rpg::ForEachString 的反射上下文（Context<Parent, Parent>）摊平成
//       字符串路径 —— 与 liblcf 自带 tools/lcfstrings.cpp 同一口径；
//    2) 路径 → DBString* 的索引，避免每次 get/set 都全文件扫一遍（否则按路径逐条
//       写回是 O(n²)，几千条文本就会明显卡）。
//
//  索引为什么可以缓存：set_bytes 只改字段内容，不增删数组元素，指针稳定；
//  结构一旦被 liblcf 重新解析就换一个新实例，缓存随之作废。
//

#include "lcf_shim.h"

#include <cstring>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>

#include <lcf/ldb/reader.h>
#include <lcf/lmt/reader.h>
#include <lcf/lmu/reader.h>
#include <lcf/rpg/database.h>
#include <lcf/rpg/map.h>
#include <lcf/rpg/treemap.h>
#include <lcf/saveopt.h>

namespace {

// 根上下文的 parent 是 void*（Context<void, void>），没有 name/index，到此为止。
void append_path(const void* /*ctx*/, std::string& /*out*/) {}

/// 递归拼出父级路径（actors[0]、events[2].pages[0] …）。
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

/// 一个 LCF 对象里"路径 → 文本字段"的索引 + 取值用的临时缓冲。
///
/// .ldb / .lmu / .lmt 三者的 ForEachString 重载不同，但用法一模一样，所以这里
/// 用模板收口；句柄各自持有一个实例（缓存不能跨对象复用 —— DBString 指针属于
/// 具体对象）。
template <typename Object>
struct StringIndex {
    std::unordered_map<std::string, lcf::DBString*> by_path;
    std::string scratch;
    bool built = false;

    void build(Object& object) {
        if (built) { return; }
        by_path.reserve(4096);
        lcf::rpg::ForEachString(object, [this](lcf::DBString& field, const auto& ctx) {
            // 同一路径出现两次说明反射有重复，保留第一个。
            by_path.emplace(make_path(ctx), &field);
        });
        built = true;
    }

    lcf::DBString* find(Object& object, const char* path) {
        build(object);
        auto it = by_path.find(path);
        return (it == by_path.end()) ? nullptr : it->second;
    }

    int each(Object& object, lcf_string_cb cb, void* userdata) {
        int count = 0;
        lcf::rpg::ForEachString(object, [&](lcf::DBString& field, const auto& ctx) {
            std::string path = make_path(ctx);
            // 空串时 data() 可能是 nullptr，给个稳定的非空指针，Swift 侧才好构造 Data。
            const char* bytes = (field.size() > 0) ? field.data() : "";
            cb(userdata, path.c_str(), bytes, static_cast<int>(field.size()));
            ++count;
        });
        return count;
    }
};

/// 把字段拷进句柄自己的 scratch，返回稳定指针（下一次调用前有效）。
/// 消息块的指令码。**不是** 101/401（那是 RGSS 的口径）：RPG Maker 2000/2003
/// 的真实值就是 10110（显示消息）与 20110（续行）—— 用 Fixtures 里的真实数据核过。
constexpr int kShowMessage = 10110;
constexpr int kMessageContinuation = 20110;
/// EasyRPG translation.cpp 的 maxLines：一条消息最多 4 行，超出部分引擎不再取，
/// 我们同样不取（否则 msgid 与引擎查表用的串对不上，永远翻不到）。
constexpr int kMaxMessageLines = 4;

std::string field_bytes(const lcf::DBString& field) {
    const char* data = (field.size() > 0) ? field.data() : "";
    return std::string(data, field.size());
}

/// 把一串事件指令按「10110 + 连续 20110」切成消息块，逐块回调。
int each_message_block(const std::vector<lcf::rpg::EventCommand>& commands,
                       const std::string& prefix, lcf_message_cb cb, void* userdata) {
    int count = 0;
    size_t block = 0;
    size_t i = 0;
    while (i < commands.size()) {
        if (commands[i].code != kShowMessage) { ++i; continue; }
        std::string text = field_bytes(commands[i].string);
        int lines = 1;
        size_t j = i + 1;
        while (j < commands.size() && commands[j].code == kMessageContinuation
               && lines < kMaxMessageLines) {
            text += '\n';
            text += field_bytes(commands[j].string);
            ++lines;
            ++j;
        }
        std::string path = prefix + ".messages[" + std::to_string(block) + "]";
        cb(userdata, path.c_str(), text.data(), static_cast<int>(text.size()));
        ++count;
        ++block;
        i = j;
    }
    return count;
}

const char* store_and_return(const lcf::DBString& field, std::string& scratch, int* out_len) {
    if (field.size() > 0) {
        scratch.assign(field.data(), field.size());
    } else {
        // assign(nullptr, 0) 是 UB；空串单独处理。
        scratch.clear();
    }
    if (out_len != nullptr) { *out_len = static_cast<int>(field.size()); }
    return (field.size() > 0) ? scratch.data() : "";
}

int assign_field(lcf::DBString* field, const char* bytes, int len) {
    if (field == nullptr) { return 0; }
    if (bytes == nullptr && len > 0) { return 0; }
    const char* source = (bytes != nullptr) ? bytes : "";
    *field = lcf::DBString(std::string_view(source, static_cast<size_t>(len)));
    return 1;
}

}  // namespace

struct lcf_db {
    std::unique_ptr<lcf::rpg::Database> object;
    std::string encoding;
    StringIndex<lcf::rpg::Database> strings;
};

struct lcf_map {
    std::unique_ptr<lcf::rpg::Map> object;
    std::string encoding;
    bool use_2003 = false;   // 只影响 save
    StringIndex<lcf::rpg::Map> strings;
};

struct lcf_tree {
    std::unique_ptr<lcf::rpg::TreeMap> object;
    std::string encoding;
    StringIndex<lcf::rpg::TreeMap> strings;
};

extern "C" {

// ---------------------------------------------------------------------------
// 数据库
// ---------------------------------------------------------------------------

lcf_db* lcf_db_load(const char* path_utf8, const char* encoding) {
    if (path_utf8 == nullptr) { return nullptr; }
    // 只有 "" 是"原始字节直通"。NULL 也按 "" 处理：本构建没有 ICU，
    // 自动检测只会退化成 cp1252 而损坏数据。
    std::string enc = (encoding != nullptr) ? encoding : "";

    auto database = lcf::LDB_Reader::Load(path_utf8, enc);
    if (!database) { return nullptr; }

    auto* handle = new lcf_db();
    handle->object = std::move(database);
    handle->encoding = enc;
    return handle;
}

void lcf_db_free(lcf_db* db) {
    delete db;
}

const char* lcf_db_encoding(const lcf_db* db) {
    return (db != nullptr) ? db->encoding.c_str() : "";
}

int lcf_db_for_each_string(lcf_db* db, lcf_string_cb cb, void* userdata) {
    if (db == nullptr || !db->object || cb == nullptr) { return 0; }
    return db->strings.each(*db->object, cb, userdata);
}

const char* lcf_db_get_bytes(lcf_db* db, const char* path, int* out_len) {
    if (db == nullptr || !db->object || path == nullptr) { return nullptr; }
    lcf::DBString* field = db->strings.find(*db->object, path);
    if (field == nullptr) { return nullptr; }
    return store_and_return(*field, db->strings.scratch, out_len);
}

int lcf_db_set_bytes(lcf_db* db, const char* path, const char* bytes, int len) {
    if (db == nullptr || !db->object || path == nullptr) { return 0; }
    return assign_field(db->strings.find(*db->object, path), bytes, len);
}

int lcf_db_save(lcf_db* db, const char* path_utf8, const char* encoding) {
    if (db == nullptr || !db->object || path_utf8 == nullptr) { return 0; }
    std::string enc = (encoding != nullptr) ? encoding : db->encoding;
    return lcf::LDB_Reader::Save(path_utf8, *db->object, enc) ? 1 : 0;
}

int lcf_db_actor_count(const lcf_db* db) {
    return (db != nullptr && db->object) ? static_cast<int>(db->object->actors.size()) : 0;
}

int lcf_db_item_count(const lcf_db* db) {
    return (db != nullptr && db->object) ? static_cast<int>(db->object->items.size()) : 0;
}

int lcf_db_ldb_id(const lcf_db* db) {
    return (db != nullptr && db->object) ? static_cast<int>(db->object->system.ldb_id) : 0;
}

int lcf_db_for_each_message(lcf_db* db, lcf_message_cb cb, void* userdata) {
    if (db == nullptr || !db->object || cb == nullptr) { return 0; }
    int count = 0;
    for (size_t i = 0; i < db->object->commonevents.size(); ++i) {
        count += each_message_block(db->object->commonevents[i].event_commands,
                                    "commonevents[" + std::to_string(i) + "]", cb, userdata);
    }
    for (size_t t = 0; t < db->object->troops.size(); ++t) {
        for (size_t p = 0; p < db->object->troops[t].pages.size(); ++p) {
            count += each_message_block(db->object->troops[t].pages[p].event_commands,
                                        "troops[" + std::to_string(t) + "].pages["
                                            + std::to_string(p) + "]", cb, userdata);
        }
    }
    return count;
}

// ---------------------------------------------------------------------------
// 地图
// ---------------------------------------------------------------------------

lcf_map* lcf_map_load(const char* path_utf8, const char* encoding) {
    if (path_utf8 == nullptr) { return nullptr; }
    std::string enc = (encoding != nullptr) ? encoding : "";
    auto map = lcf::LMU_Reader::Load(path_utf8, enc);
    if (!map) { return nullptr; }
    auto* handle = new lcf_map();
    handle->object = std::move(map);
    handle->encoding = enc;
    return handle;
}

void lcf_map_free(lcf_map* map) {
    delete map;
}

void lcf_map_set_engine(lcf_map* map, int use_2003) {
    if (map != nullptr) { map->use_2003 = (use_2003 != 0); }
}

int lcf_map_for_each_message(lcf_map* map, lcf_message_cb cb, void* userdata) {
    if (map == nullptr || !map->object || cb == nullptr) { return 0; }
    int count = 0;
    for (size_t e = 0; e < map->object->events.size(); ++e) {
        for (size_t p = 0; p < map->object->events[e].pages.size(); ++p) {
            count += each_message_block(map->object->events[e].pages[p].event_commands,
                                        "events[" + std::to_string(e) + "].pages["
                                            + std::to_string(p) + "]", cb, userdata);
        }
    }
    return count;
}

int lcf_map_for_each_string(lcf_map* map, lcf_string_cb cb, void* userdata) {
    if (map == nullptr || !map->object || cb == nullptr) { return 0; }
    return map->strings.each(*map->object, cb, userdata);
}

const char* lcf_map_get_bytes(lcf_map* map, const char* path, int* out_len) {
    if (map == nullptr || !map->object || path == nullptr) { return nullptr; }
    lcf::DBString* field = map->strings.find(*map->object, path);
    if (field == nullptr) { return nullptr; }
    return store_and_return(*field, map->strings.scratch, out_len);
}

int lcf_map_set_bytes(lcf_map* map, const char* path, const char* bytes, int len) {
    if (map == nullptr || !map->object || path == nullptr) { return 0; }
    return assign_field(map->strings.find(*map->object, path), bytes, len);
}

int lcf_map_save(lcf_map* map, const char* path_utf8, const char* encoding) {
    if (map == nullptr || !map->object || path_utf8 == nullptr) { return 0; }
    std::string enc = (encoding != nullptr) ? encoding : map->encoding;
    const lcf::EngineVersion engine = map->use_2003 ? lcf::EngineVersion::e2k3
                                                   : lcf::EngineVersion::e2k;
    return lcf::LMU_Reader::Save(path_utf8, *map->object, engine, enc) ? 1 : 0;
}

// ---------------------------------------------------------------------------
// 地图树
// ---------------------------------------------------------------------------

lcf_tree* lcf_tree_load(const char* path_utf8, const char* encoding) {
    if (path_utf8 == nullptr) { return nullptr; }
    std::string enc = (encoding != nullptr) ? encoding : "";
    auto tree = lcf::LMT_Reader::Load(path_utf8, enc);
    if (!tree) { return nullptr; }
    auto* handle = new lcf_tree();
    handle->object = std::move(tree);
    handle->encoding = enc;
    return handle;
}

void lcf_tree_free(lcf_tree* tree) {
    delete tree;
}

int lcf_tree_map_count(const lcf_tree* tree) {
    return (tree != nullptr && tree->object) ? static_cast<int>(tree->object->maps.size()) : 0;
}

int lcf_tree_map_id_at(const lcf_tree* tree, int index) {
    if (tree == nullptr || !tree->object) { return -1; }
    if (index < 0 || index >= static_cast<int>(tree->object->maps.size())) { return -1; }
    return static_cast<int>(tree->object->maps[static_cast<size_t>(index)].ID);
}

int lcf_tree_for_each_string(lcf_tree* tree, lcf_string_cb cb, void* userdata) {
    if (tree == nullptr || !tree->object || cb == nullptr) { return 0; }
    return tree->strings.each(*tree->object, cb, userdata);
}

}  // extern "C"
