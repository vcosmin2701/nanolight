//! Identifies Nanolight bundles and terminates older running copies.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

fn ours() ?objc.Object {
    const main = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    return objc.msg(?objc.Object, main, "bundleIdentifier", .{});
}

/// Whether the app at `path` is Nanolight (any copy of it).
pub fn isSelf(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = ours() orelse return false;
    const b = objc.msg(?objc.Object, objc.class("NSBundle"), "bundleWithPath:", .{objc.nsString(path)}) orelse return false;
    const theirs = objc.msg(?objc.Object, b, "bundleIdentifier", .{}) orelse return false;
    return objc.msg(objc.BOOL, id, "isEqualToString:", .{theirs}) != objc.NO;
}

/// Asks every other running Nanolight to quit. Returns how many.
pub fn quitOthers() usize {
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = ours() orelse return 0;
    const cls = objc.class("NSRunningApplication");
    const me = objc.msg(i32, objc.msg(objc.Object, cls, "currentApplication", .{}), "processIdentifier", .{});
    const apps = objc.msg(objc.Object, cls, "runningApplicationsWithBundleIdentifier:", .{id});
    var n: usize = 0;
    for (0..objc.msg(objc.NSUInteger, apps, "count", .{})) |i| {
        const a = objc.msg(objc.Object, apps, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        if (objc.msg(i32, a, "processIdentifier", .{}) == me) continue;
        _ = objc.msg(objc.BOOL, a, "terminate", .{});
        n += 1;
    }
    return n;
}

test "an app that isn't Nanolight isn't taken for it" {
    try std.testing.expect(!isSelf("/System/Applications/Calculator.app"));
    try std.testing.expect(!isSelf("/nowhere/Nothing.app"));
}
