
import Foundation
import UIKit

enum Icon_: String, CaseIterable, Identifiable {
    case primary
    case trioBlack
    case trioWhiteShadow
    case trioColorBG
    case trioWhite
    case trioCircledNoBackground
    case trio3D
    case wilford = "diabeetus"
    case catWithPod
    case catWithPodWhite = "catWithPodWhiteBG"
    case hiroSleepCat, hiroRoundCat, hiroShiba, hiroSpaniel, hiroCorgi
    var id: String { rawValue }
}

class Icons: ObservableObject, Equatable {
    @Published var appIcon: Icon_ = .primary

    static func == (lhs: Icons, rhs: Icons) -> Bool {
        lhs.appIcon == rhs.appIcon
    }

    func setAlternateAppIcon(icon: Icon_) {
        let selected = Icon_.resolvedIcon(named: icon == .primary ? nil : icon.rawValue)
        let iconName: String? = (selected != .primary) ? selected.rawValue : nil

        guard UIApplication.shared.alternateIconName != iconName else { return }

        UIApplication.shared.setAlternateIconName(iconName) { error in
            if let error = error {
                warning(.ui, "Changing the app icon failed", error: error)
            } else {
                DispatchQueue.main.async { self.appIcon = selected }
            }
        }

    }

    init() {
        let iconName = UIApplication.shared.alternateIconName

        appIcon = Icon_.resolvedIcon(named: iconName)
    }
}
