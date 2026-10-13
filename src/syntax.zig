const std = @import("std");
const Io = std.Io;
const cbor = @import("cbor");
const build_options = @import("build_options");

const treez = if (build_options.use_tree_sitter)
    @import("treez")
else
    @import("treez_dummy.zig");

const Self = @This();

pub const Edit = treez.InputEdit;
pub const FileType = @import("file_type.zig");
pub const QueryCache = @import("QueryCache.zig");
pub const Range = treez.Range;
pub const Point = treez.Point;
const Input = treez.Input;
const Language = treez.Language;
const Parser = treez.Parser;
const Query = treez.Query;
pub const Node = treez.Node;

allocator: std.mem.Allocator,
query_cache: *QueryCache,
lang: *const Language,
parser: *Parser,
query: *Query,
errors_query: *Query,
injections: ?*Query,
tree: ?*treez.Tree = null,
injection_list: std.ArrayList(Injection) = .empty,
edited_ranges: std.ArrayList(ByteRange) = .empty,
injections_state: enum { current, stale } = .current,
content: ?[]u8 = null,

const ByteRange = struct {
    start: u32,
    end: u32,

    fn touches(self: ByteRange, start: u32, end: u32) bool {
        return start <= self.end and end >= self.start;
    }
};

pub const Injection = struct {
    lang_name: []const u8,
    file_type: FileType,
    start_point: Point,
    end_row: u32,
    start_byte: u32,
    end_byte: u32,
    syntax: ?*Self = null,

    fn deinit(self: *Injection, allocator: std.mem.Allocator) void {
        if (self.syntax) |syn| syn.destroy();
        allocator.free(self.lang_name);
    }
};

pub fn create(file_type: FileType, allocator: std.mem.Allocator, query_cache: *QueryCache) !*Self {
    const query = try query_cache.get(file_type, .highlights);
    errdefer query_cache.release(query, .highlights);
    const errors_query = try query_cache.get(file_type, .errors);
    errdefer query_cache.release(errors_query, .errors);
    const injections = try query_cache.get(file_type, .injections);
    errdefer if (injections) |injections_| query_cache.release(injections_, .injections);
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const parser = try Parser.create();
    errdefer parser.destroy();
    self.* = .{
        .allocator = allocator,
        .query_cache = query_cache,
        .lang = file_type.lang_fn() orelse std.debug.panic("tree-sitter parser function failed for language: {s}", .{file_type.name}),
        .parser = parser,
        .query = query,
        .errors_query = errors_query,
        .injections = injections,
    };
    try self.parser.setLanguage(self.lang);
    return self;
}

pub fn create_file_type_static(allocator: std.mem.Allocator, lang_name: []const u8, query_cache: *QueryCache) !*Self {
    const file_type = FileType.get_by_name_static(lang_name) orelse return error.NotFound;
    return create(file_type, allocator, query_cache);
}

pub fn create_guess_file_type_static(allocator: std.mem.Allocator, content: []const u8, file_path: ?[]const u8, query_cache: *QueryCache) !*Self {
    const file_type = FileType.guess_static(file_path, content) orelse return error.NotFound;
    return create(file_type, allocator, query_cache);
}

pub fn destroy(self: *Self) void {
    self.clear_injections();
    self.injection_list.deinit(self.allocator);
    self.edited_ranges.deinit(self.allocator);
    if (self.content) |c| self.allocator.free(c);
    if (self.tree) |tree| tree.destroy();
    self.query_cache.release(self.query, .highlights);
    self.query_cache.release(self.errors_query, .errors);
    if (self.injections) |injections| self.query_cache.release(injections, .injections);
    self.parser.destroy();
    self.allocator.destroy(self);
}

pub fn reset(self: *Self) void {
    self.clear_injections();
    if (self.content) |c| self.allocator.free(c);
    self.content = null;
    if (self.tree) |tree| {
        tree.destroy();
        self.tree = null;
    }
}

fn clear_injections(self: *Self) void {
    for (self.injection_list.items) |*inj| inj.deinit(self.allocator);
    self.injection_list.clearRetainingCapacity();
    self.edited_ranges.clearRetainingCapacity();
    self.injections_state = .current;
}

pub fn refresh_full(self: *Self, content: []const u8) !void {
    self.clear_injections();
    if (self.content) |c| self.allocator.free(c);
    self.content = null;
    if (self.tree) |tree| tree.destroy();
    self.tree = try self.parser.parseString(null, content);
    const content_copy = try self.allocator.dupe(u8, content);
    self.content = content_copy;
    try self.refresh_injections(content);
}

pub fn edit(self: *Self, ed: Edit) void {
    const tree = self.tree orelse return;
    tree.edit(&ed);
    self.edit_injections(ed);
}

