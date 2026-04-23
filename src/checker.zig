const std = @import("std");

const err = @import("err.zig");
const TypeError = err.TypeError;

const ast = @import("ast.zig");
const Node = ast.Node;
const NodeData = ast.NodeData;

const type_zig = @import("type.zig");
const ComptimeValue = type_zig.ComptimeValue;
const Type = type_zig.Type;
const TypeData = type_zig.TypeData;

const TypeResult = union(enum) {
    success: ComptimeValue,
    failure: TypeError,
};

const Context = struct {
    parent: ?*Context,
    map: std.StringArrayHashMapUnmanaged(ComptimeValue),

    pub fn init(parent: ?*Context) *Context {
        const ctx = std.heap.smp_allocator.create(Context) catch unreachable;
        ctx.* = .{
            .parent = parent,
            .map = .empty,
        };
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        self.map.deinit(std.heap.smp_allocator);
    }

    pub fn set(self: *Context, name: []const u8, typ: ComptimeValue) void {
        _ = self.map.put(std.heap.smp_allocator, name, typ) catch unreachable;
    }

    pub fn get(self: *Context, name: []const u8) ?ComptimeValue {
        return self.map.get(name)
            orelse (self.parent orelse return null).get(name);
    }
};

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    ctx: *Context,
    currentFunc: ?*Type = null,

    pub fn init(allocator: std.mem.Allocator) TypeChecker {
        return .{
            .allocator = allocator,
            .ctx = .init(null),
        };
    }

    fn makeNode(self: *TypeChecker, data: NodeData, typ: ComptimeValue) *Node {
        const node = self.allocator.create(Node) catch unreachable;
        node.* = Node{
            .typ = typ,
            .inner = data,
            .span = undefined,
        };
        return node;
    }

    fn unify(_: *TypeChecker, a: *Type, b: *Type) ?*Type {
        if(Type.canCoerce(a, b)) return a;
        return null;
    }

    fn analyzeFunction(
        self: *TypeChecker,
        f: @FieldType(NodeData, "funcDecl"),
        genericMap: ?*std.StringArrayHashMapUnmanaged(ComptimeValue),
    ) TypeResult {
        const parent = self.ctx;
        const child = Context.init(parent);
        defer child.deinit();
        self.ctx = child;
        defer self.ctx = parent;

        if (genericMap) |map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                self.ctx.set(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        var paramTypes = self.allocator.alloc(*Type, f.params.len) catch unreachable;

        for (f.params, 0..) |param, i| {
            const paramType = self.inferType(param.type);
            if(paramType == .failure) return paramType;
            const t = paramType.success.value.typ;
            paramTypes[i] = t;
            self.ctx.set(param.name, .makeRuntime(.makeStorageType(.{.ptr = t})));
        }

        const retType = self.inferType(f.returnType);
        if(retType == .failure) return retType;
        const returnType = retType.success.value.typ;

        const funcType = Type.makeType(.{
            .func = .{
                .params = paramTypes,
                .returnType = returnType,
                .varArgs = f.varArgs != null,
                .hasCount = f.varArgConv == .normal,
            },
        });

        const oldFunc = self.currentFunc;
        self.currentFunc = funcType;
        defer self.currentFunc = oldFunc;

        if(f.body) |b| {
            const bodyRes = self.inferStmt(b);
            if(bodyRes == .failure) return bodyRes;
        }

        return .{.success = .makeRuntime(funcType)};
    }

    fn makeCast(self: *TypeChecker, val: *Node, prevTyp: *Type, typ: *Type) *Node {
        if(prevTyp.eql(typ)) return val;
        const typNode = self.makeNode(.typeType, .makeType(typ));
        return self.makeNode(.{.cast = .{
            .val = val,
            .type = typNode,
        }}, .makeRuntime(typ));
    }

    pub fn infer(self: *TypeChecker, node: *Node) TypeResult {
        const typ: ComptimeValue = blk: switch(node.inner) {
            .body => |children| {
                for(children) |child| {
                    const stmtRes = self.inferStmt(child);
                    if(stmtRes == .failure) return stmtRes;
                }
                break :blk .makeNone();
            },
            .intLiteral => .makeRuntime(.makeType(.{ .int = .{ .signed = true, .bits = 32 } })),
            .floatLiteral => .makeRuntime(.makeType(.{ .float = 32 })),
            .boolLiteral => .makeRuntime(.makeType(.bool)),
            .nullLiteral => .makeRuntime(.makeType(.null)),
            .stringLiteral => .makeRuntime(.makeType(.{ .slice = Type.makeType(.{.int = .{.bits = 8, .signed = false} }) })),

            .intType => |bits| .makeType(.makeType(.{ .int = .{ .signed = true, .bits = bits } })),
            .uintType => |bits| .makeType(.makeType(.{ .int = .{ .signed = false, .bits = bits } })),
            .floatType => .makeType(.makeType(.{ .float = 32 })),
            .doubleType => .makeType(.makeType(.{ .float = 64 })),
            .boolType => .makeType(.makeType(.bool)),
            .voidType => .makeType(.makeType(.void)),

            .arrayType => |a| {
                const child = self.inferType(a.child);
                if(child == .failure) return child;
                break :blk .makeType(.makeType(.{ .array = .{.child = child.success.value.typ, .len = a.len} }));
            },
            .ptrSingle => |p| {
                const child = self.inferType(p);
                if(child == .failure) return child;
                break :blk .makeType(.makeType(.{ .ptr = child.success.value.typ }));
            },
            .ptrMany => |p| {
                const child = self.inferType(p);
                if(child == .failure) return child;
                break :blk .makeType(.makeType(.{ .manyPtr = child.success.value.typ }));
            },
            .ptrSlice => |p| {
                const child = self.inferType(p);
                if(child == .failure) return child;
                break :blk .makeType(.makeType(.{ .slice = child.success.value.typ }));
            },

            .variable => |name| {
                break :blk self.ctx.get(name) orelse return .{
                    .failure = .{
                        .kind = .undefinedVar,
                        .span = node.span,
                    },
                };
            },
            .binary => |b| {
                const left = self.inferExpr(b.left);
                if(left == .failure) return left;
                const right = self.inferExpr(b.right);
                if(right == .failure) return right;

                const res: ?ComptimeValue = binBlk: switch (b.op) {
                    .plus => {
                        if(!left.success.typ.isNumeric()) break :binBlk null;
                        if(!right.success.typ.isNumeric()) break :binBlk null;
                        const typ = Type.coerceTo(left.success.typ, right.success.typ);
                        node.inner.binary.left = self.makeCast(b.left, left.success.typ, typ);
                        node.inner.binary.right = self.makeCast(b.right, right.success.typ, typ);
                        break :binBlk .makeRuntime(typ);
                    },
                    .minus => {
                        if(!left.success.typ.isNumeric()) break :binBlk null;
                        if(!right.success.typ.isNumeric()) break :binBlk null;
                        const typ = Type.coerceTo(left.success.typ, right.success.typ);
                        node.inner.binary.left = self.makeCast(b.left, left.success.typ, typ);
                        node.inner.binary.right = self.makeCast(b.right, right.success.typ, typ);
                        break :binBlk .makeRuntime(typ);
                    },
                    .star => {
                        if(!left.success.typ.isNumeric()) break :binBlk null;
                        if(!right.success.typ.isNumeric()) break :binBlk null;
                        const typ = Type.coerceTo(left.success.typ, right.success.typ);
                        node.inner.binary.left = self.makeCast(b.left, left.success.typ, typ);
                        node.inner.binary.right = self.makeCast(b.right, right.success.typ, typ);
                        break :binBlk .makeRuntime(typ);
                    },
                    .slash => {
                        if(!left.success.typ.isNumeric()) break :binBlk null;
                        if(!right.success.typ.isNumeric()) break :binBlk null;
                        const typ = Type.coerceTo(left.success.typ, right.success.typ);
                        node.inner.binary.left = self.makeCast(b.left, left.success.typ, typ);
                        node.inner.binary.right = self.makeCast(b.right, right.success.typ, typ);
                        break :binBlk .makeRuntime(typ);
                    },
                    .lt, .lt_eq, .gt, .gt_eq => {
                        if(!left.success.typ.canCoerce(right.success.typ)) break :binBlk null;
                        if(!left.success.typ.isNumeric()) break :binBlk null;
                        if(!right.success.typ.isNumeric()) break :binBlk null;
                        const typ = Type.coerceTo(left.success.typ, right.success.typ);
                        node.inner.binary.left = self.makeCast(b.left, left.success.typ, typ);
                        node.inner.binary.right = self.makeCast(b.right, right.success.typ, typ);
                        break :binBlk .makeRuntime(.makeType(.bool));
                    },
                    .eq_eq => {
                        if(!left.success.typ.canCoerce(right.success.typ)) break :binBlk null;
                        if(!left.success.typ.supportsEql()) break :binBlk null;
                        if(!right.success.typ.supportsEql()) break :binBlk null;
                        const typ = Type.coerceTo(left.success.typ, right.success.typ);
                        node.inner.binary.left = self.makeCast(b.left, left.success.typ, typ);
                        node.inner.binary.right = self.makeCast(b.right, right.success.typ, typ);
                        break :binBlk .makeRuntime(.makeType(.bool));
                    },
                    .bang_eq => {
                        if(!left.success.typ.canCoerce(right.success.typ)) break :binBlk null;
                        if(!left.success.typ.supportsEql()) break :binBlk null;
                        if(!right.success.typ.supportsEql()) break :binBlk null;
                        const typ = Type.coerceTo(left.success.typ, right.success.typ);
                        node.inner.binary.left = self.makeCast(b.left, left.success.typ, typ);
                        node.inner.binary.right = self.makeCast(b.right, right.success.typ, typ);
                        break :binBlk .makeRuntime(.makeType(.bool));
                    },
                    else => std.debug.panic("found illegal instruction {s}", .{@tagName(b.op)}),
                };
                if(res == null) {
                    return .{.failure = .{
                        .kind = .{.invalidBinOp = .{.left = left.success.typ, .right = right.success.typ, .op = b.op}},
                        .span = node.span,
                    }};
                }
                break :blk res.?;
            },
            .unary => |u| {
                const t = self.inferExpr(u.expr);
                if(t == .failure) return t;

                switch (u.op) {
                    .minus => {
                        if(!t.success.typ.isNumeric()) {
                            return .{.failure = .{
                                .kind = .mustBeNumeric,
                                .span = u.expr.span,
                            }};
                        }
                        break :blk t.success;
                    },
                    .bang => {
                        if(t.success.typ.data != .bool) {
                            return .{.failure = .{
                                .kind = .{.typeMismatch = .{.expected = .makeType(.bool), .found = t.success.typ}},
                                .span = u.expr.span,
                            }};
                        }
                        break :blk .makeRuntime(.makeType(.bool));
                    },
                    else => unreachable,
                }
            },
            .reference => |r| {
                const expr = self.inferStorage(r.expr);
                if(expr == .failure) return expr;

                if(!expr.success.typ.isStorage) return .{
                        .failure = .{
                            .kind = .mustBeStorage,
                            .span = r.expr.span,
                        }
                    };

                break :blk .makeRuntime(.makeType(expr.success.typ.data));
            },
            .index => |i| {
                const left = self.inferExpr(i.left);
                if(left == .failure) return left;

                const idxType = Type.makeType(.{.int = .{.bits = 64, .signed = false}});

                if(i.start) |start| {
                    const startRes = self.check(start, idxType);
                    if(startRes == .failure) return startRes;
                    node.inner.index.start = self.makeCast(start, start.typ.typ, idxType);
                }
                if(i.end) |end| {
                    const endRes = self.check(end, idxType);
                    if(endRes == .failure) return endRes;
                    node.inner.index.end = self.makeCast(end, end.typ.typ, idxType);
                }

                const indexed = left.success.typ.indexed(i.multiple) orelse return .{.failure = .{
                        .kind = .notIndexable,
                        .span = i.left.span,
                    }};

                break :blk .makeRuntime(indexed);
            },
            .memberAccess => |m| {
                const left = self.inferStorage(m.expr);
                if(left == .failure) return left;

                const member = left.success.typ.data.ptr.member(m.field) orelse return .{.failure = .{
                        .kind = .hasNoMembers,
                        .span = m.expr.span,
                    }};

                break :blk .makeRuntime(member);
            },
            .varDecl => |v| {
                var initType: ?TypeResult = null;
                if(v.init) |ini| {
                    initType = self.inferExpr(ini);
                    if(initType.? == .failure) return initType.?;
                }

                const finalType: ComptimeValue = if (v.typ) |typNode| declaredBlk: {
                    const declaredTyp = self.inferType(typNode);
                    if(declaredTyp == .failure) return declaredTyp;
                    const declared = declaredTyp.success.value.typ;
                    
                    if(v.init) |_| {
                        const unified = self.unify(declared, initType.?.success.typ) orelse {
                            return .{.failure = .{
                                .kind = .{.typeMismatch = .{.expected = declared, .found = initType.?.success.typ}},
                                .span = node.span,
                            }};
                        };
                        node.inner.varDecl.init = self.makeCast(v.init.?, v.init.?.typ.typ, unified);
                        break :declaredBlk .makeType(unified);
                    }

                    break :declaredBlk .makeType(declared);
                } else declaredBlk: {
                    node.inner.varDecl.typ = self.makeNode(.typeType, .makeType(initType.?.success.typ));
                    break :declaredBlk .makeType(initType.?.success.typ);
                };

                if(finalType.value.typ.data == .type) {
                    self.ctx.set(v.name, finalType);
                } else {
                    self.ctx.set(v.name, .makeRuntime(.makeStorageType(.{.ptr = finalType.value.typ})));
                }
                break :blk .makeNone();
            },
            .assign => |a| {
                const targetType = self.inferStorage(a.target);
                if(targetType == .failure) return targetType;

                const res = self.check(a.value, targetType.success.typ.data.ptr);
                if(res == .failure) return res;

                node.inner.assign.value = self.makeCast(a.value, a.value.typ.typ, targetType.success.typ.data.ptr);
                break :blk res.success;
            },
            .call => |c| {
                const calleeType = self.inferExpr(c.callee);
                if(calleeType == .failure) return calleeType;

                switch (calleeType.success.typ.data) {
                    .func => |f| {
                        if (f.params.len != c.args.len) {
                            if(!f.varArgs or c.args.len < f.params.len) {
                                return .{.failure = .{
                                    .kind = .{.paramLenMismatch = .{.expected = f.params.len, .found = c.args.len}},
                                    .span = node.span
                                }};
                            }
                        }

                        for (f.params, 0..) |param, i| {
                            const res = self.check(c.args[i], param);
                            if(res == .failure) return res;
                            node.inner.call.args[i] = self.makeCast(c.args[i], res.success.typ, param);
                        }
                        if(c.args.len > f.params.len) {
                            for(f.params.len..c.args.len) |i| {
                                const res = self.inferExpr(c.args[i]);
                                if(res == .failure) return res;
                            }
                        }

                        break :blk .makeRuntime(f.returnType);
                    },
                    else => return .{.failure = .{
                            .kind = .notCallable,
                            .span = node.span,
                        }}
                }
            },
            .applyGeneric => {
                @panic("generics not implemented");
            },
            .@"return" => |r| {
                if(r) |ret| {
                    const res = self.check(ret, self.currentFunc.?.data.func.returnType);
                    if(res == .failure) return res;
                    node.inner.@"return" = self.makeCast(ret, ret.typ.typ, self.currentFunc.?.data.func.returnType);
                } else {
                    if(self.unify(Type.makeType(.void), self.currentFunc.?.data.func.returnType) == null) {
                        return .{
                            .failure = .{
                                .kind = .{ .typeMismatch = .{.expected = self.currentFunc.?.data.func.returnType, .found = Type.makeType(.void)} },
                                .span = node.span
                            }
                        };
                    }
                }
                break :blk .makeNone();
            },
            .funcDecl => |f| {
                const genCount = f.generics.len;

                const poly = if (genCount > 0)
                    @panic("generics not implemented")
                else elseBlk: {
                    const concrete = self.analyzeFunction(f, null);
                    if(concrete == .failure) return concrete;
                    break :elseBlk concrete.success;
                };

                self.ctx.set(f.name, poly);
                break :blk poly;
            },
            .@"while" => |w| {
                const parent = self.ctx;
                const child = Context.init(parent);
                defer child.deinit();
                self.ctx = child;
                defer self.ctx = parent;

                const cond = self.check(w.cond, .makeType(.bool));
                if(cond == .failure) return cond;

                node.inner.@"while".cond = self.makeCast(w.cond, w.cond.typ.typ, .makeType(.bool));

                const body = self.inferStmt(w.body);
                if(body == .failure) return body;
                break :blk .makeNone();
            },
            .@"for" => |f| {
                const parent = self.ctx;
                const child = Context.init(parent);
                defer child.deinit();
                self.ctx = child;
                defer self.ctx = parent;

                if(f.initialize) |initialize| {
                    const initRes = self.infer(initialize);
                    if(initRes == .failure) return initRes;
                }

                if(f.condition) |condition| {
                    const condRes = self.infer(condition);
                    if(condRes == .failure) return condRes;
                    node.inner.@"for".condition = self.makeCast(condition, condition.typ.typ, .makeType(.bool));
                }

                if(f.iterate) |iterate| {
                    const iterRes = self.infer(iterate);
                    if(iterRes == .failure) return iterRes;
                }

                const body = self.inferStmt(f.body);
                if(body == .failure) return body;
                break :blk .makeNone();
            },
            else => std.debug.panic("Node type checking not implemented for {s}", .{@tagName(node.inner)}),
        };
        node.typ = typ;
        return .{.success = typ};
    }

    fn inferExpr(self: *TypeChecker, node: *Node) TypeResult {
        const typ = self.infer(node);
        if(typ == .failure) return typ;
        if(typ.success.typ.data == .void) {
            return .{.failure = .{
                .span = node.span,
                .kind = .mustBeExpr,
            }};
        }
        if(typ.success.typ.isStorage) {
            if(typ.success.typ.data != .ptr) return .{.failure = .{
                .span = node.span,
                .kind = .storageMustBePtr,
            }};
            return .{.success = .makeRuntime(typ.success.typ.data.ptr)};
        }
        return typ;
    }

    fn inferType(self: *TypeChecker, node: *Node) TypeResult {
        const typ = self.infer(node);
        if(typ == .failure) return typ;
        if(typ.success.value != .typ) {
            return .{.failure = .{
                    .span = node.span,
                    .kind = .mustBeType,
                }};
        }
        return typ;
    }

    fn inferStorage(self: *TypeChecker, node: *Node) TypeResult {
        const typ = self.infer(node);
        if(typ == .failure) return typ;
        if(typ.success.typ.data == .void) {
            return .{.failure = .{
                .span = node.span,
                .kind = .mustBeExpr,
            }};
        }
        if(!typ.success.typ.isStorage) {
            return .{.failure = .{
                .span = node.span,
                .kind = .mustBeStorage,
            }};
        }
        if(typ.success.typ.data != .ptr) return .{.failure = .{
            .span = node.span,
            .kind = .storageMustBePtr,
        }};
        return .{.success = typ.success};
    }

    fn inferStmt(self: *TypeChecker, node: *Node) TypeResult {
        const res = self.infer(node);
        if(res == .failure) return res;
        return res;
    }

    pub fn check(self: *TypeChecker, node: *Node, expected: *Type) TypeResult {
        const inferred = self.inferExpr(node);
        if(inferred == .failure) return inferred;
        return .{.success = .makeRuntime(self.unify(inferred.success.typ, expected) orelse return .{
            .failure = .{
                .kind = .{ .typeMismatch = .{.expected = expected, .found = inferred.success.typ} },
                .span = node.span
            }
        })};
    }
};