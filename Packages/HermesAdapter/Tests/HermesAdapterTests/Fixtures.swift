import Foundation
@testable import HermesAdapter

enum FixtureVersion: String, CaseIterable {
    case current
    case previous
}

// Les fixtures vivent dans Fixtures/ à côté de ce fichier : le paquet les lit en place, sans copie
struct Fixture {
    let version: FixtureVersion
    let root: [String: Any]

    static func load(_ version: FixtureVersion) throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hermes-\(version.rawValue)/contract.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return Fixture(version: version, root: object as! [String: Any])
    }

    var contracts: [String: [String: Any]] { root["contracts"] as! [String: [String: Any]] }
    var events: [[String: Any]] { root["events"] as! [[String: Any]] }

    static let placeholders = [
        "{profile}": "hv-bot-a", "{session}": "api_1_abc", "{new_session}": "api_1_abc",
        "{run}": "run_1", "{new_run}": "run_1", "{model}": "hv-fake-2", "{route_source}": "session_model_lock", "{n}": "1",
    ]

    /// Corps JSON de référence d'un contrat, avec les variables de chemin remplacées
    func response(_ name: String, fields: Bool = false) throws -> Data {
        let value = contracts[name]!["response"]!
        return try Fixture.serialize(fields ? Fixture.mutate(value) : value)
    }

    func event(named name: String, fields: Bool = false) throws -> Data {
        let value: Any = events.first { $0["event"] as? String == name }!
        return try Fixture.serialize(fields ? Fixture.mutate(value) : value)
    }

    var profileTable: String { contracts["list_profiles"]!["output"] as! String }

    static func serialize(_ value: Any) throws -> Data {
        var text = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        for (key, replacement) in placeholders { text = text.replacingOccurrences(of: key, with: replacement) }
        return Data(text.utf8)
    }

    /// Variante du mode `fields` du faux serveur : retire `title` (premier champ facultatif), ajoute `zz_new_field`
    static func mutate(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var out = object.filter { $0.key != "title" }.mapValues(mutate)
            out["zz_new_field"] = "ignore-moi"
            return out
        }
        if let array = value as? [Any] { return array.map(mutate) }
        return value
    }

    /// Flux SSE d'un tour : tous les événements de la fixture, puis le marqueur de fin
    func sseStream(fields: Bool = false, extra: [[String: Any]] = []) throws -> Data {
        var text = ": open\n\n"
        for (index, event) in (events + extra).enumerated() {
            let json = String(decoding: try Fixture.serialize(fields ? Fixture.mutate(event) : event), as: UTF8.self)
            text += "id: \(index)\ndata: \(json)\n\n"
        }
        return Data((text + ": stream closed\n\n").utf8)
    }
}
