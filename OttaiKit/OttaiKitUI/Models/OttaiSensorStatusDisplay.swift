//
//  OttaiSensorStatusDisplay.swift
//  OttaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import LoopKitUI
import SwiftUI

enum OttaiSensorStatusDisplay: Equatable, CaseIterable {
    case noSensor
    case connecting
    case ok
    case warmingUp
    case expired
    case malfunction
    case notActivated
    case readingsUnavailable
    case signalLost

    enum Severity { case neutral, good, warning, critical }

    var severity: Severity {
        switch self {
        case .connecting,
             .noSensor,
             .warmingUp: return .neutral
        case .ok: return .good
        case .signalLost: return .warning
        case .expired,
             .malfunction,
             .notActivated,
             .readingsUnavailable: return .critical
        }
    }

    var iconName: String {
        switch self {
        case .noSensor: return "plus.circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .ok: return "checkmark.circle.fill"
        case .warmingUp: return "hourglass"
        case .signalLost: return "antenna.radiowaves.left.and.right.slash"
        case .expired,
             .malfunction,
             .notActivated,
             .readingsUnavailable: return "exclamationmark.triangle.fill"
        }
    }

    func iconColor(_ guidanceColors: GuidanceColors) -> Color {
        switch severity {
        case .neutral: return .secondary
        case .good: return .green
        case .warning: return guidanceColors.warning
        case .critical: return guidanceColors.critical
        }
    }

    var title: Text {
        switch self {
        case .noSensor: return Text("No Sensor", bundle: .ottaiUI, comment: "status no sensor")
        case .connecting: return Text("Connecting", bundle: .ottaiUI, comment: "status connecting")
        case .ok: return Text("Sensor OK", bundle: .ottaiUI, comment: "status ok")
        case .warmingUp: return Text("Warming Up", bundle: .ottaiUI, comment: "status warming up")
        case .expired: return Text("Sensor Expired", bundle: .ottaiUI, comment: "status expired")
        case .malfunction: return Text("Sensor Malfunction", bundle: .ottaiUI, comment: "status malfunction")
        case .notActivated: return Text("Not Activated", bundle: .ottaiUI, comment: "status sensor not activated")
        case .readingsUnavailable: return Text("Readings Unavailable", bundle: .ottaiUI, comment: "status unavailable")
        case .signalLost: return Text("Signal Lost", bundle: .ottaiUI, comment: "status signal lost")
        }
    }

    var message: Text {
        switch self {
        case .noSensor:
            return Text("Pair a new sensor to start receiving readings.", bundle: .ottaiUI, comment: "msg no sensor")
        case .connecting:
            return Text("Establishing a connection to your sensor.", bundle: .ottaiUI, comment: "msg connecting")
        case .ok:
            return Text("Your sensor is functioning normally.", bundle: .ottaiUI, comment: "msg ok")
        case .warmingUp:
            return Text("Your sensor is warming up.", bundle: .ottaiUI, comment: "msg warming up")
        case .expired:
            return Text("Your sensor has expired. Start a new one as soon as possible.", bundle: .ottaiUI, comment: "msg expired")
        case .malfunction:
            return Text("Your sensor is malfunctioning. Start a new one as soon as possible.", bundle: .ottaiUI, comment: "msg malfunction")
        case .notActivated:
            return Text(
                "Your sensor reports itself as not activated. Check that your sensor is nearby, or re-pair if this continues.", bundle: .ottaiUI,
                comment: "msg sensor not activated"
            )
        case .readingsUnavailable:
            return Text(
                "This could be due to compression or connection loss. Wait for it to resolve, or replace the sensor if it persists.", bundle: .ottaiUI,
                comment: "msg unavailable"
            )
        case .signalLost:
            return Text(
                "Readings have been unavailable for a while. This could be compression or connection loss, and it usually resolves on its own. Replace the sensor only if it persists.", bundle: .ottaiUI,
                comment: "msg signal lost"
            )
        }
    }
}
