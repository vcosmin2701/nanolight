//! Installed application index, launch counts, and cached system icons.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const mac = builtin.os.tag == .macos;
const objc = nanoui.objc;

pub const App = struct {
    name: []const u8,
    path: []const u8,
    /// The folder it is in, as the row shows it: "Applications", "Utilities".
    folder: []const u8,
};

/// Where apps are, in the order a name is first taken from.
pub const roots = [_][]const u8{
    "/Applications",
    "/System/Applications",
    "/System/Library/CoreServices/Applications",
};

/// Shown with an empty query before anything was opened.
const starters = [_][]const u8{ "Safari", "Notes", "Calendar", "System Settings", "Finder" };

pub const Icon = struct { png: []u8 };

pub const Index = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    apps: std.ArrayList(App) = .empty,
    /// The names alone, for `search.rank`.
    names: std.ArrayList([]const u8) = .empty,
    /// Times each was opened.
    launches: std.ArrayList(u16) = .empty,
    icons: std.AutoHashMapUnmanaged(u32, ?Icon) = .empty,

    pub fn init(gpa: std.mem.Allocator) Index {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(ix: *Index) void {
        var it = ix.icons.valueIterator();
        while (it.next()) |v| if (v.*) |i| ix.gpa.free(i.png);
        ix.icons.deinit(ix.gpa);
        ix.apps.deinit(ix.gpa);
        ix.names.deinit(ix.gpa);
        ix.launches.deinit(ix.gpa);
        ix.arena.deinit();
    }

    /// Adds an app unless one of its name is there already.
    pub fn add(ix: *Index, name: []const u8, path: []const u8) !void {
        for (ix.names.items) |n| if (std.ascii.eqlIgnoreCase(n, name)) return;
        // Reserve all three arrays before changing their lengths.
        try ix.apps.ensureUnusedCapacity(ix.gpa, 1);
        try ix.names.ensureUnusedCapacity(ix.gpa, 1);
        try ix.launches.ensureUnusedCapacity(ix.gpa, 1);
        const a = ix.arena.allocator();
        const p = try a.dupe(u8, path);
        const owned_name = try a.dupe(u8, name);
        const parent = std.fs.path.dirname(p) orelse "";
        const folder = std.fs.path.basename(parent);
        ix.apps.appendAssumeCapacity(.{ .name = owned_name, .path = p, .folder = folder });
        ix.names.appendAssumeCapacity(owned_name);
        ix.launches.appendAssumeCapacity(0);
    }

    /// Finds the apps on this machine; `home` adds ~/Applications.
    pub fn scan(ix: *Index, io: std.Io, home: ?[]const u8) void {
        for (roots) |r| ix.scanDir(io, r, 1);
        ix.add("Finder", "/System/Library/CoreServices/Finder.app") catch {};
        if (home) |h| {
            var buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}/Applications", .{h})) |p| ix.scanDir(io, p, 1) else |_| {}
        }
        ix.sort();
    }

    fn scanDir(ix: *Index, io: std.Io, dir_path: []const u8, depth: u8) void {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        var buf: [1024]u8 = undefined;
        while (it.next(io) catch null) |e| {
            if (e.name.len == 0 or e.name[0] == '.') continue;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, e.name }) catch continue;
            if (std.mem.endsWith(u8, e.name, ".app")) {
                ix.add(e.name[0 .. e.name.len - 4], full) catch return;
            } else if (depth > 0 and e.kind == .directory) {
                // The callee formats into its own buffer: copy the path first.
                var sub: [1024]u8 = undefined;
                @memcpy(sub[0..full.len], full);
                ix.scanDir(io, sub[0..full.len], depth - 1);
            }
        }
    }

    /// Alphabetical, case-insensitive; names and counts kept in step.
    fn sort(ix: *Index) void {
        const Ctx = struct {
            pub fn lessThan(_: @This(), a: App, b: App) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        };
        std.sort.pdq(App, ix.apps.items, Ctx{}, Ctx.lessThan);
        for (ix.apps.items, 0..) |a, i| ix.names.items[i] = a.name;
    }

    pub fn find(ix: *const Index, name: []const u8) ?u32 {
        for (ix.names.items, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) return @intCast(i);
        return null;
    }

    /// Up to `out.len` apps for an empty query: the most opened, else a
    /// few every Mac has.
    pub fn suggestions(ix: *const Index, out: []u32) usize {
        var n: usize = 0;
        // Most opened first: a few passes from the highest count down.
        var best: u32 = @as(u32, std.math.maxInt(u16)) + 1;
        while (n < out.len) {
            var next: u16 = 0;
            for (ix.launches.items) |l| if (l < best and l > next) {
                next = l;
            };
            if (next == 0) break;
            for (ix.launches.items, 0..) |l, i| if (l == next and n < out.len) {
                out[n] = @intCast(i);
                n += 1;
            };
            best = next;
        }
        for (starters) |s| {
            if (n == out.len) break;
            const i = ix.find(s) orelse continue;
            if (std.mem.indexOfScalar(u32, out[0..n], i) == null) {
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    /// Counts an opening, and keeps the counts in `store`.
    pub fn opened(ix: *Index, i: u32, store: ?nanoui.kv.Store) void {
        ix.launches.items[i] +|= 1;
        if (store) |kv| ix.save(kv);
    }

    /// Keeps every count in `kv` (as `opened` does, and a sync after it).
    pub fn save(ix: *Index, kv: nanoui.kv.Store) void {
        var aw: std.Io.Writer.Allocating = .init(ix.gpa);
        defer aw.deinit();
        for (ix.apps.items, ix.launches.items) |a, l| if (l > 0) aw.writer.print("{s}\t{d}\n", .{ a.name, l }) catch return;
        kv.set(store_key, aw.written()) catch {};
    }

    /// The counts `opened` kept.
    pub fn load(ix: *Index, store: nanoui.kv.Store) void {
        const v = (store.get(ix.gpa, store_key) catch null) orelse return;
        defer ix.gpa.free(v);
        var lines = std.mem.splitScalar(u8, v, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const i = ix.find(line[0..tab]) orelse continue;
            ix.launches.items[i] = std.fmt.parseInt(u16, line[tab + 1 ..], 10) catch 0;
        }
    }

    /// The app's icon as PNG, made the first time it is asked for.
    pub fn icon(ix: *Index, i: u32) ?[]const u8 {
        const entry = ix.icons.getOrPut(ix.gpa, i) catch return null;
        if (!entry.found_existing) {
            const png = if (mac) iconPng(ix.gpa, ix.apps.items[i].path) else null;
            entry.value_ptr.* = if (png) |p| .{ .png = p } else null;
        }
        return if (entry.value_ptr.*) |cached| cached.png else null;
    }
};

const store_key = "nanolight.launches";

/// The Finder's icon for `path`, drawn at 64 pixels and encoded as PNG.
fn iconPng(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const img = objc.msg(objc.Object, ws, "iconForFile:", .{objc.nsString(path)});
    var rect: objc.CGRect = .{ .size = .{ .width = 64, .height = 64 } };
    const cg = objc.msg(?*anyopaque, img, "CGImageForProposedRect:context:hints:", .{ &rect, @as(?objc.Object, null), @as(?objc.Object, null) }) orelse return null;
    const rep = objc.msg(objc.Object, objc.alloc("NSBitmapImageRep"), "initWithCGImage:", .{cg});
    defer objc.release(rep);
    const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
    // NSBitmapImageFileTypePNG
    const data = objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), props }) orelse return null;
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const bytes = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return null;
    return gpa.dupe(u8, bytes[0..len]) catch null;
}

