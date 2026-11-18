import CGMSetupKit

struct GS1Target {
    private let identifier: String

    init?(input: String) {
        guard let identifier = CGMPackageCode.sibionicsIdentifier(from: input)
            ?? CGMPackageCode.identifier(input, length: 9 ... 20)
        else { return nil }
        self.identifier = identifier
    }

    func matches(localName: String?) -> Bool {
        guard let localName, let name = CGMPackageCode.identifier(localName, length: 8 ... 20) else { return false }
        return name == identifier
    }
}
