//! Application state. Knows nothing about drawing, so it can outlive the renderer.

pub const Screen = enum {
    dashboard,
    api_tests,
    test_suites,
    load_tests,
    reports,
    environments,
    settings,

    pub fn label(s: Screen) []const u8 {
        return switch (s) {
            .dashboard => "Dashboard",
            .api_tests => "API Tests",
            .test_suites => "Test Suites",
            .load_tests => "Load Tests",
            .reports => "Reports",
            .environments => "Environments",
            .settings => "Settings",
        };
    }

    pub fn subtitle(s: Screen) []const u8 {
        return switch (s) {
            .dashboard => "Overview of your test activity, results, and performance.",
            .api_tests => "Build, save, and run API requests.",
            .test_suites => "Manage and run regression suites.",
            .load_tests => "Simulate real-world traffic and analyze performance under load.",
            .reports => "Export results as JSON, HTML, or JUnit XML.",
            .environments => "Manage variables and secrets for each environment.",
            .settings => "Configure ZTest.",
        };
    }
};

pub const Environment = enum {
    production,
    staging,
    development,

    pub fn label(e: Environment) []const u8 {
        return switch (e) {
            .production => "Production",
            .staging => "Staging",
            .development => "Development",
        };
    }

    pub fn next(e: Environment) Environment {
        return switch (e) {
            .production => .staging,
            .staging => .development,
            .development => .production,
        };
    }
};

pub const Outcome = enum { passed, failed, skipped };

pub const ResultFilter = enum {
    all,
    passed,
    failed,
    skipped,

    pub fn allows(f: ResultFilter, outcome: Outcome) bool {
        return switch (f) {
            .all => true,
            .passed => outcome == .passed,
            .failed => outcome == .failed,
            .skipped => outcome == .skipped,
        };
    }
};

pub const SuiteHealth = enum { active, failing, scheduled };

pub const SuiteFilter = enum {
    all,
    active,
    scheduled,

    pub fn allows(f: SuiteFilter, health: SuiteHealth) bool {
        return switch (f) {
            .all => true,
            .active => health == .active,
            .scheduled => health == .scheduled,
        };
    }
};

/// Collapses `index` if it is open, otherwise opens it.
pub fn toggled(open: ?usize, index: usize) ?usize {
    return if (open == index) null else index;
}

pub const State = struct {
    screen: Screen = .dashboard,
    environment: Environment = .production,
    scroll: f32 = 0,
    /// The page's height and the room it had on the last frame, so a wheel
    /// turn between frames stops at either end instead of drawing past it.
    content_height: f32 = 0,
    view_height: f32 = 0,

    request_tab: usize = 3,
    body_type: usize = 0,
    /// Index into the Auth tab's types, mirrored from its selector.
    auth_kind: usize = 0,
    /// The first assertion row shown, for scrolling the Assertions panel.
    assert_offset: usize = 0,
    /// Load Tests: whether Advanced Options are open.
    load_advanced: bool = false,
    /// Test Suites: the suite shown, by catalog index, and its result filter.
    suite_search_changed: bool = false,
    response_tab: usize = 0,
    /// Dashboard: the Recent Test Runs page, and the days the trend covers.
    runs_page: usize = 0,
    trend_days: usize = 7,

    suite: usize = 0,
    suite_filter: SuiteFilter = .all,
    suite_tab: usize = 0,
    result_filter: ResultFilter = .all,
    open_group: ?usize = 1,
    open_test: ?usize = null,
    detail_tab: usize = 0,

    pub fn navigate(s: *State, screen: Screen) void {
        if (s.screen == screen) return;
        s.screen = screen;
        s.scroll = 0;
        s.content_height = 0;
    }

    /// Keeps the scroll offset inside the content, and remembers its size.
    pub fn clampScroll(s: *State, content_height: f32, view_height: f32) void {
        s.content_height = content_height;
        s.view_height = view_height;
        s.scroll = @max(0, @min(s.scroll, content_height - view_height));
    }

    /// Scrolls by `delta`, stopping at the ends of the last frame's content.
    pub fn scrollBy(s: *State, delta: f32) void {
        s.scroll = @max(0, @min(s.scroll + delta, s.content_height - s.view_height));
    }
};

const testing = @import("std").testing;

test "navigating to another screen resets scroll" {
    var s: State = .{ .scroll = 120 };
    s.navigate(.dashboard);
    try testing.expectEqual(@as(f32, 120), s.scroll);
    s.navigate(.reports);
    try testing.expectEqual(Screen.reports, s.screen);
    try testing.expectEqual(@as(f32, 0), s.scroll);
}

test "scroll stays inside the content" {
    var s: State = .{ .scroll = 500 };
    s.clampScroll(900, 600);
    try testing.expectEqual(@as(f32, 300), s.scroll);
    s.clampScroll(400, 600);
    try testing.expectEqual(@as(f32, 0), s.scroll);
}

test "scrolling stops at both ends of the page" {
    var s: State = .{};
    s.clampScroll(900, 600);
    s.scrollBy(1000);
    try testing.expectEqual(@as(f32, 300), s.scroll);
    s.scrollBy(-60);
    try testing.expectEqual(@as(f32, 240), s.scroll);
    s.scrollBy(-1000);
    try testing.expectEqual(@as(f32, 0), s.scroll);
    // A page shorter than the window never scrolls.
    s.clampScroll(400, 600);
    s.scrollBy(60);
    try testing.expectEqual(@as(f32, 0), s.scroll);
}

test "result filter matches only its outcome" {
    try testing.expect(ResultFilter.all.allows(.skipped));
    try testing.expect(ResultFilter.failed.allows(.failed));
    try testing.expect(!ResultFilter.failed.allows(.passed));
}

test "suite filter hides other suites" {
    try testing.expect(SuiteFilter.all.allows(.failing));
    try testing.expect(SuiteFilter.scheduled.allows(.scheduled));
    try testing.expect(!SuiteFilter.active.allows(.failing));
}

test "toggling opens and collapses" {
    try testing.expectEqual(@as(?usize, 2), toggled(null, 2));
    try testing.expectEqual(@as(?usize, 2), toggled(1, 2));
    try testing.expectEqual(@as(?usize, null), toggled(2, 2));
}

test "environments cycle back to the start" {
    try testing.expectEqual(Environment.production, Environment.production.next().next().next());
}
