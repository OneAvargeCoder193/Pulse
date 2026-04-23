const std = @import("std");
const token = @import("token.zig");
const TokenType = token.TokenType;

const ComptimeValue = @import("type.zig").ComptimeValue;

const Span = @import("err.zig").Span;

pub const VarArgConv = enum{ normal, c };

pub const NodeData = union(enum) {
    body: []*Node,
    intLiteral: i64,
    floatLiteral: f64,
    boolLiteral: bool,
    nullLiteral: void,
    stringLiteral: []const u8,

    typeType: void,
    intType: u32,
    uintType: u32,
    floatType: void,
    doubleType: void,
    boolType: void,
    voidType: void,

    arrayType: struct {
        child: *Node,
        len: u32,
    },
    ptrSingle: *Node,
    ptrMany: *Node,
    ptrSlice: *Node,

    cast: struct { type: *Node, val: *Node },

    variable: []const u8,
    binary: struct { left: *Node, op: TokenType, right: *Node },
    unary: struct { op: TokenType, expr: *Node },
    reference: struct { expr: *Node },
    call: struct { callee: *Node, args: []*Node },
    index: struct { left: *Node, start: ?*Node, end: ?*Node, multiple: bool },
    memberAccess: struct { expr: *Node, field: []const u8 },

    lambda: struct { params: []Param, returnType: ?*Node, body: *Node },

    varDecl: struct { name: []const u8, typ: ?*Node, init: ?*Node },
    assign: struct { target: *Node, value: *Node, op: TokenType },
    applyGeneric: struct { value: *Node, generics: []*Node },
    @"return": ?*Node,
    @"if": struct { cond: *Node, thenBranch: *Node, elseBranch: ?*Node },
    @"while": struct { cond: *Node, body: *Node },
    @"for": struct { initialize: ?*Node, condition: ?*Node, iterate: ?*Node, body: *Node },
    funcDecl: struct { name: []const u8, generics: [][]const u8, params: []Param, returnType: *Node, body: ?*Node, varArgs: ?[]const u8, varArgConv: VarArgConv },
    classDecl: struct { name: []const u8, generics: [][]const u8, body: *Node },
};

pub const Param = struct {
    name: []const u8,
    type: *Node,
};

