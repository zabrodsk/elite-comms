import Foundation
import PDFKit

/// The delegation brief: every .md/.txt/.pdf in `<workspace>/Brief`, concatenated into the model's background.
enum BriefStore {
    static var workspaceURL: URL {
        if let custom = UserDefaults.standard.string(forKey: "workspacePath"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        // Outside Desktop/Documents on purpose: no privacy prompt, no iCloud sync conflicts.
        let project = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/elite-comms")
        // Only a local source checkout may use the developer's personal brief.
        if FileManager.default.fileExists(atPath: project.appendingPathComponent("Package.swift").path),
           FileManager.default.fileExists(atPath: project.appendingPathComponent("Brief").path) { return project }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("elite-comms")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    static var briefURL: URL { ensure(workspaceURL.appendingPathComponent("Brief")) }
    static var sessionsURL: URL { ensure(workspaceURL.appendingPathComponent("Sessions")) }
    static var notesURL: URL { briefURL.appendingPathComponent("90-my-notes.md") }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Doc: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let words: Int
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    static func documents() -> [Doc] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: briefURL, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["md", "txt", "pdf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Doc(url: $0, words: text(of: $0).split(whereSeparator: \.isWhitespace).count) }
    }

    static func text(of url: URL) -> String {
        if url.pathExtension.lowercased() == "pdf" {
            return PDFDocument(url: url)?.string ?? ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func fullBrief() -> String {
        documents().map { "=== \($0.name) ===\n\(text(of: $0.url))" }.joined(separator: "\n\n")
    }

    /// Imports a file into the brief. PDFs are converted to text so the model sees clean input.
    @discardableResult
    static func importFile(_ url: URL) -> URL? {
        let base = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "pdf" {
            let dest = briefURL.appendingPathComponent("60-\(base).txt")
            let t = PDFDocument(url: url)?.string ?? ""
            try? t.write(to: dest, atomically: true, encoding: .utf8)
            return dest
        }
        let dest = briefURL.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    static func loadNotes() -> String { (try? String(contentsOf: notesURL, encoding: .utf8)) ?? "" }
    static func saveNotes(_ s: String) { try? s.write(to: notesURL, atomically: true, encoding: .utf8) }

    /// Words to bias the on-device recogniser toward.
    static let vocabulary: [String] = {
        var v = Countries.names
        v += [
            "DISEC", "SPECPOL", "ECOSOC", "UNSC", "UNGA", "WHO", "UNHRC", "UNHCR", "UNICEF",
            "UNESCO", "UNEP", "UNDP", "UNODC", "ILO", "IMF", "WTO", "ICC", "ICJ", "IAEA",
            "OAS", "NATO", "ASEAN", "African Union", "European Union", "UN Charter",
            "Article 41", "Article 51", "Chapter VII", "sovereignty", "humanitarian aid",
            "moderated caucus", "unmoderated caucus", "point of information", "point of order",
            "point of personal privilege", "parliamentary inquiry", "right of reply", "yield", "yields",
            "the chair recognises", "honourable delegate", "draft resolution", "operative clause",
            "preambulatory clause", "amendment", "sponsors", "signatories", "abstain", "placard",
        ]
        return v
    }()
}
