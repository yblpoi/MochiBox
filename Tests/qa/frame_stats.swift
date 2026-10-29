//
//  frame_stats.swift
//  MochiBox · QA 工具（AC-8 的机器判据之一：帧非空白）
//
//  读一张 PNG，按 16px 步长采样，输出：
//      <width> <height> <distinct_colors> <mean_luma>
//
//  判据：`distinct_colors > 1` 即"非空白"（AC-8 第 4 条）。
//  **不用固定像素比对**：Retina/缩放假设一变（U2）就会假红，而"是不是纯色"与缩放无关。
//
//  编译： xcrun swiftc -O Tests/qa/frame_stats.swift -o /tmp/frame_stats -framework AppKit
//  用法： /tmp/frame_stats /tmp/window.png
//  退出码：0 = 打印成功；2 = 参数/读取失败；3 = 全空白（distinct == 1）
//

import Foundation
import AppKit

struct FrameStatsMain {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("用法: frame_stats <png>\n".utf8))
            exit(2)
        }
        let path = args[1]
        guard let image = NSImage(contentsOfFile: path) else {
            FileHandle.standardError.write(Data("无法读取图片：\(path)\n".utf8))
            exit(2)
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            FileHandle.standardError.write(Data("无法解码为位图：\(path)\n".utf8))
            exit(2)
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else {
            FileHandle.standardError.write(Data("位图尺寸为 0：\(path)\n".utf8))
            exit(2)
        }

        // 16px 步长：816×624 下约 51×39 = 1989 个采样点。既够密（不会漏掉一小块字），
        // 又足够快（AC-8 每轮只跑一次，但没必要逐像素扫 2M 个点）。
        let step = 16
        var seenColors = Set<UInt32>()
        var lumaSum: Double = 0
        var samples = 0

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                if let color = bitmap.colorAt(x: x, y: y) {
                    // `usingColorSpace(.deviceRGB)` 把 P3/灰度统一到同一坐标，避免同一种颜色
                    // 因色彩空间不同被算成两种。
                    let rgb = color.usingColorSpace(.deviceRGB) ?? color
                    let r = UInt32(max(0, min(255, Int(rgb.redComponent * 255))))
                    let g = UInt32(max(0, min(255, Int(rgb.greenComponent * 255))))
                    let b = UInt32(max(0, min(255, Int(rgb.blueComponent * 255))))
                    seenColors.insert((r << 16) | (g << 8) | b)
                    // Rec.601 亮度：判断"整帧是不是接近纯黑/纯白"用。
                    lumaSum += 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
                    samples += 1
                }
                x += step
            }
            y += step
        }

        let meanLuma = samples > 0 ? lumaSum / Double(samples) : 0
        print(String(
            format: "%d %d %d %.1f",
            width,
            height,
            seenColors.count,
            meanLuma
        ))
        exit(seenColors.count > 1 ? 0 : 3)
    }
}

FrameStatsMain.main()
