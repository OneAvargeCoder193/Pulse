const std = @import("std");
const args = @import("args");

pub const Options = struct {
    const Emit = enum {exec, obj, @"llvm-ir", @"asm"};
    const Optimization = enum {@"0", @"1", @"2", @"3", @"s"};

    inputs: [][:0]const u8,
    output: []const u8,
    emit: Emit,
    @"opt-level": Optimization,
    target: ?[]const u8,
    @"dump-ast": bool = false,

    const VisibleOptions = struct {
        output: []const u8 = undefined,
        emit: Emit = .obj,
        @"opt-level": Optimization = .@"0",
        target: ?[]const u8 = null,
        @"dump-ast": bool = false,

        pub const shorthands = .{
            .O = "opt-level",
            .o = "output",
            .e = "emit",
            .t = "target",
        };
    };

    pub fn parse(allocator: std.mem.Allocator, argList: anytype) !Options {
        const result = try args.parse(VisibleOptions, argList, allocator, .print);
        var self: Options = undefined;
        inline for(std.meta.fields(VisibleOptions)) |field| {
            @field(self, field.name) = @field(result.options, field.name);
        }
        self.inputs = result.positionals[1..];
        return self;
    }
};