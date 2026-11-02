//! Local filename search using Spotlight's existing index. All Cocoa calls
//! run on the main thread; the query gathers asynchronously.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

pub const max_files = 4;
pub const max_query = 512;
pub const pause_ms = 150;
pub const poll_ms = 50;
const max_polls = 100;
const max_candidates = 200;
const max_path_bytes = 4096;
pub const State = enum { idle, searching, ready, failed };

pub fn dedicated(typed: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(std.mem.trim(u8, typed, " \t\r\n"), "file:");
}

pub fn words(typed: []const u8) []const u8 {
    const q = std.mem.trim(u8, typed, " \t\r\n");
    return if (dedicated(q)) std.mem.trim(u8, q[5..], " \t\r\n") else q;
}

pub fn eligible(typed: []const u8) bool {
    const q = words(typed);
    if (q.len < 2 or typed.len > max_query) return false;
    for (q) |ch| if (ch < 32 or ch == 127) return false;
    return dedicated(typed) or @import("calc.zig").eval(q) == null;
}

pub const Entry = struct {
    bytes: [max_path_bytes]u8 = undefined,
    len: usize = 0,
    folder: bool = false,

    pub fn path(e: *const Entry) []const u8 {
        return e.bytes[0..e.len];
    }
    pub fn name(e: *const Entry) []const u8 {
        return std.fs.path.basename(e.path());
    }
    pub fn parent(e: *const Entry) []const u8 {
        return std.fs.path.dirname(e.path()) orelse "";
    }
};

pub const List = struct {
    entries: [max_files]Entry = undefined,
    n: usize = 0,

    pub fn push(l: *List, path: []const u8, folder: bool) void {
        if (l.n == max_files or path.len == 0 or path.len > max_path_bytes) return;
        // Hidden directories and app bundles aren't document results.
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| if (std.mem.startsWith(u8, part, ".") or std.mem.endsWith(u8, part, ".app")) return;
        for (l.entries[0..l.n]) |*e| if (std.mem.eql(u8, e.path(), path)) return;
        const e = &l.entries[l.n];
        @memcpy(e.bytes[0..path.len], path);
        e.len = path.len;
        e.folder = folder;
        l.n += 1;
    }
};

/// Escape user-supplied glob characters and match anywhere in the filename.
fn pattern(buf: []u8, query: []const u8) std.Io.Writer.Error![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeByte('*');
    for (query) |ch| {
        if (ch == '*' or ch == '?' or ch == '\\') try w.writeByte('\\');
        try w.writeByte(ch);
    }
    try w.writeByte('*');
    return w.buffered();
}

/// Pass query text as an argument so it cannot become predicate syntax.
fn namePredicate(query: []const u8) ?objc.Object {
    var buf: [max_query * 2 + 2]u8 = undefined;
    const glob = pattern(&buf, query) catch return null;
    const args = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.nsString(glob)});
    return objc.msg(objc.Object, objc.class("NSPredicate"), "predicateWithFormat:argumentArray:", .{
        objc.nsString("kMDItemFSName LIKE[cd] %@ AND NOT (kMDItemContentTypeTree == 'com.apple.application-bundle')"), args,
    });
}

pub const Query = struct {
    ns: ?objc.Object = null,
    polls: usize = 0,

    pub fn stop(q: *Query) void {
        if (q.ns) |ns| {
            objc.msg(void, ns, "stopQuery", .{});
            objc.release(ns);
        }
        q.ns = null;
    }

    pub fn start(q: *Query, typed: []const u8, home: []const u8) bool {
        q.stop();
        if (!eligible(typed) or home.len == 0) return false;
        const pool = objc.Pool.push();
        defer pool.pop();
        const predicate = namePredicate(words(typed)) orelse return false;
        const scopes = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
        for ([_][]const u8{ "Desktop", "Documents", "Downloads" }) |folder| {
            var path: [max_path_bytes]u8 = undefined;
            const p = std.fmt.bufPrint(&path, "{s}/{s}", .{ home, folder }) catch continue;
            objc.msg(void, scopes, "addObject:", .{objc.nsString(p)});
        }
        const ns = objc.msg(objc.Object, objc.alloc("NSMetadataQuery"), "init", .{});
        objc.msg(void, ns, "setPredicate:", .{predicate});
        objc.msg(void, ns, "setSearchScopes:", .{scopes});
        const sort = objc.msg(objc.Object, objc.class("NSSortDescriptor"), "sortDescriptorWithKey:ascending:", .{ objc.nsString("kMDItemFSContentChangeDate"), objc.NO });
        objc.msg(void, ns, "setSortDescriptors:", .{objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{sort})});
        if (objc.msg(objc.BOOL, ns, "startQuery", .{}) == objc.NO) {
            objc.release(ns);
            return false;
        }
        q.ns = ns;
        q.polls = 0;
        return true;
    }

    /// Null until gathering finishes. A bounded wait also handles an
    /// unavailable index, without leaving the panel searching forever.
    pub fn poll(q: *Query, out: *List) ?State {
        const ns = q.ns orelse return .idle;
        q.polls += 1;
        if (objc.msg(objc.BOOL, ns, "isGathering", .{}) != objc.NO) {
            if (q.polls < max_polls) return null;
            q.stop();
            return .failed;
        }
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, ns, "disableUpdates", .{});
        defer q.stop();
        out.n = 0;
        const count = objc.msg(objc.NSUInteger, ns, "resultCount", .{});
        for (0..@min(count, max_candidates)) |i| {
            const item = objc.msg(objc.Object, ns, "resultAtIndex:", .{i});
            const path = objc.fromNSString(objc.msg(?objc.Object, item, "valueForAttribute:", .{objc.nsString("kMDItemPath")}));
            const kind = objc.fromNSString(objc.msg(?objc.Object, item, "valueForAttribute:", .{objc.nsString("kMDItemContentType")}));
            out.push(path, std.mem.eql(u8, kind, "public.folder"));
            if (out.n == max_files) break;
        }
        return .ready;
    }
};

