//! Builds calculator, app, file, and web results within a fixed row limit.
const std = @import("std");
const search = @import("search.zig");
const calc = @import("calc.zig");
const files = @import("files.zig");

pub const Input = struct {
    query: []const u8,
    names: []const []const u8 = &.{},
    boost: []const u16 = &.{},
    suggestions: []const u32 = &.{},
    web: []const []const u8 = &.{},
    local: *const files.List = &.{},
};

pub const Kind = enum {
    calc,
    app,
    file,
    folder,
    ask_grok,
    search_x,
    search_web,
    /// One of Google's completions (`Row.web`).
    suggest,
    /// Nanolight's own Settings, listed when the query asks for them.
    settings,

    /// The row's kind as its trailing label shows it.
    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .calc => "Calculator",
            .app => "Application",
            .file => "File",
            .folder => "Folder",
            .settings => "Nanolight",
            .ask_grok, .search_x, .search_web, .suggest => "Web",
        };
    }

    /// What Return does to it.
    pub fn action(k: Kind) []const u8 {
        return switch (k) {
            .calc => "Copy Answer",
            .app => "Open Application",
            .file => "Open File",
            .folder => "Open Folder",
            .settings => "Open Settings",
            .ask_grok => "Ask Grok",
            .search_x => "Search X",
            .search_web, .suggest => "Search Google",
        };
    }

    fn section(k: Kind, suggested: bool) []const u8 {
        return switch (k) {
            .calc => "Calculator",
            .app => if (suggested) "Suggestions" else "Applications",
            .file, .folder => "Files",
            .settings => "Nanolight",
            .search_web, .suggest => "Google",
            .ask_grok, .search_x => "Ask & Search",
        };
    }
};

pub const Row = struct {
    kind: Kind,
    /// The app's index (`.app`).
    app: u32 = 0,
    file: u8 = 0,
    /// Which of the completions (`.suggest`).
    web: u8 = 0,
    /// Which of its name's bytes the query matched.
    match: search.Match = .{ .score = 0 },
};

pub const max_apps = 6;
/// Google's completions fill what room is left, up to four.
pub const max_web = 4;
/// Shared row budget for apps, files, settings, and web actions.
pub const max_rows = 12;
/// The web rows that always follow the apps: Google, Grok, X.
const handoffs = 3;

pub const Results = struct {
    rows: [max_rows]Row = undefined,
    n: usize = 0,
    /// No query: the apps are suggestions, nothing else is listed.
    suggested: bool = false,
    /// The math's answer, as shown.
    answer_buf: [64]u8 = undefined,
    answer: []const u8 = "",
    /// A whole answer in hexadecimal too ("0xC00"), else empty.
    hex_buf: [24]u8 = undefined,
    hex: []const u8 = "",

    pub fn slice(r: *const Results) []const Row {
        return r.rows[0..r.n];
    }

    pub fn build(r: *Results, input: Input) void {
        r.n = 0;
        const query = std.mem.trim(u8, input.query, " ");
        r.suggested = query.len == 0;
        if (files.dedicated(query)) {
            r.appendFiles(input.local, files.max_files);
            return;
        }
        if (query.len == 0) {
            for (input.suggestions[0..@min(input.suggestions.len, max_apps)]) |i| r.push(.{ .kind = .app, .app = i });
            return;
        }
        if (calc.eval(query)) |v| {
            r.answer = calc.format(&r.answer_buf, v, true);
            r.hex = if (v >= 0 and v < 1e15 and v == @round(v))
                std.fmt.bufPrint(&r.hex_buf, "0x{X}", .{@as(u64, @intFromFloat(v))}) catch ""
            else
                "";
            r.push(.{ .kind = .calc });
            return;
        }
        var ranked: [max_apps]search.Ranked = undefined;
        const n = search.rank(query, input.names, input.boost, &ranked);
        for (ranked[0..n]) |x| r.push(.{ .kind = .app, .app = x.index, .match = x.match });
        // "settings" / "preferences": Nanolight's own screen, right under
        // the apps: Return still opens System Settings, a key away from this.
        if (isSettings(query)) r.push(.{ .kind = .settings });
        r.appendFiles(input.local, max_rows - r.n - handoffs);
        // The search for what was typed, its completions (as many as leave
        // room for the rest), then Grok and X.
        const room = max_rows - r.n - handoffs;
        r.push(.{ .kind = .search_web });
        for (0..@min(input.web.len, max_web, room)) |i| r.push(.{ .kind = .suggest, .web = @intCast(i) });
        r.push(.{ .kind = .ask_grok });
        r.push(.{ .kind = .search_x });
    }

    /// "settings" and "preferences", the words people type for this.
    fn isSettings(query: []const u8) bool {
        return std.ascii.eqlIgnoreCase(query, "settings") or std.ascii.eqlIgnoreCase(query, "preferences");
    }

    fn push(r: *Results, row: Row) void {
        std.debug.assert(r.n < max_rows);
        r.rows[r.n] = row;
        r.n += 1;
    }

    fn appendFiles(r: *Results, list: *const files.List, limit: usize) void {
        const count = @min(list.n, limit);
        for (0..count) |i| r.push(.{ .kind = if (list.entries[i].folder) .folder else .file, .file = @intCast(i) });
    }

    /// The header above row `i`, if a section starts there.
    pub fn section(r: *const Results, i: usize) ?[]const u8 {
        const k = r.rows[i].kind;
        const name = k.section(r.suggested);
        if (i > 0 and std.mem.eql(u8, r.rows[i - 1].kind.section(r.suggested), name)) return null;
        return name;
    }
};

