//
//  ConfigLoader.swift
//  MacRDP
//
//  YAML config loader with default-overlay semantics.
//
//  Pipeline:
//    1. Encode `DefaultConfig.value` → JSON dictionary tree.
//    2. If a user YAML path is given, parse it → dictionary tree.
//    3. Deep-merge: user overrides default at every nested mapping; leaves
//       and arrays fully replace. Type policing happens at step 4.
//    4. Decode merged tree → typed `Config`.
//
//  If no path is given, just return `DefaultConfig.value`. No filesystem
//  search; the loader is explicit.
//

import Foundation
import Yams

enum ConfigLoader {
    /// Load config. `explicitPath == nil` → return defaults verbatim.
    /// Otherwise parse YAML at `explicitPath`, overlay onto defaults, decode.
    static func load(explicitPath: String?) throws -> Config {
        guard let path = explicitPath else {
            return DefaultConfig.value
        }

        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MacRDPError.configNotFound(path)
        }

        let yamlText: String
        if let s = String(data: data, encoding: .utf8) {
            yamlText = s
        } else {
            throw MacRDPError.configParseFailure(
                "\(path): file is not UTF-8")
        }

        // Empty file → defaults verbatim (treat as "no overrides").
        let trimmed = yamlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return DefaultConfig.value
        }

        let userTree: Any?
        do {
            userTree = try Yams.load(yaml: yamlText)
        } catch {
            throw MacRDPError.configParseFailure(
                "\(path): \(error.localizedDescription)")
        }

        // Top level must be a mapping (or empty). A bare scalar / list at the
        // root is meaningless for our config and would confuse the merge.
        let userDict: [String: Any]
        switch userTree {
        case nil:
            return DefaultConfig.value
        case let d as [String: Any]:
            userDict = d
        default:
            throw MacRDPError.configParseFailure(
                "\(path): top-level YAML must be a mapping, got \(type(of: userTree as Any))")
        }

        return try overlay(userDict: userDict, onto: DefaultConfig.value, path: path)
    }

    // MARK: - Default-overlay

    private static func overlay(userDict: [String: Any],
                                onto defaults: Config,
                                path: String) throws -> Config {
        // Round-trip defaults through JSON to get a homogeneous [String: Any]
        // representation that mirrors the user dict — same primitive types,
        // same shape — so deep-merge sees apples-to-apples.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let defaultData: Data
        do {
            defaultData = try encoder.encode(defaults)
        } catch {
            // Defaults are typed; encoding can't realistically fail. If it
            // does, it's a programming error, not a user-config error.
            throw MacRDPError.configParseFailure(
                "internal: cannot encode default config: \(error)")
        }
        let defaultsAny: Any
        do {
            defaultsAny = try JSONSerialization.jsonObject(
                with: defaultData, options: [.fragmentsAllowed])
        } catch {
            throw MacRDPError.configParseFailure(
                "internal: cannot reserialize default config: \(error)")
        }
        guard var defaultsDict = defaultsAny as? [String: Any] else {
            throw MacRDPError.configParseFailure(
                "internal: default config is not a mapping")
        }

        // Sanity-check user input shape against the default shape: complain
        // about unknown top-level keys early so typos surface as errors, not
        // silent no-ops. (Nested keys are checked recursively below.)
        try checkUnknownKeys(user: userDict, default: defaultsDict, path: "")

        defaultsDict = deepMerge(user: userDict, onto: defaultsDict)

        // Re-encode the merged tree and decode through the typed Config.
        // JSONSerialization is the only place that catches type mismatches
        // we couldn't see while walking [String: Any].
        let mergedData: Data
        do {
            mergedData = try JSONSerialization.data(
                withJSONObject: defaultsDict, options: [.sortedKeys])
        } catch {
            throw MacRDPError.configParseFailure(
                "\(path): merged config is not serializable: \(error.localizedDescription)")
        }

        do {
            return try JSONDecoder().decode(Config.self, from: mergedData)
        } catch {
            throw MacRDPError.configParseFailure(
                "\(path): \(describe(decodingError: error))")
        }
    }

    /// Recursively merge `user` onto `base`. Rules:
    ///   - dict + dict → recurse (union of keys, user wins on collisions).
    ///   - anything else → user value wholly replaces base (including arrays
    ///     and scalars; we do NOT merge by array index — too surprising).
    ///   - NSNull from YAML → leave base unchanged (treat `key: ~` / `key:`
    ///     as "use default", not "set to null"; null isn't representable in
    ///     our typed Config anyway).
    private static func deepMerge(user: [String: Any],
                                  onto base: [String: Any]) -> [String: Any] {
        var out = base
        for (k, uVal) in user {
            if uVal is NSNull { continue }
            if let uDict = uVal as? [String: Any],
               let bDict = out[k] as? [String: Any] {
                out[k] = deepMerge(user: uDict, onto: bDict)
            } else {
                out[k] = uVal
            }
        }
        return out
    }

    /// Walk both trees in parallel and reject user keys absent from defaults.
    /// Stops at the first unknown key, with the full dotted path. We descend
    /// into mappings only; arrays and scalars are leaves.
    private static func checkUnknownKeys(user: [String: Any],
                                         default base: [String: Any],
                                         path: String) throws {
        for (k, uVal) in user {
            guard base[k] != nil else {
                let full = path.isEmpty ? k : "\(path).\(k)"
                throw MacRDPError.configParseFailure(
                    "unknown config key \"\(full)\"")
            }
            if let uDict = uVal as? [String: Any],
               let bDict = base[k] as? [String: Any] {
                let nextPath = path.isEmpty ? k : "\(path).\(k)"
                try checkUnknownKeys(user: uDict, default: bDict, path: nextPath)
            }
        }
    }

    /// Pretty-print a `DecodingError` with the JSON path that broke. Vanilla
    /// `error.localizedDescription` drops the context, so a user sees only
    /// "The data couldn't be read..." with no hint at the field.
    private static func describe(decodingError error: Error) -> String {
        switch error {
        case let DecodingError.typeMismatch(_, ctx),
             let DecodingError.valueNotFound(_, ctx),
             let DecodingError.keyNotFound(_, ctx),
             let DecodingError.dataCorrupted(ctx):
            let path = ctx.codingPath.map { $0.stringValue }.joined(separator: ".")
            let where_ = path.isEmpty ? "" : " at \"\(path)\""
            return "\(ctx.debugDescription)\(where_)"
        default:
            return error.localizedDescription
        }
    }
}
