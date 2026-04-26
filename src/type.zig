const std = @import("std");

const c = @import("codegen.zig").c;
const Node = @import("ast.zig").Node;

pub const TypeData = union(enum) {
    int: struct {
        signed: bool,
        bits: u32,
    },
    float: u32,
    bool: void,
    const_int: void,
    const_float: void,
    const_bool: void,
    null: void,
    void: void,
    array: struct {
        child: *Type,
        len: u32,
    },
    ptr: *Type,
    manyPtr: *Type,
    slice: *Type,
    func: struct {
        params: []*Type,
        returnType: *Type,
        varArgs: bool,
        hasCount: bool,
    },
    type: void,
};

pub const Type = struct {
    data: TypeData,
    isStorage: bool = false,
    
    pub fn makeType(typ: TypeData) *Type {
        const t = std.heap.smp_allocator.create(Type) catch unreachable;
        t.data = typ;
        t.isStorage = false;
        return t;
    }

    pub fn makeStorageType(typ: TypeData) *Type {
        const t = std.heap.smp_allocator.create(Type) catch unreachable;
        t.data = typ;
        t.isStorage = true;
        return t;
    }

    pub fn isNumeric(self: *Type) bool {
        switch(self.data) {
            .int, .float, .const_int, .const_float => return true,
            else => return false,
        }
    }

    pub fn isPointer(self: *Type) bool {
        switch(self.data) {
            .ptr, .manyPtr, .slice => return true,
            else => return false,
        }
    }

    pub fn isConstant(self: *Type) bool {
        switch(self.data) {
            .const_int, .const_float, .const_bool, .null => return true,
            else => return false,
        }
    }

    pub fn indexed(self: *Type, multiple: bool) ?*Type {
        switch(self.data) {
            .array => {
                if(multiple) {
                    return .makeType(.{.slice = self.data.array.child});
                }
                return .makeStorageType(.{.ptr = self.data.array.child});
            },
            .slice, .manyPtr => |d| {
                if(multiple) {
                    return .makeType(.{.slice = d});
                }
                return .makeStorageType(.{.ptr = d});
            },
            else => return null,
        }
    }

    pub fn member(self: *Type, name: []const u8) ?*Type {
        switch(self.data) {
            .array => {
                if(std.mem.eql(u8, name, "ptr")) {
                    return .makeType(.{.manyPtr = self.data.array.child});
                } else if(std.mem.eql(u8, name, "len")) {
                    return .makeType(.{.int = .{.bits = 64, .signed = false}});
                }
                return null;
            },
            .slice => {
                if(std.mem.eql(u8, name, "ptr")) {
                    return .makeType(.{.manyPtr = self.data.slice});
                } else if(std.mem.eql(u8, name, "len")) {
                    return .makeStorageType(.{.ptr = .makeType(.{.int = .{.bits = 64, .signed = false}})});
                }
                return null;
            },
            .ptr => {
                if(std.mem.eql(u8, name, "*")) {
                    return self.data.ptr;
                }
                return null;
            },
            else => return null,
        }
    }

    pub fn supportsEql(self: *Type) bool {
        switch(self.data) {
            .int, .float, .const_int, .const_float, .const_bool, .bool, .ptr, .type => return true,
            else => return false,
        }
    }

    pub fn canCoerce(self: *Type, other: *Type) bool {
        if(self.isNumeric() and other.isNumeric()) return true;
        if(self.data == .null and other.isPointer()) return true;
        if(self.isPointer() and other.data == .null) return true;
        if(self.data == .ptr and other.data == .ptr) return true;
        if(self.data == .slice and other.data == .manyPtr and self.data.slice.eql(other.data.manyPtr)) return true;
        return self.eql(other);
    }

    pub fn coerceValues(self: *Type, other: *Type) *Type {
        if(self.data == .slice and other.data == .manyPtr and self.data.slice.eql(other.data.manyPtr)) return other;

        if(!self.isNumeric() or !other.isNumeric()) @panic("attempting to find more precise numeric type on non-numeric types");
        if(self.eql(other)) return self;
        if(self.data == .const_int and other.data == .int) return other;
        if(self.data == .const_int and other.data == .float) return other;
        if(self.data == .const_float and other.data == .int) return other;
        if(self.data == .const_float and other.data == .float) return other;
        if(self.data == .const_bool and other.data == .bool) return other;
        if(self.data == .int and other.data == .const_int) return self;
        if(self.data == .float and other.data == .const_int) return self;
        if(self.data == .int and other.data == .const_float) return self;
        if(self.data == .float and other.data == .const_float) return self;
        if(self.data == .bool and other.data == .const_bool) return self;
        if(self.data == .int and other.data == .int) {
            if(self.data.int.bits > other.data.int.bits) {
                return self;
            } else if(self.data.int.bits < other.data.int.bits) {
                return other;
            } else {
                if(!self.data.int.signed) return self;
                return other;
            }
        } else if(self.data == .float and other.data == .float) {
            if(self.data.float > other.data.float) {
                return self;
            } else {
                return other;
            }
        } else {
            if(self.data == .float) return self;
            return other;
        }
    }

    pub fn eql(a: *Type, b: *Type) bool {
        if(a.isStorage != b.isStorage) return false;
        if(std.meta.activeTag(a.data) != std.meta.activeTag(b.data)) return false;
        switch(std.meta.activeTag(a.data)) {
            .bool, .void, .null, .type, .const_int, .const_float, .const_bool => {
                return true;
            },
            .int => {
                return a.data.int.signed == b.data.int.signed and a.data.int.bits == b.data.int.bits;
            },
            .float => {
                return a.data.float == b.data.float;
            },
            .array => {
                return a.data.array.len == b.data.array.len and Type.eql(a.data.array.child, b.data.array.child);
            },
            .ptr => {
                return Type.eql(a.data.ptr, b.data.ptr);
            },
            .manyPtr => {
                return Type.eql(a.data.manyPtr, b.data.manyPtr);
            },
            .slice => {
                return Type.eql(a.data.slice, b.data.slice);
            },
            .func => {
                if(a.data.func.varArgs != b.data.func.varArgs) return false;
                if(!eql(a.data.func.returnType, b.data.func.returnType)) return false;
                if(a.data.func.params.len != b.data.func.params.len) return false;
                for(a.data.func.params, 0..) |aParam, i| {
                    if(!eql(aParam, b.data.func.params[i])) return false;
                }
                return true;
            },
        }
    }

    pub fn toString(self: *Type, allocator: std.mem.Allocator) []u8 {
        switch(self.data) {
            .bool => {
                return allocator.dupe(u8, "bool") catch unreachable;
            },
            .null => {
                return allocator.dupe(u8, "null") catch unreachable;
            },
            .void => {
                return allocator.dupe(u8, "void") catch unreachable;
            },
            .const_int => {
                return allocator.dupe(u8, "const_int") catch unreachable;
            },
            .const_float => {
                return allocator.dupe(u8, "const_float") catch unreachable;
            },
            .const_bool => {
                return allocator.dupe(u8, "const_bool") catch unreachable;
            },
            .int => |i| {
                const char: u8 = if(i.signed) 'i' else 'u';
                return std.fmt.allocPrint(allocator, "{c}{d}", .{char, i.bits}) catch unreachable;
            },
            .float => |f| {
                return std.fmt.allocPrint(allocator, "f{d}", .{f}) catch unreachable;
            },
            .array => |a| {
                const child = a.child.toString(allocator);
                defer allocator.free(child);
                return std.fmt.allocPrint(allocator, "[{d}]{s}", .{a.len, child}) catch unreachable;
            },
            .ptr => |p| {
                const child = p.toString(allocator);
                defer allocator.free(child);
                return std.fmt.allocPrint(allocator, "*{s}", .{child}) catch unreachable;
            },
            .manyPtr => |p| {
                const child = p.toString(allocator);
                defer allocator.free(child);
                return std.fmt.allocPrint(allocator, "[*]{s}", .{child}) catch unreachable;
            },
            .slice => |p| {
                const child = p.toString(allocator);
                defer allocator.free(child);
                return std.fmt.allocPrint(allocator, "[]{s}", .{child}) catch unreachable;
            },
            .func => |f| {
                var argList: std.ArrayList(u8) = .empty;
                defer argList.deinit(allocator);
                for(f.params, 0..) |param, i| {
                    if(i > 0) argList.appendSlice(allocator, ", ") catch unreachable;
                    const arg = param.toString(allocator);
                    defer allocator.free(arg);
                    argList.appendSlice(allocator, arg) catch unreachable;
                }
                const ellipsisStr = if(f.hasCount) ", ..." else ", ...[c]";
                return std.fmt.allocPrint(allocator, "({s}{s}) -> {s}", .{argList.items, if(f.varArgs) ellipsisStr else "", f.returnType.toString(allocator)}) catch unreachable;
            },
            .type => {
                return allocator.dupe(u8, "type") catch unreachable;
            },
        }
    }

    pub fn toLLVM(self: *Type) c.LLVMTypeRef {
        switch(self.data) {
            .bool => {
                return c.LLVMInt1Type();
            },
            .void => {
                return c.LLVMVoidType();
            },
            .int => |i| {
                return c.LLVMIntType(@intCast(i.bits));
            },
            .float => |f| {
                return if(f == 64) c.LLVMDoubleType() else c.LLVMFloatType();
            },
            .array => |a| {
                return c.LLVMArrayType2(a.child.toLLVM(), @intCast(a.len));
            },
            .ptr => |p| {
                return c.LLVMPointerType(p.toLLVM(), 0);
            },
            .manyPtr => |p| {
                return c.LLVMPointerType(p.toLLVM(), 0);
            },
            .slice => |p| {
                var elems = [_]c.LLVMTypeRef{c.LLVMPointerType(p.toLLVM(), 0), c.LLVMIntType(64)};
                return c.LLVMStructType(&elems, elems.len, 0);
            },
            .func => |f| {
                var argCount = f.params.len;
                if(f.varArgs and f.hasCount) argCount += 1;

                var argList = std.heap.smp_allocator.alloc(c.LLVMTypeRef, argCount) catch unreachable;
                defer std.heap.smp_allocator.free(argList);
                for(f.params, 0..) |param, i| {
                    argList[i] = param.toLLVM();
                }
                if(f.varArgs and f.hasCount) argList[f.params.len] = c.LLVMInt32Type();
                const returnType = f.returnType.toLLVM();
                return c.LLVMFunctionType(returnType, @ptrCast(argList), @intCast(argList.len), if(f.varArgs) 1 else 0);
            },
            else => std.debug.panic("type {s} cannot be converted to llvm", .{@tagName(self.data)}),
        }
    }
};

