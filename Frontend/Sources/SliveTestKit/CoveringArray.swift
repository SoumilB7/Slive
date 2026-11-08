/// Configuration matrices too big to run whole: rows of value indices (one
/// per dimension) such that every combination of `strength` values from any
/// `strength` dimensions appears in at least one row. Strength 2 is
/// "all-pairs"; a strength at or above the dimension count is the full
/// product. Deterministic (greedy, no randomness), so a failing row is the
/// same row on every run.
public enum CoveringArray {
    public static func rows(_ sizes: [Int], strength: Int) -> [[Int]] {
        guard !sizes.isEmpty, sizes.allSatisfy({ $0 > 0 }) else { return [] }
        if strength >= sizes.count { return product(sizes) }
        let t = max(1, strength)
        let groups = combinations(Array(sizes.indices), t)
        // Per group: which value tuples are still uncovered (mixed radix).
        var uncovered: [[Bool]] = groups.map { g in
            Array(repeating: true, count: g.reduce(1) { $0 * sizes[$1] })
        }
        var left = uncovered.reduce(0) { $0 + $1.count }
        func code(_ g: [Int], _ row: [Int]) -> Int {
            g.reduce(0) { $0 * sizes[$1] + row[$1] }
        }
        var rows: [[Int]] = []
        while left > 0 {
            var row = Array(repeating: -1, count: sizes.count)
            // Seed with the first uncovered tuple.
            let gi = uncovered.firstIndex { $0.contains(true) }!
            var c = uncovered[gi].firstIndex(of: true)!
            for dim in groups[gi].reversed() {
                row[dim] = c % sizes[dim]
                c /= sizes[dim]
            }
            // Fill the rest one dimension at a time, each with the value that
            // covers the most new tuples among the groups it completes.
            for dim in sizes.indices where row[dim] < 0 {
                var best = 0, bestGain = -1
                for value in 0..<sizes[dim] {
                    row[dim] = value
                    var gain = 0
                    for (k, g) in groups.enumerated() where g.contains(dim) && g.allSatisfy({ row[$0] >= 0 }) {
                        if uncovered[k][code(g, row)] { gain += 1 }
                    }
                    if gain > bestGain { best = value; bestGain = gain }
                }
                row[dim] = best
            }
            for (k, g) in groups.enumerated() {
                let i = code(g, row)
                if uncovered[k][i] { uncovered[k][i] = false; left -= 1 }
            }
            rows.append(row)
        }
        return rows
    }

    /// Every row of the full product.
    public static func product(_ sizes: [Int]) -> [[Int]] {
        sizes.reduce([[]]) { rows, size in rows.flatMap { row in (0..<size).map { row + [$0] } } }
    }

    /// Whether `rows` covers every `strength`-way combination of `sizes`.
    public static func covers(_ rows: [[Int]], _ sizes: [Int], strength: Int) -> Bool {
        let t = min(max(1, strength), sizes.count)
        for g in combinations(Array(sizes.indices), t) {
            let need = g.reduce(1) { $0 * sizes[$1] }
            let seen = Set(rows.map { row in g.reduce(0) { $0 * sizes[$1] + row[$1] } })
            if seen.count < need { return false }
        }
        return true
    }

    private static func combinations(_ items: [Int], _ k: Int) -> [[Int]] {
        guard k > 0 else { return [[]] }
        guard items.count >= k else { return [] }
        var out: [[Int]] = []
        for (i, first) in items.enumerated() {
            for rest in combinations(Array(items[(i + 1)...]), k - 1) { out.append([first] + rest) }
        }
        return out
    }
}