fn edit_injections(self: *Self, ed: Edit) void {
    var index: usize = 0;
    while (index < self.injection_list.items.len) {
        const inj = &self.injection_list.items[index];
        if (inj.end_byte < ed.start_byte) {
            index += 1;
        } else if (inj.start_byte > ed.old_end_byte) {
            if (inj.start_point.row == ed.old_end_point.row)
                inj.start_point.column = inj.start_point.column - ed.old_end_point.column + ed.new_end_point.column;
            inj.start_point.row = inj.start_point.row - ed.old_end_point.row + ed.new_end_point.row;
            inj.end_row = inj.end_row - ed.old_end_point.row + ed.new_end_point.row;
            inj.start_byte = inj.start_byte - ed.old_end_byte + ed.new_end_byte;
            inj.end_byte = inj.end_byte - ed.old_end_byte + ed.new_end_byte;
            index += 1;
        } else {
            inj.deinit(self.allocator);
            _ = self.injection_list.orderedRemove(index);
        }
    }
    for (self.edited_ranges.items) |*range| {
        if (range.end < ed.start_byte) continue;
        if (range.start > ed.old_end_byte) {
            range.start = range.start - ed.old_end_byte + ed.new_end_byte;
            range.end = range.end - ed.old_end_byte + ed.new_end_byte;
        } else {
            range.start = @min(range.start, ed.start_byte);
            range.end = @max(range.end, ed.old_end_byte) - ed.old_end_byte + ed.new_end_byte;
        }
    }
    self.edited_ranges.append(self.allocator, .{ .start = ed.start_byte, .end = ed.new_end_byte }) catch {
        self.injections_state = .stale;
    };
}

pub fn refresh_from_buffer(self: *Self, buffer: anytype, metrics: anytype) !void {
    const old_tree = self.tree;
    defer if (old_tree) |tree| tree.destroy();

    const State = struct {
        buffer: @TypeOf(buffer),
        metrics: @TypeOf(metrics),
        syntax: *Self,
        result_buf: [1024]u8 = undefined,
    };
    var state: State = .{
        .buffer = buffer,
        .metrics = metrics,
        .syntax = self,
    };

    const input: Input = .{
        .payload = &state,
        .read = struct {
            fn read(payload: ?*anyopaque, _: u32, position: treez.Point, bytes_read: *u32) callconv(.c) [*:0]const u8 {
                const ctx: *State = @ptrCast(@alignCast(payload orelse return ""));
                const result = ctx.buffer.get_from_pos(.{ .row = position.row, .col = position.column }, &ctx.result_buf, ctx.metrics);
                bytes_read.* = @intCast(result.len);
                return @ptrCast(result.ptr);
            }
        }.read,
        .encoding = .utf_8,
    };
    self.tree = try self.parser.parse(old_tree, input);
}

pub fn refresh_from_string(self: *Self, content: [:0]const u8) !void {
    const old_tree = self.tree;
    defer if (old_tree) |tree| tree.destroy();

    const State = struct {
        content: @TypeOf(content),
    };
    var state: State = .{
        .content = content,
    };

    const input: Input = .{
        .payload = &state,
        .read = struct {
            fn read(payload: ?*anyopaque, _: u32, position: treez.Point, bytes_read: *u32) callconv(.c) [*:0]const u8 {
                bytes_read.* = 0;
                const ctx: *State = @ptrCast(@alignCast(payload orelse return ""));
                const pos = (find_line_begin(ctx.content, position.row) orelse return "") + position.column;
                if (pos >= ctx.content.len) return "";
                bytes_read.* = @intCast(ctx.content.len - pos);
                return ctx.content[pos..].ptr;
            }
        }.read,
        .encoding = .utf_8,
    };
    self.tree = try self.parser.parse(old_tree, input);
    if (self.content) |c| self.allocator.free(c);
    self.content = null;
    const content_copy = try self.allocator.dupe(u8, content);
    self.content = content_copy;
    try self.update_injections(old_tree, content);
}

fn update_injections(self: *Self, old_tree: ?*treez.Tree, content: []const u8) !void {
    const old = old_tree orelse return self.refresh_injections(content);
    const tree = self.tree orelse return self.refresh_injections(content);
    if (self.injections_state == .stale or self.injections == null) return self.refresh_injections(content);
    errdefer self.injections_state = .stale;

    const changed = tree_changed_ranges(old, tree);
    defer free_changed_ranges(changed);
    try self.edited_ranges.ensureUnusedCapacity(self.allocator, changed.len);
    for (changed) |range| self.edited_ranges.appendAssumeCapacity(.{ .start = range.start_byte, .end = range.end_byte });

    for (self.edited_ranges.items) |range_| {
        const range = whole_lines(content, range_);
        var index: usize = 0;
        while (index < self.injection_list.items.len) {
            const inj = &self.injection_list.items[index];
            if (range.touches(inj.start_byte, inj.end_byte)) {
                inj.deinit(self.allocator);
                _ = self.injection_list.orderedRemove(index);
            } else index += 1;
        }
        try self.add_injections(content, range);
    }
    self.edited_ranges.clearRetainingCapacity();
}

