import Swinject

/// Factories receive this same synchronized resolver, including services that retain it for later callbacks.
enum LockedResolver {
    static func assemble(_ assemblies: [Assembly]) -> Resolver {
        let registrations = Container(defaultObjectScope: .container)
        _ = Assembler(assemblies, container: registrations)
        return registrations.synchronize()
    }
}
