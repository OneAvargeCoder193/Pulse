const std = @import("std");
const token = @import("token.zig");
const Type = @import("type.zig").Type;

pub const Pos = struct {
    line: u32,
    column: u32,
    idx: usize,

    pub fn next(self: Pos) Pos {
        return .{
            .line = self.line,
            .column = self.column + 1,
            .idx = self.idx + 1
        };
    }
};

pub const Span = struct {
    start: Pos,
    end: Pos,

    pub fn len(self: Span) usize {
        return self.end.offset - self.start.offset;
    }
};

pub const LexerError = union(enum) {
    unexpectedChar: u8,
    expectedChar: u8,

    pub fn createMessage(self: LexerError, allocator: std.mem.Allocator) []u8 {
        return switch(self) {
            .unexpectedChar => |char| return std.fmt.allocPrint(allocator, "Unexpected Character {c}", .{char}) catch unreachable,
            .expectedChar => |char| return std.fmt.allocPrint(allocator, "Expected Character {c}", .{char}) catch unreachable,
        };
    }
};

pub const LexError = struct {
    kind: LexerError,
    span: Span,

    pub fn print(self: LexError, allocator: std.mem.Allocator, file: []const u8, _: []const u8) void {
        const message = self.kind.createMessage(allocator);
        defer allocator.free(message);

        std.debug.print("{s}, {d}:{d}: {s}\n", .{file, self.span.start.line + 1, self.span.start.column + 1, message});
    }
};

pub const ParserError = union(enum) {
    unexpectedEof: void,
    unexpectedToken: []const token.TokenType,
    invalidLiteral: void,
    expectedC: void,

    pub fn createMessage(self: ParserError, allocator: std.mem.Allocator) []u8 {
        switch(self) {
            .unexpectedEof => return std.fmt.allocPrint(allocator, "Unexpected EOF", .{}) catch unreachable,
            .unexpectedToken => |expected| {
                if(expected.len != 0) {
                    var expectedStr: std.ArrayList(u8) = .empty;
                    defer expectedStr.deinit(allocator);
                    for(expected, 0..) |tok, i| {
                        if(i != 0) {
                            expectedStr.appendSlice(allocator, ", ") catch unreachable;
                        }
                        expectedStr.print(allocator, "{any}", .{tok}) catch unreachable;
                    }
                    return std.fmt.allocPrint(allocator, "Unexpected Token, expected {s}", .{expectedStr.items}) catch unreachable;
                }
                return std.fmt.allocPrint(allocator, "Unexpected Token", .{}) catch unreachable;
            },
            .invalidLiteral => return std.fmt.allocPrint(allocator, "Invalid Literal", .{}) catch unreachable,
            .expectedC => return std.fmt.allocPrint(allocator, "Expected 'c'", .{}) catch unreachable,
        }
    }
};

pub const ParseError = struct {
    kind: ParserError,
    span: Span,

    pub fn print(self: ParseError, allocator: std.mem.Allocator, file: []const u8, code: []const u8) void {
        const message = self.kind.createMessage(allocator);
        defer allocator.free(message);

        std.debug.print("{s}, {d}:{d}: {s}\n", .{file, self.span.start.line + 1, self.span.start.column + 1, message});
        std.debug.print("{s}\n", .{code[self.span.start.idx..self.span.end.idx]});
    }
};

pub const TypeError = struct {
    kind: union(enum) {
        typeMismatch: struct {expected: *Type, found: *Type},
        paramLenMismatch: struct{expected: usize, found: usize},
        invalidBinOp: struct{left: *Type, right: *Type, op: token.TokenType},
        mustBeNumeric: void,
        mustBeExpr: void,
        mustBeType: void,
        notCallable: void,
        undefinedVar: void,
        mustBeStorage: void,
        mustBeConstant: void,
        storageMustBePtr: void,
        notIndexable: void,
        hasNoMembers: void,
        cannotCast: void,
        cannotAssignToConstant: void,

        pub fn createMessage(self: @This(), allocator: std.mem.Allocator) []u8 {
            switch(self) {
                .typeMismatch => |t| {
                    const expectedStr = t.expected.toString(allocator);
                    defer allocator.free(expectedStr);
                    const foundStr = t.found.toString(allocator);
                    defer allocator.free(foundStr);
                    return std.fmt.allocPrint(allocator, "Type Mismatch, expected {s} found {s}", .{expectedStr, foundStr}) catch unreachable;
                },
                .paramLenMismatch => |t| {
                    return std.fmt.allocPrint(allocator, "Parameter Length Mismatch, expected {d} found {d}", .{t.expected, t.found}) catch unreachable;
                },
                .invalidBinOp => |t| {
                    const leftStr = t.left.toString(allocator);
                    defer allocator.free(leftStr);
                    const rightStr = t.right.toString(allocator);
                    defer allocator.free(rightStr);
                    return std.fmt.allocPrint(allocator, "Types {s} and {s} do not support {s} binary operation", .{leftStr, rightStr, @tagName(t.op)}) catch unreachable;
                },
                .mustBeNumeric => return allocator.dupe(u8, "Must Be Numeric") catch unreachable,
                .mustBeExpr => return allocator.dupe(u8, "Must Be Expression") catch unreachable,
                .mustBeType => return allocator.dupe(u8, "Must Be Type") catch unreachable,
                .notCallable => return allocator.dupe(u8, "Not Callable") catch unreachable,
                .undefinedVar => return allocator.dupe(u8, "Variable Is Not Defined") catch unreachable,
                .mustBeStorage => return allocator.dupe(u8, "Expr Must Be Storage") catch unreachable,
                .mustBeConstant => return allocator.dupe(u8, "Expr Must Be Constant") catch unreachable,
                .storageMustBePtr => return allocator.dupe(u8, "Storage Expr Must Be Ptr") catch unreachable,
                .notIndexable => return allocator.dupe(u8, "Type Not Indexable") catch unreachable,
                .hasNoMembers => return allocator.dupe(u8, "Type Has No Members Or Is Not A Member") catch unreachable,
                .cannotCast => return allocator.dupe(u8, "Cannot Cast") catch unreachable,
                .cannotAssignToConstant => return allocator.dupe(u8, "Cannot Assign To Constant") catch unreachable,
            }
        }
    },
    span: Span,

    pub fn print(self: TypeError, allocator: std.mem.Allocator, file: []const u8, code: []const u8) void {
        const message = self.kind.createMessage(allocator);
        defer allocator.free(message);

        std.debug.print("{s}, {d}:{d}: {s}\n", .{file, self.span.start.line + 1, self.span.start.column + 1, message});
        std.debug.print("{s}\n", .{code[self.span.start.idx..self.span.end.idx]});
    }
};