fn tree_changed_ranges(old: *treez.Tree, new: *treez.Tree) []const Range {
    return if (build_options.use_tree_sitter) treez.Tree.getChangedRanges(old, new) else &.{};
}

fn free_changed_ranges(ranges: []const Range) void {
    if (build_options.use_tree_sitter and ranges.len > 0) std.c.free(@constCast(ranges.ptr));
}

fn whole_lines(content: []const u8, range: ByteRange) ByteRange {
    var start: usize = @min(range.start, content.len);
    var end: usize = @min(@max(range.end, range.start), content.len);
    for (0..2) |_| start = if (std.mem.lastIndexOfScalar(u8, content[0..start -| 1], '\n')) |eol| eol + 1 else 0;
    for (0..2) |_| end = if (std.mem.indexOfScalarPos(u8, content, end, '\n')) |eol| eol + 1 else content.len;
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

pub fn refresh_injections(self: *Self, content: []const u8) !void {
    self.clear_injections();
    return self.add_injections(content, null);
}

fn add_injections(self: *Self, content: []const u8, range: ?ByteRange) !void {
    const injections_query = self.injections orelse return;
    const tree = self.tree orelse return;

    const cursor = try Query.Cursor.create();
    defer cursor.destroy();
    if (build_options.use_tree_sitter) if (range) |range_| cursor.setByteRange(range_.start, range_.end);
    cursor.execute(injections_query, tree.getRootNode());

    while (cursor.nextMatch()) |match| {
        var lang_range: ?Range = null;
        var content_range: ?Range = null;

        for (match.captures()) |capture| {
            const name = injections_query.getCaptureNameForId(capture.id);
            if (std.mem.eql(u8, name, "injection.language")) {
                lang_range = capture.node.getRange();
            } else if (std.mem.eql(u8, name, "injection.content")) {
                content_range = capture.node.getRange();
            }
        }

        const crange = content_range orelse continue;

        const lang_name: []const u8 = if (lang_range) |lr|
            extract_node_text(content, lr) orelse continue
        else
            get_static_injection_language(injections_query, match.pattern_index) orelse continue;

        if (lang_name.len == 0) continue;

        const file_type = FileType.get_by_name_static(lang_name) orelse
            FileType.get_by_name_static(normalize_lang_name(lang_name)) orelse
            continue;

        const start_byte = crange.start_byte;
        const end_byte = crange.end_byte;
        if (start_byte >= end_byte or end_byte > content.len) continue;
        if (range != null) {
            const known = for (self.injection_list.items, 0..) |*inj, index| {
                if (inj.start_byte == start_byte and inj.end_byte == end_byte) break index;
            } else null;
            if (known) |index| {
                if (std.mem.eql(u8, self.injection_list.items[index].lang_name, lang_name)) continue;
                self.injection_list.items[index].deinit(self.allocator);
                _ = self.injection_list.orderedRemove(index);
            }
        }

        const lang_name_owned = try self.allocator.dupe(u8, lang_name);
        errdefer self.allocator.free(lang_name_owned);

        try self.injection_list.append(self.allocator, .{
            .lang_name = lang_name_owned,
            .file_type = file_type,
            .start_point = crange.start_point,
            .end_row = crange.end_point.row,
            .start_byte = start_byte,
            .end_byte = end_byte,
        });
    }
}

fn extract_node_text(content: []const u8, range: Range) ?[]const u8 {
    const s = range.start_byte;
    const e = range.end_byte;
    if (s >= e or e > content.len) return null;
    return std.mem.trim(u8, content[s..e], &std.ascii.whitespace);
}

/// Normalize common language name aliases found in markdown
/// This should probably be in file_types
fn normalize_lang_name(name: []const u8) []const u8 {
    const aliases = .{
        .{ "js", "javascript" },
        .{ "kt", "kotlin" },
        .{ "ts", "typescript" },
        .{ "py", "python" },
        .{ "rb", "ruby" },
        .{ "sh", "bash" },
        .{ "shell", "bash" },
        .{ "zsh", "bash" },
        .{ "c++", "cpp" },
        .{ "cs", "c-sharp" },
        .{ "csharp", "c-sharp" },
        .{ "yml", "yaml" },
        .{ "md", "markdown" },
        .{ "rs", "rust" },
    };
    inline for (aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(name, alias[0])) return alias[1];
    }
    return name;
}

/// Read a static `#set! injection.language "name"` predicate for the given
/// pattern index, returning the language name string if found or null otherwise.
fn get_static_injection_language(query: *const Query, pattern_idx: u16) ?[]const u8 {
    const steps = query.getPredicatesForPattern(pattern_idx);
    var i: usize = 0;
    while (i < steps.len) {
        var j = i;
        while (j < steps.len and steps[j].type != .done) j += 1;
        const group = steps[i..j];
        i = j + 1;

        if (group.len == 3 and
            group[0].type == .string and
            group[1].type == .string and
            group[2].type == .string)
        {
            const name = query.getStringValueForId(group[0].value_id);
            const key = query.getStringValueForId(group[1].value_id);
            if (std.mem.eql(u8, name, "set!") and
                std.mem.eql(u8, key, "injection.language"))
            {
                return query.getStringValueForId(group[2].value_id);
            }
        }
    }
    return null;
}

