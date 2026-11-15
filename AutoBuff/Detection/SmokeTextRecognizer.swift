import CoreGraphics
import Foundation
import Vision

struct SmokeTextBlock: Sendable {
    let text: String
    let center: CGPoint
}

enum SmokeGamePage: Sendable, Equatable {
    case login
    case character
}

enum SmokeTextRecognizer {
    static func recognize(
        _ image: ImageBuffer,
        region: CGRect? = nil,
        minimumConfidence: Float = 0.25
    ) -> [SmokeTextBlock] {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = (region ?? bounds).intersection(bounds).integral
        guard !crop.isNull, crop.width > 0, crop.height > 0,
              let cropped = image.cropped(x: Int(crop.minX), y: Int(crop.minY), width: Int(crop.width), height: Int(crop.height)),
              let cgImage = makeImage(cropped) else { return [] }
        let scale = region == nil ? 2 : 5
        guard let context = CGContext(data: nil, width: cropped.width * scale, height: cropped.height * scale,
                                      bitsPerComponent: 8, bytesPerRow: cropped.width * scale * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cropped.width * scale, height: cropped.height * scale))
        guard let enlarged = context.makeImage() else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hant", "zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: enlarged, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else { return nil }
            let box = observation.boundingBox
            return SmokeTextBlock(
                text: candidate.string,
                center: CGPoint(
                    x: crop.minX + box.midX * crop.width,
                    y: crop.minY + (1 - box.midY) * crop.height
                )
            )
        }
    }

    static func normalize(_ value: String) -> String {
        value.filter { !$0.isWhitespace && !$0.isNewline }.lowercased()
    }

    static func contains(_ blocks: [SmokeTextBlock], any words: [String]) -> Bool {
        blocks.contains { block in
            let value = normalize(block.text)
            return words.contains { value.contains(normalize($0)) }
        }
    }

    static func matchingFriend(_ blocks: [SmokeTextBlock], name: String) -> CGPoint? {
        let expected = normalize(name)
        guard !expected.isEmpty else { return nil }
        let candidates = blocks.filter { block in
            let value = normalize(block.text)
            let latinPrefix = expected.prefix(while: { $0.isASCII && $0.isLetter })
            guard matchesName(value, expected) || (latinPrefix.count >= 4 && value.hasPrefix(latinPrefix)) else { return false }
            return blocks.contains { status in
                let statusText = normalize(status.text)
                return statusText.hasPrefix("正在")
                    && status.center.y >= block.center.y
                    && status.center.y - block.center.y <= 20
                    && abs(status.center.x - block.center.x) <= 55
            }
        }
        return candidates.count == 1 ? candidates[0].center : nil
    }

    static func matchesName(_ observed: String, _ expected: String) -> Bool {
        guard !observed.isEmpty else { return false }
        if observed == expected { return true }
        guard observed.count < expected.count, expected.count - observed.count <= 2 else { return false }
        var remainder = expected[...]
        for character in observed {
            guard let index = remainder.firstIndex(of: character) else { return false }
            remainder = remainder[remainder.index(after: index)...]
        }
        return true
    }

    static func togetherAction(_ blocks: [SmokeTextBlock]) -> CGPoint? {
        let candidates = blocks.filter { normalize($0.text).hasPrefix("一起") }
        return candidates.count == 1 ? candidates[0].center : nil
    }

    static func togetherGameConfirmationVisible(_ blocks: [SmokeTextBlock]) -> Bool {
        contains(blocks, any: ["一起进行游戏", "一起進行遊戲"])
    }

    static func isSocialPanel(_ blocks: [SmokeTextBlock]) -> Bool {
        contains(blocks, any: ["社交", "好友"])
    }

    static func gamePage(_ blocks: [SmokeTextBlock]) -> SmokeGamePage? {
        if isCharacterSelection(blocks) { return .character }
        if contains(blocks, any: ["密码", "密碼", "登录", "登入"]) { return .login }
        return nil
    }

    static func isCharacterSelection(_ blocks: [SmokeTextBlock]) -> Bool {
        contains(blocks, any: ["新建角色", "选择角色", "選擇角色"])
    }

    static func dailyRewardVisible(_ blocks: [SmokeTextBlock]) -> Bool {
        blocks.contains {
            let value = normalize($0.text)
            return value.contains("每日") && (value.contains("奖励") || value.contains("獎勵"))
        }
    }

    static func signInVisible(_ blocks: [SmokeTextBlock]) -> Bool {
        contains(blocks, any: ["连续签到", "連續簽到"])
    }

    private static func makeImage(_ buffer: ImageBuffer) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: buffer.width * buffer.height * 4)
        for index in 0..<(buffer.width * buffer.height) {
            rgba[index * 4] = buffer.bgr[index * 3 + 2]
            rgba[index * 4 + 1] = buffer.bgr[index * 3 + 1]
            rgba[index * 4 + 2] = buffer.bgr[index * 3]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: buffer.width, height: buffer.height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: buffer.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
