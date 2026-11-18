import Combine
import Foundation
import SwiftUI
import Swinject

struct TagCloudView: View {
    var tags: [String]
    var shouldParseToMmolL: Bool

    @Environment(\.colorScheme) var colorScheme

    @State private var totalHeight = CGFloat.zero // << variant for ScrollView/List
//    = CGFloat.infinity // << variant for VStack

    var body: some View {
        VStack {
            GeometryReader { geometry in
                self.generateContent(in: geometry)
            }
        }
        .frame(height: totalHeight) // << variant for ScrollView/List
//        .frame(maxHeight: totalHeight) // << variant for VStack
    }

    private func generateContent(in geometry: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero

        return ZStack(alignment: .topLeading) {
            ForEach(self.tags, id: \.self) { tag in
                self.drawTag(for: tag, isMmolL: shouldParseToMmolL)
                    .padding([.horizontal, .vertical], 3)
                    .alignmentGuide(.leading, computeValue: { dimensions in
                        if abs(width - dimensions.width) > geometry.size.width {
                            width = 0
                            height -= dimensions.height
                        }
                        let result = width
                        if tag == self.tags.last! {
                            width = 0 // last item
                        } else {
                            width -= dimensions.width
                        }
                        return result
                    })
                    .alignmentGuide(.top, computeValue: { _ in
                        let result = height
                        if tag == self.tags.last! {
                            height = 0 // last item
                        }
                        return result
                    })
            }
        }.background(viewHeightReader($totalHeight))
    }