pub fn write_pattern_predicates_cbor(
    query: *Query,
    match: Query.Match,
    content: []const u8,
    writer: *Io.Writer,
) !void {
    const steps = query.getPredicatesForPattern(match.pattern_index);
    var group_count: usize = 0;
    for (steps) |step| {
        if (step.type == .done) group_count += 1;
    }
    try cbor.writeArrayHeader(writer, group_count);

    var i: usize = 0;
    while (i < steps.len) {
        var j = i;
        while (j < steps.len and steps[j].type != .done) j += 1;
        const group = steps[i..j];
        i = j + 1;

        try cbor.writeArrayHeader(writer, group.len);
        for (group) |step| {
            switch (step.type) {
                .string => try cbor.writeValue(writer, query.getStringValueForId(step.value_id)),
                .capture => try write_capture_values(match, step.value_id, content, writer),
                .done => unreachable,
            }
        }
    }
}

fn write_capture_values(match: Query.Match, capture_id: u32, content: []const u8, writer: *Io.Writer) !void {
    var count: usize = 0;
    for (match.captures()) |capture| {
        if (capture.id == capture_id) count += 1;
    }

    switch (count) {
        0 => try cbor.writeValue(writer, null),
        1 => for (match.captures()) |capture| {
            if (capture.id == capture_id)
                return cbor.writeValue(writer, node_text(content, capture.node));
        },
        else => {
            try cbor.writeArrayHeader(writer, count);
            for (match.captures()) |capture| {
                if (capture.id == capture_id)
                    try cbor.writeValue(writer, node_text(content, capture.node));
            }
        },
    }
}

fn node_text(content: []const u8, node: Node) []const u8 {
    const range = node.getRange();
    const s = range.start_byte;
    const e = range.end_byte;
    if (s > e or e > content.len) return "";
    return content[s..e];
}

fn find_line_begin(s: []const u8, line: usize) ?usize {
    var idx: usize = 0;
    var at_line: usize = 0;
    while (idx < s.len) {
        if (at_line == line)
            return idx;
        if (s[idx] == '\n')
            at_line += 1;
        idx += 1;
    }
    return null;
}

fn CallBack(comptime T: type) type {
    return fn (ctx: T, sel: Range, scope: []const u8, id: u32, capture_idx: usize, priority: i32, pattern_index: u32, node: *const Node) error{Stop}!void;
}

/// default match priority (as defined by nvim)
const default_priority: i32 = 100;

/// injected-language captures are layered (far) above
const injection_pattern_bias: u32 = 1 << 20;

fn get_pattern_priority(query: *const Query, pattern_idx: u16) i32 {
    const steps = query.getPredicatesForPattern(pattern_idx);
    var i: usize = 0;
    while (i < steps.len) {
        var j = i;
        while (j < steps.len and steps[j].type != .done) j += 1;
        const group = steps[i..j];
        i = j + 1;

        if (group.len == 3 and
            group[0].type == .string and
            group[1].type == .string and
            group[2].type == .string)
        {
            const name = query.getStringValueForId(group[0].value_id);
            const key = query.getStringValueForId(group[1].value_id);
            if (std.mem.eql(u8, name, "set!") and
                std.mem.eql(u8, key, "priority"))
            {
                const value = query.getStringValueForId(group[2].value_id);
                return std.fmt.parseInt(i32, value, 10) catch default_priority;
            }
        }
    }
    return default_priority;
}

/// A match validator that is given the predicates attached to a match to
/// evaluate
fn Validator(comptime T: type) type {
    return fn (ctx: T, predicates: cbor.Raw) bool;
}

pub fn IgnoreAll(comptime T: type) Validator(T) {
    return struct {
        pub fn validate(_: T, _: cbor.Raw) bool {
            return false;
        }
    }.validate;
}
pub fn AcceptAll(comptime T: type) Validator(T) {
    return struct {
        pub fn validate(_: T, _: cbor.Raw) bool {
            return true;
        }
    }.validate;
}

