import CoreGraphics
import Foundation

enum TemplatePaths {
    static let marketButton = "Templates/market/market_btn"
    static let marketLogo = "Templates/market/market_logo"
    static let confirmButton = "Templates/dialog/confirm_btn"
    static let partyAcceptButton = "Templates/party/accept_btn"
    static let partyDeclineButton = "Templates/party/decline_btn"
    static let expAnchor = "Templates/exp/exp_anchor"
    static let expLeftParenthesis = "Templates/exp/exp_left_paren"
    static let expDot = "Templates/exp/exp_dot"
    static let expPercent = "Templates/exp/exp_percent"
    static let expRightParenthesis = "Templates/exp/exp_right_paren"

    static func expDigit(_ digit: Int) -> String {
        "Templates/exp/exp_char_\(digit)"
    }
    
    static func load(_ resource: String) -> ImageBuffer? {
        ImagePipeline.loadTemplate(named: resource + ".png")
    }
}
