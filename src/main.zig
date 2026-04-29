const std = @import("std");

const tokenizer = @import("tokenizer.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const checker = @import("checker.zig");
const codegen = @import("codegen.zig");

const c = codegen.c;
const options = @import("options.zig");

pub fn main(init: std.process.Init) u8 {
    const arenaAllocator = init.arena.allocator();
    const io = init.io;

    c.LLVMInitializeAllTargets();
    c.LLVMInitializeAllTargetInfos();
    c.LLVMInitializeAllTargetMCs();
    c.LLVMInitializeAllAsmPrinters();
    c.LLVMInitializeAllAsmParsers();
    
    var iter = init.minimal.args.iterateAllocator(arenaAllocator) catch unreachable;
    const opts = options.Options.parse(arenaAllocator, &iter) catch return 1;

    const contents = std.Io.Dir.cwd().readFileAlloc(init.io, opts.inputs[0], arenaAllocator, .unlimited) catch return 1;
    var lexer = tokenizer.Tokenizer.init(contents);
    const lexResult = lexer.tokenize(arenaAllocator);
    if(lexResult == .failure) {
        _ = lexResult.failure.print(init.gpa, opts.inputs[0], contents);
        return 1;
    }

    var parse = parser.Parser.init(lexResult.success, arenaAllocator);
    const parseResult = parse.parse();
    if(parseResult == .failure) {
        _ = parseResult.failure.print(init.gpa, opts.inputs[0], contents);
        return 1;
    }

    const defaultTriple = c.LLVMGetDefaultTargetTriple();
    defer c.LLVMDisposeMessage(defaultTriple);

    const triple = arenaAllocator.dupeZ(u8, opts.target orelse std.mem.span(defaultTriple)) catch unreachable;

    var typeChecker = checker.TypeChecker.init(arenaAllocator);
    
    typeChecker.ctx.set("linux", .makeConstant(.makeType(.const_bool), .{
        .bool = std.mem.count(u8, triple, "linux") != 0,
    }));
    typeChecker.ctx.set("windows", .makeConstant(.makeType(.const_bool), .{
        .bool = std.mem.count(u8, triple, "windows") != 0,
    }));
    
    const checkerResult = typeChecker.infer(parseResult.success);
    if(checkerResult == .failure) {
        _ = checkerResult.failure.print(std.heap.smp_allocator, opts.inputs[0], contents);
        return 1;
    }
    if(opts.@"dump-ast") parseResult.success.print(0);

    var codeGen = codegen.CodeGenerator.init(arenaAllocator);
    _ = codeGen.visit(parseResult.success);

    _ = c.LLVMPrintModuleToFile(codeGen.module, "out.ll", null);

    var errorMessage: [*c]u8 = undefined;
    if(c.LLVMVerifyModule(codeGen.module, c.LLVMReturnStatusAction, &errorMessage) != 0) {
        std.debug.print("{s}\n", .{errorMessage});
        return 1;
    }

    var target: c.LLVMTargetRef = undefined;

    if(c.LLVMGetTargetFromTriple(@ptrCast(triple), &target, &errorMessage) != 0) {
        std.debug.print("{s}\n", .{errorMessage});
        return 1;
    }

    const passManagerOptions = c.LLVMCreatePassBuilderOptions();
    defer c.LLVMDisposePassBuilderOptions(passManagerOptions);
    const passes = std.fmt.allocPrintSentinel(arenaAllocator, "default<O{s}>", .{@tagName(opts.@"opt-level")}, 0) catch return 1;
    _ = c.LLVMRunPasses(codeGen.module, passes, null, passManagerOptions);

    const targetMachine = c.LLVMCreateTargetMachine(
        target, @ptrCast(triple),
        "generic", "",
        c.LLVMCodeGenLevelNone, c.LLVMRelocDefault, c.LLVMCodeModelDefault);
    defer c.LLVMDisposeTargetMachine(targetMachine);

    const outPath = arenaAllocator.dupeZ(u8, opts.output) catch unreachable;

    switch(opts.emit) {
        .@"llvm-ir" => {
            _ = c.LLVMPrintModuleToFile(codeGen.module, @ptrCast(outPath), null);
        },
        .@"asm" => {
            _ = c.LLVMTargetMachineEmitToFile(targetMachine, codeGen.module, @ptrCast(outPath), c.LLVMAssemblyFile, null);
        },
        .obj => {
            _ = c.LLVMTargetMachineEmitToFile(targetMachine, codeGen.module, @ptrCast(outPath), c.LLVMObjectFile, null);
        },
        .exec => {
            const objPath = std.fmt.allocPrintSentinel(arenaAllocator, "{s}.o", .{opts.output}, 0) catch unreachable;
            _ = c.LLVMTargetMachineEmitToFile(targetMachine, codeGen.module, @ptrCast(objPath), c.LLVMObjectFile, null);
            _ = std.process.run(arenaAllocator, io, .{
                .argv = &.{"LLVM/bin/clang", objPath, "-o", outPath},
            }) catch return 1;
            std.Io.Dir.cwd().deleteFile(io, objPath) catch unreachable;
        },
    }
    return 0;
}