pub fn SimpleNonRegex(comptime T: type) Validator(T) {
    const local = struct {
        fn eval_simple_predicates(predicates: cbor.Raw) cbor.Error!bool {
            var iter = predicates.bytes;
            var count = cbor.decodeArrayHeader(&iter) catch return true;
            while (count > 0) : (count -= 1) {
                var predicate: cbor.Raw = undefined;
                _ = try cbor.matchValue(&iter, cbor.extract(&predicate));
                if (!try eval_simple_predicate(predicate)) return false;
            }
            return true;
        }

        fn eval_simple_predicate(predicate: cbor.Raw) cbor.Error!bool {
            var capture: cbor.Raw = undefined;
            var value: cbor.Raw = undefined;
            if (try cbor.match(predicate.bytes, .{ "eq?", cbor.extract(&capture), cbor.extract(&value) }))
                return eval_eq(capture, value, .{ .positive = true, .match_all = true });
            if (try cbor.match(predicate.bytes, .{ "not-eq?", cbor.extract(&capture), cbor.extract(&value) }))
                return eval_eq(capture, value, .{ .positive = false, .match_all = true });
            if (try cbor.match(predicate.bytes, .{ "any-eq?", cbor.extract(&capture), cbor.extract(&value) }))
                return eval_eq(capture, value, .{ .positive = true, .match_all = false });
            if (try cbor.match(predicate.bytes, .{ "any-not-eq?", cbor.extract(&capture), cbor.extract(&value) }))
                return eval_eq(capture, value, .{ .positive = false, .match_all = false });
            if (try cbor.match(predicate.bytes, .{ "any-of?", cbor.extract(&capture), cbor.more }))
                return eval_any_of(predicate, capture, true);
            if (try cbor.match(predicate.bytes, .{ "not-any-of?", cbor.extract(&capture), cbor.more }))
                return eval_any_of(predicate, capture, false);
            var op: []const u8 = undefined;
            if (try cbor.match(predicate.bytes, .{ cbor.extract(&op), cbor.more }))
                return std.mem.endsWith(u8, op, "!"); // directives always evaluate to true
            return false;
        }

        const EqMode = struct { positive: bool, match_all: bool };
        fn eval_eq(capture: cbor.Raw, value: cbor.Raw, mode: EqMode) cbor.Error!bool {
            var value_text: []const u8 = undefined;
            if (!(cbor.match(value.bytes, cbor.extract(&value_text)) catch false)) return true;

            var nodes = NodeTexts.init(capture);
            while (nodes.next()) |text| {
                const is_match = std.mem.eql(u8, text, value_text);
                if (mode.match_all and is_match != mode.positive) return false;
                if (!mode.match_all and is_match == mode.positive) return true;
            }
            // No node forced a decision: with match_all every node passed; with match_any
            // none did.
            return mode.match_all;
        }

        fn eval_any_of(predicate: cbor.Raw, capture: cbor.Raw, positive: bool) cbor.Error!bool {
            var iter = predicate.bytes;
            const total = cbor.decodeArrayHeader(&iter) catch return true;
            if (total < 2) return true;
            try cbor.skipValue(&iter); // operator
            try cbor.skipValue(&iter); // capture
            const values = iter;
            const value_count = total - 2;

            var nodes = NodeTexts.init(capture);
            while (nodes.next()) |text| {
                if ((try text_in_set(text, values, value_count)) != positive) return false;
            }
            return true;
        }

        fn text_in_set(text: []const u8, values: []const u8, value_count: usize) cbor.Error!bool {
            var iter = values;
            var remaining = value_count;
            while (remaining > 0) : (remaining -= 1) {
                var value: []const u8 = undefined;
                if (!try cbor.matchValue(&iter, cbor.extract(&value))) return false;
                if (std.mem.eql(u8, text, value)) return true;
            }
            return false;
        }

        const NodeTexts = struct {
            iter: []const u8,
            remaining: usize,

            fn init(value: cbor.Raw) NodeTexts {
                if (cbor.match(value.bytes, cbor.null_) catch false)
                    return .{ .iter = value.bytes, .remaining = 0 };
                if (cbor.match(value.bytes, cbor.string) catch false)
                    return .{ .iter = value.bytes, .remaining = 1 };
                var iter = value.bytes;
                const count = cbor.decodeArrayHeader(&iter) catch 0;
                return .{ .iter = iter, .remaining = count };
            }

            fn next(self: *NodeTexts) ?[]const u8 {
                if (self.remaining == 0) return null;
                self.remaining -= 1;
                var text: []const u8 = undefined;
                return if (cbor.matchValue(&self.iter, cbor.extract(&text)) catch false) text else null;
            }
        };
    };
    return struct {
        fn validate(_: T, predicates: cbor.Raw) bool {
            return local.eval_simple_predicates(predicates) catch true;
        }
    }.validate;
}

