import Foundation

/// “腾出空间”的计划：从候选项里挑出一组，达到用户想腾出的目标。
enum GoalPlanner {
    struct Plan {
        let items: [CleanupItem]
        var total: Double { items.map(\.size).reduce(0, +) }
        var safeTotal: Double { items.filter { $0.safety == .safe }.map(\.size).reduce(0, +) }
        var reviewCount: Int { items.filter { $0.safety == .review }.count }
    }

    /// 根据目标（GB）挑选候选项。
    /// 稳妥的先用完再碰要确认的；同一档里“最贴合”：每一步优先选刚好能补齐缺口的最小一项，
    /// 补不齐就先拿最大的一项再继续。这样目标 5 GB 时不会一上来就选 14 GB 的那项，步骤也尽量少
    static func plan(target: Double, from candidates: [CleanupItem]) -> Plan {
        var picked: [CleanupItem] = []
        var got = 0.0
        for tier in [Safety.safe, .review] where got < target {
            var pool = candidates.filter { $0.safety == tier && $0.size > 0 }
            while got < target, !pool.isEmpty {
                let missing = target - got
                let fit = pool.filter { $0.size >= missing }.min { $0.size < $1.size }
                let next = fit ?? pool.max { $0.size < $1.size }!
                picked.append(next)
                got += next.size
                pool.removeAll { $0.id == next.id }
            }
        }
        // 展示顺序：稳妥的在前，同档大的在前
        return Plan(items: picked.sorted {
            if $0.safety != $1.safety { return $0.safety == .safe }
            return $0.size > $1.size
        })
    }
}
