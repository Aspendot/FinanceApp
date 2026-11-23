import Foundation

/// Assigns a `(group, category)` pair to a merchant using learned overrides,
/// regex rules and conditional amount rules from a `RuleSet`.
public struct Categorizer: Sendable {
    public static let uncategorized: (group: String, category: String) = ("Other", "Uncategorized")

    /// Zero-based indexes of `rules.rules` whose regex pattern failed to compile.
    public let invalidRuleIndexes: [Int]
    /// Zero-based indexes of `rules.amountRules` whose `merchantPattern` failed to compile.
    public let invalidAmountRuleIndexes: [Int]

    private let compiledRules: [CompiledRule]
    private let compiledAmountRules: [CompiledAmountRule]
    private let learned: [String: CategoryPair]

    public init(rules: RuleSet) {
        var badRules: [Int] = []
        var validRules: [CompiledRule] = []
        validRules.reserveCapacity(rules.rules.count)
        for (index, rule) in rules.rules.enumerated() {
            if let regex = CompiledRegex(pattern: rule.pattern) {
                validRules.append(CompiledRule(regex: regex, group: rule.group, category: rule.category))
            } else {
                badRules.append(index)
            }
        }

        var badAmountRules: [Int] = []
        var validAmountRules: [CompiledAmountRule] = []
        validAmountRules.reserveCapacity(rules.amountRules.count)
        for (index, rule) in rules.amountRules.enumerated() {
            if let pattern = rule.merchantPattern {
                if let regex = CompiledRegex(pattern: pattern) {
                    validAmountRules.append(CompiledAmountRule(rule: rule, regex: regex))
                } else {
                    badAmountRules.append(index)
                }
            } else {
                validAmountRules.append(CompiledAmountRule(rule: rule, regex: nil))
            }
        }

        self.invalidRuleIndexes = badRules
        self.invalidAmountRuleIndexes = badAmountRules
        self.compiledRules = validRules
        self.compiledAmountRules = validAmountRules
        self.learned = rules.learned
    }

    /// Categorizes a payment by merchant name, whole-yen amount and "YYYY-MM-DD" date.
    public func categorize(merchant: String, amount: Int, date: String) -> (group: String, category: String) {
        let learnedMatch = learned[TextFold.key(merchant)]
        var cachedRulesBase: (group: String, category: String)?

        func rulesBase() -> (group: String, category: String) {
            if let cached = cachedRulesBase {
                return cached
            }
            let computed = matchRule(merchant) ?? Self.uncategorized
            cachedRulesBase = computed
            return computed
        }

        let base: (group: String, category: String)
        if let learnedMatch {
            base = (learnedMatch.group, learnedMatch.category)
        } else {
            base = rulesBase()
        }

        for entry in compiledAmountRules {
            let rule = entry.rule
            if let regex = entry.regex {
                guard regex.matches(merchant) else { continue }
                if let when = rule.whenCategory, when != rulesBase().category {
                    continue
                }
            } else {
                if let when = rule.whenCategory, when != base.category {
                    continue
                }
            }
            if let minAmount = rule.minAmount, amount < minAmount {
                continue
            }
            if let maxAmount = rule.maxAmount, amount > maxAmount {
                continue
            }
            if let fromDate = rule.fromDate, date < fromDate {
                continue
            }
            return (rule.group, rule.category)
        }

        return base
    }

    private func matchRule(_ merchant: String) -> (group: String, category: String)? {
        for rule in compiledRules where rule.regex.matches(merchant) {
            return (rule.group, rule.category)
        }
        return nil
    }
}

private struct CompiledRegex: @unchecked Sendable {
    let regex: NSRegularExpression

    init?(pattern: String) {
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        self.regex = compiled
    }

    func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}

private struct CompiledRule: Sendable {
    let regex: CompiledRegex
    let group: String
    let category: String
}

private struct CompiledAmountRule: Sendable {
    let rule: AmountRule
    let regex: CompiledRegex?
}