test "SimpleNonRegex predicate evaluation" {
    const expect = std.testing.expect;
    const validator = SimpleNonRegex(void);
    const eval = struct {
        fn eval(value: anytype) bool {
            var buf: [4096]u8 = undefined;
            return validator({}, .{ .bytes = cbor.fmt(&buf, value) });
        }
    }.eval;

    try expect(eval(.{.{ "eq?", "x", "x" }}));
    try expect(!eval(.{.{ "eq?", "y", "x" }}));
    try expect(eval(.{.{ "not-eq?", "y", "x" }}));
    try expect(!eval(.{.{ "not-eq?", "x", "x" }}));
    try expect(eval(.{.{ "eq?", "abc", "abc" }}));

    // multi-node capture: #eq? requires all nodes equal, #any-eq? requires one
    try expect(eval(.{.{ "eq?", .{ "x", "x" }, "x" }}));
    try expect(!eval(.{.{ "eq?", .{ "x", "y" }, "x" }}));
    try expect(eval(.{.{ "any-eq?", .{ "y", "x" }, "x" }}));
    try expect(!eval(.{.{ "any-eq?", .{ "y", "z" }, "x" }}));
    try expect(eval(.{.{ "any-not-eq?", .{ "x", "y" }, "x" }}));
    try expect(!eval(.{.{ "any-not-eq?", .{ "x", "x" }, "x" }}));

    try expect(eval(.{.{ "any-of?", "y", "x", "y" }}));
    try expect(!eval(.{.{ "any-of?", "z", "x", "y" }}));
    try expect(eval(.{.{ "not-any-of?", "z", "x", "y" }}));
    try expect(!eval(.{.{ "not-any-of?", "x", "x", "y" }}));
    // every node of a multi-node capture must be in the set
    try expect(eval(.{.{ "any-of?", .{ "x", "y" }, "x", "y" }}));
    try expect(!eval(.{.{ "any-of?", .{ "x", "z" }, "x", "y" }}));

    // a missing capture (null) has no nodes: #eq? vacuously holds, #any-eq? fails
    try expect(eval(.{.{ "eq?", null, "x" }}));
    try expect(!eval(.{.{ "any-eq?", null, "x" }}));

    // unrecognized predicates always drop a match
    try expect(!eval(.{.{ "match?", "x", "[a-z]+" }}));

    // directives (names ending in '!', e.g. #set!) are ignored and keep the match
    try expect(eval(.{.{ "set!", "injection.language", "zig" }}));
    try expect(eval(.{.{ "set!", "key" }}));
    try expect(eval(.{.{ "select-adjacent!", "x", "y" }}));
    // a directive does not rescue a failing predicate in the same group
    try expect(!eval(.{ .{ "set!", "k", "v" }, .{ "eq?", "y", "z" } }));

    // a match is kept only if every predicate passes
    try expect(eval(.{ .{ "eq?", "x", "x" }, .{ "any-of?", "y", "y", "z" } }));
    try expect(!eval(.{ .{ "eq?", "x", "x" }, .{ "eq?", "y", "z" } }));

    // capture-to-capture with a multi-node right-hand side is left unevaluated
    try expect(eval(.{.{ "eq?", "x", .{ "x", "y" } }}));
}

fn match_applies(
    self: *const Self,
    ctx: anytype,
    comptime validator: Validator(@TypeOf(ctx)),
    match: Query.Match,
) !bool {
    if (self.query.getPredicatesForPattern(match.pattern_index).len == 0) return true;
    var predicates: Io.Writer.Allocating = .init(self.allocator);
    defer predicates.deinit();
    try write_pattern_predicates_cbor(self.query, match, self.content orelse "", &predicates.writer);
    return validator(ctx, .{ .bytes = predicates.writer.buffered() });
}

pub fn render(self: *Self, ctx: anytype, comptime cb: CallBack(@TypeOf(ctx)), comptime validator: Validator(@TypeOf(ctx)), range: ?Range) !void {
    try self.render_highlights_only(ctx, cb, validator, range);

    const content = self.content orelse return;
    for (self.injection_list.items) |*inj| {
        if (range) |r| {
            if (inj.end_row < r.start_point.row) continue;
            if (inj.start_point.row > r.end_point.row) continue;
        }

        if (inj.syntax == null) {
            const child_content = content[inj.start_byte..inj.end_byte];
            const child = try Self.create(inj.file_type, self.allocator, self.query_cache);
            errdefer child.destroy();
            if (child.tree) |t| t.destroy();
            child.tree = try child.parser.parseString(null, child_content);
            inj.syntax = child;
        }
        const child_syn = inj.syntax.?;

        const child_range: ?Range = if (range) |r| blk: {
            const child_start_row: u32 = if (r.start_point.row > inj.start_point.row)
                r.start_point.row - inj.start_point.row
            else
                0;
            const child_end_row: u32 = r.end_point.row - inj.start_point.row;
            break :blk .{
                .start_point = .{ .row = child_start_row, .column = 0 },
                .end_point = .{ .row = child_end_row, .column = 0 },
                .start_byte = 0,
                .end_byte = 0,
            };
        } else null;

        // Wrap the context to translate local ranges to document coordinates
        const InjCtx = struct {
            parent_ctx: @TypeOf(ctx),
            inj: *const Injection,

            fn translated_cb(
                self_: *const @This(),
                child_sel: Range,
                scope: []const u8,
                id: u32,
                capture_idx: usize,
                priority: i32,
                pattern_index: u32,
                node: *const Node,
            ) error{Stop}!void {
                const start_row = child_sel.start_point.row + self_.inj.start_point.row;
                const end_row = child_sel.end_point.row + self_.inj.start_point.row;
                const start_col = child_sel.start_point.column +
                    if (child_sel.start_point.row == 0) self_.inj.start_point.column else 0;
                const end_col = child_sel.end_point.column +
                    if (child_sel.end_point.row == 0) self_.inj.start_point.column else 0;
                const doc_range: Range = .{
                    .start_point = .{ .row = start_row, .column = start_col },
                    .end_point = .{ .row = end_row, .column = end_col },
                    .start_byte = child_sel.start_byte,
                    .end_byte = child_sel.end_byte,
                };
                try cb(self_.parent_ctx, doc_range, scope, id, capture_idx, priority, pattern_index +| injection_pattern_bias, node);
            }

            fn translated_validator(self_: *const @This(), predicates: cbor.Raw) bool {
                return validator(self_.parent_ctx, predicates);
            }
        };

        var inj_ctx: InjCtx = .{ .parent_ctx = ctx, .inj = inj };
        try child_syn.render_highlights_only(&inj_ctx, InjCtx.translated_cb, InjCtx.translated_validator, child_range);
    }
}

