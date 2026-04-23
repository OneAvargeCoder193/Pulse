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
            .int, .float => return true,
            else => return false,
        }
    }

    pub fn isPointer(self: *Type) bool {
        switch(self.data) {
            .ptr, .manyPtr, .slice => return true,
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
            else => return null,
        }
    }

    pub fn supportsEql(self: *Type) bool {
        switch(self.data) {
            .int, .float, .bool, .ptr, .type => return true,
            else => return false,
        }
    }

    pub fn canCoerce(self: *Type, other: *Type) bool {
        if(self.isNumeric() and other.isNumeric()) return true;
        if(self.data == .null and other.isPointer()) return true;
        if(self.isPointer() and other.data == .null) return true;
        if(self.data == .slice and other.data == .manyPtr and self.data.slice.eql(other.data.manyPtr)) return true;
        return self.eql(other);
    }

    pub fn coerceTo(self: *Type, other: *Type) *Type {
        if(self.data == .slice and other.data == .manyPtr and self.data.slice.eql(other.data.manyPtr)) return other;

        if(!self.isNumeric() or !other.isNumeric()) @panic("attempting to find more precise numeric type on non-numeric types");
        if(self.eql(other)) return self;
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
            .bool, .void, .null, .type => {
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
            .null => {
                @panic("null cannot be represented without a type");
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

pub const ComptimeValue = struct {
    value: union(enum) {
        none: void,
        runtime: void,
        typ: *Type,
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
};