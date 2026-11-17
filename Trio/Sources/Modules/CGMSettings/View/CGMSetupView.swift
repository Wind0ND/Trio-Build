import LoopKit
import LoopKitUI
import SwiftUI
import SyaiKit
import SyaiKitUI
import UIKit

extension CGMSettings {
    struct CGMSetupView: UIViewControllerRepresentable {
        let CGMType: CGMModel
        let bluetoothManager: BluetoothStateManager
        let unit: GlucoseUnits
        weak var completionDelegate: CompletionDelegate?
        weak var setupDelegate: CGMManagerOnboardingDelegate?
        let pluginCGMManager: PluginManager

        func makeUIViewController(context _: UIViewControllerRepresentableContext<CGMSetupView>) -> UIViewController {
            var setupViewController: SetupUIResult<
                CGMManagerViewController,
                CGMManagerUI
            >?

            let displayGlucosePreference: DisplayGlucosePreference
            switch unit {
            case .mgdL:
                displayGlucosePreference = DisplayGlucosePreference(displayGlucoseUnit: .milligramsPerDeciliter)
            case .mmolL:
                displayGlucosePreference = DisplayGlucosePreference(displayGlucoseUnit: .millimolesPerLiter)
            }

            switch CGMType.type {
            case .plugin:
                let entry = DeviceCatalog.cgmEntry(id: CGMType.id)
                debug(
                    .cgm,
                    "CGM setup: entry=\(entry?.id ?? "nil") factory=\(entry?.onboardingFactory != nil)"
                )
                if let makeVC = entry?.onboardingFactory {
                    // The catalogue carries the builder itself. Nothing here asks what class the
                    // entry is: a subclass of a manager cannot be recognised from inside that
                    // manager's own protocol witness, so the choice has to arrive as data.
                    setupViewController = makeVC(displayGlucosePreference, .default, false)
                } else if let cgmManagerUIType = pluginCGMManager.getCGMManagerTypeByIdentifier(CGMType.id) {
                    setupViewController = cgmManagerUIType.setupViewController(
                        bluetoothProvider: bluetoothManager,
                        displayGlucosePreference: displayGlucosePreference,
                        colorPalette: .default,
                        allowDebugFeatures: false,
                        prefersToSkipUserInteraction: false
                    )
                } else {
                    break
                }
            default:
                break
            }

            switch setupViewController {
            case var .userInteractionRequired(setupViewControllerUI):
                setupViewControllerUI.cgmManagerOnboardingDelegate = setupDelegate
                setupViewControllerUI.completionDelegate = completionDelegate
                return setupViewControllerUI
            case let .createdAndOnboarded(cgmManagerUI):
                debug(.cgm, "CGM setup finished")
                setupDelegate?.cgmManagerOnboarding(didCreateCGMManager: cgmManagerUI)
                return UIViewController()
            case .none:
                return UIViewController()
            }
        }

        func updateUIViewController(
            _ uiViewController: UIViewController,
            context _: UIViewControllerRepresentableContext<CGMSetupView>
        ) {
            uiViewController.isModalInPresentation = true
        }
    }
}
