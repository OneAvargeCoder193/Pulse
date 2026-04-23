const std = @import("std");

const err = @import("err.zig");
const Pos = err.Pos;
const Span = err.Span;
const LexError = err.LexError;

const token = @import("token.zig");
const TokenType = token.TokenType;
const Token = token.Token;

pub const LexerResult = union(enum) {
    success: std.ArrayList(Token),
    failure: LexError,
};

pub const Tokenizer = struct {
    code: []const u8,
    tokens: std.ArrayList(Token),
    pos: Pos,

    idx: i32,
    line: i32,
    column: i32,

    pub fn init(input: []const u8) Tokenizer {
        return .{
            .code = input,
            .tokens = .empty,
            .pos = undefined,
            .idx = -1,
            .line = 0,
            .column = -1,
        };
    }

    fn advance(self: *Tokenizer) ?u8 {
        self.idx += 1;
        self.column += 1;
        defer self.pos = .{
            .column = @intCast(self.column),
            .idx = @intCast(self.idx),
            .line = @intCast(self.line)
        };

        if(self.idx >= self.code.len) {
            return null;
        }
        const char = self.code[@intCast(self.idx)];
        if(char == '\n') {
            self.line += 1;
            self.column = 0;
        }

        return char;
    }

    fn current(self: Tokenizer) ?u8 {
        if(self.pos.idx >= self.code.len) {
            return null;
        }
        return self.code[self.pos.idx];
    }

    fn tokenizeNumber(self: *Tokenizer, allocator: std.mem.Allocator) ?LexError {
        const start = self.pos;
        var hasDot: bool = false;

        while(true) {
            const cur = self.current() orelse break;

            if(!std.ascii.isDigit(cur) and cur != '.') break;

            if(cur == '.') {
                if(hasDot) {
                    return .{
                        .kind = .{.unexpectedChar = cur},
                        .span = .{
                            .start = self.pos,
                            .end = self.pos.next(),
                        }
                    };
                }
                hasDot = true;
            }

            _ = self.advance();
        }
        
        self.tokens.append(allocator, Token{
            .typ = if(hasDot) .float_literal else .int_literal,
            .lexeme = self.code[start.idx..self.pos.idx],
            .span = .{
                .start = start,
                .end = self.pos,
            }
        }) catch unreachable;

        return null;
    }

    fn isValidType(s: []const u8, expectedChar: u8) bool {
        const len = s.len;
        if(len < 2) return false;

        if(s[0] != expectedChar) return false;

        if(s[1] == '0') return false;

        for(s[1..]) |c| {
            if(!std.ascii.isDigit(c)) return false;
        }

        return true;
    }

    fn tokenizeIdentifier(self: *Tokenizer, allocator: std.mem.Allocator) void {
        const start = self.pos;

        while(true) {
            const cur = self.current() orelse break;

            if(!std.ascii.isAlphanumeric(cur) and cur != '_') break;

            _ = self.advance();
        }

        const lexeme = self.code[start.idx..self.pos.idx];

        var typ: TokenType = .identifier;
        inline for(token.keywords) |keyword| {
            if(std.mem.eql(u8, keyword, lexeme)) {
                typ = std.meta.stringToEnum(TokenType, "kw_" ++ keyword) orelse unreachable;
            }
        }
        inline for(token.hardcodedTypes) |hardcodedType| {
            if(std.mem.eql(u8, hardcodedType, lexeme)) {
                typ = std.meta.stringToEnum(TokenType, "type_" ++ hardcodedType) orelse unreachable;
            }
        }

        if(isValidType(lexeme, 'i')) {
            typ = .type_int;
        }

        if(isValidType(lexeme, 'u')) {
            typ = .type_uint;
        }
        
        self.tokens.append(allocator, Token{
            .typ = typ,
            .lexeme = lexeme,
            .span = .{
                .start = start,
                .end = self.pos,
            }
        }) catch unreachable;
    }

    fn tokenizeString(self: *Tokenizer, allocator: std.mem.Allocator) ?LexError {
        const start = self.pos;

        _ = self.advance();

        while (true) {
            const cur = self.current() orelse {
                return .{
                    .kind = .{ .unexpectedChar = '"' },
                    .span = .{
                        .start = start,
                        .end = self.pos,
                    },
                };
            };

            if (cur == '"') break;

            if (cur == '\\') {
                _ = self.advance();
                if (self.current() == null) break;
            }

            _ = self.advance();
        }

        _ = self.advance();

        self.tokens.append(allocator, Token{
            .typ = .string_literal,
            .lexeme = self.code[start.idx .. self.pos.idx],
            .span = .{
                .start = start,
                .end = self.pos,
            },
        }) catch unreachable;

        return null;
    }

    const TokenOption = struct{ lexeme: []const u8, token: TokenType };
    fn parseAndAddToken(
        self: *Tokenizer,
        allocator: std.mem.Allocator,
        options: []const TokenOption,
    ) ?LexError {
        const start = self.pos;

        var best_match: ?TokenOption = null;
        var best_len: usize = 0;

        for(options) |opt| {
            const end_idx = self.pos.idx + opt.lexeme.len;
            if(end_idx <= self.code.len and std.mem.eql(u8, self.code[self.pos.idx..end_idx], opt.lexeme)) {
                if(opt.lexeme.len > best_len) {
                    best_match = opt;
                    best_len = opt.lexeme.len;
                }
            }
        }

        if(best_match) |match| {
            for(match.lexeme) |_| _ = self.advance();

            self.tokens.append(allocator, Token{
                .typ = match.token,
                .lexeme = match.lexeme,
                .span = .{ .start = start, .end = self.pos },
            }) catch unreachable;
            return null;
        }

        return null;
    }

    fn skipComment(self: *Tokenizer) void {
        _ = self.advance();
        _ = self.advance();

        while (true) {
            const cur = self.current() orelse break;
            if (cur == '\n') break;
            _ = self.advance();
        }
    }

    pub fn tokenize(self: *Tokenizer, allocator: std.mem.Allocator) LexerResult {
        defer self.tokens.deinit(allocator);

        _ = self.advance();
        while(self.current()) |cur| {
            if(std.ascii.isWhitespace(cur)) {
                _ = self.advance();
            } else if(std.ascii.isDigit(cur)) {
                if(self.tokenizeNumber(allocator)) |lexErr| {
                    return .{.failure = lexErr};
                }
            } else if(std.ascii.isAlphabetic(cur) or cur == '_') {
                self.tokenizeIdentifier(allocator);
            } else if (cur == '"') {
                if (self.tokenizeString(allocator)) |lexErr| {
                    return .{ .failure = lexErr };
                }
            } else {
                if (cur == '/' and self.pos.idx + 1 < self.code.len and self.code[self.pos.idx + 1] == '/') {
                    self.skipComment();
                    continue;
                }

                if(parseAndAddToken(self, allocator, &.{
                    // Question marks
                    .{ .lexeme = "??", .token = .question_question },
                    .{ .lexeme = "?",  .token = .question },

                    // Arrows and minus operators
                    .{ .lexeme = "=>", .token = .arrow },
                    .{ .lexeme = "-=", .token = .minus_eq },
                    .{ .lexeme = "-",  .token = .minus },

                    // Plus operators
                    .{ .lexeme = "+=", .token = .plus_eq },
                    .{ .lexeme = "+",  .token = .plus },

                    // Multiplication/division
                    .{ .lexeme = "*=", .token = .star_eq },
                    .{ .lexeme = "*",  .token = .star },
                    .{ .lexeme = "/=", .token = .slash_eq },
                    .{ .lexeme = "/",  .token = .slash },
                    .{ .lexeme = "%=", .token = .percent_eq },
                    .{ .lexeme = "%",  .token = .percent },

                    // Equality and comparisons
                    .{ .lexeme = "==", .token = .eq_eq },
                    .{ .lexeme = "!=", .token = .bang_eq },
                    .{ .lexeme = "=",  .token = .eq },
                    .{ .lexeme = "<=", .token = .lt_eq },
                    .{ .lexeme = ">=", .token = .gt_eq },
                    .{ .lexeme = "<",  .token = .lt },
                    .{ .lexeme = ">",  .token = .gt },

                    // Logical operators
                    .{ .lexeme = "&&", .token = .and_and },
                    .{ .lexeme = "&&=", .token = .and_and_equal },
                    .{ .lexeme = "||", .token = .or_or },
                    .{ .lexeme = "||=", .token = .or_or_equal },
                    .{ .lexeme = "!",  .token = .bang },

                    // Bitwise operators
                    .{ .lexeme = "&=", .token = .and_equal },
                    .{ .lexeme = "&",  .token = .bit_and },
                    .{ .lexeme = "|=", .token = .or_equal },
                    .{ .lexeme = "|",  .token = .bit_or },
                    .{ .lexeme = "^=",  .token = .xor_equal },
                    .{ .lexeme = "^",  .token = .bit_xor },
                    .{ .lexeme = "~",  .token = .bit_not },
                    .{ .lexeme = "<<", .token = .shift_left },
                    .{ .lexeme = "<<=", .token = .shift_left_equal },
                    .{ .lexeme = ">>", .token = .shift_right },
                    .{ .lexeme = ">>=", .token = .shift_right_equal },

                    // Delimiters
                    .{ .lexeme = "(",  .token = .l_paren },
                    .{ .lexeme = ")",  .token = .r_paren },
                    .{ .lexeme = "{",  .token = .l_brace },
                    .{ .lexeme = "}",  .token = .r_brace },
                    .{ .lexeme = "[",  .token = .l_bracket },
                    .{ .lexeme = "]",  .token = .r_bracket },
                    .{ .lexeme = ",",  .token = .comma },
                    .{ .lexeme = ";",  .token = .semicolon },
                    .{ .lexeme = ":",  .token = .colon },
                    .{ .lexeme = ".",  .token = .dot },
                    .{ .lexeme = "...", .token = .ellipsis },
                })) |lexErr| {
                    return .{.failure = lexErr};
                }
            }
        }
        self.tokens.append(allocator, .{.typ = .eof, .lexeme = &.{}, .span = .{.start = self.pos, .end = self.pos.next()}}) catch unreachable;
        return .{.success = .fromOwnedSlice(self.tokens.toOwnedSlice(allocator) catch unreachable)};
    }
};