import CoreGraphics
import Foundation

enum TemplatePaths {
    static let marketButton = "Templates/market/market_btn"
    static let marketLogo = "Templates/market/market_logo"
    static let confirmButton = "Templates/dialog/confirm_btn"
    static let partyAcceptButton = "Templates/party/accept_btn"
    static let partyDeclineButton = "Templates/party/decline_btn"
    
    static func load(_ resource: String) -> ImageBuffer? {
        ImagePipeline.loadTemplate(named: resource + ".png")
    }
}
