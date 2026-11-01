//
//  lcf_synth.cpp
//  MochiBox · QA 辅助工具（只在 contract 18 里现场编译，不进产物）
//
//  作用：造两个"现实中存在但仓库里没有"的 LDB，用来钉住版本判据的反方向：
//
//    empty-2k3  读 2003 库 → 清空 classes / battleranimations / battlecommands → 存盘。
//               产物 ldb_id 仍是 2003，但文件里**不会**出现 0x1D/0x1E/0x1F 三个 chunk。
//               用来证明"按 chunk 存在性判版本"会把 2003 误判成 2000。
//
//    inject-2k  读 2000 库 → 塞进一个 Class / BattlerAnimation / BattleCommand → 存盘。
//               产物 ldb_id 仍是 0，liblcf 按 2k 编码，**三个 chunk 与内容全部静默丢弃**，
//               而 Save 返回 true。用来证明"Save 成功 ≠ 数据还在"。
//
//  为什么不把这两个 .ldb 入库：它们是**测试构造物**，不是真实游戏数据；
//  入库等于把"liblcf 的编码行为"固化成二进制证据，反而会随上游升级变成噪声。
//  现场生成 → 断言 → 删，符合本仓库"源码优先"的口径。
//
//  编译（由 18_lcf_extract.mjs 完成）：
//    clang++ -std=c++17 -O2 -I vendor/liblcf-build/install/include \
//            lcf_synth.cpp vendor/liblcf-build/install/lib/liblcf.a -o lcf_synth
//
#include <cstdio>
#include <string>
#include <lcf/ldb/reader.h>
#include <lcf/rpg/database.h>

static int makeEmpty2k3(const char* in, const char* out) {
    auto db = lcf::LDB_Reader::Load(in, "");
    if (!db) { std::fprintf(stderr, "load failed: %s\n", in); return 1; }
    db->classes.clear();
    db->battleranimations.clear();
    db->battlecommands.commands.clear();
    if (!lcf::LDB_Reader::Save(out, *db, "")) { std::fprintf(stderr, "save failed: %s\n", out); return 1; }
    return 0;
}

static int makeInject2k(const char* in, const char* out) {
    auto db = lcf::LDB_Reader::Load(in, "");
    if (!db) { std::fprintf(stderr, "load failed: %s\n", in); return 1; }
    lcf::rpg::Class cls;
    cls.ID = 1;
    cls.name = "SYNTH_CLASS_MARK";
    db->classes.push_back(cls);
    lcf::rpg::BattlerAnimation ba;
    ba.ID = 1;
    ba.name = "SYNTH_BA_MARK";
    db->battleranimations.push_back(ba);
    db->battlecommands.commands.push_back(lcf::rpg::BattleCommand());
    if (!lcf::LDB_Reader::Save(out, *db, "")) { std::fprintf(stderr, "save failed: %s\n", out); return 1; }
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: lcf_synth <empty-2k3|inject-2k> <in.ldb> <out.ldb>\n");
        return 2;
    }
    const std::string mode = argv[1];
    if (mode == "empty-2k3") return makeEmpty2k3(argv[2], argv[3]);
    if (mode == "inject-2k") return makeInject2k(argv[2], argv[3]);
    std::fprintf(stderr, "unknown mode: %s\n", mode.c_str());
    return 2;
}
