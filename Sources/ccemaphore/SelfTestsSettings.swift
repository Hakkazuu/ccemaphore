import Foundation

/// `--self-test` suites for the Settings screen's navigation (`SettingsNavigation`): which tab and
/// sub-screen it lands on, which way a move slides, and that every tab and sub-screen is localized.
extension SelfTest {
    static func settingsSuites() -> [Suite] {
        [
            Suite(name: "Settings navigation", body: settingsNavigation),
            Suite(name: "Settings strings", body: settingsStrings),
        ]
    }

    private static func settingsNavigation(_ t: inout Tester) {
        t.equal(SettingsTab.allCases, [.appearance, .notifications, .agents, .ssh, .general], "strip order")
        t.equal(SettingsTab.stored("agents"), .agents, "a stored tab is restored")
        t.equal(SettingsTab.stored("widget"), .appearance, "an unknown stored tab opens the first")
        t.equal(SettingsTab.stored(nil), .appearance, "a fresh install opens the first")
        t.equal(Set(SettingsTab.allCases.map(\.symbol.rest)).count, SettingsTab.allCases.count, "every tab has its own icon")

        var nav = SettingsNavigation(tab: .notifications)
        t.equal(nav.direction, .none, "nothing moved yet")
        nav.select(.ssh)
        t.equal(nav.tab, .ssh, "a tab switch lands on that tab")
        t.equal(nav.direction, .forward, "a tab to the right slides forward")
        nav.select(.appearance)
        t.equal(nav.direction, .backward, "a tab to the left slides backward")

        nav.push(.trustedCommands)
        t.equal(nav.route, nil, "a sub-screen of another tab is refused")
        nav.push(.productGroups)
        t.equal(nav.route, .productGroups, "a tab's own sub-screen opens")
        t.equal(nav.direction, .forward, "opening a sub-screen slides forward")
        let pushed = nav
        nav.push(.productGroups)
        t.equal(nav, pushed, "opening the open sub-screen again changes nothing")

        nav.select(.appearance)
        t.equal(nav.route, nil, "clicking the current tab returns to its root")
        t.equal(nav.direction, .backward, "…sliding backward")
        let root = nav
        nav.select(.appearance)
        t.equal(nav, root, "clicking the current tab at its root changes nothing")
        nav.pop()
        t.equal(nav, root, "back at a root changes nothing")

        nav.select(.agents)
        nav.push(.trustedCommands)
        nav.select(.general)
        t.equal(nav.route, nil, "another tab always opens at its root")
        t.equal(nav.tab, .general, "…and is that tab")

        var pages = Set<String>()
        for tab in SettingsTab.allCases {
            var n = SettingsNavigation(tab: tab)
            pages.insert(n.pageID)
            for route in SettingsRoute.allCases where route.tab == tab {
                n.push(route)
                pages.insert(n.pageID)
                n.pop()
            }
        }
        t.equal(pages.count, SettingsTab.allCases.count + SettingsRoute.allCases.count, "every page has its own identity")
    }

    private static func settingsStrings(_ t: inout Tester) {
        let keys = SettingsTab.allCases.map(\.labelKey) + SettingsRoute.allCases.map(\.titleKey)
            + ["settings.chats.section", "settings.groups.mode.title", "settings.groups.subtitle",
               "settings.trusted.subtitle", "settings.trusted.off", "settings.registry.live", "settings.back.a11y"]
        defer { Loc.setOverride(nil) }
        for code in Loc.supported {
            Loc.setOverride(code)
            for key in keys { t.expect(L(key) != key, "\(code): \(key) is localized") }
        }
    }
}