pub const Node = struct {
    typ: ComptimeValue = undefined,
    inner: NodeData,
    span: Span,

    pub fn print(self: Node, indent: usize) void {
        const pad = indentSpaces(indent);

        switch (self.inner) {
            .body => |nodes| {
                std.debug.print("{{\n", .{});
                for(nodes) |node| {
                    node.print(indent + 2);
                    std.debug.print("\n", .{});
                }
                std.debug.print("{s}}}", .{pad});
            },

            .intLiteral => |v| {
                std.debug.print("{d}", .{v});
            },
            .floatLiteral => |v| {
                std.debug.print("{d}", .{v});
            },
            .boolLiteral => |v| {
                std.debug.print("{}", .{v});
            },
            .nullLiteral => {
                std.debug.print("null", .{});
            },
            .stringLiteral => |v| {
                std.debug.print("\"{s}\"", .{v});
            },

            .typeType => {
                const str = self.typ.value.typ.toString(std.heap.smp_allocator);
                defer std.heap.smp_allocator.free(str);
                std.debug.print("{s}", .{str});
            },
            .intType => |v| {
                std.debug.print("i{d}", .{v});
            },
            .uintType => |v| {
                std.debug.print("u{d}", .{v});
            },
            .floatType => {
                std.debug.print("f32", .{});
            },
            .doubleType => {
                std.debug.print("f64", .{});
            },
            .boolType => {
                std.debug.print("bool", .{});
            },
            .voidType => {
                std.debug.print("void", .{});
            },
            .arrayType => |a| {
                std.debug.print("[", .{});
                std.debug.print("{d}", .{a.len});
                std.debug.print("]", .{});
                a.child.print(0);
            },
            .ptrSingle => |p| {
                std.debug.print("*", .{});
                p.print(0);
            },
            .ptrMany => |p| {
                std.debug.print("[*]", .{});
                p.print(0);
            },
            .ptrSlice => |p| {
                std.debug.print("[]", .{});
                p.print(0);
            },

            .cast => |c| {
                std.debug.print("{s}((", .{pad});
                c.type.print(0);
                std.debug.print(")", .{});
                c.val.print(0);
                std.debug.print(")", .{});
            },

            .variable => |name| {
                std.debug.print("{s}", .{name});
            },

            .binary => |b| {
                std.debug.print("(", .{});
                b.left.print(0);
                std.debug.print(" {any} ", .{b.op});
                b.right.print(0);
                std.debug.print(")", .{});
            },

            .unary => |u| {
                std.debug.print("{any}", .{u.op});
                u.expr.print(0);
            },
            .reference => |r| {
                std.debug.print("&", .{});
                r.expr.print(0);
            },

            .index => |i| {
                i.left.print(0);
                std.debug.print("[", .{});
                if(i.start) |start| start.print(0);
                if(i.multiple) std.debug.print(":", .{});
                if(i.end) |end| end.print(0);
                std.debug.print("]", .{});
            },

            .call => |c| {
                std.debug.print("{s}", .{pad});
                c.callee.print(0);
                std.debug.print("(", .{});
                for(c.args, 0..) |arg, i| {
                    if(i > 0) std.debug.print(", ", .{});
                    arg.print(0);
                }
                std.debug.print(")", .{});
            },

            .lambda => |l| {
                std.debug.print("fn(", .{});
                for(l.params, 0..) |p, i| {
                    if(i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}: ", .{p.name});
                    p.type.print(0);
                }
                std.debug.print(") ", .{});
                if(l.returnType) |typ| {
                    typ.print(0);
                }
                l.body.print(indent);
            },

            .memberAccess => |m| {
                m.expr.print(0);
                std.debug.print(".{s}", .{m.field});
            },

            .varDecl => |v| {
                std.debug.print("{s}var {s}", .{pad, v.name});
                if(v.typ) |typ| {
                    std.debug.print(": ", .{});
                    typ.print(0);
                }
                if(v.init) |init| {
                    std.debug.print(" = ", .{});
                    init.print(0);
                }
                std.debug.print(";", .{});
            },

            .assign => |a| {
                std.debug.print("{s}", .{pad});
                a.target.print(0);
                std.debug.print(" {any} ", .{a.op});
                a.value.print(0);
            },

            .applyGeneric => |g| {
                g.value.print(indent);
                std.debug.print("<", .{});
                for(g.generics, 0..) |generic, i| {
                    if(i > 0) std.debug.print(", ", .{});
                    generic.print(0);
                }
                std.debug.print(">", .{});
            },

            .@"return" => |r| {
                std.debug.print("{s}return", .{pad});
                if(r) |expr| {
                    std.debug.print(" ", .{});
                    expr.print(0);
                }
                std.debug.print(";", .{});
            },

            .@"if" => |i| {
                std.debug.print("{s}if (", .{pad});
                i.cond.print(0);
                std.debug.print(") ", .{});
                i.thenBranch.print(indent);

                if(i.elseBranch) |elseBranch| {
                    std.debug.print("{s}else ", .{pad});
                    elseBranch.print(indent);
                }
            },

            .@"while" => |w| {
                std.debug.print("{s}while (", .{pad});
                w.cond.print(0);
                std.debug.print(") ", .{});
                w.body.print(indent);
            },

            .@"for" => |f| {
                std.debug.print("{s}for (", .{pad});
                if(f.initialize) |init| init.print(0);
                if(f.condition) |cond| cond.print(0);
                if(f.iterate) |iter| iter.print(0);
                std.debug.print(") ", .{});
                f.body.print(indent);
            },

            .funcDecl => |f| {
                std.debug.print("{s}fn {s}<", .{pad, f.name});
                for(f.generics, 0..) |generic, i| {
                    if(i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{generic});
                }
                std.debug.print(">(", .{});
                for(f.params, 0..) |p, i| {
                    if(i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}: ", .{p.name});
                    p.type.print(0);
                }
                if(f.varArgs) |name| {
                    std.debug.print(", ...{s}", .{name});
                }
                std.debug.print(") ", .{});
                f.returnType.print(0);
                if(f.body) |b| {
                    b.print(indent);
                }
            },

            .classDecl => |c| {
                std.debug.print("{s}class {s} ", .{pad, c.name});
                c.body.print(indent);
            },
        }
    }

    fn indentSpaces(n: usize) []const u8 {
        return "                                "[0..@min(n, 32)];
    }
};