pub const ConstVal = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    null: void,
};

pub const ComptimeValue = struct {
    value: union(enum) {
        none: void,
        runtime: void,
        typ: *Type,
        constant: ConstVal,
    },
    typ: *Type,

    pub fn makeNone() ComptimeValue {
        return .{
            .value = .none,
            .typ = .makeType(.void),
        };
    }

    pub fn makeRuntime(typ: *Type) ComptimeValue {
        return .{
            .value = .runtime,
            .typ = typ,
        };
    }

    pub fn makeType(typ: *Type) ComptimeValue {
        return .{
            .value = .{.typ = typ},
            .typ = .makeType(.type),
        };
    }

    pub fn makeConstant(typ: *Type, value: ConstVal) ComptimeValue {
        return .{
            .value = .{.constant = value},
            .typ = typ
        };
    }

    pub fn print(self: ComptimeValue) void {
        switch (self.value) {
            .none => {
                std.debug.print("ComptimeValue(none, type={s})\n", .{
                    self.typ.toString(std.heap.smp_allocator),
                });
            },

            .runtime => {
                const typ_str = self.typ.toString(std.heap.smp_allocator);
                defer std.heap.smp_allocator.free(typ_str);

                std.debug.print("ComptimeValue(runtime, type={s})\n", .{
                    typ_str,
                });
            },

            .typ => |t| {
                const value_str = t.toString(std.heap.smp_allocator);
                defer std.heap.smp_allocator.free(value_str);

                std.debug.print("ComptimeValue(type, value={s})\n", .{
                    value_str,
                });
            },

            .constant => |cval| {
                const typ_str = self.typ.toString(std.heap.smp_allocator);
                defer std.heap.smp_allocator.free(typ_str);

                switch (cval) {
                    .int => |v| {
                        std.debug.print(
                            "ComptimeValue(constant, type={s}, value={d})\n",
                            .{ typ_str, v },
                        );
                    },
                    .float => |v| {
                        std.debug.print(
                            "ComptimeValue(constant, type={s}, value={d})\n",
                            .{ typ_str, v },
                        );
                    },
                    .bool => |v| {
                        std.debug.print(
                            "ComptimeValue(constant, type={s}, value={})\n",
                            .{ typ_str, v },
                        );
                    },
                    .null => {
                        std.debug.print(
                            "ComptimeValue(constant, type={s}, value=null)\n",
                            .{ typ_str },
                        );
                    },
                }
            },
        }
    }

    pub fn castToHigher(self: ComptimeValue, other: ComptimeValue) ?ComptimeValue {
        if(self.typ.data == .const_bool and other.typ.data == .bool)
            return other;
        if(self.typ.data == .bool and other.typ.data == .const_bool)
            return self;
        if(self.typ.data == .const_bool and other.typ.data == .const_bool)
            return self;
        if(!self.typ.isNumeric() or !self.typ.isNumeric())
            return null;
        if(self.value == .runtime and other.value == .runtime)
            return .makeRuntime(self.typ.coerceValues(other.typ));
        if(self.value == .runtime and other.value == .constant)
            return self;
        if(self.value == .constant and other.value == .runtime)
            return other;
        if(self.typ.data == .const_int and other.typ.data == .const_int)
            return self;
        if(self.typ.data == .const_int and other.typ.data == .const_float)
            return .makeConstant(other.typ, .{.float = @as(f64, @floatFromInt(self.value.constant.int))});
        if(self.typ.data == .const_float and other.typ.data == .const_int)
            return .makeConstant(self.typ, .{.float = self.value.constant.float});
        if(self.typ.data == .const_float and other.typ.data == .const_float)
            return self;
        return null;
    }

    pub fn add(self: ComptimeValue, other: ComptimeValue) ?ComptimeValue {
        if(!self.typ.isNumeric()) return null;
        if(!other.typ.isNumeric()) return null;
        if(self.typ.isConstant() and other.typ.isConstant()) {
            const left = self.castToHigher(other) orelse return null;
            const right = other.castToHigher(self) orelse return null;
            if(left.typ.data == .const_int)
                return .makeConstant(left.typ, .{.int = left.value.constant.int +% right.value.constant.int});
            if(left.typ.data == .const_float)
                return .makeConstant(left.typ, .{.float = left.value.constant.float + right.value.constant.float});
        }
        const typ = Type.coerceValues(self.typ, other.typ);
        return .makeRuntime(typ);
    }

    pub fn sub(self: ComptimeValue, other: ComptimeValue) ?ComptimeValue {
        if(!self.typ.isNumeric()) return null;
        if(!other.typ.isNumeric()) return null;
        if(self.typ.isConstant() and other.typ.isConstant()) {
            const left = self.castToHigher(other) orelse return null;
            const right = other.castToHigher(self) orelse return null;
            if(left.typ.data == .const_int)
                return .makeConstant(left.typ, .{.int = left.value.constant.int -% right.value.constant.int});
            if(left.typ.data == .const_float)
                return .makeConstant(left.typ, .{.float = left.value.constant.float - right.value.constant.float});
        }
        const typ = Type.coerceValues(self.typ, other.typ);
        return .makeRuntime(typ);
    }

    pub fn mul(self: ComptimeValue, other: ComptimeValue) ?ComptimeValue {
        if(!self.typ.isNumeric()) return null;
        if(!other.typ.isNumeric()) return null;
        if(self.typ.isConstant() and other.typ.isConstant()) {
            const left = self.castToHigher(other) orelse return null;
            const right = other.castToHigher(self) orelse return null;
            if(left.typ.data == .const_int)
                return .makeConstant(left.typ, .{.int = left.value.constant.int *% right.value.constant.int});
            if(left.typ.data == .const_float)
                return .makeConstant(left.typ, .{.float = left.value.constant.float * right.value.constant.float});
        }
        const typ = Type.coerceValues(self.typ, other.typ);
        return .makeRuntime(typ);
    }

    pub fn div(self: ComptimeValue, other: ComptimeValue) ?ComptimeValue {
        if(!self.typ.isNumeric()) return null;
        if(!other.typ.isNumeric()) return null;
        if(self.typ.isConstant() and other.typ.isConstant()) {
            const left = self.castToHigher(other) orelse return null;
            const right = other.castToHigher(self) orelse return null;
            if(left.typ.data == .const_int)
                return .makeConstant(left.typ, .{.int = @divTrunc(left.value.constant.int, right.value.constant.int)});
            if(left.typ.data == .const_float)
                return .makeConstant(left.typ, .{.float = left.value.constant.float / right.value.constant.float});
        }
        const typ = Type.coerceValues(self.typ, other.typ);
        return .makeRuntime(typ);
    }

    pub fn lt(self: ComptimeValue, other: ComptimeValue) ?ComptimeValue {
        if(!self.typ.isNumeric()) return null;
        if(!other.typ.isNumeric()) return null;
        if(self.typ.isConstant() and other.typ.isConstant()) {
            const left = self.castToHigher(other) orelse return null;
            const right = other.castToHigher(self) orelse return null;
            if(left.typ.data == .const_int)
                return .makeConstant(.makeType(.const_bool), .{.bool = left.value.constant.int < right.value.constant.int});
            if(left.typ.data == .const_float)
                return .makeConstant(.makeType(.const_bool), .{.bool = left.value.constant.float < right.value.constant.float});
        }
        return .makeRuntime(.makeType(.bool));
    }

    pub fn lte(self: ComptimeValue, other: ComptimeValue) ?ComptimeValue {
        if(!self.typ.isNumeric()) return null;
        if(!other.typ.isNumeric()) return null;
        if(self.typ.isConstant() and other.typ.isConstant()) {
            const left = self.castToHigher(other) orelse return null;
            const right = other.castToHigher(self) orelse return null;
            if(left.typ.data == .const_int)
                return .makeConstant(.makeType(.const_bool), .{.bool = left.value.constant.int <= right.value.constant.int});
            if(left.typ.data == .const_float)
                return .makeConstant(.makeType(.const_bool), .{.bool = left.value.constant.float <= right.value.constant.float});
        }
        return .makeRuntime(.makeType(.bool));
    }

    pub fn gt(self: ComptimeValue, other: ComptimeValue) ?ComptimeValue {
        if(!self.typ.isNumeric()) return null;
        if(!other.typ.isNumeric()) return null;
        if(self.typ.isConstant() and other.typ.isConstant()) {
            const left = self.castToHigher(other) orelse return null;
            const right = other.castToHigher(self) orelse return null;
            if(left.typ.data == .const_int)
                return .makeConstant(.makeType(.const_bool), .{.bool = left.value.constant.int > right.value.constant.int});
            if(left.typ.data == .const_float)
                return .makeConstant(.makeType(.const_bool), .{.bool = left.value.constant.float > right.value.constant.float});
        }
        return .makeRuntime(.makeType(.bool));
    }

    pub fn gte(self: ComptimeValue, other: ComptimeValue) ?ComptimeValue {
        if(!self.typ.isNumeric()) return null;
        if(!other.typ.isNumeric()) return null;
        if(self.typ.isConstant() and other.typ.isConstant()) {
            const left = self.castToHigher(other) orelse return null;
            const right = other.castToHigher(self) orelse return null;
            if(left.typ.data == .const_int)
                return .makeConstant(.makeType(.const_bool), .{.bool = left.value.constant.int >= right.value.constant.int});
            if(left.typ.data == .const_float)
                return .makeConstant(.makeType(.const_bool), .{.bool = left.value.constant.float >= right.value.constant.float});
        }
        return .makeRuntime(.makeType(.bool));
    }

    pub fn neg(self: ComptimeValue) ?ComptimeValue {
        if(!self.typ.isNumeric()) return null;
        if(self.typ.isConstant()) {
            if(self.typ.data == .const_int)
                return .makeConstant(self.typ, .{.int = -self.value.constant.int});
            if(self.typ.data == .const_float)
                return .makeConstant(self.typ, .{.float = -self.value.constant.float});
        }
        return self;
    }

    pub fn not(self: ComptimeValue) ?ComptimeValue {
        if(self.typ.data != .bool) return null;
        if(self.typ.isConstant()) {
            return .makeConstant(self.typ, .{.bool = !self.value.constant.bool});
        }
        return self;
    }
};