import SliveCoreSuites
import SliveTestKit

/// The self-test itself: one registry each side, unambiguous `--only`
/// names, and no fake dictation lines in the real event log.
@MainActor
enum SelfTestLayoutTests {
    static let suite = TestSuite(name: "Self-test layout") { t in
        print("[Self-test layout]")
        let core = CoreSuites.all.map(\.name)
        let app = AllSuites.all.map(\.name)
        t.check(Set(core).count == core.count && Set(app).count == app.count,
                "suite names are unique within each registry")
        t.check(Set(core).isDisjoint(with: app),
                "no suite runs twice (core and app registries are disjoint)")
        t.check(Log.eventDestination.subsystem != "com.slive.app"
                && Log.eventDestination.category != "events",
                "self-test event lines stay out of com.slive.app \"events\"")
    }
}
