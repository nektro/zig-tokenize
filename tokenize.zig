const std = @import("std");
const string = []const u8;

pub const Document = struct {
    tokens: std.MultiArrayList(Token).Slice,
    string_bytes: []const u8,
    extra: []const u32,

    pub fn str(self: Document, ind: Token.Index) []const u8 {
        const tag = self.tokens.items(.tag)[ind];
        const extra = self.tokens.items(.extra)[ind];
        return switch (tag) {
            .symbol => &[_]u8{@intCast(u8, extra)},
            .word, .string => self.string_bytes[self.extra[extra]..][0..self.extra[extra + 1]],
        };
    }

    pub fn deinit(self: *Document, alloc: std.mem.Allocator) void {
        self.tokens.deinit(alloc);
        alloc.free(self.string_bytes);
        alloc.free(self.extra);
    }
};

pub const Token = struct {
    tag: Tag,
    extra: u32,
    line: u32,
    pos: u32,

    pub const Index = u32;

    pub const Tag = std.meta.Tag(Data);

    pub const Data = union(enum) {
        symbol: void,
        word: ExtraStr,
        string: ExtraStr,
    };

    pub const skippedChars = &[_]u8{ ' ', '\n', '\t', '\r' };
};

const ExtraStr = struct {
    start: u32,
    len: u32,

    pub fn get(self: @This(), code: Document) []const u8 {
        return code.string_bytes[self.start..][0..self.len];
    }
};

const Worker = struct {
    insts: std.ArrayListUnmanaged(Token) = .{},
    extras: std.ArrayListUnmanaged(u32) = .{},
    strings: std.ArrayListUnmanaged(u8) = .{},
    strings_map: std.StringHashMapUnmanaged(u32) = .{},

    pub fn addStr(self: *Worker, alloc: std.mem.Allocator, str: string) !u32 {
        var res = try self.strings_map.getOrPut(alloc, str);
        if (res.found_existing) return res.value_ptr.*;
        const q = self.strings.items.len;
        try self.strings.appendSlice(alloc, str);
        const r = self.extras.items.len;
        try self.extras.appendSlice(alloc, &[_]u32{ @intCast(u32, q), @intCast(u32, str.len) });
        res.value_ptr.* = @intCast(u32, r);
        return @intCast(u32, r);
    }

    pub fn final(self: *Worker, alloc: std.mem.Allocator) !Document {
        self.strings_map.deinit(alloc);
        var tokens_list = self.insts.toOwnedSlice(alloc);
        defer alloc.free(tokens_list);
        var multilist = std.MultiArrayList(Token){};
        errdefer multilist.deinit(alloc);
        try multilist.ensureUnusedCapacity(alloc, tokens_list.len);
        for (tokens_list) |item| multilist.appendAssumeCapacity(item);
        return Document{
            .tokens = multilist.slice(),
            .string_bytes = self.strings.toOwnedSlice(alloc),
            .extra = self.extras.toOwnedSlice(alloc),
        };
    }
};

const InnerMode = enum {
    unknown,
    line_comment,
    string,
};

/// Document owns its memory, `input` may be freed after this function returns
pub fn do(alloc: std.mem.Allocator, symbols: []const u8, input: string) !Document {
    var wrk = Worker{};
    // String table indexes 0 and 1 are reserved for special meaning.
    try wrk.strings.appendSlice(alloc, &[_]u8{ 0, 0 });

    var line: u32 = 1;
    var pos: u32 = 1;

    var start: usize = 0;
    var end: usize = 0;
    var mode = InnerMode.unknown;

    @setEvalBranchQuota(100000);

    for (input) |c, i| {
        var shouldFlush: bool = undefined;

        blk: {
            if (mode == .unknown) {
                if (c == '/' and input[i + 1] == '/') {
                    mode = .line_comment;
                    shouldFlush = false;
                    break :blk;
                }
                if (c == '"') {
                    mode = .string;
                    shouldFlush = false;
                    break :blk;
                }
            }
            if (mode == .line_comment) {
                if (c == '\n') {
                    // skip comments
                    // f(v.handle(TTCom, in[s:i]))
                    start = i;
                    end = i;
                    mode = .unknown;
                }
                shouldFlush = c == '\n';
                break :blk;
            }
            if (mode == .string) {
                if (c == input[start]) {
                    try wrk.insts.append(alloc, .{
                        .tag = .string,
                        .extra = try wrk.addStr(alloc, input[start .. i + 1]),
                        .line = line,
                        .pos = pos,
                    });
                    start = i + 1;
                    end = i;
                    mode = .unknown;
                }
                shouldFlush = false;
                break :blk;
            }
            if (std.mem.indexOfScalar(u8, Token.skippedChars, c)) |_| {
                shouldFlush = true;
                break :blk;
            }
            if (std.mem.indexOfScalar(u8, symbols, c)) |_| {
                shouldFlush = true;
                break :blk;
            }
            shouldFlush = false;
            break :blk;
        }

        if (!shouldFlush) {
            end += 1;
        }
        if (shouldFlush) {
            if (mode == .unknown) {
                if (end - start > 0) {
                    try wrk.insts.append(alloc, .{
                        .tag = .word,
                        .extra = try wrk.addStr(alloc, input[start..end]),
                        .line = line,
                        .pos = pos,
                    });
                    start = i;
                    end = i;
                }
                if (std.mem.indexOfScalar(u8, Token.skippedChars, c)) |_| {
                    start += 1;
                    end += 1;
                }
                if (std.mem.indexOfScalar(u8, symbols, c)) |_| {
                    try wrk.insts.append(alloc, .{
                        .tag = .symbol,
                        .extra = c,
                        .line = line,
                        .pos = pos,
                    });
                    start += 1;
                    end += 1;
                }
            }
        }

        pos += 1;
        if (c != '\n') continue;
        line += 1;
        pos = 1;
    }

    alloc.free(input);
    return try wrk.final(alloc);
}
