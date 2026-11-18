import CGMSetupKit

struct GS1Target {
    private let identifier: String

    init?(input: String) {
        guard let identifier = CGMPackageCode.sibionicsIdentifier(from: input)
            ?? CGMPackageCode.identifier(input, length: 9 ... 20)
        else { return nil }
        self.identifier = identifier
    }

    func matches(localName: String?, advertisesService: Bool) -> Bool {
        guard let localName, let name = CGMPackageCode.identifier(localName, length: 8 ... 20) else { return false }
        if name == identifier { return true }
        return advertisesService && identifier.count == 8 && (10 ... 11).contains(name.count) && name.hasPrefix(identifier)
    }
}