pub fn reveal(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    const urls = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{url});
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    objc.msg(void, ws, "activateFileViewerSelectingURLs:", .{urls});
}

test "file mode and literal queries" {
    const t = std.testing;
    try t.expect(dedicated(" FILE: report "));
    try t.expectEqualStrings("report", words(" FILE: report "));
    try t.expect(!eligible("file:"));
    try t.expect(!eligible("a"));
    try t.expect(!eligible("2+2"));
    try t.expect(eligible("file:2+2"));
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("*report\\*\\?\\\\' café*", try pattern(&buf, "report*?\\' café"));
}

test "file paths retain duplicates by name, exclude hidden paths and bundles" {
    var l: List = .{};
    l.push("/Users/me/Documents/report.pdf", false);
    l.push("/Users/me/Downloads/report.pdf", false);
    l.push("/Users/me/Documents/report.pdf", false);
    l.push("/Users/me/Documents/.hidden/report.pdf", false);
    l.push("/Users/me/Documents/Test.app/file", false);
    l.push("/Users/me/Documents/Reports", true);
    try std.testing.expectEqual(@as(usize, 3), l.n);
    try std.testing.expectEqualStrings("report.pdf", l.entries[0].name());
    try std.testing.expectEqualStrings("/Users/me/Downloads", l.entries[1].parent());
    try std.testing.expect(l.entries[2].folder);
}

test "native filename predicates treat user syntax as literal text" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const obj = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    objc.msg(void, obj, "setObject:forKey:", .{ objc.nsString("Café 'report*.pdf"), objc.nsString("kMDItemFSName") });
    objc.msg(void, obj, "setObject:forKey:", .{ objc.nsString("public.pdf"), objc.nsString("kMDItemContentTypeTree") });
    const predicate = namePredicate("cafe 'report*").?;
    try std.testing.expect(objc.msg(objc.BOOL, predicate, "evaluateWithObject:", .{obj}) != objc.NO);
    objc.msg(void, obj, "setObject:forKey:", .{ objc.nsString("Café 'reportX.pdf"), objc.nsString("kMDItemFSName") });
    try std.testing.expect(objc.msg(objc.BOOL, predicate, "evaluateWithObject:", .{obj}) == objc.NO);
    try std.testing.expect(objc.msg(objc.BOOL, namePredicate("' OR TRUEPREDICATE OR '").?, "evaluateWithObject:", .{obj}) == objc.NO);
}

test "native metadata query gathers asynchronously and can be cancelled" {
    const pool = objc.Pool.push();
    defer pool.pop();
    var q: Query = .{};
    defer q.stop();
    const process = objc.msg(objc.Object, objc.class("NSProcessInfo"), "processInfo", .{});
    const env = objc.msg(objc.Object, process, "environment", .{});
    const home = objc.fromNSString(objc.msg(?objc.Object, env, "objectForKey:", .{objc.nsString("HOME")}));
    try std.testing.expect(q.start("file:nanolight-unlikely-test-name-94f2", home));
    const loop = objc.msg(objc.Object, objc.class("NSRunLoop"), "currentRunLoop", .{});
    var list: List = .{};
    var state: ?State = null;
    for (0..100) |_| {
        const until = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{@as(f64, 0.05)});
        objc.msg(void, loop, "runUntilDate:", .{until});
        state = q.poll(&list);
        if (state != null) break;
    }
    try std.testing.expectEqual(State.ready, state.?);
    try std.testing.expect(q.ns == null);
    try std.testing.expect(q.start("file:report", home));
    q.stop();
    q.stop();
    try std.testing.expectEqual(State.idle, q.poll(&list).?);
}