fn render_highlights_only(self: *const Self, ctx: anytype, comptime cb: CallBack(@TypeOf(ctx)), comptime validator: Validator(@TypeOf(ctx)), range: ?Range) !void {
    const cursor = try Query.Cursor.create();
    defer cursor.destroy();
    const tree = self.tree orelse return;
    cursor.execute(self.query, tree.getRootNode());
    if (range) |r| cursor.setPointRange(r.start_point, r.end_point);
    while (cursor.nextMatch()) |match| {
        if (!try self.match_applies(ctx, validator, match)) continue;
        const priority = get_pattern_priority(self.query, match.pattern_index);
        var idx: usize = 0;
        for (match.captures()) |capture| {
            try cb(ctx, capture.node.getRange(), self.query.getCaptureNameForId(capture.id), capture.id, idx, priority, match.pattern_index, &capture.node);
            idx += 1;
        }
    }
}

pub fn highlights_at_point(self: *const Self, ctx: anytype, comptime cb: CallBack(@TypeOf(ctx)), comptime validator: Validator(@TypeOf(ctx)), point: Point) bool {
    const cursor = Query.Cursor.create() catch return false;
    defer cursor.destroy();
    const tree = self.tree orelse return false;
    cursor.execute(self.query, tree.getRootNode());
    cursor.setPointRange(.{ .row = point.row, .column = 0 }, .{ .row = point.row + 1, .column = 0 });
    var found_highlight = false;
    while (cursor.nextMatch()) |match| {
        if (!(self.match_applies(ctx, validator, match) catch true)) continue;
        const priority = get_pattern_priority(self.query, match.pattern_index);
        for (match.captures()) |capture| {
            const range = capture.node.getRange();
            const start = range.start_point;
            const end = range.end_point;
            const scope = self.query.getCaptureNameForId(capture.id);
            if (start.row == point.row and start.column <= point.column and point.column < end.column) {
                cb(ctx, range, scope, capture.id, 0, priority, match.pattern_index, &capture.node) catch return found_highlight;
                found_highlight = true;
            }
            break;
        }
    }
    return found_highlight;
}

pub fn node_at_point_range(self: *const Self, range: Range) error{Stop}!treez.Node {
    const tree = self.tree orelse return error.Stop;
    const root_node = tree.getRootNode();
    return treez.Node.externs.ts_node_descendant_for_point_range(root_node, range.start_point, range.end_point);
}

pub fn count_error_nodes(self: *const Self) usize {
    const cursor = Query.Cursor.create() catch return std.math.maxInt(usize);
    defer cursor.destroy();
    const tree = self.tree orelse return 0;
    cursor.execute(self.errors_query, tree.getRootNode());
    var error_count: usize = 0;
    while (cursor.nextMatch()) |match| for (match.captures()) |_| {
        error_count += 1;
    };
    return error_count;
}

test "simple build and link test" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const zig_file_type = @import("file_type.zig").get_by_name_static("zig") orelse return error.TestFailed;
    const query_cache = try QueryCache.create(io, gpa, .{});
    defer query_cache.deinit();
    const syntax = try create(zig_file_type, gpa, query_cache);
    defer syntax.destroy();

    const content = try std.Io.Dir.readFileAlloc(.cwd(), io, "src/syntax.zig", gpa, .unlimited);
    defer gpa.free(content);
    try syntax.refresh_full(content);

    try syntax.render({}, struct {
        fn cb(_: void, _: Range, _: []const u8, _: u32, _: usize, _: i32, _: u32, _: *const Node) error{Stop}!void {}
    }.cb, struct {
        fn validate(_: void, _: cbor.Raw) bool {
            return true;
        }
    }.validate, null);
}