    private func drawTag(for textTag: String, isMmolL: Bool) -> some View {
        var colorOfTag: Color {
            switch textTag {
            case textTag where textTag.contains("SMB Delivery Ratio:"):
                return .uam
            case textTag where textTag.contains("Bolus"),
                 textTag where textTag.contains("Swift Oref"): // FIXME: remove this before feat/dev-oref-swift is merged to dev
                return .green
            case textTag where textTag.contains("TDD:"),
                 textTag where textTag.contains("tdd_factor"),
                 textTag where textTag.contains("Sigmoid function"),
                 textTag where textTag.contains("Logarithmic formula"),
                 textTag where textTag.contains("AF:"),
                 textTag where textTag.contains("Autosens/Dynamic Limit:"),
                 textTag where textTag.contains("Dynamic ISF/CR"),
                 textTag where textTag.contains("Basal ratio"),
                 textTag where textTag.contains("SMB Ratio"):
                return .zt
            case textTag where textTag.contains("Middleware:"):
                return .red
            case textTag where textTag.contains("SMB Ratio"):
                return .orange
            case textTag where textTag.contains("Smoothing: On"):
                return .gray
            default:
                return .insulin
            }
        }

        let formattedTextTag = LoopReasonDisplay.localized(formatGlucoseTags(textTag, isMmolL: isMmolL))

        return ZStack {
            Text(formattedTextTag)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .font(.subheadline)
                .fontWeight(.semibold)
                .background(colorOfTag.opacity(colorScheme == .dark ? 0.15 : 0.25))
                .foregroundColor(colorOfTag)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(colorOfTag.opacity(0.4), lineWidth: 2)
                )
        }
    }

    /**
     Converts glucose-related values in the given `tag` string to mmol/L, including ranges (e.g., `ISF: 54→54`), comparisons (e.g., `maxDelta 37 > 20% of BG 95`), and both positive and negative values (e.g., `Dev: -36`).

     - Parameters:
       - tag: The string containing glucose-related values to be converted.
       - isMmolL: A Boolean flag indicating whether to convert values to mmol/L.

     - Returns:
       A string with glucose values converted to mmol/L.

     - Glucose tags handled: `ISF:`, `Target:`, `minPredBG`, `minGuardBG`, `IOBpredBG`, `COBpredBG`, `UAMpredBG`, `Dev:`, `maxDelta`, `BGI`.
     */

    // TODO: Consolidate all mmol parsing methods (in TagCloudView, NightscoutManager and HomeRootView) to one central func
    private func formatGlucoseTags(_ tag: String, isMmolL: Bool) -> String {
        let patterns = [
            "(?:ISF|Target):\\s*-?\\d+\\.?\\d*(?:→-?\\d+\\.?\\d*)+",
            "Dev:\\s*-?\\d+\\.?\\d*",
            "BGI:\\s*-?\\d+\\.?\\d*",
            "Target:\\s*-?\\d+\\.?\\d*",
            "(?:minPredBG|minGuardBG|IOBpredBG|COBpredBG|UAMpredBG)\\s*-?\\d+\\.?\\d*"
        ]
        let pattern = patterns.joined(separator: "|")
        let regex = try! NSRegularExpression(pattern: pattern)

        // Convert only if isMmolL == true; otherwise return original mg/dL string
        func convertToMmolL(_ value: String) -> String {
            if let glucoseValue = Double(value.replacingOccurrences(of: "[^\\d.-]", with: "", options: .regularExpression)) {
                let mmolValue = Decimal(glucoseValue).asMmolL // your mg/dL → mmol/L routine
                return isMmolL ? mmolValue.description : value
            }
            return value
        }

        let matches = regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag))
        var updatedTag = tag

        // Process each match in reverse order
        for match in matches.reversed() {
            guard let range = Range(match.range, in: tag) else { continue }
            let glucoseValueString = String(tag[range])

            if glucoseValueString.contains("→") {
                // -- Handle ISF: X→Y… or Target: X→Y→Z…
                let parts = glucoseValueString.components(separatedBy: ":")
                guard parts.count == 2 else { continue }
                let targetOrISF = parts[0].trimmingCharacters(in: .whitespaces)
                let values = parts[1]
                    .components(separatedBy: "→")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let convertedValues = values.map { convertToMmolL($0) }
                let joined = convertedValues.joined(separator: "→")
                let rebuilt = "\(targetOrISF): \(joined)"
                updatedTag.replaceSubrange(range, with: rebuilt)

            } else if glucoseValueString.starts(with: "Dev:") {
                // -- Handle Dev
                let value = glucoseValueString.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                let formattedValue = convertToMmolL(value)
                let formattedString = "Dev: \(formattedValue)"
                updatedTag.replaceSubrange(range, with: formattedString)

            } else if glucoseValueString.starts(with: "BGI:") {
                // -- Handle BGI
                let value = glucoseValueString.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                let formattedValue = convertToMmolL(value)
                let formattedString = "BGI: \(formattedValue)"
                updatedTag.replaceSubrange(range, with: formattedString)

            } else if glucoseValueString.starts(with: "Target:") {
                // -- Handle Target
                let value = glucoseValueString.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                let formattedValue = convertToMmolL(value)
                let formattedString = "Target: \(formattedValue)"
                updatedTag.replaceSubrange(range, with: formattedString)

            } else {
                // -- Handle everything else (e.g., "minPredBG 39" etc.)
                let parts = glucoseValueString.components(separatedBy: .whitespaces)
                if parts.count >= 2 {
                    let metric = parts[0]
                    let value = parts[1]
                    let formattedValue = convertToMmolL(value)
                    let formattedString = "\(metric): \(formattedValue)"
                    updatedTag.replaceSubrange(range, with: formattedString)
                }
            }
        }

        return updatedTag
    }

    private func viewHeightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { geometry -> Color in
            let rect = geometry.frame(in: .local)
            DispatchQueue.main.async {
                binding.wrappedValue = rect.size.height
            }
            return .clear
        }
    }
}

struct TestTagCloudView: View {
    var body: some View {
        VStack {
            Text("Header").font(.largeTitle)
            TagCloudView(
                tags: ["Ninetendo", "XBox", "PlayStation", "PlayStation 2", "PlayStation 3", "PlayStation 4"],
                shouldParseToMmolL: false
            )
            Text("Some other text")
            Divider()
            Text("Some other cloud")
            TagCloudView(
                tags: ["Apple", "Google", "Amazon", "Microsoft", "Oracle", "Facebook"],
                shouldParseToMmolL: false
            )
        }
    }
}