test "names are kept once, sorted, and opening one suggests it" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    try ix.add("notes", "/System/Applications/Notes.app");
    try ix.add("Notes", "/Applications/Notes.app");
    try ix.add("Calculator", "/System/Applications/Calculator.app");
    ix.sort();
    try t.expectEqual(@as(usize, 3), ix.apps.items.len);
    try t.expectEqualStrings("Calculator", ix.names.items[0]);
    try t.expectEqualStrings("Applications", ix.apps.items[0].folder);
    var out: [3]u32 = undefined;
    // Nothing opened yet: the starters there are.
    try t.expectEqual(@as(usize, 2), ix.suggestions(&out));
    try t.expectEqualStrings("Safari", ix.names.items[out[0]]);
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    ix.opened(0, mem.store());
    ix.opened(0, mem.store());
    try t.expectEqual(@as(usize, 3), ix.suggestions(&out));
    try t.expectEqualStrings("Calculator", ix.names.items[out[0]]);
    // Kept, and read back.
    ix.launches.items[0] = 0;
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 2), ix.launches.items[0]);
}

fn addWithAllocationFailures(gpa: std.mem.Allocator) !void {
    var ix: Index = .init(gpa);
    defer ix.deinit();
    defer std.debug.assert(ix.apps.items.len == ix.names.items.len and ix.apps.items.len == ix.launches.items.len);
    for (0..24) |i| {
        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "App {d}", .{i});
        try ix.add(name, "/Applications/Test.app");
    }
}

test "allocation failure leaves the app index consistent" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, addWithAllocationFailures, .{});
}

test "saturated launch counts remain first in suggestions" {
    var ix: Index = .init(std.testing.allocator);
    defer ix.deinit();
    try ix.add("Rare", "/Applications/Rare.app");
    try ix.add("Frequent", "/Applications/Frequent.app");
    ix.launches.items[0] = 1;
    ix.launches.items[1] = std.math.maxInt(u16);
    var out: [2]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), ix.suggestions(&out));
    try std.testing.expectEqual(@as(u32, 1), out[0]);
}
