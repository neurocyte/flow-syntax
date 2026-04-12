const std = @import("std");
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
content: ?[]u8 = null,

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
    if (self.tree) |tree| tree.edit(&ed);
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
    try self.refresh_injections(content);
}

pub fn refresh_injections(self: *Self, content: []const u8) !void {
    self.clear_injections();

    const injections_query = self.injections orelse return;
    const tree = self.tree orelse return;

    const cursor = try Query.Cursor.create();
    defer cursor.destroy();
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

/// Read a static `#set! injection.language "name"` predicate from the query's
/// internal predicate table for the given pattern index, returning the language
/// name string if found or null otherwise.
///
/// This accesses TSQuery internals via the same cast used in ts_bin_query_gen.zig
fn get_static_injection_language(query: *Query, pattern_idx: u16) ?[]const u8 {
    const tss = @import("ts_serializer.zig");
    const ts_query: *tss.TSQuery = @ptrCast(@alignCast(query));

    const patterns = ts_query.patterns;
    if (patterns.contents == null or @as(u32, pattern_idx) >= patterns.size) return null;
    const pattern_arr: [*]tss.QueryPattern = @ptrCast(patterns.contents.?);
    const pattern = pattern_arr[pattern_idx];

    const pred_steps = ts_query.predicate_steps;
    if (pred_steps.contents == null or pred_steps.size == 0) return null;
    const steps_arr: [*]tss.PredicateStep = @ptrCast(pred_steps.contents.?);

    const pred_values = ts_query.predicate_values;
    if (pred_values.slices.contents == null or pred_values.characters.contents == null) return null;
    const slices_arr: [*]tss.Slice = @ptrCast(pred_values.slices.contents.?);
    const chars: [*]u8 = @ptrCast(pred_values.characters.contents.?);

    // Walk the predicate steps for this pattern looking for the sequence:
    //   string("set!")  string("injection.language")  string("<name>")  done
    const step_start = pattern.predicate_steps.offset;
    const step_end = step_start + pattern.predicate_steps.length;

    var i = step_start;
    while (i < step_end) {
        const s = steps_arr[i];
        if (s.type == .done) {
            i += 1;
            continue;
        }

        // We need at least 4 steps: 3 strings + done.
        if (i + 3 >= step_end) break;

        const s0 = steps_arr[i];
        const s1 = steps_arr[i + 1];
        const s2 = steps_arr[i + 2];
        const s3 = steps_arr[i + 3];

        if (s0.type == .string and s1.type == .string and
            s2.type == .string and s3.type == .done)
        {
            if (s0.value_id < pred_values.slices.size and
                s1.value_id < pred_values.slices.size and
                s2.value_id < pred_values.slices.size)
            {
                const sl0 = slices_arr[s0.value_id];
                const sl1 = slices_arr[s1.value_id];
                const sl2 = slices_arr[s2.value_id];
                const n0 = chars[sl0.offset .. sl0.offset + sl0.length];
                const n1 = chars[sl1.offset .. sl1.offset + sl1.length];
                const n2 = chars[sl2.offset .. sl2.offset + sl2.length];
                if (std.mem.eql(u8, n0, "set!") and
                    std.mem.eql(u8, n1, "injection.language"))
                {
                    return n2;
                }
            }
        }

        // Advance past this predicate group to the next .done boundary.
        while (i < step_end and steps_arr[i].type != .done) i += 1;
        if (i < step_end) i += 1;
    }
    return null;
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
    return fn (ctx: T, sel: Range, scope: []const u8, id: u32, capture_idx: usize, node: *const Node) error{Stop}!void;
}

pub fn render(self: *Self, ctx: anytype, comptime cb: CallBack(@TypeOf(ctx)), range: ?Range) !void {
    try self.render_highlights_only(ctx, cb, range);

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
                try cb(self_.parent_ctx, doc_range, scope, id, capture_idx, node);
            }
        };

        var inj_ctx: InjCtx = .{ .parent_ctx = ctx, .inj = inj };
        try child_syn.render_highlights_only(&inj_ctx, InjCtx.translated_cb, child_range);
    }
}

fn render_highlights_only(self: *const Self, ctx: anytype, comptime cb: CallBack(@TypeOf(ctx)), range: ?Range) !void {
    const cursor = try Query.Cursor.create();
    defer cursor.destroy();
    const tree = self.tree orelse return;
    cursor.execute(self.query, tree.getRootNode());
    if (range) |r| cursor.setPointRange(r.start_point, r.end_point);
    while (cursor.nextMatch()) |match| {
        var idx: usize = 0;
        for (match.captures()) |capture| {
            try cb(ctx, capture.node.getRange(), self.query.getCaptureNameForId(capture.id), capture.id, idx, &capture.node);
            idx += 1;
        }
    }
}

pub fn highlights_at_point(self: *const Self, ctx: anytype, comptime cb: CallBack(@TypeOf(ctx)), point: Point) bool {
    const cursor = Query.Cursor.create() catch return false;
    defer cursor.destroy();
    const tree = self.tree orelse return false;
    cursor.execute(self.query, tree.getRootNode());
    cursor.setPointRange(.{ .row = point.row, .column = 0 }, .{ .row = point.row + 1, .column = 0 });
    var found_highlight = false;
    while (cursor.nextMatch()) |match| {
        for (match.captures()) |capture| {
            const range = capture.node.getRange();
            const start = range.start_point;
            const end = range.end_point;
            const scope = self.query.getCaptureNameForId(capture.id);
            if (start.row == point.row and start.column <= point.column and point.column < end.column) {
                cb(ctx, range, scope, capture.id, 0, &capture.node) catch return found_highlight;
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
    const gpa = std.testing.allocator;

    const zig_file_type = @import("file_type.zig").get_by_name_static("zig") orelse return error.TestFailed;
    const query_cache = try QueryCache.create(gpa, .{});
    defer query_cache.deinit();
    const syntax = try create(zig_file_type, gpa, query_cache);
    defer syntax.destroy();

    const content = try std.fs.cwd().readFileAlloc(gpa, "src/syntax.zig", std.math.maxInt(usize));
    defer gpa.free(content);
    try syntax.refresh_full(content);

    try syntax.render({}, struct {
        fn cb(_: void, _: Range, _: []const u8, _: u32, _: usize, _: *const Node) error{Stop}!void {}
    }.cb, null);
}