// Display localization only. The algorithm's reason, units conversion,
// stored history and alert rules still use the English original.
enum LoopReasonDisplay {
    private static let phrases: [(source: String, translated: String)] = [
        ("CGM is calibrating, in ??? state, or noise is high", String(localized: "loop.reason.1", defaultValue: "CGM is calibrating, in ??? state, or noise is high")),
        ("CGM was just calibrated", String(localized: "loop.reason.2", defaultValue: "CGM was just calibrated")),
        ("CGM data is unchanged", String(localized: "loop.reason.3", defaultValue: "CGM data is unchanged")),
        ("If current system time", String(localized: "loop.reason.4", defaultValue: "If current system time")),
        ("is correct, then BG data is too old. The last BG data was read", String(localized: "loop.reason.5", defaultValue: "is correct, then BG data is too old. The last BG data was read")),
        ("~15m change", String(localized: "loop.reason.6", defaultValue: "~15m change")),
        ("~45m change", String(localized: "loop.reason.7", defaultValue: "~45m change")),
        ("Suggested rate is same as profile rate, a temp basal is active, canceling current temp", String(localized: "loop.reason.8", defaultValue: "Suggested rate is same as profile rate, a temp basal is active, canceling current temp")),
        ("Suggested rate is same as profile rate, no temp basal is active, doing nothing", String(localized: "loop.reason.9", defaultValue: "Suggested rate is same as profile rate, no temp basal is active, doing nothing")),
        ("no temp required", String(localized: "loop.reason.10", defaultValue: "no temp required")),
        ("setting current basal of", String(localized: "loop.reason.11", defaultValue: "setting current basal of")),
        ("as temp", String(localized: "loop.reason.12", defaultValue: "as temp")),
        ("basal testing; no adjustment.", String(localized: "loop.reason.13", defaultValue: "basal testing; no adjustment.")),
        ("SMB disabled!", String(localized: "loop.reason.14", defaultValue: "SMB disabled!")),
        ("Autosens/Dynamic Limit:", String(localized: "loop.reason.15", defaultValue: "Autosens/Dynamic Limit:")),
        ("SMB Delivery Ratio:", String(localized: "loop.reason.16", defaultValue: "SMB Delivery Ratio:")),
        ("SMB Ratio:", String(localized: "loop.reason.17", defaultValue: "SMB Ratio:")),
        ("Dynamic ISF: On", String(localized: "loop.reason.18", defaultValue: "Dynamic ISF: On")),
        ("Dynamic ISF/CR", String(localized: "loop.reason.19", defaultValue: "Dynamic ISF/CR")),
        ("Sigmoid function", String(localized: "loop.reason.20", defaultValue: "Sigmoid function")),
        ("Logarithmic formula", String(localized: "loop.reason.21", defaultValue: "Logarithmic formula")),
        ("Autosens ratio:", String(localized: "loop.reason.22", defaultValue: "Autosens ratio:")),
        ("Basal ratio:", String(localized: "loop.reason.23", defaultValue: "Basal ratio:")),
        ("Smoothing: On", String(localized: "loop.reason.24", defaultValue: "Smoothing: On")),
        ("minPredBG", String(localized: "loop.reason.26", defaultValue: "minPredBG")),
        ("minGuardBG", String(localized: "loop.reason.27", defaultValue: "minGuardBG")),
        ("IOBpredBG", String(localized: "loop.reason.28", defaultValue: "IOBpredBG")),
        ("COBpredBG", String(localized: "loop.reason.29", defaultValue: "COBpredBG")),
        ("UAMpredBG", String(localized: "loop.reason.30", defaultValue: "UAMpredBG")),
        ("naive_eventualBG", String(localized: "loop.reason.31", defaultValue: "naive_eventualBG")),
        ("Eventual BG", String(localized: "loop.reason.32", defaultValue: "Eventual BG")),
        ("maxDelta", String(localized: "loop.reason.33", defaultValue: "maxDelta")),
        ("of BG", String(localized: "loop.reason.34", defaultValue: "of BG")),
        ("TDD:", String(localized: "loop.reason.35", defaultValue: "TDD:")),
        ("AF:", String(localized: "loop.reason.36", defaultValue: "AF:")),
        ("ISF:", String(localized: "loop.reason.37", defaultValue: "ISF:")),
        ("COB:", String(localized: "loop.reason.38", defaultValue: "COB:")),
        ("Dev:", String(localized: "loop.reason.39", defaultValue: "Dev:")),
        ("BGI:", String(localized: "loop.reason.40", defaultValue: "BGI:")),
        ("CR:", String(localized: "loop.reason.41", defaultValue: "CR:")),
        ("Target:", String(localized: "loop.reason.42", defaultValue: "Target:")),
        ("max_iob", String(localized: "loop.reason.43", defaultValue: "max_iob")),
        ("insulinReq", String(localized: "loop.reason.44", defaultValue: "insulinReq")),
        ("maxBolus", String(localized: "loop.reason.45", defaultValue: "maxBolus")),
        ("doing nothing", String(localized: "loop.reason.46", defaultValue: "doing nothing")),
        ("is a lot less than needed", String(localized: "loop.reason.47", defaultValue: "is a lot less than needed")),
        ("Middleware:", String(localized: "loop.reason.48", defaultValue: "Middleware:")),
        ("Microbolusing", String(localized: "loop.reason.49", defaultValue: "Microbolusing")),
        ("to microbolus again", String(localized: "loop.reason.50", defaultValue: "to microbolus again"))
    ]

