const std = @import("std");

const err = @import("err.zig");
const TypeError = err.TypeError;

const ast = @import("ast.zig");
const Node = ast.Node;
const NodeData = ast.NodeData;

const type_zig = @import("type.zig");
const Type = type_zig.Type;
const TypeData = type_zig.TypeData;

const Value = @import("value.zig").Value;

pub const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/TargetMachine.h");
    @cInclude("llvm-c/BitWriter.h");
    @cInclude("llvm-c/Linker.h");
    @cInclude("llvm-c/Transforms/PassBuilder.h");
});

const TypeResult = union(enum) {
    success: *Type,
    failure: TypeError,
};

const Context = struct {
    parent: ?*Context,
    map: std.StringArrayHashMapUnmanaged(Value),

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
        std.heap.smp_allocator.destroy(self);
    }

    pub fn set(self: *Context, name: []const u8, val: Value) void {
        _ = self.map.put(std.heap.smp_allocator, name, val) catch unreachable;
    }

    pub fn get(self: *Context, name: []const u8) ?Value {
        return self.map.get(name)
            orelse (self.parent orelse return null).get(name);
    }
};

fn unescape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const char = input[i];

        if (char != '\\') {
            try out.append(allocator, char);
            continue;
        }

        if (i + 1 >= input.len) return error.InvalidEscape;
        i += 1;

        switch (input[i]) {
            '\\' => try out.append(allocator, '\\'),
            '\'' => try out.append(allocator, '\''),
            '"'  => try out.append(allocator, '"'),
            '?'  => try out.append(allocator, '?'),

            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'a' => try out.append(allocator, 0x07),
            'b' => try out.append(allocator, 0x08),
            'f' => try out.append(allocator, 0x0C),
            'v' => try out.append(allocator, 0x0B),

            '0'...'7' => {
                var value: u32 = input[i] - '0';
                var count: usize = 1;

                while (count < 3 and i + 1 < input.len) {
                    const next = input[i + 1];
                    if (next < '0' or next > '7') break;
                    i += 1;
                    count += 1;
                    value = value * 8 + (next - '0');
                }

                try out.append(allocator, @intCast(value & 0xFF));
            },

            'x' => {
                if (i + 1 >= input.len) return error.InvalidEscape;

                var value: u32 = 0;
                var digits: usize = 0;

                while (i + 1 < input.len) {
                    const next = input[i + 1];
                    const digit = hexValue(next) orelse break;
                    i += 1;
                    digits += 1;
                    value = value * 16 + digit;
                }

                if (digits == 0) return error.InvalidEscape;
                try out.append(allocator, @intCast(value & 0xFF));
            },

            'u' => {
                if (i + 1 >= input.len or input[i + 1] != '{')
                    return error.InvalidEscape;

                i += 2;

                var value: u32 = 0;
                var digits: usize = 0;

                while (i < input.len and input[i] != '}') : (i += 1) {
                    const digit = hexValue(input[i]) orelse return error.InvalidEscape;
                    value = value * 16 + digit;
                    digits += 1;
                }

                if (i >= input.len or input[i] != '}' or digits == 0)
                    return error.InvalidEscape;

                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(@intCast(value), &buf);
                try out.appendSlice(allocator, buf[0..len]);
            },

            else => return error.InvalidEscape,
        }
    }

    return out.toOwnedSlice(allocator);
}

fn hexValue(char: u8) ?u32 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

