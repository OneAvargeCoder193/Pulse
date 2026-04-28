const std = @import("std");

const c = @import("codegen.zig").c;
const type_zig = @import("type.zig");
const ConstVal = type_zig.ConstVal;
const Type = type_zig.Type;

pub const Value = struct {
    val: union{
        val: c.LLVMValueRef,
        typ: c.LLVMTypeRef,
        constant: ConstVal
    },
    type: *Type,

    pub fn makeValue(val: c.LLVMValueRef, typ: *Type) Value {
        return .{
            .val = .{.val = val},
            .type = typ,
        };
    }

    pub fn makeType(typ: *Type) Value {
        return .{
            .val = .{.typ = typ.toLLVM()},
            .type = typ,
        };
    }

    pub fn makeConst(val: ConstVal, typ: *Type) Value {
        return .{
            .val = .{.constant = val},
            .type = typ,
        };
    }

    pub fn makeNull(typ: *Type) Value {
        const val: c.LLVMValueRef = blk: switch(typ.data) {
            .ptr => c.LLVMConstPointerNull(typ.toLLVM()),
            .manyPtr => c.LLVMConstPointerNull(typ.toLLVM()),
            .slice => |s| {
                var vals = [_]c.LLVMValueRef{c.LLVMConstPointerNull(c.LLVMPointerType(s.toLLVM(), 0)), c.LLVMConstInt(c.LLVMIntType(64), 0, 0)};
                break :blk c.LLVMConstStruct(&vals, vals.len, 0);
            },
            else => @panic("type is not nullable"),
        };
        return .{
            .val = .{.val = val},
            .type = typ,
        };
    }

    pub fn value(self: Value) c.LLVMValueRef {
        return self.val.val;
    }

    pub fn numeric(self: Value) bool {
        return self.type.isNumeric();
    }

    fn assertSameType(self: Value, other: Value) void {
        if(!self.type.eql(other.type)) @panic("type mismatch");
    }

    fn wrappingCast(comptime To: type, v: anytype) To {
        const From = @TypeOf(v);

        const from_info = @typeInfo(From).int;
        const to_info = @typeInfo(To).int;

        const UnsignedFrom = @Int(.unsigned, from_info.bits);

        const bits = @as(UnsignedFrom, @bitCast(v));

        if (to_info.bits < from_info.bits) {
            return @truncate(bits);
        } else {
            return @as(To, bits);
        }
    }

    fn castNumeric(builder: c.LLVMBuilderRef, v: Value, typ: *Type) Value {
        var val: c.LLVMValueRef = undefined;
        if(v.type.data == .const_int and typ.data == .int) {
            return .makeValue(c.LLVMConstInt(typ.toLLVM(), wrappingCast(c_ulonglong, v.val.constant.int), if(typ.data.int.signed) 1 else 0), typ);
        }
        if(v.type.data == .const_int and typ.data == .float) {
            return .makeValue(c.LLVMConstReal(typ.toLLVM(), @floatFromInt(v.val.constant.int)), typ);
        }
        if(v.type.data == .const_float and typ.data == .int) {
            return .makeValue(c.LLVMConstInt(typ.toLLVM(), @trunc(v.val.constant.float), if(typ.data.int.signed) 1 else 0), typ);
        }
        if(v.type.data == .const_float and typ.data == .float) {
            return .makeValue(c.LLVMConstReal(typ.toLLVM(), v.val.constant.float), typ);
        }
        if(v.type.data == .const_bool and typ.data == .bool) {
            return .makeValue(c.LLVMConstInt(typ.toLLVM(), if(v.val.constant.bool) 1 else 0, 0), typ);
        }
        
        if(v.type.data == .int and typ.data == .int) {
            val = c.LLVMBuildIntCast2(builder, v.value(), typ.toLLVM(), if(typ.data.int.signed) 1 else 0, "");
        } else if(v.type.data == .float and typ.data == .float) {
            val = c.LLVMBuildFPCast(builder, v.value(), typ.toLLVM(), "");
        } else if(v.type.data == .int and typ.data == .float) {
            if(v.type.data.int.signed) {
                val = c.LLVMBuildSIToFP(builder, v.value(), typ.toLLVM(), "");
            } else {
                val = c.LLVMBuildUIToFP(builder, v.value(), typ.toLLVM(), "");
            }
        } else if(v.type.data == .float and typ.data == .int) {
            if(typ.data.int.signed) {
                val = c.LLVMBuildFPToSI(builder, v.value(), typ.toLLVM(), "");
            } else {
                val = c.LLVMBuildFPToUI(builder, v.value(), typ.toLLVM(), "");
            }
        }
        return .makeValue(val, typ);
    }

    pub fn cast(builder: c.LLVMBuilderRef, v: Value, typ: *Type) Value {
        if(v.type.data == .slice and typ.data == .manyPtr and v.type.data.slice.eql(typ.data.manyPtr)) {
            const ptr = c.LLVMBuildExtractValue(builder, v.value(), 0, "");
            return .makeValue(
                ptr,
                .makeType(.{.manyPtr = v.type.data.slice}),
            );
        } else if(v.type.data == .null and typ.isPointer()) {
            return .makeNull(typ);
        } else if(v.type.data == .ptr and typ.data == .ptr) {
            return .makeValue(
                v.value(),
                typ,
            );
        } else if(v.type.isNumeric() and typ.isNumeric()) {
            return castNumeric(builder, v, typ);
        } else if(v.type.data == .const_bool and typ.data == .bool) {
            return .makeValue(
                c.LLVMConstInt(c.LLVMInt1Type(), if(v.val.constant.bool) 1 else 0, 0),
                typ
            );
        }
        @panic("invalid cast");
    }

    pub fn add(builder: c.LLVMBuilderRef, a: Value, b: Value) Value {
        if(!a.numeric()) @panic("add expects numeric");
        if(!b.numeric()) @panic("add expects numeric");
        assertSameType(a, b);

        switch(a.type.data) {
            .int => return .makeValue(c.LLVMBuildAdd(builder, a.value(), b.value(), ""), a.type),
            .float => return .makeValue(c.LLVMBuildFAdd(builder, a.value(), b.value(), ""), a.type),
            else => unreachable,
        }
    }

    pub fn sub(builder: c.LLVMBuilderRef, a: Value, b: Value) Value {
        if(!a.numeric()) @panic("sub expects numeric");
        if(!b.numeric()) @panic("sub expects numeric");
        assertSameType(a, b);

        switch(a.type.data) {
            .int => return .makeValue(c.LLVMBuildSub(builder, a.value(), b.value(), ""), a.type),
            .float => return .makeValue(c.LLVMBuildFSub(builder, a.value(), b.value(), ""), a.type),
            else => unreachable,
        }
    }

    pub fn mul(builder: c.LLVMBuilderRef, a: Value, b: Value) Value {
        if(!a.numeric()) @panic("mul expects numeric");
        if(!b.numeric()) @panic("mul expects numeric");
        assertSameType(a, b);

        switch(a.type.data) {
            .int => return .makeValue(c.LLVMBuildMul(builder, a.value(), b.value(), ""), a.type),
            .float => return .makeValue(c.LLVMBuildFMul(builder, a.value(), b.value(), ""), a.type),
            else => unreachable,
        }
    }

    pub fn div(builder: c.LLVMBuilderRef, a: Value, b: Value) Value {
        if(!a.numeric()) @panic("div expects numeric");
        if(!b.numeric()) @panic("div expects numeric");
        assertSameType(a, b);

        switch(a.type.data) {
            .int => |i| {
                if(i.signed) {
                    return .makeValue(c.LLVMBuildSDiv(builder, a.value(), b.value(), ""), a.type);
                } else {
                    return .makeValue(c.LLVMBuildUDiv(builder, a.value(), b.value(), ""), a.type);
                }
            },
            .float => return .makeValue(c.LLVMBuildFDiv(builder, a.value(), b.value(), ""), a.type),
            else => unreachable,
        }
    }

    pub fn lt(builder: c.LLVMBuilderRef, a: Value, b: Value) Value {
        if(!a.numeric()) @panic("lt expects numeric");
        if(!b.numeric()) @panic("lt expects numeric");
        assertSameType(a, b);

        switch(a.type.data) {
            .int => return .makeValue(c.LLVMBuildICmp(builder, if(a.type.data.int.signed) c.LLVMIntSLT else c.LLVMIntULT, a.value(), b.value(), ""), .makeType(.bool)),
            .float => return .makeValue(c.LLVMBuildFCmp(builder, c.LLVMRealULT, a.value(), b.value(), ""), .makeType(.bool)),
            else => unreachable,
        }
    }

    pub fn lte(builder: c.LLVMBuilderRef, a: Value, b: Value) Value {
        if(!a.numeric()) @panic("lte expects numeric");
        if(!b.numeric()) @panic("lte expects numeric");
        assertSameType(a, b);

        switch(a.type.data) {
            .int => return .makeValue(c.LLVMBuildICmp(builder, if(a.type.data.int.signed) c.LLVMIntSLE else c.LLVMIntULE, a.value(), b.value(), ""), .makeType(.bool)),
            .float => return .makeValue(c.LLVMBuildFCmp(builder, c.LLVMRealULE, a.value(), b.value(), ""), .makeType(.bool)),
            else => unreachable,
        }
    }

    pub fn gt(builder: c.LLVMBuilderRef, a: Value, b: Value) Value {
        if(!a.numeric()) @panic("gt expects numeric");
        if(!b.numeric()) @panic("gt expects numeric");
        assertSameType(a, b);

        switch(a.type.data) {
            .int => return .makeValue(c.LLVMBuildICmp(builder, if(a.type.data.int.signed) c.LLVMIntSGT else c.LLVMIntUGT, a.value(), b.value(), ""), .makeType(.bool)),
            .float => return .makeValue(c.LLVMBuildFCmp(builder, c.LLVMRealUGT, a.value(), b.value(), ""), .makeType(.bool)),
            else => unreachable,
        }
    }

    pub fn gte(builder: c.LLVMBuilderRef, a: Value, b: Value) Value {
        if(!a.numeric()) @panic("gte expects numeric");
        if(!b.numeric()) @panic("gte expects numeric");
        assertSameType(a, b);

        switch(a.type.data) {
            .int => return .makeValue(c.LLVMBuildICmp(builder, if(a.type.data.int.signed) c.LLVMIntSGE else c.LLVMIntUGE, a.value(), b.value(), ""), .makeType(.bool)),
            .float => return .makeValue(c.LLVMBuildFCmp(builder, c.LLVMRealUGE, a.value(), b.value(), ""), .makeType(.bool)),
            else => unreachable,
        }
    }

    pub fn eql(builder: c.LLVMBuilderRef, a: Value, b: Value) Value {
        if(!a.numeric()) @panic("eql expects numeric");
        if(!b.numeric()) @panic("eql expects numeric");
        assertSameType(a, b);

        switch(a.type.data) {
            .int => return .makeValue(c.LLVMBuildICmp(builder, c.LLVMIntEQ, a.value(), b.value(), ""), a.type),
            .float => return .makeValue(c.LLVMBuildFCmp(builder, c.LLVMRealUEQ, a.value(), b.value(), ""), a.type),
            else => unreachable,
        }
    }

    pub fn neq(builder: c.LLVMBuilderRef, a: Value, b: Value) Value {
        if(!a.numeric()) @panic("neq expects numeric");
        if(!b.numeric()) @panic("neq expects numeric");
        assertSameType(a, b);

        switch(a.type.data) {
            .int => return .makeValue(c.LLVMBuildICmp(builder, c.LLVMIntNE, a.value(), b.value(), ""), a.type),
            .float => return .makeValue(c.LLVMBuildFCmp(builder, c.LLVMRealUNE, a.value(), b.value(), ""), a.type),
            else => unreachable,
        }
    }

    pub fn neg(builder: c.LLVMBuilderRef, v: Value) Value {
        if(!v.numeric()) @panic("neg expects numeric");
        switch(v.type.data) {
            .int => return .makeValue(c.LLVMBuildNeg(builder, v.value(), ""), v.type),
            .float => return .makeValue(c.LLVMBuildFNeg(builder, v.value(), ""), v.type),
            else => unreachable,
        }
    }

    pub fn not(builder: c.LLVMBuilderRef, v: Value) Value {
        if(!v.numeric()) @panic("not expects numeric");
        switch(v.type.data) {
            .bool => return .makeValue(c.LLVMBuildNot(builder, v.value(), ""), v.type),
            else => @panic("not expects bool"),
        }
    }

    fn buildSliceValue(builder: c.LLVMBuilderRef, sliceType: *Type, ptr: c.LLVMValueRef, len: c.LLVMValueRef) Value {
        const undef = c.LLVMGetUndef(sliceType.toLLVM());

        const withPtr = c.LLVMBuildInsertValue(
            builder,
            undef,
            ptr,
            0,
            "",
        );

        const fullSlice = c.LLVMBuildInsertValue(
            builder,
            withPtr,
            len,
            1,
            "",
        );

        return .makeValue(fullSlice, sliceType);
    }

    pub fn index(builder: c.LLVMBuilderRef, v: Value, start: Value, end: Value, multiple: bool) Value {
        const childType = v.type.data.ptr;
        const indexed = childType.indexed(multiple) orelse @panic("not indexable");
        switch(childType.data) {
            .array => {
                if(multiple) {
                    var indices = [_]c.LLVMValueRef{
                        c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                        start.value(),
                    };
                    const ptr = c.LLVMBuildGEP2(builder, childType.toLLVM(), v.value(), &indices, indices.len, "");
                    const len = Value.sub(builder, end, start);
                    return buildSliceValue(builder, indexed, ptr, len.value());
                }
                var indices = [_]c.LLVMValueRef{
                    c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                    start.value(),
                };
                return .makeValue(
                    c.LLVMBuildGEP2(builder, childType.toLLVM(), v.value(), &indices, indices.len, ""),
                    indexed,
                );
            },
            .manyPtr => {
                if(multiple) {
                    var indices = [_]c.LLVMValueRef{
                        c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                        start.value(),
                    };
                    const ptr = c.LLVMBuildGEP2(builder, childType.toLLVM(), v.value(), &indices, indices.len, "");
                    const len = Value.sub(builder, end, start);
                    return buildSliceValue(builder, indexed, ptr, len.value());
                }
                var indices = [_]c.LLVMValueRef{
                    c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                    start.value(),
                };
                return .makeValue(
                    c.LLVMBuildGEP2(builder, childType.toLLVM(), v.value(), &indices, indices.len, ""),
                    indexed,
                );
            },
            .slice => |memberType| {
                if(multiple) {
                    var indices = [_]c.LLVMValueRef{
                        c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                        c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                    };
                    const gep = makeValue(
                        c.LLVMBuildGEP2(builder, childType.toLLVM(), v.value(), &indices, indices.len, ""),
                        .makeStorageType(.{.ptr = .makeType(.{.manyPtr = memberType})}),
                    );
                    const dataPtr = c.LLVMBuildLoad2(builder, gep.type.toLLVM(), gep.value(), "");
                    var indexIndices = [_]c.LLVMValueRef{
                        start.value(),
                    };
                    const ptr = c.LLVMBuildGEP2(builder, memberType.toLLVM(), dataPtr, &indexIndices, indexIndices.len, "");
                    const len = Value.sub(builder, end, start);
                    return buildSliceValue(builder, indexed, ptr, len.value());
                }
                var indices = [_]c.LLVMValueRef{
                    c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                    c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                };
                const gep = makeValue(
                    c.LLVMBuildGEP2(builder, childType.toLLVM(), v.value(), &indices, indices.len, ""),
                    .makeStorageType(.{.ptr = .makeType(.{.manyPtr = memberType})}),
                );
                const ptr = c.LLVMBuildLoad2(builder, gep.type.toLLVM(), gep.value(), "");
                var indexIndices = [_]c.LLVMValueRef{
                    start.value(),
                };
                return .makeValue(
                    c.LLVMBuildGEP2(builder, memberType.toLLVM(), ptr, &indexIndices, indexIndices.len, ""),
                    indexed,
                );
            },
            else => @panic("not indexable"),
        }
    }

    pub fn member(builder: c.LLVMBuilderRef, v: Value, field: []const u8) Value {
        const childType = v.type.data.ptr;
        const memberType = childType.member(field) orelse @panic("no members");
        switch(childType.data) {
            .array => {
                if(std.mem.eql(u8, field, "ptr")) {
                    var indices = [_]c.LLVMValueRef{
                        c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                        c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                    };
                    return .makeValue(
                        c.LLVMBuildGEP2(builder, childType.toLLVM(), v.value(), &indices, indices.len, ""),
                        memberType,
                    );
                } else if(std.mem.eql(u8, field, "len")) {
                    return .makeValue(
                        c.LLVMConstInt(c.LLVMInt64Type(), childType.data.array.len, 0),
                        memberType,
                    );
                }
                @panic("not a member");
            },
            .slice => {
                if(std.mem.eql(u8, field, "ptr")) {
                    var indices = [_]c.LLVMValueRef{
                        c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                        c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                    };
                    const ptr = c.LLVMBuildGEP2(builder, childType.toLLVM(), v.value(), &indices, indices.len, "");
                    return .makeValue(
                        c.LLVMBuildLoad2(builder, memberType.toLLVM(), ptr, ""),
                        memberType,
                    );
                } else if(std.mem.eql(u8, field, "len")) {
                    var indices = [_]c.LLVMValueRef{
                        c.LLVMConstInt(c.LLVMInt32Type(), 0, 0),
                        c.LLVMConstInt(c.LLVMInt32Type(), 1, 0),
                    };
                    return .makeValue(
                        c.LLVMBuildGEP2(builder, childType.toLLVM(), v.value(), &indices, indices.len, ""),
                        memberType,
                    );
                }
                @panic("not a member");
            },
            .ptr => {
                if(std.mem.eql(u8, field, "*")) {
                    return .makeValue(
                        c.LLVMBuildLoad2(builder, memberType.toLLVM(), v.value(), ""),
                        memberType,
                    );
                }
                @panic("not a member");
            },
            else => @panic("no members"),
        }
    }

    pub fn call(builder: c.LLVMBuilderRef, callee: Value, args: []Value) ?Value {
        if(callee.type.data != .func) @panic("not callable");
        const argList = std.heap.smp_allocator.alloc(c.LLVMValueRef, args.len) catch unreachable;
        for(args, 0..) |arg, i| {
            argList[i] = arg.value();
        }
        const res = c.LLVMBuildCall2(builder, callee.type.toLLVM(), callee.value(), @ptrCast(argList), @intCast(argList.len), "");
        if(callee.type.data.func.returnType.data == .void) return null;
        return .makeValue(res, callee.type.data.func.returnType);
    }
};