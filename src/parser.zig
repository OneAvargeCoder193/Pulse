const std = @import("std");

const err = @import("err.zig");
const Pos = err.Pos;
const Span = err.Span;
const ParseError = err.ParseError;

const token = @import("token.zig");
const Token = token.Token;
const TokenType = token.TokenType;

const ast = @import("ast.zig");
const Node = ast.Node;
const NodeData = ast.NodeData;

pub const ParserResult = union(enum) {
    success: *Node,
    failure: ParseError,
};

const PrefixFn = *const fn (self: *Parser) ParserResult;
const InfixFn = *const fn (self: *Parser, left: *Node, op: Token) ParserResult;
const ParseRule = struct {
    prefix: ?PrefixFn,
    infix: ?InfixFn,
    precedence: Precedence,
};

const Precedence = enum(u8) {
    none = 0,
    assignment,   // =
    @"or",           // ||
    @"and",          // &&
    equality,     // == !=
    comparison,   // < <= > >=
    term,         // + -
    factor,       // * / %
    unary,        // - !
    call,         // () .
    primary,
};

pub const Parser = struct {
    tokens: std.ArrayList(Token),
    idx: i32 = -1,
    current: Token = undefined,
    allocator: std.mem.Allocator,

    pub fn init(tokens: std.ArrayList(Token), allocator: std.mem.Allocator) Parser {
        return .{
            .tokens = tokens,
            .allocator = allocator,
        };
    }

    fn advance(self: *Parser) ?Token {
        self.idx += 1;

        if(self.idx >= self.tokens.items.len) {
            return null;
        }
        self.current = self.tokens.items[@intCast(self.idx)];
        return self.current;
    }

    fn match(self: *Parser, typ: TokenType) ?ParseError {
        if(self.current.typ != typ) {
            return .{
                .kind = .{.unexpectedToken = &.{typ}},
                .span = self.current.span,
            };
        }
        _ = self.advance();
        return null;
    }

    fn matchAny(self: *Parser, typs: []const TokenType) ?ParseError {
        if(std.mem.countScalar(TokenType, typs, self.current.typ) == 0) {
            return .{
                .kind = .{.unexpectedToken = typs},
                .span = self.current.span,
            };
        }
        _ = self.advance();
        return null;
    }

    fn makeNode(self: *Parser, data: NodeData, span: Span) *Node {
        const node = self.allocator.create(Node) catch unreachable;
        node.* = Node{
            .inner = data,
            .span = span,
        };
        return node;
    }

    fn getRule(tt: TokenType) ParseRule {
        return switch (tt) {
            .int_literal => .{ .prefix = &parseInt, .infix = null, .precedence = .none },
            .float_literal => .{ .prefix = &parseFloat, .infix = null, .precedence = .none },
            .string_literal => .{ .prefix = &parseString, .infix = null, .precedence = .none },
            .identifier => .{ .prefix = &parseVariable, .infix = null, .precedence = .none },
            .kw_null => .{ .prefix = &parseNull, .infix = null, .precedence = .none },
            .kw_true, .kw_false => .{ .prefix = &parseBool, .infix = null, .precedence = .none },

            // Types
            .type_int, .type_uint,
            .type_f32, .type_f64,
            .type_bool, .type_void => .{.prefix = &parseType, .infix = null, .precedence = .none},

            // Grouping / function call
            .l_paren => .{ .prefix = &parseGroupingOrLambda, .infix = &parseCall, .precedence = .call },
            .dot => .{ .prefix = null, .infix = &parseMember, .precedence = .call },

            // Unary operators
            .bang, .bit_not => .{ .prefix = &parseUnary, .infix = null, .precedence = .unary },

            // Multiplicative
            .star => .{ .prefix = &parsePtrSingle, .infix = &parseBinary, .precedence = .factor },
            .slash, .percent => .{ .prefix = null, .infix = &parseBinary, .precedence = .factor },

            .l_bracket => .{ .prefix = &parsePtrMultiple, .infix = &parseIndex, .precedence = .call },

            // Additive
            .plus => .{ .prefix = null, .infix = &parseBinary, .precedence = .term },
            .minus => .{ .prefix = &parseUnary, .infix = &parseBinary, .precedence = .term },

            // Shift operators
            .shift_left, .shift_right => .{ .prefix = null, .infix = &parseBinary, .precedence = .comparison },

            // Relational
            .gt, .lt_eq, .gt_eq => .{ .prefix = null, .infix = &parseBinary, .precedence = .comparison },

            // Generics
            .lt => .{ .prefix = null, .infix = &parseLessOrGenerics, .precedence = .comparison },

            // Equality
            .eq_eq, .bang_eq => .{ .prefix = null, .infix = &parseBinary, .precedence = .equality },

            // Bitwise AND
            .bit_and => .{ .prefix = &parseReference, .infix = &parseBinary, .precedence = .@"and" },

            // Bitwise XOR
            .bit_xor => .{ .prefix = null, .infix = &parseBinary, .precedence = .equality },

            // Bitwise OR
            .bit_or => .{ .prefix = null, .infix = &parseBinary, .precedence = .@"or" },

            // Logical AND
            .and_and => .{ .prefix = null, .infix = &parseBinary, .precedence = .@"and" },

            // Logical OR
            .or_or => .{ .prefix = null, .infix = &parseBinary, .precedence = .@"or" },

            // Assignment operators
            .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq,
            .and_equal, .or_equal, .xor_equal, .shift_left_equal, .shift_right_equal =>
                .{ .prefix = null, .infix = &parseAssign, .precedence = .assignment },

            else => .{ .prefix = null, .infix = null, .precedence = .none },
        };
    }

    fn parseExpr(self: *Parser, min_prec: Precedence) ParserResult {
        const prefix_rule = Parser.getRule(self.current.typ).prefix
            orelse return .{ .failure = ParseError{
                .kind = .{.unexpectedToken = &.{}},
                .span = self.current.span,
            } };

        const left_result = prefix_rule(self);
        if(left_result == .failure) return left_result;
        var left = left_result.success;

        while(true) {
            const rule = Parser.getRule(self.current.typ);
            if(@intFromEnum(rule.precedence) < @intFromEnum(min_prec)) break;

            const op = self.current;
            const infix = rule.infix orelse break;
            _ = self.advance();

            const right_result = infix(self, left, op);
            if(right_result == .failure) return right_result;

            left = right_result.success;
        }

        return .{ .success = left };
    }

    fn parseType(self: *Parser) ParserResult {
        const tok = self.current;

        switch (tok.typ) {
            .type_void => {
                _ = self.advance();
                return .{ .success = self.makeNode(.{ .voidType = {} }, tok.span) };
            },
            .type_bool => {
                _ = self.advance();
                return .{ .success = self.makeNode(.{ .boolType = {} }, tok.span) };
            },
            .type_f32 => {
                _ = self.advance();
                return .{ .success = self.makeNode(.{ .floatType = {} }, tok.span) };
            },
            .type_f64 => {
                _ = self.advance();
                return .{ .success = self.makeNode(.{ .doubleType = {} }, tok.span) };
            },
            .type_uint, .type_int => {
                const name = tok.lexeme;
                if(name.len < 2) unreachable;
                const prefix = name[0];
                const bits_slice = name[1..];

                const bits = std.fmt.parseInt(u32, bits_slice, 10) catch unreachable;

                _ = self.advance();

                if(prefix == 'i') {
                    return .{ .success = self.makeNode(.{ .intType = bits }, tok.span) };
                } else if(prefix == 'u') {
                    return .{ .success = self.makeNode(.{ .uintType = bits }, tok.span) };
                }
            },
            else => {},
        }

        return .{ .failure = ParseError{ .kind = .{.unexpectedToken = &.{.type_int, .type_uint, .type_f32, .type_f64, .type_void, .type_bool}}, .span = tok.span } };
    }

    fn parseUnary(self: *Parser) ParserResult {
        const op = self.current;
        _ = self.advance();

        const rhs_result = self.parseExpr(.unary);
        if(rhs_result == .failure) return rhs_result;

        return .{ .success = self.makeNode(.{
            .unary = .{
                .op = op.typ,
                .expr = rhs_result.success,
            },
        }, .{
            .start = op.span.start,
            .end = rhs_result.success.span.end
        }) };
    }

    fn parseReference(self: *Parser) ParserResult {
        _ = self.advance();

        const rhs_result = self.parseExpr(.unary);
        if(rhs_result == .failure) return rhs_result;

        return .{ .success = self.makeNode(.{
            .reference = .{
                .expr = rhs_result.success,
            },
        }, rhs_result.success.span) };
    }

    fn parsePtrSingle(self: *Parser) ParserResult {
        const op = self.current;
        _ = self.advance();

        const rhs_result = self.parseExpr(.call);
        if(rhs_result == .failure) return rhs_result;

        return .{ .success = self.makeNode(.{
            .ptrSingle = rhs_result.success,
        }, .{
            .start = op.span.start,
            .end = rhs_result.success.span.end
        }) };
    }

    fn parsePtrMultiple(self: *Parser) ParserResult {
        const op = self.current;
        _ = self.advance();

        if(self.current.typ == .star) {
            _ = self.advance();
            if(self.match(.r_bracket)) |e| return .{.failure = e};

            const rhs_result = self.parseExpr(.call);
            if(rhs_result == .failure) return rhs_result;

            return .{ .success = self.makeNode(.{
                .ptrMany = rhs_result.success,
            }, .{
                .start = op.span.start,
                .end = rhs_result.success.span.end
            }) };
        } else if(self.current.typ == .r_bracket) {
            _ = self.advance();

            const rhs_result = self.parseExpr(.call);
            if(rhs_result == .failure) return rhs_result;

            return .{ .success = self.makeNode(.{
                .ptrSlice = rhs_result.success,
            }, .{
                .start = op.span.start,
                .end = rhs_result.success.span.end
            }) };
        } else {
            const lenTok = self.current;
            if(self.match(.int_literal)) |e| return .{.failure = e};
            const len = std.fmt.parseInt(u32, lenTok.lexeme, 10) catch unreachable;

            if(self.match(.r_bracket)) |e| return .{.failure = e};

            const rhs_result = self.parseExpr(.call);
            if(rhs_result == .failure) return rhs_result;

            const arrayType = self.makeNode(.{
                    .arrayType = .{
                        .child = rhs_result.success,
                        .len = len,
                    },
                }, .{
                    .start = op.span.start,
                    .end = rhs_result.success.span.end
                });

            if(self.current.typ == .l_brace) {
                _ = self.advance();
                var children: std.ArrayList(*Node) = .empty;
                while(true) {
                    const val = self.parseExpr(.none);
                    if(val == .failure) return val;
                    children.append(self.allocator, val.success) catch unreachable;

                    if(self.current.typ == .r_brace) break;

                    if(self.match(.comma)) |e| return .{.failure = e};
                }

                if(self.match(.r_brace)) |e| return .{.failure = e};

                return .{ .success = self.makeNode(.{ .array = .{
                    .type = arrayType,
                    .children = children.toOwnedSlice(self.allocator) catch unreachable,
                }}, .{
                    .start = op.span.start,
                    .end = self.current.span.start,
                }) };
            }

            return .{ .success = arrayType };
        }
    }

    fn parseBinary(self: *Parser, left: *Node, op: Token) ParserResult {
        const bp = Parser.getRule(op.typ).precedence;

        const right_result = self.parseExpr(@enumFromInt(@intFromEnum(bp) + 1)); // right-binding power
        if(right_result == .failure) return right_result;

        return .{ .success = self.makeNode(.{
            .binary = .{
                .left = left,
                .op = op.typ,
                .right = right_result.success,
            }
        }, .{
            .start = left.span.start,
            .end = right_result.success.span.end,
        }) };
    }

    fn parseInt(self: *Parser) ParserResult {
        const tok = self.current;
        _ = self.advance();
        const value = std.fmt.parseInt(i64, tok.lexeme, 10) catch return .{
            .failure = ParseError{ .kind = .invalidLiteral, .span = tok.span }
        };
        return .{ .success = self.makeNode(.{.intLiteral = value}, tok.span) };
    }

    fn parseFloat(self: *Parser) ParserResult {
        const tok = self.current;
        _ = self.advance();
        const value = std.fmt.parseFloat(f64, tok.lexeme) catch return .{
            .failure = ParseError{ .kind = .invalidLiteral, .span = tok.span }
        };
        return .{ .success = self.makeNode(.{.floatLiteral = value}, tok.span) };
    }

    fn parseString(self: *Parser) ParserResult {
        const tok = self.current;
        _ = self.advance();
        return .{ .success = self.makeNode(.{.stringLiteral = tok.lexeme[1..tok.lexeme.len - 1]}, tok.span) };
    }

    fn parseNull(self: *Parser) ParserResult {
        const tok = self.current;
        _ = self.advance();
        return .{ .success = self.makeNode(.nullLiteral, tok.span) };
    }

    fn parseBool(self: *Parser) ParserResult {
        const tok = self.current;
        _ = self.advance();
        return .{ .success = self.makeNode(.{.boolLiteral = tok.typ == .kw_true}, tok.span) };
    }

    fn parseVariable(self: *Parser) ParserResult {
        const tok = self.current;
        _ = self.advance();
        return .{ .success = self.makeNode(.{.variable = tok.lexeme}, tok.span) };
    }

    fn parseGroupingOrLambda(self: *Parser) ParserResult {
        _ = self.advance();

        var params: std.ArrayList(ast.Param) = .empty;
        var is_lambda = false;

        const start_idx = self.idx;

        if (self.current.typ != .r_paren) {
            while (true) {
                if (self.current.typ != .identifier) break;

                const name_tok = self.current;
                _ = self.advance();

                if(self.match(.colon) != null) break;

                const type_res = self.parseExpr(.none);
                if (type_res == .failure) return type_res;

                _ = params.append(self.allocator, ast.Param{
                    .name = name_tok.lexeme,
                    .type = type_res.success,
                }) catch unreachable;

                if (self.current.typ == .comma) {
                    _ = self.advance();
                    continue;
                }

                break;
            }
        }

        if (self.current.typ != .r_paren) {
            self.idx = start_idx;
            self.current = self.tokens.items[@intCast(self.idx)];

            const exprResult = self.parseExpr(.none);
            if (exprResult == .failure) return exprResult;

            if(self.match(.r_paren)) |e| return .{.failure = e};

            return exprResult;
        }

        _ = self.advance();

        var returnTypeResult: ?ParserResult = null;
        if (self.current.typ == .arrow) {
            is_lambda = true;
            _ = self.advance();
        } else {
            returnTypeResult = self.parseExpr(.call);
            if(returnTypeResult.? == .failure) {
                is_lambda = false;
            } else {
                if (self.current.typ == .arrow) {
                    is_lambda = true;
                    _ = self.advance();
                }
            }
        }

        if (!is_lambda) {
            if (params.items.len == 0) {
                return .{ .failure = ParseError{
                    .kind = .{.unexpectedToken = &.{.identifier}},
                    .span = self.current.span,
                }};
            }

            self.idx = start_idx;
            self.current = self.tokens.items[@intCast(self.idx)];

            const exprResult = self.parseExpr(.none);
            if (exprResult == .failure) return exprResult;

            if(self.match(.r_paren)) |e| return .{.failure = e};

            return exprResult;
        }

        var body_result: ParserResult = undefined;

        if (self.current.typ == .l_brace) {
            body_result = self.parseBody();
        } else {
            body_result = self.parseExpr(.none);
        }

        if (body_result == .failure) return body_result;

        return .{ .success = self.makeNode(.{
            .lambda = .{
                .params = params.toOwnedSlice(self.allocator) catch unreachable,
                .returnType = if(returnTypeResult) |res| res.success else null,
                .body = body_result.success,
            }
        }, .{
            .start = self.tokens.items[@intCast(start_idx)].span.start,
            .end = body_result.success.span.end,
        }) };
    }

    fn parseLessOrGenerics(self: *Parser, left: *Node, op: Token) ParserResult {
        const checkpoint_idx = self.idx;
        const checkpoint_tok = self.current;
        var is_generic = true;
        var generics: std.ArrayList(*Node) = .empty;

        while (true) {
            const arg = self.parseExpr(.call);
            if (arg == .failure) {
                is_generic = false;
                break;
            }

            generics.append(self.allocator, arg.success) catch unreachable;

            if (self.current.typ == .comma) {
                _ = self.advance();
                continue;
            }

            break;
        }

        if (self.current.typ != .gt) {
            is_generic = false;
        }

        if (is_generic) {
            _ = self.advance();

            return .{ .success = self.makeNode(.{
                .applyGeneric = .{
                    .value = left,
                    .generics = generics.toOwnedSlice(self.allocator) catch unreachable,
                }
            }, left.span) };
        }

        self.idx = checkpoint_idx;
        self.current = checkpoint_tok;

        return self.parseBinary(left, op);
    }

    fn parseCall(self: *Parser, callee: *Node, _: Token) ParserResult {
        var args: std.ArrayList(*Node) = .empty;

        while(self.current.typ != .r_paren) {
            const argResult = self.parseExpr(.none);
            if(argResult == .failure) return argResult;

            _ = args.append(self.allocator, argResult.success) catch unreachable;

            if(self.current.typ == .comma) {
                _ = self.advance();
            } else {
                break;
            }
        }

        if(self.match(.r_paren)) |e| return .{.failure = e};

        return .{ .success = self.makeNode(.{
                .call = .{
                    .callee = callee,
                    .args = args.toOwnedSlice(self.allocator) catch unreachable
                }
            }, .{
                .start = callee.span.start,
                .end = self.current.span.start,
            }) };
    }

    fn parseAssign(self: *Parser, target: *Node, op: Token) ParserResult {
        const valueResult = self.parseExpr(.assignment);
        if(valueResult == .failure) return valueResult;

        return .{ .success = self.makeNode(.{
                .assign = .{
                    .target = target,
                    .value = valueResult.success,
                    .op = op.typ
                }
            }, .{
                .start = target.span.start,
                .end = valueResult.success.span.end,
            }) };
    }

    fn parseIndex(self: *Parser, expr: *Node, _: Token) ParserResult {
        var start: ?*Node = null;
        if(self.current.typ != .colon) {
            const startRes = self.parseExpr(.none);
            if(startRes == .failure) return startRes;
            start = startRes.success;
        }

        if(start == null) {
            if(self.current.typ != .colon) {
                return .{.failure = .{
                        .kind = .{.unexpectedToken = &.{.colon}},
                        .span = self.current.span,
                    }};
            }
        }
        var multiple: bool = false;
        var end: ?*Node = null;
        if(self.current.typ == .colon) {
            _ = self.advance();
            multiple = true;
            if(self.current.typ != .r_bracket) {
                const endRes = self.parseExpr(.none);
                if(endRes == .failure) return endRes;
                end = endRes.success;
            }
        }

        if(self.match(.r_bracket)) |e| return .{.failure = e};

        return .{
            .success = self.makeNode(.{
                .index = .{
                    .left = expr,
                    .start = start,
                    .end = end,
                    .multiple = multiple,
                }
            }, .{
                .start = expr.span.start,
                .end = self.current.span.end,
            }) };
    }

    fn parseMember(self: *Parser, expr: *Node, _: Token) ParserResult {
        const tok = self.current;
        if(self.matchAny(&.{.identifier, .star})) |e| return .{.failure = e};

        return .{
            .success = self.makeNode(.{
                .memberAccess = .{
                    .expr = expr,
                    .field = tok.lexeme
                }
            }, .{
                .start = expr.span.start,
                .end = tok.span.end,
            }) };
    }

    fn parseStatement(self: *Parser, expectSemicolon: bool) ParserResult {
        switch (self.current.typ) {
            .kw_func => return self.parseFuncDecl(),
            .kw_var  => {
                const result = self.parseVarDecl(expectSemicolon);
                if(result == .failure) return result;
                return result;
            },
            .kw_return => {
                const result = self.parseReturn(expectSemicolon);
                if(result == .failure) return result;
                return result;
            },

            // .kw_if => return self.parseIf(),
            .kw_while => return self.parseWhile(),
            .kw_for => return self.parseFor(),

            else => {
                const exprResult = self.parseExpr(.none);
                if(exprResult == .failure) return exprResult;
                if(expectSemicolon) if(self.match(.semicolon)) |e| return .{.failure = e};
                return exprResult;
            }
        }
    }

    fn parseReturn(self: *Parser, expectSemicolon: bool) ParserResult {
        const tok = self.current;
        _ = self.advance();
        if(self.current.typ == .semicolon) {
            _ = self.advance();
            return .{ .success = self.makeNode(.{.@"return" = null}, tok.span) };
        }

        const exprResult = self.parseExpr(.none);
        if(exprResult == .failure) return exprResult;

        if(expectSemicolon) if(self.match(.semicolon)) |e| return .{.failure = e};

        return .{ .success = self.makeNode(.{.@"return" = exprResult.success}, .{
            .start = tok.span.start,
            .end = exprResult.success.span.end,
        }) };
    }

    fn parseVarDecl(self: *Parser, expectSemicolon: bool) ParserResult {
        _ = self.advance();
        const tok = self.current;
        if(self.match(.identifier)) |e| return .{.failure = e};
        const name = tok.lexeme;

        var typ: ?*Node = null;
        if(self.current.typ == .colon) {
            _ = self.advance();
            const typeExpr = self.parseExpr(.call);
            if(typeExpr == .failure) return typeExpr;
            typ = typeExpr.success;
        }

        if(self.current.typ == .semicolon and typ != null) {
            _ = self.advance();
            return .{ .success = self.makeNode(.{.varDecl = .{
                .name = name,
                .typ = typ,
                .init = null,
            }}, .{
                .start = tok.span.start,
                .end = typ.?.span.end
            }) };
        }

        if(self.match(.eq)) |e| return .{.failure = e};

        const initResult = self.parseExpr(.none);
        if(initResult == .failure) return initResult;

        if(expectSemicolon) if(self.match(.semicolon)) |e| return .{.failure = e};
        return .{ .success = self.makeNode(.{.varDecl = .{
            .name = name,
            .typ = typ,
            .init = initResult.success,
        }}, .{
            .start = tok.span.start,
            .end = initResult.success.span.end
        }) };
    }

    fn parseFuncDecl(self: *Parser) ParserResult {
        _ = self.advance();
        const tok = self.current;
        if(self.match(.identifier)) |e| return .{.failure = e};
        const name = tok.lexeme;

        var generics: std.ArrayList([]const u8) = .empty;
        if(self.current.typ == .lt) {
            _ = self.advance();

            generics.append(self.allocator, self.current.lexeme) catch unreachable;
            if(self.match(.identifier)) |e| return .{ .failure = e };
            
            while(self.current.typ == .comma) {
                _ = self.advance();
                generics.append(self.allocator, self.current.lexeme) catch unreachable;
                if(self.match(.identifier)) |e| return .{ .failure = e };
            }

            if(self.match(.gt)) |e| return .{.failure = e};
        }

        if(self.match(.l_paren)) |e| return .{.failure = e};

        var varArg: ?[]const u8 = null;
        var varArgConv: ast.VarArgConv = .normal;
        var params: std.ArrayList(ast.Param) = .empty;
        while(self.current.typ != .r_paren) {
            const paramTok = self.current;
            if(paramTok.typ == .ellipsis) {
                _ = self.advance();
                varArg = self.current.lexeme;
                if(self.current.typ == .l_bracket) {
                    _ = self.advance();
                    if(!std.mem.eql(u8, self.current.lexeme, "c")) {
                        return .{.failure = .{
                            .kind = .expectedC,
                            .span = self.current.span,
                        }};
                    }
                    if(self.match(.identifier)) |e| return .{.failure = e};
                    if(self.match(.r_bracket)) |e| return .{.failure = e};
                    varArgConv = .c;
                }
                if(self.match(.identifier)) |e| return .{.failure = e};
                break;
            }
            if(self.match(.identifier)) |e| return .{.failure = e};
            const paramName = paramTok.lexeme;

            if(self.match(.colon)) |e| return .{.failure = e};

            const typeExpr = self.parseExpr(.call);
            if(typeExpr == .failure) return typeExpr;

            _ = params.append(self.allocator, ast.Param{ .name = paramName, .type = typeExpr.success }) catch unreachable;

            if(self.current.typ == .comma) {
                _ = self.advance();
            } else {
                break;
            }
        }

        if(self.match(.r_paren)) |e| return .{.failure = e};

        const typeExpr = self.parseExpr(.call);
        if(typeExpr == .failure) return typeExpr;
        const returnType: *Node = typeExpr.success;

        var body: ?*Node = null;
        if(self.current.typ == .semicolon) {
            _ = self.advance();
        } else {
            const bodyResult = self.parseBody();
            if(bodyResult == .failure) return bodyResult;
            body = bodyResult.success;
        }

        return .{ .success = self.makeNode(.{ .funcDecl = .{
            .name = name,
            .generics = generics.toOwnedSlice(self.allocator) catch unreachable,
            .params = params.toOwnedSlice(self.allocator) catch unreachable,
            .returnType = returnType,
            .body = body,
            .varArgs = varArg,
            .varArgConv = varArgConv,
        }}, .{
            .start = tok.span.start,
            .end = if(body) |b| b.span.end else returnType.span.end,
        }) };
    }

    fn parseWhile(self: *Parser) ParserResult {
        const start = self.current;
        _ = self.advance();
        if(self.match(.l_paren)) |e| return .{.failure = e};
        const condition = self.parseExpr(.none);
        if(condition == .failure) return condition;

        if(self.match(.r_paren)) |e| return .{.failure = e};
        const body = self.parseBody();
        if(body == .failure) return body;

        return .{ .success = self.makeNode(.{ .@"while" = .{
            .cond = condition.success,
            .body = body.success,
        }}, .{
            .start = start.span.start,
            .end = self.current.span.start,
        }) };
    }

    fn parseFor(self: *Parser) ParserResult {
        const start = self.current;
        _ = self.advance();
        if(self.match(.l_paren)) |e| return .{.failure = e};

        var createNode: ?*Node = null;
        if(self.current.typ != .semicolon) {
            const create = self.parseStatement(false);
            if(create == .failure) return create;
            createNode = create.success;
        }
        if(self.match(.semicolon)) |e| return .{.failure = e};

        var condNode: ?*Node = null;
        if(self.current.typ != .semicolon) {
            const cond = self.parseStatement(false);
            if(cond == .failure) return cond;
            condNode = cond.success;
        }
        if(self.match(.semicolon)) |e| return .{.failure = e};

        var incNode: ?*Node = null;
        if(self.current.typ != .r_paren) {
            const inc = self.parseStatement(false);
            if(inc == .failure) return inc;
            incNode = inc.success;
        }
        if(self.match(.r_paren)) |e| return .{.failure = e};

        const body = self.parseBody();
        if(body == .failure) return body;

        return .{ .success = self.makeNode(.{ .@"for" = .{
            .initialize = createNode,
            .condition = condNode,
            .iterate = incNode,
            .body = body.success,
        }}, .{
            .start = start.span.start,
            .end = self.current.span.start,
        }) };
    }

    fn parseBody(self: *Parser) ParserResult {
        const start = self.current;
        if(self.match(.l_brace)) |e| return .{.failure = e};

        var bodyNodes: std.ArrayList(*Node) = .empty;
        while(self.current.typ != .r_brace) {
            const stmt = self.parseStatement(true);
            if(stmt == .failure) return stmt;
            _ = bodyNodes.append(self.allocator, stmt.success) catch unreachable;
        }

        if(self.match(.r_brace)) |e| return .{.failure = e};
        return .{ .success = self.makeNode(.{
                .body = bodyNodes.toOwnedSlice(self.allocator) catch unreachable
            }, .{
                .start = start.span.start,
                .end = self.current.span.start,
            }) };
    }

    pub fn parse(self: *Parser) ParserResult {
        _ = self.advance();

        const start = self.current;
        var bodyNodes: std.ArrayList(*Node) = .empty;
        while(self.current.typ != .eof) {
            const stmt = self.parseStatement(true);
            if(stmt == .failure) return stmt;
            _ = bodyNodes.append(self.allocator, stmt.success) catch unreachable;
        }

        return .{ .success = self.makeNode(.{ .body = bodyNodes.toOwnedSlice(self.allocator) catch unreachable }, .{
                .start = start.span.start,
                .end = self.current.span.start,
            }) };
    }
};