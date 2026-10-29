/*
 * rmmz_core.js —— **空壳**。
 *
 * 它的唯一职责是让 EngineDetector 命中 MZ：
 *   Sources/Adapters/EngineDetector.swift 只判断 <root>/js/rmmz_core.js 是否存在（不读内容）。
 * 真实 MZ 运行时代码由 ../engine_stub.js 顶替，本文件不会被 index.html 加载。
 */
