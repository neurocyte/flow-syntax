const std = @import("std");
const cbor = @import("cbor");
const build_options = @import("build_options");

const treez = if (build_options.use_tree_sitter)
    @import("treez")
else
    @import("treez_dummy.zig");

pub const FileType = @This();

color: u24,
icon: []const u8,
name: []const u8,
description: []const u8,
lang_fn: LangFn,
extensions: []const []const u8,
first_line_matches: ?FirstLineMatch = null,
comment: []const u8,
formatter: ?[]const []const u8,
language_server: ?[]const []const u8,

pub fn get_by_name_static(name: []const u8) ?FileType {
    return FileType.static_file_types.get(name);
}

pub fn get_all() []const FileType {
    return FileType.static_file_types.values();
}

pub fn guess_static(file_path: ?[]const u8, content: []const u8) ?FileType {
    if (guess_first_line_static(content)) |ft| return ft;
    for (static_file_types.values()) |file_type|
        if (file_path) |fp| if (match_file_type(file_type.extensions, fp))
            return file_type;
    return null;
}

fn guess_first_line_static(content: []const u8) ?FileType {
    const first_line = if (std.mem.indexOf(u8, content, "\n")) |pos| content[0..pos] else content;
    for (static_file_types.values()) |file_type|
        if (file_type.first_line_matches) |match|
            if (match_first_line(match.prefix, match.content, first_line))
                return file_type;
    return null;
}

pub fn match_first_line(match_prefix: ?[]const u8, match_content: ?[]const u8, first_line: []const u8) bool {
    if (match_prefix == null and match_content == null) return false;
    if (match_prefix) |prefix|
        if (prefix.len > first_line.len or !std.mem.eql(u8, first_line[0..prefix.len], prefix))
            return false;
    if (match_content) |content|
        if (std.mem.indexOf(u8, first_line, content)) |_| {} else return false;
    return true;
}

pub fn match_file_type(extensions: []const []const u8, file_path: []const u8) bool {
    const basename = std.fs.path.basename(file_path);
    const extension = std.fs.path.extension(file_path);
    return for (extensions) |ext| {
        if (ext.len == basename.len and std.mem.eql(u8, ext, basename))
            return true;
        if (extension.len > 0 and ext.len == extension.len - 1 and std.mem.eql(u8, ext, extension[1..]))
            return true;
    } else false;
}

pub fn Parser(comptime lang: []const u8) LangFn {
    return get_parser(lang);
}

fn get_parser(comptime lang: []const u8) LangFn {
    if (build_options.use_tree_sitter) {
        const language_name = ft_func_name(lang);
        return @extern(?LangFn, .{ .name = "tree_sitter_" ++ language_name }) orelse @compileError(std.fmt.comptimePrint("Cannot find extern tree_sitter_{s}", .{language_name}));
    } else {
        return treez.Language.LangFn;
    }
}

fn ft_func_name(comptime lang: []const u8) []const u8 {
    var transform: [lang.len]u8 = undefined;
    for (lang, 0..) |c, i|
        transform[i] = if (c == '-') '_' else c;
    const func_name = transform;
    return &func_name;
}

pub const LangFn = *const fn () callconv(.c) ?*const treez.Language;

pub const FirstLineMatch = struct {
    prefix: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

const static_file_type_list = load_file_types(@import("file_types.zig"));
const static_file_types = std.StaticStringMap(FileType).initComptime(static_file_type_list);

fn vec(comptime args: anytype) []const []const u8 {
    var cmd: []const []const u8 = &[_][]const u8{};
    inline for (args) |arg| {
        cmd = cmd ++ [_][]const u8{arg};
    }
    return cmd;
}

const ListEntry = struct { []const u8, FileType };

fn load_file_types(comptime Namespace: type) []const ListEntry {
    comptime switch (@typeInfo(Namespace)) {
        .@"struct" => |info| {
            var count = 0;
            for (info.decls) |_| {
                // @compileLog(decl.name, @TypeOf(@field(Namespace, decl.name)));
                count += 1;
            }
            var construct_types: [count]ListEntry = undefined;
            var i = 0;
            for (info.decls) |decl| {
                const lang = decl.name;
                const args = @field(Namespace, lang);
                construct_types[i] = .{ lang, .{
                    .color = if (@hasField(@TypeOf(args), "color")) args.color else 0xffffff,
                    .icon = if (@hasField(@TypeOf(args), "icon")) args.icon else "󱀫",
                    .name = lang,
                    .description = args.description,
                    .lang_fn = if (@hasField(@TypeOf(args), "parser")) args.parser else get_parser(lang),
                    .extensions = vec(args.extensions),
                    .comment = args.comment,
                    .first_line_matches = if (@hasField(@TypeOf(args), "first_line_matches")) args.first_line_matches else null,
                    .formatter = if (@hasField(@TypeOf(args), "formatter")) vec(args.formatter) else null,
                    .language_server = if (@hasField(@TypeOf(args), "language_server")) vec(args.language_server) else null,
                } };
                i += 1;
            }
            const types = construct_types;
            return &types;
        },
        else => @compileError("expected tuple or struct type"),
    };
}

pub const FileTypeQueries = struct {
    highlights_bin: []const u8,
    errors_bin: []const u8,
    injections_bin: ?[]const u8,
};

pub const queries = std.StaticStringMap(FileTypeQueries).initComptime(load_queries());

fn load_queries() []const struct { []const u8, FileTypeQueries } {
    if (!build_options.use_tree_sitter) return &.{};
    @setEvalBranchQuota(32000);
    const queries_cb = @embedFile("syntax_bin_queries");
    var iter: []const u8 = queries_cb;
    var len = cbor.decodeMapHeader(&iter) catch |e| {
        @compileLog("cbor.decodeMapHeader", e);
        @compileError("invalid syntax_bin_queries");
    };
    var construct_types: [len]struct { []const u8, FileTypeQueries } = undefined;
    var i = 0;
    while (len > 0) : (len -= 1) {
        var lang: []const u8 = undefined;
        if (!try cbor.matchString(&iter, &lang))
            @compileError("invalid language name field");
        construct_types[i] = .{ lang, .{
            .highlights_bin = blk: {
                var iter_: []const u8 = iter;
                break :blk get_query_value_bin(&iter_, "highlights") orelse @compileError("missing highlights for " ++ lang);
            },
            .errors_bin = blk: {
                var iter_: []const u8 = iter;
                break :blk get_query_value_bin(&iter_, "errors") orelse @compileError("missing errors query for " ++ lang);
            },
            .injections_bin = blk: {
                var iter_: []const u8 = iter;
                break :blk get_query_value_bin(&iter_, "injections");
            },
        } };
        try cbor.skipValue(&iter);
        i += 1;
    }
    const types = construct_types;
    return &types;
}

fn get_query_value_bin(iter: *[]const u8, comptime query: []const u8) ?[]const u8 {
    var len = cbor.decodeMapHeader(iter) catch |e| {
        @compileLog("cbor.decodeMapHeader", e);
        @compileError("invalid query map in syntax_bin_queries");
    };
    while (len > 0) : (len -= 1) {
        var query_name: []const u8 = undefined;
        if (!try cbor.matchString(iter, &query_name))
            @compileError("invalid query name field");
        if (std.mem.eql(u8, query_name, query)) {
            var query_value: []const u8 = undefined;
            if (try cbor.matchValue(iter, cbor.extract(&query_value)))
                return query_value;
            @compileError("invalid query value field");
        } else {
            try cbor.skipValue(iter);
        }
    }
    return null;
}
