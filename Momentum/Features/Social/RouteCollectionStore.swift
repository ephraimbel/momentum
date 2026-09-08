import Foundation
import Observation

/// Private, local organization of saved posts. Separate from the shipped SwiftData schema.
/// Profile scoping prevents collection names leaking into another athlete's library on this device.
@MainActor @Observable
final class RouteCollectionStore {
    struct Collection: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var routeIDs: Set<UUID> = []
    }
    private(set) var collections: [Collection] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var key: String?
    private static let prefix = "com.momentum.routeCollections."

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load(profileID: UUID?) {
        key = profileID.map { Self.prefix + $0.uuidString }
        collections = key.flatMap { defaults.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode([Collection].self, from: $0) } ?? []
    }
    @discardableResult func create(name: String) -> UUID? {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard key != nil, !name.isEmpty else { return nil }
        if let existing = collections.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return existing.id }
        let collection = Collection(name: name)
        collections.append(collection); persist()
        return collection.id
    }
    func add(routeID: UUID, to collectionID: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if collections[index].routeIDs.insert(routeID).inserted { persist() }
    }
    func toggle(routeID: UUID, in collectionID: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if collections[index].routeIDs.contains(routeID) { collections[index].routeIDs.remove(routeID) }
        else { collections[index].routeIDs.insert(routeID) }
        persist()
    }
    func remove(_ id: UUID) { collections.removeAll { $0.id == id }; persist() }
    func prune(validIDs: Set<UUID>) {
        let previous = collections
        for i in collections.indices { collections[i].routeIDs.formIntersection(validIDs) }
        if previous != collections { persist() }
    }
    private func persist() {
        guard let key, let data = try? JSONEncoder().encode(collections) else { return }
        defaults.set(data, forKey: key)
    }
    static func clearAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
    }
}
