import Foundation

/// keymap.json produced by scripts/gen-keymap.py from config/totem.keymap + totem-layouts.dtsi.
struct Keymap: Decodable {
    struct PhysicalKey: Decodable {
        let w, h, x, y: Double
        let rot: Double  // degrees
        let rx, ry: Double
    }

    struct Binding: Decodable {
        let kind: String  // key, mod, layer, system, trans, none
        let tap: String?
        let hold: String?
        let layer: Int?
        let desc: String?
    }

    struct Layer: Decodable {
        let id: String
        let name: String
        let keys: [Binding]
    }

    struct Conditional: Decodable {
        let `if`: [Int]
        let then: Int
    }

    let layout: [PhysicalKey]
    let layers: [Layer]
    let conditional: [Conditional]

    static let shared: Keymap? = {
        let bundled = Bundle.main.url(forResource: "keymap", withExtension: "json")
        // `swift run` (no .app bundle): fall back to the file next to the sources.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/keymap.json")
        guard let data = try? Data(contentsOf: bundled ?? source) else { return nil }
        return try? JSONDecoder().decode(Keymap.self, from: data)
    }()

    var winLayer: Int? { layers.firstIndex { $0.name == "WIN" } }

    /// Layers worth showing as tabs: not the WIN overlay and not conditional (auto) layers.
    var browsableLayers: [Int] {
        let hidden = Set(conditional.map(\.then) + [winLayer].compactMap { $0 })
        return layers.indices.filter { !hidden.contains($0) }
    }

    struct ResolvedKey {
        let binding: Binding?
        /// Falls through from a lower layer (shown dimmed).
        let inherited: Bool
        /// Holding this key activates the layer being viewed.
        let activator: Bool
    }

    /// What each key does while `layer` is held, like the firmware resolves it.
    func resolve(layer: Int, windows: Bool) -> [ResolvedKey] {
        var base: Set<Int> = [0]
        if windows, let winLayer { base.insert(winLayer) }

        var active = base.union([layer])
        for c in conditional where c.if.allSatisfy(active.contains) {
            active.insert(c.then)
        }
        let own = layer == 0 ? base.union(active) : active.subtracting(base)
        let order = active.sorted(by: >)

        // Keys on the base layers that activate the viewed layer when held.
        let baseOrder = base.sorted(by: >)
        func baseBinding(_ i: Int) -> Binding? {
            for l in baseOrder where layers[l].keys[i].kind != "trans" { return layers[l].keys[i] }
            return nil
        }

        return layout.indices.map { i in
            var found: (Binding, Int)?
            for l in order where layers[l].keys[i].kind != "trans" {
                found = (layers[l].keys[i], l)
                break
            }
            let activator = layer != 0 && baseBinding(i)?.layer == layer
            guard let (binding, from) = found, binding.kind != "none" else {
                return ResolvedKey(binding: nil, inherited: false, activator: activator)
            }
            return ResolvedKey(binding: binding, inherited: !own.contains(from), activator: activator)
        }
    }
}