pub const CodeGenerator = struct {
    allocator: std.mem.Allocator,
    ctx: *Context,
    module: c.LLVMModuleRef,
    builder: c.LLVMBuilderRef,
    currentFunc: c.LLVMValueRef,

    pub fn init(allocator: std.mem.Allocator) CodeGenerator {
        const mod = c.LLVMModuleCreateWithName("main");
        const builder = c.LLVMCreateBuilder();

        return .{
            .allocator = allocator,
            .ctx = .init(null),
            .module = mod,
            .builder = builder,
            .currentFunc = null,
        };
    }

    pub fn deinit(self: *CodeGenerator) void {
        defer c.LLVMDisposeModule(self.mod);
        defer c.LLVMDisposeBuilder(self.builder);
    }

    pub fn visit(self: *CodeGenerator, node: *Node) ?Value {
        switch(node.inner) {
            .body => |children| {
                for(children) |child| {
                    _ = self.visit(child);
                }
                return null;
            },
            .intLiteral => |i| return .makeValue(c.LLVMConstInt(node.typ.typ.toLLVM(), @intCast(i), 1), node.typ.typ),
            .floatLiteral => |f| return .makeValue(c.LLVMConstReal(node.typ.typ.toLLVM(), @floatCast(f)), node.typ.typ),
            .boolLiteral => |b| return .makeValue(c.LLVMConstInt(node.typ.typ.toLLVM(), if(b) 1 else 0, 0), node.typ.typ),
            .nullLiteral => return .makeValue(c.LLVMConstPointerNull(c.LLVMPointerType(c.LLVMIntType(8), 0)), node.typ.typ),
            .stringLiteral => |s| {
                const unescaped = unescape(std.heap.smp_allocator, s) catch unreachable;
                defer std.heap.smp_allocator.free(unescaped);
                const cStr = std.heap.smp_allocator.dupeZ(u8, unescaped) catch unreachable;
                defer std.heap.smp_allocator.free(cStr);
                const stringPtr = c.LLVMBuildGlobalStringPtr(self.builder, cStr, "");
                const stringLen = c.LLVMConstInt(c.LLVMIntType(64), unescaped.len, 0);
                var stringArgs = [_]c.LLVMValueRef{stringPtr, stringLen};
                return .makeValue(c.LLVMConstStruct(&stringArgs, stringArgs.len, 0), node.typ.typ);
            },

            .intType, .uintType, .floatType, .doubleType, .boolType, .voidType => return .makeType(node.typ.value.typ),

            .array => |a| {
                const typ = a.type.typ.value.typ;
                var val = c.LLVMConstNull(typ.toLLVM());
                for(0..typ.data.array.len) |i| {
                    const expr = self.visitValue(a.children[i]);
                    val = c.LLVMBuildInsertValue(self.builder, val, expr.value(), @intCast(i), "");
                }
                return .makeValue(val, typ);
            },

            .cast => |ca| {
                const value = self.visitValue(ca.val);
                return Value.cast(self.builder, value, ca.type.typ.value.typ);
            },

            .variable => |name| {
                return self.ctx.get(name) orelse unreachable;
            },
            .binary => |b| {
                const left = self.visitValue(b.left);
                const right = self.visitValue(b.right);

                switch (b.op) {
                    .plus =>    return Value.add(self.builder, left, right),
                    .minus =>   return Value.sub(self.builder, left, right),
                    .star =>    return Value.mul(self.builder, left, right),
                    .slash =>   return Value.div(self.builder, left, right),
                    .lt =>      return Value.lt(self.builder, left, right),
                    .lt_eq =>   return Value.lte(self.builder, left, right),
                    .gt =>      return Value.gt(self.builder, left, right),
                    .gt_eq =>   return Value.gte(self.builder, left, right),
                    .eq_eq =>   return Value.eql(self.builder, left, right),
                    .bang_eq => return Value.neq(self.builder, left, right),
                    else => unreachable,
                }
            },
            .unary => |u| {
                const t = self.visitValue(u.expr);

                switch (u.op) {
                    .minus => return Value.neg(self.builder, t),
                    .bang =>  return Value.not(self.builder, t),
                    else => unreachable,
                }
            },
            .reference => |r| {
                const storage = self.visitStorage(r.expr);
                return .makeValue(storage.value(), node.typ.typ);
            },
            .index => |i| {
                const expr = self.visitStorage(i.left);
                const idxType = Type.makeType(.{.int = .{.bits = 64, .signed = false}});
                const start: Value = if(i.start) |start| self.visitValue(start)
                    else .makeValue(c.LLVMConstInt(c.LLVMInt32Type(), 0, 0), idxType);
                const end: Value = if(i.end) |end| self.visitValue(end)
                    else endBlk: {
                        var len = Value.member(self.builder, expr, "len");
                        if(len.type.isStorage) {
                            len = Value.makeValue(c.LLVMBuildLoad2(self.builder, len.type.data.ptr.toLLVM(), len.value(), ""), len.type.data.ptr);
                        }
                        break :endBlk len;
                    };
                return Value.index(self.builder, expr, start, end, i.multiple);
            },
            .memberAccess => |m| {
                const expr = self.visitStorage(m.expr);
                return Value.member(self.builder, expr, m.field);
            },
            .varDecl => |v| {
                if(v.typ.?.typ.value.typ.data == .type) return null;

                const varType = v.typ.?.typ.value.typ;
                const storageType = Type.makeStorageType(.{.ptr = varType});

                const cName = self.allocator.dupeZ(u8, v.name) catch unreachable;
                defer self.allocator.free(cName);

                if(self.currentFunc == null) {
                    const variable = c.LLVMAddGlobal(self.module, varType.toLLVM(), cName);
                    c.LLVMSetLinkage(variable, c.LLVMExternalLinkage);
                    c.LLVMSetGlobalConstant(variable, 0); // mutable (1 would make it constant)
                    c.LLVMSetInitializer(variable, c.LLVMConstNull(varType.toLLVM()));
                    if(v.init) |ini| {
                        c.LLVMSetInitializer(variable, self.visitValue(ini).value());
                    }
                    self.ctx.set(v.name, .makeValue(variable, storageType));
                } else {
                    const alloc = Value.makeValue(c.LLVMBuildAlloca(self.builder, varType.toLLVM(), cName), storageType);
                    if(v.init) |ini| {
                        const val = self.visitValue(ini);
                        _ = c.LLVMBuildStore(self.builder, val.value(), alloc.value());
                    }
                    self.ctx.set(v.name, alloc);
                }
                return null;
            },
            .assign => |a| {
                const targetType = self.visitStorage(a.target);
                const value = self.visitValue(a.value);

                if(a.op != .eq) @panic("assignments other than = not supported yet");

                _ = c.LLVMBuildStore(self.builder, value.value(), targetType.value());
                return value;
            },
            .call => |cl| {
                const callee = self.visitValue(cl.callee);
                var argsLen = cl.args.len;
                if(callee.type.data.func.hasCount and callee.type.data.func.varArgs) argsLen += 1;
                const args = self.allocator.alloc(Value, argsLen) catch unreachable;
                for(0..callee.type.data.func.params.len) |i| {
                    args[i] = self.visitValue(cl.args[i]);
                }
                if(callee.type.data.func.varArgs) {
                    if(callee.type.data.func.hasCount and callee.type.data.func.varArgs) {
                        args[callee.type.data.func.params.len] = .makeValue(
                            c.LLVMConstInt(c.LLVMInt32Type(), cl.args.len - callee.type.data.func.params.len, 0),
                            .makeType(.{.int = .{.bits = 32, .signed = false}}),
                        );
                    }
                    const offset: usize = if(callee.type.data.func.hasCount and callee.type.data.func.varArgs) 1 else 0;
                    for(callee.type.data.func.params.len..cl.args.len) |i| {
                        args[i + offset] = self.visitValue(cl.args[i]);
                    }
                }
                return Value.call(self.builder, callee, args);
            },
            .applyGeneric => {
                @panic("generics not implemented");
            },
            .@"return" => |r| {
                if(r) |ret| {
                    const value = self.visitValue(ret);
                    _ = c.LLVMBuildRet(self.builder, value.value());
                } else {
                    _ = c.LLVMBuildRetVoid(self.builder);
                }
                return null;
            },
            .funcDecl => |f| {
                const poly = if (f.generics.len > 0)
                    @panic("generics not implemented")
                else elseBlk: {
                    const parent = self.ctx;
                    const child = Context.init(parent);
                    defer child.deinit();
                    self.ctx = child;
                    defer self.ctx = parent;

                    const params: []*Type = self.allocator.alloc(*Type, f.params.len) catch unreachable;
                    for(f.params, 0..) |param, i| {
                        params[i] = param.type.typ.value.typ;
                    }

                    const returnType = f.returnType.typ.value.typ;

                    const funcType = Type.makeType(.{.func = .{
                        .params = params,
                        .returnType = returnType,
                        .varArgs = f.varArgs != null,
                        .hasCount = f.varArgConv == .normal,
                    }});

                    const func = Value.makeValue(c.LLVMAddFunction(self.module, self.allocator.dupeZ(u8, f.name) catch unreachable, funcType.toLLVM()), funcType);

                    if(f.body) |b| {
                        const entry = c.LLVMAppendBasicBlock(func.value(), "entry");
                        c.LLVMPositionBuilderAtEnd(self.builder, entry);

                        for(params, 0..) |param, i| {
                            const alloc = c.LLVMBuildAlloca(self.builder, param.toLLVM(), "");
                            const val = c.LLVMGetParam(func.value(), @intCast(i));
                            const varType = Type.makeStorageType(.{.ptr = param});
                            _ = c.LLVMBuildStore(self.builder, val, alloc);
                            self.ctx.set(f.params[i].name, .makeValue(alloc, varType));
                        }

                        const oldFunc = self.currentFunc;
                        self.currentFunc = func.value();
                        _ = self.visit(b);
                        self.currentFunc = oldFunc;

                        const lastBB = c.LLVMGetInsertBlock(self.builder);
                        if(c.LLVMGetBasicBlockTerminator(lastBB) == null) {
                            _ = c.LLVMBuildRetVoid(self.builder);
                        }
                    }

                    break :elseBlk func;
                };

                self.ctx.set(f.name, poly);
                return null;
            },
            .@"if" => |i| {
                const condBBs = std.heap.smp_allocator.alloc(c.LLVMBasicBlockRef, i.cond.len) catch unreachable;
                defer std.heap.smp_allocator.free(condBBs);
                const bodyBBs = std.heap.smp_allocator.alloc(c.LLVMBasicBlockRef, i.thenBranch.len) catch unreachable;
                defer std.heap.smp_allocator.free(bodyBBs);
                var elseBB: c.LLVMBasicBlockRef = null;
                var endBB: c.LLVMBasicBlockRef = null;

                for(0..i.cond.len) |j| {
                    condBBs[j] = c.LLVMAppendBasicBlock(self.currentFunc, "");
                    bodyBBs[j] = c.LLVMAppendBasicBlock(self.currentFunc, "");
                }
                if(i.elseBranch) |_| elseBB = c.LLVMAppendBasicBlock(self.currentFunc, "");
                endBB = c.LLVMAppendBasicBlock(self.currentFunc, "");
                _ = c.LLVMBuildBr(self.builder, condBBs[0]);

                for(i.cond, i.thenBranch, 0..) |cond, then, j| {
                    const parent = self.ctx;
                    const child = Context.init(parent);
                    defer child.deinit();
                    self.ctx = child;
                    defer self.ctx = parent;
                    
                    c.LLVMPositionBuilderAtEnd(self.builder, condBBs[j]);
                    const condition = self.visitValue(cond);
                    const nextBB = if(j + 1 < condBBs.len) condBBs[j + 1] else if(elseBB) |e| e else endBB;
                    _ = c.LLVMBuildCondBr(self.builder, condition.value(), bodyBBs[j], nextBB);

                    c.LLVMPositionBuilderAtEnd(self.builder, bodyBBs[j]);
                    _ = self.visit(then);
                    if(c.LLVMGetBasicBlockTerminator(c.LLVMGetInsertBlock(self.builder)) == null) {
                        _ = c.LLVMBuildBr(self.builder, endBB);
                    }
                }
                if(i.elseBranch) |elseBranch| {
                    c.LLVMPositionBuilderAtEnd(self.builder, elseBB);
                    _ = self.visit(elseBranch);

                    if(c.LLVMGetBasicBlockTerminator(c.LLVMGetInsertBlock(self.builder)) == null) {
                        _ = c.LLVMBuildBr(self.builder, endBB);
                    }
                }
                c.LLVMPositionBuilderAtEnd(self.builder, endBB);

                return null;
            },
            .@"while" => |w| {
                const parent = self.ctx;
                const child = Context.init(parent);
                defer child.deinit();
                self.ctx = child;
                defer self.ctx = parent;

                const condBB = c.LLVMAppendBasicBlock(self.currentFunc, "");
                const bodyBB = c.LLVMAppendBasicBlock(self.currentFunc, "");
                const endBB  = c.LLVMAppendBasicBlock(self.currentFunc, "");

                _ = c.LLVMBuildBr(self.builder, condBB);
                c.LLVMPositionBuilderAtEnd(self.builder, condBB);

                const cond = self.visitValue(w.cond);
                _ = c.LLVMBuildCondBr(self.builder, cond.value(), bodyBB, endBB);

                c.LLVMPositionBuilderAtEnd(self.builder, bodyBB);
                _ = self.visit(w.body);

                _ = c.LLVMBuildBr(self.builder, condBB);
                c.LLVMPositionBuilderAtEnd(self.builder, endBB);

                return null;
            },
            .@"for" => |f| {
                const parent = self.ctx;
                const child = Context.init(parent);
                defer child.deinit();
                self.ctx = child;
                defer self.ctx = parent;

                const condBB = c.LLVMAppendBasicBlock(self.currentFunc, "");
                const bodyBB = c.LLVMAppendBasicBlock(self.currentFunc, "");
                const endBB  = c.LLVMAppendBasicBlock(self.currentFunc, "");

                if(f.initialize) |initialize| _ = self.visit(initialize);
                _ = c.LLVMBuildBr(self.builder, condBB);

                c.LLVMPositionBuilderAtEnd(self.builder, condBB);

                const cond: Value = if(f.condition) |condition| self.visitValue(condition) else .makeValue(c.LLVMConstInt(c.LLVMInt1Type(), 1, 0), .makeType(.bool));
                _ = c.LLVMBuildCondBr(self.builder, cond.value(), bodyBB, endBB);

                c.LLVMPositionBuilderAtEnd(self.builder, bodyBB);
                _ = self.visit(f.body);
                if(f.iterate) |iterate| _ = self.visit(iterate);

                _ = c.LLVMBuildBr(self.builder, condBB);
                c.LLVMPositionBuilderAtEnd(self.builder, endBB);

                return null;
            },
            else => std.debug.panic("Node codegen not implemented for {s}", .{@tagName(node.inner)}),
        }
        unreachable;
    }

    pub fn visitValue(self: *CodeGenerator, node: *Node) Value {
        const val = self.visit(node).?;
        if(val.type.isStorage) {
            return .makeValue(c.LLVMBuildLoad2(self.builder, val.type.data.ptr.toLLVM(), val.value(), ""), node.typ.typ.data.ptr);
        }
        return val;
    }

    pub fn visitStorage(self: *CodeGenerator, node: *Node) Value {
        const val = self.visit(node).?;
        if(!val.type.isStorage) @panic("expected storage");
        return val;
    }
};