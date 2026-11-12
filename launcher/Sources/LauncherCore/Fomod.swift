import Foundation

/// A FOMOD installer (fomod/ModuleConfig.xml): required files plus steps of option groups. Conditional installs that
/// depend on flags set by the chosen options are supported; dependencies on other installed files are treated as unmet.
public struct Fomod: Sendable {
    public struct FileMap: Sendable, Hashable { public var source: String; public var destination: String; public var isFolder: Bool }

    public struct Option: Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let description: String
        public let type: String        // Required, Recommended, Optional, NotUsable, CouldBeUsable
        public let files: [FileMap]
        public let flags: [String: String]
    }

    public struct Group: Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let type: String        // SelectExactlyOne, SelectAtMostOne, SelectAtLeastOne, SelectAny, SelectAll
        public let options: [Option]
    }

    public struct Step: Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let groups: [Group]
    }

    public let name: String
    public let required: [FileMap]
    public let steps: [Step]
    let conditional: [(flags: [String: String], files: [FileMap])]

    /// Parses `<root>/fomod/ModuleConfig.xml` (case-insensitive lookup).
    public static func load(root: URL) -> Fomod? {
        let fm = FileManager.default
        guard let dirName = (try? fm.contentsOfDirectory(atPath: root.path))?.first(where: { $0.lowercased() == "fomod" }) else { return nil }
        let dir = root.appendingPathComponent(dirName)
        guard let file = (try? fm.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.lowercased() == "moduleconfig.xml" }),
              let doc = try? XMLDocument(contentsOf: dir.appendingPathComponent(file), options: []) else { return nil }

        func maps(_ node: XMLNode?) -> [FileMap] {
            guard let el = node as? XMLElement else { return [] }
            return (el.children ?? []).compactMap { child in
                guard let c = child as? XMLElement, ["file", "folder"].contains(c.name ?? "") else { return nil }
                let src = (c.attribute(forName: "source")?.stringValue ?? "").replacingOccurrences(of: "\\", with: "/")
                let dst = (c.attribute(forName: "destination")?.stringValue ?? src).replacingOccurrences(of: "\\", with: "/")
                return FileMap(source: src, destination: dst, isFolder: c.name == "folder")
            }
        }
        func first(_ el: XMLElement, _ name: String) -> XMLElement? { el.elements(forName: name).first }

        guard let rootEl = doc.rootElement() else { return nil }
        let name = first(rootEl, "moduleName")?.stringValue ?? "FOMOD"
        let required = maps(first(rootEl, "requiredInstallFiles"))
        var steps: [Step] = []
        for (si, step) in (first(rootEl, "installSteps")?.elements(forName: "installStep") ?? []).enumerated() {
            var groups: [Group] = []
            for (gi, group) in (first(step, "optionalFileGroups")?.elements(forName: "group") ?? []).enumerated() {
                var options: [Option] = []
                for (pi, plugin) in (first(group, "plugins")?.elements(forName: "plugin") ?? []).enumerated() {
                    var flags: [String: String] = [:]
                    for f in first(plugin, "conditionFlags")?.elements(forName: "flag") ?? [] {
                        flags[f.attribute(forName: "name")?.stringValue ?? ""] = f.stringValue ?? ""
                    }
                    let type = first(plugin, "typeDescriptor").flatMap { td in
                        first(td, "type")?.attribute(forName: "name")?.stringValue
                            ?? first(td, "dependencyType").flatMap { first($0, "defaultType")?.attribute(forName: "name")?.stringValue }
                    } ?? "Optional"
                    options.append(Option(id: "\(si).\(gi).\(pi)", name: plugin.attribute(forName: "name")?.stringValue ?? "Option",
                                          description: (first(plugin, "description")?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                          type: type, files: maps(first(plugin, "files")), flags: flags))
                }
                groups.append(Group(id: "\(si).\(gi)", name: group.attribute(forName: "name")?.stringValue ?? "Options",
                                    type: group.attribute(forName: "type")?.stringValue ?? "SelectAny", options: options))
            }
            steps.append(Step(id: "\(si)", name: step.attribute(forName: "name")?.stringValue ?? "Step \(si + 1)", groups: groups))
        }
        var conditional: [([String: String], [FileMap])] = []
        for pattern in first(rootEl, "conditionalFileInstalls").flatMap({ first($0, "patterns") })?.elements(forName: "pattern") ?? [] {
            var flags: [String: String] = [:]
            for dep in first(pattern, "dependencies")?.elements(forName: "flagDependency") ?? [] {
                flags[dep.attribute(forName: "flag")?.stringValue ?? ""] = dep.attribute(forName: "value")?.stringValue ?? ""
            }
            conditional.append((flags, maps(first(pattern, "files"))))
        }
        return Fomod(name: name, required: required, steps: steps, conditional: conditional)
    }

    /// The options a user sees selected by default: Required and Recommended ones, else the first of each
    /// SelectExactlyOne / SelectAtLeastOne group.
    public func defaultSelection() -> Set<String> {
        var out = Set<String>()
        for g in steps.flatMap(\.groups) {
            let pick = g.options.filter { ["Required", "Recommended"].contains($0.type) }
            if g.type == "SelectAll" { out.formUnion(g.options.map(\.id)) }
            else if !pick.isEmpty { out.formUnion((g.type == "SelectExactlyOne" || g.type == "SelectAtMostOne") ? [pick[0].id] : pick.map(\.id)) }
            else if (g.type == "SelectExactlyOne" || g.type == "SelectAtLeastOne"), let f = g.options.first { out.insert(f.id) }
        }
        return out
    }

    /// The file maps for a selection of option ids, in install order (later ones overwrite earlier ones).
    public func files(for selection: Set<String>) -> [FileMap] {
        var out = required
        var flags: [String: String] = [:]
        for o in steps.flatMap(\.groups).flatMap(\.options) where selection.contains(o.id) {
            out += o.files
            flags.merge(o.flags) { _, new in new }
        }
        for (need, files) in conditional where need.allSatisfy({ flags[$0.key] == $0.value }) { out += files }
        return out
    }
}
