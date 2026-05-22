import Foundation

/// Phase 6B: 簡易エフェクトチェイン DSL。
///
/// 文法:
///   chain := step ("->" step)*
///   step  := identifier ("(" arg ("," arg)* ")")?
///   arg   := number   (key=value 形式は v1.1 で対応予定: TODO)
///
/// 例: "plasma -> bloom(0.4) -> vignette(0.8)"
public enum EffectChainDSL {

    public enum ParseError: Error, Equatable {
        case emptyInput
        case missingClosingParen(step: String)
        case invalidArgument(step: String, raw: String)
        case invalidIdentifier(raw: String)
        case unknownEffect(String)
    }

    public static func parse(_ source: String) throws -> [EffectInvocation] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ParseError.emptyInput
        }
        let stepStrings = splitByArrow(trimmed)
        var result: [EffectInvocation] = []
        for raw in stepStrings {
            let step = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if step.isEmpty { continue }
            result.append(try parseStep(step))
        }
        if result.isEmpty {
            throw ParseError.emptyInput
        }
        return result
    }

    /// "->" でトークン化する (シングルパス)。
    private static func splitByArrow(_ s: String) -> [String] {
        let parts = s.components(separatedBy: "->")
        return parts
    }

    /// "name(0.4, 0.8)" や "name" を 1 ステップに分解する。
    private static func parseStep(_ raw: String) throws -> EffectInvocation {
        // 括弧があれば引数を抜き出す。
        if let openIdx = raw.firstIndex(of: "(") {
            guard let closeIdx = raw.lastIndex(of: ")") else {
                throw ParseError.missingClosingParen(step: raw)
            }
            if closeIdx <= openIdx {
                throw ParseError.missingClosingParen(step: raw)
            }
            let nameRaw = raw[..<openIdx]
            let argsRaw = raw[raw.index(after: openIdx)..<closeIdx]
            let name = String(nameRaw).trimmingCharacters(in: .whitespacesAndNewlines)
            try validateIdentifier(name)
            // close 以降にゴミがあるか確認
            let trailing = raw[raw.index(after: closeIdx)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                throw ParseError.invalidArgument(step: raw, raw: trailing)
            }

            var args: [Double] = []
            let argTokens = String(argsRaw)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for token in argTokens where !token.isEmpty {
                guard let value = Double(token) else {
                    throw ParseError.invalidArgument(step: raw, raw: token)
                }
                args.append(value)
            }
            return EffectInvocation(id: name, positionalArguments: args)
        } else {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            try validateIdentifier(name)
            return EffectInvocation(id: name, positionalArguments: [])
        }
    }

    private static func validateIdentifier(_ name: String) throws {
        if name.isEmpty {
            throw ParseError.invalidIdentifier(raw: name)
        }
        for ch in name {
            if !(ch.isLetter || ch.isNumber || ch == "_") {
                throw ParseError.invalidIdentifier(raw: name)
            }
        }
        // 先頭は文字 / アンダースコアであること
        if let first = name.first, !(first.isLetter || first == "_") {
            throw ParseError.invalidIdentifier(raw: name)
        }
    }
}