    private static let templates: [(regex: NSRegularExpression, format: String)] = [
        ("Replacing high temp basal of %@ with neutral temp of %@", String(localized: "loop.reason.template.1", defaultValue: "Replacing high temp basal of %@ with neutral temp of %@")),
        ("Shortening %@m long zero temp to 30m.", String(localized: "loop.reason.template.2", defaultValue: "Shortening %@m long zero temp to 30m.")),
        ("Temp %@ <= current basal %@U/hr; doing nothing.", String(localized: "loop.reason.template.3", defaultValue: "Temp %@ <= current basal %@U/hr; doing nothing.")),
        ("Setting neutral temp basal of %@U/hr", String(localized: "loop.reason.template.4", defaultValue: "Setting neutral temp basal of %@U/hr")),
        ("%@m left and %@ ~ req %@U/hr: no temp required", String(localized: "loop.reason.template.5", defaultValue: "%@m left and %@ ~ req %@U/hr: no temp required")),
        ("Canceling temp at %@min before turn of the hour to avoid beeping of MDT. SMB are disabled anyways.", String(localized: "loop.reason.template.6", defaultValue: "Canceling temp at %@min before turn of the hour to avoid beeping of MDT. SMB are disabled anyways.")),
        ("%@ add'l carbs req w/in %@m", String(localized: "loop.reason.template.7", defaultValue: "%@ add'l carbs req w/in %@m")),
        ("temp %@ ~ req %@U/hr.", String(localized: "loop.reason.template.8", defaultValue: "temp %@ ~ req %@U/hr.")),
        ("temp %@ ~< req %@U/hr.", String(localized: "loop.reason.template.9", defaultValue: "temp %@ ~< req %@U/hr.")),
        ("temp %@ >~ req %@U/hr.", String(localized: "loop.reason.template.10", defaultValue: "temp %@ >~ req %@U/hr.")),
        ("temp %@<%@U/hr.", String(localized: "loop.reason.template.11", defaultValue: "temp %@<%@U/hr.")),
        ("setting %@m zero temp.", String(localized: "loop.reason.template.12", defaultValue: "setting %@m zero temp.")),
        ("setting %@m low temp of %@U/h", String(localized: "loop.reason.template.13", defaultValue: "setting %@m low temp of %@U/h")),
        ("no temp, setting %@U/hr.", String(localized: "loop.reason.template.14", defaultValue: "no temp, setting %@U/hr.")),
        ("Setting temp basal of %@U/hr.", String(localized: "loop.reason.template.15", defaultValue: "Setting temp basal of %@U/hr.")),
        ("setting %@U/hr.", String(localized: "loop.reason.template.16", defaultValue: "setting %@U/hr.")),
        ("Microbolusing %@U.", String(localized: "loop.reason.template.17", defaultValue: "Microbolusing %@U.")),
        ("Waiting %@m %@s to microbolus again.", String(localized: "loop.reason.template.18", defaultValue: "Waiting %@m %@s to microbolus again.")),
        ("adj. req. rate: %@ to maxSafeBasal: %@", String(localized: "loop.reason.template.19", defaultValue: "adj. req. rate: %@ to maxSafeBasal: %@")),
        ("%@-%@ in range: no temp required", String(localized: "loop.reason.template.20", defaultValue: "%@-%@ in range: no temp required"))
    ].compactMap { source, localized in
        let fragments = source.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern(for:))
        let number = #"([-+]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))"#
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![a-zA-Z])"# + fragments.joined(separator: number)
        ) else { return nil }
        return (regex, localized)
    }

    static func localized(_ reason: String) -> String {

        if reason.hasPrefix("Middleware:") {
            return String(localized: "loop.reason.48", defaultValue: "Middleware:") + String(reason.dropFirst("Middleware:".count))
        }
        var display = reason
        for template in templates {
            let matches = template.regex.matches(in: display, range: NSRange(display.startIndex..., in: display))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: display) else { continue }
                let arguments: [CVarArg] = (1 ..< match.numberOfRanges).compactMap { index in
                    Range(match.range(at: index), in: display).map { String(display[$0]) }
                }
                guard arguments.count == match.numberOfRanges - 1 else { continue }
                display.replaceSubrange(range, with: String(format: template.format, arguments: arguments))
            }
        }
        return phrases.reduce(display) { result, phrase in
            result.replacingOccurrences(of: phrase.source, with: phrase.translated)
        }
    }
}
