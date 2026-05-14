import Foundation
import SwiftUI
import Combine

// MARK: - Model

struct VNCProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String       // display label (defaults to host)
    var host: String
    var port: String
    var password: String
    var lastConnected: Date?

    /// Abbreviated label shown on the chip (host, truncated).
    var chipLabel: String {
        name.isEmpty ? host : name
    }
}

// MARK: - Store

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [VNCProfile] = []
    /// ID of the profile that is currently active (connected or last used).
    @Published var activeProfileID: UUID?

    private let defaultsKey = "vnc.profiles"

    init() {
        load()
        // Seed the hardcoded default if store is empty
        if profiles.isEmpty {
            let seed = VNCProfile(
                name: "PiKVM",
                host: "192.168.50.102",
                port: "5902",
                password: "berecik",
                lastConnected: nil
            )
            profiles = [seed]
            save()
        }
    }

    // MARK: Mutations

    func add(_ profile: VNCProfile) {
        profiles.append(profile)
        save()
    }

    func update(_ profile: VNCProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        save()
    }

    func delete(_ profile: VNCProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = nil }
        save()
    }

    /// Upsert by host+port: if a profile with the same host+port exists, update it;
    /// otherwise append. Marks it as last connected.
    func touch(host: String, port: String, password: String, name: String? = nil) {
        let now = Date()
        if let idx = profiles.firstIndex(where: { $0.host == host && $0.port == port }) {
            profiles[idx].password = password
            profiles[idx].lastConnected = now
            if let n = name, !n.isEmpty { profiles[idx].name = n }
            activeProfileID = profiles[idx].id
        } else {
            let p = VNCProfile(
                name: name ?? host,
                host: host,
                port: port,
                password: password,
                lastConnected: now
            )
            profiles.append(p)
            activeProfileID = p.id
        }
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([VNCProfile].self, from: data)
        else { return }
        profiles = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