test "get_pattern_priority reads #set! priority from the yaml query" {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const yaml_file_type = @import("file_type.zig").get_by_name_static("yaml") orelse return error.TestFailed;
    const query_cache = try QueryCache.create(io, gpa, .{});
    defer query_cache.deinit();
    const syntax = try create(yaml_file_type, gpa, query_cache);
    defer syntax.destroy();

    // The nvim-treesitter yaml highlights query demotes (block_scalar) @string with
    // `(#set! priority 99)`; every other pattern keeps the default priority of 100.
    var seen_99 = false;
    const count = syntax.query.getPatternCount();
    var pattern: u16 = 0;
    while (pattern < count) : (pattern += 1) {
        const priority = get_pattern_priority(syntax.query, pattern);
        if (priority == 99) {
            seen_99 = true;
        } else {
            try std.testing.expectEqual(default_priority, priority);
        }
    }
    try std.testing.expect(seen_99);
}

const TestInjection = struct { start_byte: u32, end_byte: u32, start_point: Point, end_row: u32, lang: []const u8 };

fn test_injections(allocator: std.mem.Allocator, syn: *const Self) ![]TestInjection {
    const list = try allocator.alloc(TestInjection, syn.injection_list.items.len);
    for (list, syn.injection_list.items) |*item, inj| item.* = .{
        .start_byte = inj.start_byte,
        .end_byte = inj.end_byte,
        .start_point = inj.start_point,
        .end_row = inj.end_row,
        .lang = inj.lang_name,
    };
    std.mem.sort(TestInjection, list, {}, struct {
        fn less(_: void, a: TestInjection, b: TestInjection) bool {
            return if (a.start_byte != b.start_byte) a.start_byte < b.start_byte else a.end_byte < b.end_byte;
        }
    }.less);
    return list;
}

fn test_point(text: []const u8, offset: usize) Point {
    const row = std.mem.count(u8, text[0..offset], "\n");
    const line_begin = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |eol| eol + 1 else 0;
    return .{ .row = @intCast(row), .column = @intCast(offset - line_begin) };
}

test "injections after incremental parses equal the injections of a full parse" {
    if (!build_options.use_tree_sitter) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const file_type = FileType.get_by_name_static("markdown") orelse return error.SkipZigTest;
    const query_cache = try QueryCache.create(io, gpa, .{});
    defer query_cache.deinit();
    const incremental = try create(file_type, gpa, query_cache);
    defer incremental.destroy();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..12) |i| try text.print(gpa, "# Title {d}\n\nSome *text* with `code` here.\n\n```zig\nconst a{d} = {d};\n```\n\n```json\n{{\"k\": {d}}}\n```\n\n", .{ i, i, i, i });
    try text.append(gpa, 0);
    try incremental.refresh_full(text.items[0 .. text.items.len - 1]);
    try std.testing.expect(incremental.injection_list.items.len > 12);

    const pieces = [_][]const u8{ "x", "\n", "```", "```zig\n", "zig", "json", " ", "\n\n", "`", "# ", "*", "const b = 1;\n" };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    for (0..400) |round| {
        // one to three edits before the next parse, the last one first, as the editor sends them
        var limit: usize = text.items.len - 1;
        for (0..random.intRangeAtMost(usize, 1, 3)) |_| {
            if (limit == 0) break;
            const start = random.uintLessThan(usize, limit);
            const old_end = @min(limit, start + if (random.boolean()) random.uintLessThan(usize, 12) else 0);
            const new_text = if (random.uintLessThan(u8, 4) == 0) "" else pieces[random.uintLessThan(usize, pieces.len)];
            const start_point = test_point(text.items, start);
            const old_end_point = test_point(text.items, old_end);
            try text.replaceRange(gpa, start, old_end - start, new_text);
            incremental.edit(.{
                .start_byte = @intCast(start),
                .old_end_byte = @intCast(old_end),
                .new_end_byte = @intCast(start + new_text.len),
                .start_point = start_point,
                .old_end_point = old_end_point,
                .new_end_point = test_point(text.items, start + new_text.len),
            });
            limit = start;
        }
        const content = text.items[0 .. text.items.len - 1 :0];
        try incremental.refresh_from_string(content);

        const full = try create(file_type, gpa, query_cache);
        defer full.destroy();
        try full.refresh_full(content);
        const expected = try test_injections(gpa, full);
        defer gpa.free(expected);
        const actual = try test_injections(gpa, incremental);
        defer gpa.free(actual);
        errdefer std.debug.print("round {d}: expected {d} injections, found {d}\n", .{ round, expected.len, actual.len });
        try std.testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |e, a| {
            try std.testing.expectEqual(e.start_byte, a.start_byte);
            try std.testing.expectEqual(e.end_byte, a.end_byte);
            try std.testing.expectEqual(e.start_point.row, a.start_point.row);
            try std.testing.expectEqual(e.start_point.column, a.start_point.column);
            try std.testing.expectEqual(e.end_row, a.end_row);
            try std.testing.expectEqualStrings(e.lang, a.lang);
        }
    }
}