/// The address a web row opens for `query`.
pub fn url(buf: []u8, kind: Kind, query: []const u8) []const u8 {
    const base = switch (kind) {
        .ask_grok => "https://grok.com/?q=",
        .search_x => "https://x.com/search?f=live&q=",
        .search_web, .suggest => "https://www.google.com/search?q=",
        .calc, .app, .file, .folder, .settings => return "",
    };
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(base) catch return "";
    escape(&w, query) catch return "";
    return w.buffered();
}

/// URL-encode a trimmed query. Returns an error if the writer is full.
pub fn escape(w: *std.Io.Writer, query: []const u8) std.Io.Writer.Error!void {
    for (std.mem.trim(u8, query, " ")) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try w.writeByte(ch);
        } else if (ch == ' ') {
            try w.writeByte('+');
        } else try w.print("%{X:0>2}", .{ch});
    }
}

test "math first, then apps; ask and search only without an answer" {
    const t = std.testing;
    const names = [_][]const u8{ "Safari", "System Settings", "Calculator" };
    var r: Results = .{};
    r.build(.{ .query = "saf", .names = &names });
    try t.expectEqual(Kind.app, r.rows[0].kind);
    try t.expectEqual(@as(u32, 0), r.rows[0].app);
    try t.expectEqual(Kind.search_web, r.rows[r.n - 3].kind);
    try t.expectEqualStrings("Applications", r.section(0).?);
    try t.expectEqualStrings("Google", r.section(1).?);
    try t.expectEqualStrings("Ask & Search", r.section(2).?);
    try t.expect(r.section(3) == null);
    r.build(.{ .query = "2^10 * 3", .names = &names, .web = &.{"ignored"} });
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("3,072", r.answer);
    try t.expectEqualStrings("0xC00", r.hex);
    try t.expectEqual(@as(usize, 1), r.n);
    r.build(.{ .query = "", .names = &names, .suggestions = &.{ 2, 0 } });
    try t.expectEqual(@as(usize, 2), r.n);
    try t.expectEqualStrings("Suggestions", r.section(0).?);
    r.build(.{ .query = "liquid glass", .names = &names });
    try t.expectEqual(@as(usize, 3), r.n);
    // No app: the search for what was typed comes first.
    try t.expectEqual(Kind.search_web, r.rows[0].kind);
    try t.expectEqualStrings("Google", r.section(0).?);
    try t.expectEqualStrings("Ask & Search", r.section(1).?);
    // Completions under it, in the same section, then Grok and X.
    r.build(.{ .query = "liquid gl", .names = &names, .web = &.{ "liquid glass", "liquid glue" } });
    try t.expectEqual(@as(usize, 5), r.n);
    try t.expectEqual(Kind.search_web, r.rows[0].kind);
    try t.expectEqual(Kind.suggest, r.rows[1].kind);
    try t.expectEqual(@as(u8, 1), r.rows[2].web);
    try t.expectEqual(Kind.ask_grok, r.rows[3].kind);
    try t.expect(r.section(1) == null and r.section(2) == null);
    try t.expectEqualStrings("Ask & Search", r.section(3).?);
    // "settings": System Settings first, Nanolight's own a row under it.
    r.build(.{ .query = "settings", .names = &names });
    try t.expectEqual(Kind.app, r.rows[0].kind);
    try t.expectEqual(@as(u32, 1), r.rows[0].app);
    try t.expectEqual(Kind.settings, r.rows[1].kind);
    // A full list of apps still ends with every handoff.
    const many = [_][]const u8{ "Safari", "Mail", "Maps", "Pages", "Calendar", "Calculator", "FaceTime" };
    r.build(.{ .query = "a", .names = &many, .web = &.{ "a1", "a2", "a3", "a4" } });
    try t.expectEqual(max_rows, r.n);
    try t.expectEqual(Kind.search_web, r.rows[max_apps].kind);
    try t.expectEqual(Kind.suggest, r.rows[max_apps + 1].kind);
    try t.expectEqual(Kind.search_x, r.rows[max_rows - 1].kind);
}

test "queries are escaped into the address" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://x.com/search?f=live&q=liquid+glass+%26+UI", url(&buf, .search_x, " liquid glass & UI "));
}

test "full result lists retain file rows and every web action" {
    const names = [_][]const u8{ "Settings A", "Settings B", "Settings C", "Settings D", "Settings E", "Settings F" };
    var local: files.List = .{};
    for ([_][]const u8{ "/tmp/a", "/tmp/b", "/tmp/c", "/tmp/d" }) |path| local.push(path, false);
    var r: Results = .{};
    r.build(.{ .query = "settings", .names = &names, .local = &local, .web = &.{ "settings one", "settings two", "settings three", "settings four" } });
    try std.testing.expectEqual(max_rows, r.n);
    try std.testing.expectEqual(Kind.settings, r.rows[max_apps].kind);
    try std.testing.expectEqual(Kind.file, r.rows[max_apps + 1].kind);
    try std.testing.expectEqual(Kind.search_web, r.rows[r.n - 3].kind);
    try std.testing.expectEqual(Kind.ask_grok, r.rows[r.n - 2].kind);
    try std.testing.expectEqual(Kind.search_x, r.rows[r.n - 1].kind);
}

test "URL overflow returns no address instead of a truncated search" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("", url(&buf, .search_web, "a long query with spaces and unicode café"));
}
