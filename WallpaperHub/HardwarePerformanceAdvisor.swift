import Foundation
import Darwin

/// この Mac の CPU 表記とメモリから、パフォーマンスプリセット（FPS・解像度スケール等）を提案する。
enum HardwarePerformanceAdvisor {

    struct Snapshot {
        /// `sysctl machdep.cpu.brand_string`（例: Apple M4 Pro, Intel Core i7）
        let cpuBrandString: String
        let physicalMemoryBytes: UInt64

        /// UI 用（8 / 16 / 24 GB など端数を丸める）
        var formattedMemoryGB: String {
            let gb = Double(physicalMemoryBytes) / (1024 * 1024 * 1024)
            return "\(Int((gb * 2).rounded() / 2)) GB"
        }
    }

    struct Advice {
        let preset: PerformancePreset
        /// 設定画面に表示する短文（日本語）
        let rationale: String
    }

    // MARK: - Public

    static func currentSnapshot() -> Snapshot {
        Snapshot(
            cpuBrandString: sysctlBrandString() ?? "不明",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    static func recommendedAdvice(for snapshot: Snapshot) -> Advice {
        let ramClass = memoryClass(physicalMemoryBytes: snapshot.physicalMemoryBytes)
        let profile = ChipProfile.parse(cpuBrandString: snapshot.cpuBrandString)

        switch profile {
        case .intel:
            if ramClass <= 8 {
                return Advice(
                    preset: .low,
                    rationale: "Intel Mac でメモリが 8GB 級のため、GPU・CPU 負荷を抑えた省電力を推奨します。"
                )
            }
            return Advice(
                preset: .balanced,
                rationale: "Intel Mac 向けの標準提案です。重い壁紙では高品質に上げても構いません。"
            )
        case .unknown:
            return Advice(
                preset: .balanced,
                rationale: "チップ情報を判別できなかったため、まずはバランスを推奨します。"
            )
        case .appleSilicon(let generation, let variant):
            return adviceAppleSilicon(generation: generation, variant: variant, ramClass: ramClass)
        }
    }

    // MARK: - Apple Silicon

    private static func adviceAppleSilicon(
        generation: Int,
        variant: ChipProfile.Variant,
        ramClass: Int
    ) -> Advice {
        switch variant {
        case .base:
            if generation >= 4 && ramClass >= 24 {
                return Advice(
                    preset: .ultra,
                    rationale: "最新世代のベースチップと 24GB 以上のメモリのため、最高品質も選択肢です。"
                )
            }
            if ramClass <= 8 {
                return Advice(
                    preset: .low,
                    rationale: "ベースチップでメモリが 8GB 級のため、まずは省電力（低 FPS・解像度 75%）を推奨します。"
                )
            }
            if generation == 1 {
                return Advice(
                    preset: .balanced,
                    rationale: "Apple M1 と十分なメモリのため、バランス（30FPS）を推奨します。"
                )
            }
            return Advice(
                preset: .high,
                rationale: "新世代ベースチップと十分なメモリのため、高品質（60FPS）を推奨します。"
            )

        case .pro, .max, .ultra:
            if ramClass <= 8 {
                return Advice(
                    preset: .balanced,
                    rationale: "Pro / Max / Ultra でもメモリが 8GB 級のため、バランスを推奨します。"
                )
            }
            if generation >= 4 {
                return Advice(
                    preset: .ultra,
                    rationale: "M4 Pro / Max / Ultra 相当と十分なメモリのため、最高品質（最大 120FPS）を試せます。"
                )
            }
            if generation >= 3 {
                return Advice(
                    preset: .ultra,
                    rationale: "M3 Pro / Max / Ultra 相当と十分なメモリのため、最高品質を試せます。"
                )
            }
            if generation == 2 {
                return Advice(
                    preset: .high,
                    rationale: "M2 Pro / Max / Ultra と十分なメモリのため、高品質を推奨します。"
                )
            }
            return Advice(
                preset: .high,
                rationale: "M1 Pro / Max と十分なメモリのため、高品質を推奨します。"
            )
        }
    }

    // MARK: - sysctl

    private static func sysctlBrandString() -> String? {
        sysctlString("machdep.cpu.brand_string")
    }

    private static func sysctlString(_ name: String) -> String? {
        name.withCString { cName in
            var size: size_t = 0
            guard sysctlbyname(cName, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            var len = size
            guard sysctlbyname(cName, &buffer, &len, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
    }

    /// 8GB / 16GB / 24GB+ のざっくり階級（統合メモリの中間構成も 16GB 側へ寄せる）
    private static func memoryClass(physicalMemoryBytes: UInt64) -> Int {
        let gb = Double(physicalMemoryBytes) / (1024 * 1024 * 1024)
        if gb < 11.5 { return 8 }
        if gb < 20 { return 16 }
        return 24
    }
}

// MARK: - Chip parsing

private enum ChipProfile {
    case intel
    case appleSilicon(generation: Int, variant: Variant)
    case unknown

    enum Variant {
        case base
        case pro
        case max
        case ultra
    }

    static func parse(cpuBrandString: String) -> ChipProfile {
        let trimmed = cpuBrandString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "不明" else { return .unknown }

        if trimmed.contains("Intel") {
            return .intel
        }

        // 例: "Apple M4 Pro", "Apple M3", "Apple M2 Ultra"
        guard trimmed.contains("Apple") else { return .unknown }

        let pattern = #"Apple M(\d+)(?:\s+(Pro|Max|Ultra))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return .unknown
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges >= 2,
              let genRange = Range(match.range(at: 1), in: trimmed),
              let generation = Int(trimmed[genRange]) else {
            return .unknown
        }

        let variant: Variant
        if match.numberOfRanges >= 3, let vRange = Range(match.range(at: 2), in: trimmed) {
            let token = String(trimmed[vRange])
            switch token {
            case "Pro": variant = .pro
            case "Max": variant = .max
            case "Ultra": variant = .ultra
            default: variant = .base
            }
        } else {
            variant = .base
        }

        return .appleSilicon(generation: generation, variant: variant)
    }
}
