const std = @import("std");

const err = @import("err.zig");
const Span = err.Span;

pub const TokenType = enum {
    eof,
    identifier,

    int_literal,
    float_literal,
    string_literal,

    kw_func,
    kw_var,
    kw_return,
    kw_class,
    kw_interface,
    kw_pub,
    kw_for,
    kw_if,
    kw_else,
    kw_while,
    kw_break,
    kw_continue,
    kw_self,
    kw_null,
    kw_true,
    kw_false,

    type_void,
    type_bool,
    type_int,
    type_uint,
    type_f32,
    type_f64,

    plus, minus, star, slash, percent,

    plus_eq, minus_eq, star_eq, slash_eq, percent_eq,
    eq, eq_eq, bang_eq,

    lt, gt, lt_eq, gt_eq,

    and_and, or_or, bang,
    and_and_equal, or_or_equal,

    bit_and, bit_or, bit_xor, bit_not,
    and_equal, or_equal, xor_equal,
    shift_left, shift_right,
    shift_left_equal, shift_right_equal,

    arrow,
    question,
    question_question,
    dot,

    l_paren, r_paren,
    l_brace, r_brace,
    l_bracket, r_bracket,

    comma,
    semicolon,
    colon,
    ellipsis,
};

pub const keywords = [_][]const u8 {
    "func",
    "var",
    "return",
    "class",
    "interface",
    "pub",
    "for",
    "if",
    "else",
    "while",
    "break",
    "continue",
    "self",
    "null",
    "true",
    "false",
};

pub const hardcodedTypes = [_][]const u8 {
    "void",
    "bool",
    "f32",
    "f64",
};

pub const Token = struct {
    typ: TokenType,
    lexeme: []const u8,
    span: Span,

    pub fn format(self: Token, writer: *std.io.Writer) !void {
        try writer.print("{s}:{s}", .{@tagName(self.typ), self.lexeme});
    }
};