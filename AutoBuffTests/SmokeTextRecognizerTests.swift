import CoreGraphics
import Testing
@testable import AutoBuff

struct SmokeTextRecognizerTests {
    @Test func onlineFriendRequiresUniqueOnlineMatch() {
        let blocks = [
            SmokeTextBlock(text: "QQNeNe好喝到咩噗茶", center: CGPoint(x: 796, y: 251)),
            SmokeTextBlock(text: "正在 Artale 繁体中文区", center: CGPoint(x: 800, y: 262)),
            SmokeTextBlock(text: "离线", center: CGPoint(x: 775, y: 294))
        ]

        #expect(
            SmokeTextRecognizer.matchingFriend(blocks, name: "QQNeNe好喝到咩噗茶")
                == CGPoint(x: 796, y: 251)
        )
    }

    @Test func offlineOrDuplicateFriendIsRejected() {
        let offline = [
            SmokeTextBlock(text: "Alice", center: CGPoint(x: 20, y: 20)),
            SmokeTextBlock(text: "离线", center: CGPoint(x: 20, y: 30))
        ]
        #expect(SmokeTextRecognizer.matchingFriend(offline, name: "Alice") == nil)

        let duplicate = [
            SmokeTextBlock(text: "Alice", center: CGPoint(x: 20, y: 20)),
            SmokeTextBlock(text: "正在游戏中", center: CGPoint(x: 20, y: 30)),
            SmokeTextBlock(text: "Alice", center: CGPoint(x: 20, y: 50)),
            SmokeTextBlock(text: "正在游戏中", center: CGPoint(x: 20, y: 60))
        ]
        #expect(SmokeTextRecognizer.matchingFriend(duplicate, name: "Alice") == nil)
    }

    @Test func nameMatchingAllowsOnlySmallDeletionErrors() {
        #expect(SmokeTextRecognizer.matchesName("abde", "abcde"))
        #expect(!SmokeTextRecognizer.matchesName("abXde", "abcde"))
        #expect(!SmokeTextRecognizer.matchesName("ae", "abcde"))
    }

    @Test func togetherActionAndPagePredicatesAreStrict() {
        #expect(
            SmokeTextRecognizer.togetherAction([
                SmokeTextBlock(text: "一起畅游游戏", center: CGPoint(x: 10, y: 20))
            ]) == CGPoint(x: 10, y: 20)
        )
        #expect(
            SmokeTextRecognizer.togetherAction([
                SmokeTextBlock(text: "不是一起", center: CGPoint(x: 10, y: 20))
            ]) == nil
        )
        #expect(
            SmokeTextRecognizer.gamePage([
                SmokeTextBlock(text: "新建角色", center: .zero)
            ]) == .character
        )
        #expect(
            SmokeTextRecognizer.isCharacterSelection([
                SmokeTextBlock(text: "選擇角色", center: .zero)
            ])
        )
        #expect(
            !SmokeTextRecognizer.isCharacterSelection([
                SmokeTextBlock(text: "登录", center: .zero)
            ])
        )
    }

    @Test func detectsTogetherGameConfirmation() {
        #expect(
            SmokeTextRecognizer.togetherGameConfirmationVisible([
                SmokeTextBlock(text: "一起进行游戏", center: .zero)
            ])
        )
        #expect(
            SmokeTextRecognizer.togetherGameConfirmationVisible([
                SmokeTextBlock(text: "一起進行遊戲", center: .zero)
            ])
        )
        #expect(
            !SmokeTextRecognizer.togetherGameConfirmationVisible([
                SmokeTextBlock(text: "一起畅游游戏", center: .zero)
            ])
        )
    }
}
