//
//  OttaiSettingsView+Alerts.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI

extension OttaiSettingsView {
    var removeCGMAlert: Alert {
        Alert(
            title: Text("Remove CGM", bundle: .ottaiUI, comment: "delete title"),
            message: Text(
                "Are you sure you want to stop using the Ottai Ultra? Your Ottai account stays signed in, and sensor history is kept.", bundle: .ottaiUI,
                comment: "delete message"
            ),
            primaryButton: .destructive(Text("Confirm", bundle: .ottaiUI, comment: "confirm")) { viewModel.deleteCGM() },
            secondaryButton: .cancel()
        )
    }

    var endSensorAlert: Alert {
        Alert(
            title: Text("End Sensor", bundle: .ottaiUI, comment: "end sensor title"),
            message: Text(
                "This shuts the sensor down and releases it from your Ottai account. You cannot reverse this action or reuse the sensor. Remove it from your arm afterwards.", bundle: .ottaiUI,
                comment: "end sensor message"
            ),
            primaryButton: .destructive(Text("Confirm", bundle: .ottaiUI, comment: "confirm")) { viewModel.endSensor() },
            secondaryButton: .cancel()
        )
    }

    var forceEndSensorAlert: Alert {
        Alert(
            title: Text("Could Not Confirm Shutdown", bundle: .ottaiUI, comment: "force end sensor title"),
            message: Text(
                "Trio could not reach the sensor to confirm it powered down. It may still be transmitting nearby, or it may already be off the air for good. Ending the session now releases it from your account without that confirmation.", bundle: .ottaiUI,
                comment: "force end sensor message"
            ),
            primaryButton: .destructive(Text("End Anyway", bundle: .ottaiUI, comment: "force end confirm")) { viewModel.endSensor(force: true) },
            secondaryButton: .cancel()
        )
    }
}
