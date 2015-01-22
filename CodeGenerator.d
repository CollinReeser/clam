import std.stdio;
import Function;
import typedecl;
import parser;
import visitor;
import std.conv;
import std.algorithm;
import std.array;
import std.range;
import ExprCodeGenerator;

// Since functions can return tuples, the function ABI is to place the return
// value into an assumed-allocated location just before where the arguments are
// placed. Note that arguments 0-5 are in registers rdi, rsi, rdx, rcx, r8, and
// r9. So, on the stack for a function call, we have:
// return value allocation
// arg8
// arg7
// arg6
// return address
// RBP
// beginning of available stack space

// The 64-bit ABI additionally guarantees 128 bytes of space below RSP that can
// be freely used by the function definition. Any sub's from RSP will continue
// to move this 128 byte space further downward. This space can only be
// considered "available" if this function call is a leaf call in the call tree.
// Otherwise, it'll get clobbered by a deeper function call. So if the call
// isn't a leaf call, stack space must be specifically allocated by sub's from
// RSP. The stack must be kept on a 16 byte alignment or else everything blows
// up

// Any operation that expects an expression value can be found on the top of the
// stack, save for the actual variable values, which are in register r8, or
// across r8 and r9 in the case of a fat ptr. A tuple will always be on the
// stack

// Listing of caller-saved vs. callee-saved registers
// Caller-Saved        Callee-Saved
// ------------        ------------
// rax                 rbx
// rcx                 rbp
// rdx                 r12
// rsi                 r13
// rdi                 r14
// rsp                 r15
// r8
// r9
// r10
// r11

const RBP_SIZE = 8;
const RETURN_ADDRESS_SIZE = 8;
const STACK_PROLOGUE_SIZE = RBP_SIZE + RETURN_ADDRESS_SIZE;
const ENVIRON_PTR_SIZE = 8;

const CLAM_PTR_SIZE = 8; // sizeof(char*))
const REF_COUNT_SIZE = 4; // sizeof(uint32_t))
const CLAM_STR_SIZE = 4; // sizeof(uint32_t))
const CHAN_VALID_SIZE = 4; // sizeof(uint32_t))
const STR_START_OFFSET = REF_COUNT_SIZE + CLAM_STR_SIZE;
const VARIANT_TAG_SIZE = 4; // sizeof(uint32_t))

const INT_REG = ["rdi", "rsi", "rdx", "rcx", "r8", "r9"];
const FLOAT_REG = ["xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6",
                   "xmm7"];
const STACK_RESTORE_PLACEHOLDER = "\n____STACK_RESTORE_PLACEHOLDER____\n";

debug (COMPILE_TRACE)
{
    string traceIndent;
    enum tracer =
        `
        string mixin_funcName = __FUNCTION__;
        writeln(traceIndent, "Entered: ", mixin_funcName);
        traceIndent ~= "  ";
        scope(success)
        {
            traceIndent = traceIndent[0..$-2];
            writeln(traceIndent, "Exiting: ", mixin_funcName);
        }
        `;
}

auto getIdentifier(IdentifierNode node)
{
    return (cast(ASTTerminal)node.children[0]).token;
}

auto getOffset(VarTypePair*[] vars, ulong index)
{
    return getAlignedIndexOffset(vars.map!(a => a.type.size).array, index);
}

auto getWordSize(ulong size)
{
    final switch (size)
    {
    case 1:  return "byte";
    case 2:  return "word";
    case 4:  return "dword";
    case 8:  return "qword";
    case 16: return "oword";
    }
}

auto getRRegSuffix(ulong size)
{
    final switch (size)
    {
    case 1: return "b";
    case 2: return "w";
    case 4: return "d";
    case 8: return "";
    }
}

string compileRegSave(string[] regs, Context* vars)
{
    auto str = "";
    foreach (i, reg; regs)
    {
        vars.allocateStackSpace(8);
        str ~= "    mov    qword [rbp-" ~ vars.getTop.to!string
                                        ~ "], "
                                        ~ reg
                                        ~ "\n";
    }
    return str;
}

// This function assumes it is being called on the same array of strings in the
// same order as a previous call on compileRegSave
string compileRegRestore(string[] regs, Context* vars)
{
    auto str = "";
    foreach_reverse (i, reg; regs)
    {
        str ~= "    mov    " ~ reg
                             ~ ", qword [rbp-"
                             ~ vars.getTop.to!string
                             ~ "]\n";
        vars.deallocateStackSpace(8);
    }
    return str;
}

// Get the power-of-2 size larger than the input size, for use in array size
// allocations. Arrays are always a power-of-2 in size.
// Credit: Henry S. Warren, Jr.'s "Hacker's Delight.", and Larry Gritz from
// http://stackoverflow.com/questions/364985/algorithm-for-finding-the-smallest-power-of-two-thats-greater-or-equal-to-a-giv
auto getAllocSize(ulong requestedSize)
{
    auto x = requestedSize;
    --x;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    x |= x >> 32;
    return x+1;
}

auto getStructAllocSize(StructType* type)
{
    return REF_COUNT_SIZE
        + type.members
              .map!(a => a.type.size)
              .array
              .getAlignedSize;
}

auto getVariantAllocSize(VariantType* type)
{
    return REF_COUNT_SIZE
         + VARIANT_TAG_SIZE
         + type.members
               .map!(a => a.constructorElems.size)
               .array
               .reduce!((a, b) => max(a, b));
}

// Derived from "gcc -S -O2" on:
// unsigned long long getAllocSize(unsigned long long x)
// {
//     --x;
//     x |= x >> 1;
//     x |= x >> 2;
//     x |= x >> 4;
//     x |= x >> 8;
//     x |= x >> 16;
//     x |= x >> 32;
//     return x+1;
// }
string getAllocSizeAsm(string inReg, string outReg)
in {
    assert(inReg != outReg, "inReg must be a different register than outReg");
}
body {
    auto str = "";
    str ~= "    sub    " ~ inReg ~ ", 1\n";
    str ~= "    mov    " ~ outReg ~ ", " ~ inReg ~ "\n";
    str ~= "    shr    " ~ outReg ~ ", 1\n";
    str ~= "    or     " ~ outReg ~ ", " ~ inReg ~ "\n";
    str ~= "    mov    " ~ inReg ~ ", " ~ outReg ~ "\n";
    str ~= "    shr    " ~ inReg ~ ", 2\n";
    str ~= "    or     " ~ outReg ~ ", " ~ inReg ~ "\n";
    str ~= "    mov    " ~ inReg ~ ", " ~ outReg ~ "\n";
    str ~= "    shr    " ~ inReg ~ ", 4\n";
    str ~= "    or     " ~ outReg ~ ", " ~ inReg ~ "\n";
    str ~= "    mov    " ~ inReg ~ ", " ~ outReg ~ "\n";
    str ~= "    shr    " ~ inReg ~ ", 8\n";
    str ~= "    or     " ~ outReg ~ ", " ~ inReg ~ "\n";
    str ~= "    mov    " ~ inReg ~ ", " ~ outReg ~ "\n";
    str ~= "    shr    " ~ inReg ~ ", 16\n";
    str ~= "    or     " ~ outReg ~ ", " ~ inReg ~ "\n";
    str ~= "    mov    " ~ inReg ~ ", " ~ outReg ~ "\n";
    str ~= "    shr    " ~ inReg ~ ", 32\n";
    str ~= "    or     " ~ outReg ~ ", " ~ inReg ~ "\n";
    str ~= "    add    " ~ outReg ~ ", 1\n";
    return str;
}

unittest
{
    assert(0.getAllocSize == 0);
    assert(1.getAllocSize == 1);
    assert(2.getAllocSize == 2);
    assert(3.getAllocSize == 4);
    assert(4.getAllocSize == 4);
    assert(6.getAllocSize == 8);
    assert(1002.getAllocSize == 1024);
}

auto toNasmDataString(string input)
{
    auto str = "`";
    //foreach (c; input)
    //{
    //    switch (c)
    //    {
    //    case ' ': .. case '~': str ~= c;
    //    }
    //}
    str ~= input;
    str ~= "`, 0";
    return str;
}

struct DataEntry
{
    string label;
    string data;

    static auto toNasmDataString(string input)
    {
        auto str = "`";
        //foreach (c; input)
        //{
        //    switch (c)
        //    {
        //    case ' ': .. case '~': str ~= c;
        //    }
        //}
        str ~= input;
        str ~= "`, 0";
        return str;
    }
}

struct FloatEntry
{
    string label;
    string floatStr;
}

struct Context
{
    DataEntry*[] dataEntries;
    FloatEntry*[] floatEntries;
    string[] blockEndLabels;
    string[] blockNextLabels;
    bool[string] runtimeExterns;
    bool[string] bssQWordAllocs;
    FuncSig*[string] externFuncs;
    FuncSig*[string] compileFuncs;
    StructType*[string] structDefs;
    VariantType*[string] variantDefs;
    VarTypePair*[] closureVars;
    VarTypePair*[] funcArgs;
    VarTypePair*[] stackVars;
    Type* retType;
    // Set when calculating l-value addresses, to determine how the assignment
    // should be made
    bool isStackAligned;
    uint reservedStackSpace;
    uint maxTempSpaceUsed;
    private uint topOfStack;
    private uint uniqLabelCounter;
    private uint uniqDataCounter;

    void resetState(FuncSig* sig)
    {
        closureVars = sig.closureVars;
        funcArgs = [];
        stackVars = [];
        topOfStack = 0;
        reservedStackSpace = sig.stackVarAllocSize;
        maxTempSpaceUsed = 0;
        retType = sig.returnType;
        uniqLabelCounter = 0;
    }

    auto getUniqDataLabel()
    {
        return "__S" ~ (uniqDataCounter++).to!string;
    }

    auto getUniqLabel()
    {
        return ".L" ~ (uniqLabelCounter++).to!string;
    }

    auto getTop()
    {
        return reservedStackSpace + topOfStack;
    }

    void allocateStackSpace(uint bytes)
    {
        topOfStack += bytes;
        if (topOfStack > maxTempSpaceUsed)
        {
            maxTempSpaceUsed = topOfStack;
        }
    }

    void deallocateStackSpace(uint bytes)
    {
        topOfStack -= bytes;
    }

    bool isStackAlignedVar(string varName)
    {
        foreach (var; stackVars)
        {
            if (var.varName == varName)
            {
                return true;
            }
        }
        foreach (var; funcArgs)
        {
            if (var.varName == varName)
            {
                return true;
            }
        }
        return false;
    }

    bool isFuncName(string name)
    {
        foreach (func; externFuncs.values)
        {
            if (func.funcName == name)
            {
                return true;
            }
        }
        foreach (func; compileFuncs.values)
        {
            if (func.funcName == name)
            {
                return true;
            }
        }
        return false;
    }

    // Either the value of the variable is in r8, implying that the type is
    // either 1, 2, 4, or 8 bytes, or it is split between r8 and r9, where
    // r8 is the environment portion of a fat pointer, and r9 is the function
    // pointer itself. Because we've passed the typecheck stage, we're
    // guaranteed that lookup will succeed
    string compileVarGet(string varName)
    {
        const environOffset = (closureVars.length > 0)
                           ? ENVIRON_PTR_SIZE
                           : 0;
        const retValOffset = retType.size;
        foreach (i, var; funcArgs)
        {
            if (varName == var.varName)
            {
                if (var.type.size <= 8)
                {
                    return "    mov    r8, qword [rbp+"
                        ~ (STACK_PROLOGUE_SIZE + environOffset + retValOffset +
                           getOffset(funcArgs, i)).to!string ~ "]\n";
                }
                return "    mov    r8, qword [rbp+"
                    ~ (STACK_PROLOGUE_SIZE + environOffset + retValOffset +
                       getOffset(funcArgs, i)).to!string ~ "]\n"
                    ~ "    mov    r9, qword [rbp+"
                    ~ (STACK_PROLOGUE_SIZE + environOffset + retValOffset +
                       getOffset(funcArgs, i) + 8).to!string ~ "]\n";
            }
        }
        foreach (i, var; closureVars)
        {
            if (varName == var.varName)
            {
                auto str = "    mov    r10, [rbp+8]\n";
                if (var.type.size <= 8)
                {
                    str ~= "    mov    r8, qword [r10+"
                        ~ getOffset(closureVars, i).to!string ~ "]\n";
                    return str;
                }
                str ~= "    mov    r8, qword [r10+"
                    ~ getOffset(funcArgs, i).to!string ~ "]\n"
                    ~ "    mov    r9, qword [r10+"
                    ~ getOffset(funcArgs, i).to!string ~ "]\n";
                return str;
            }
        }
        foreach (i, var; stackVars)
        {
            if (varName == var.varName)
            {
                if (var.type.size <= 8)
                {
                    return "    mov    r8, qword [rbp-"
                        ~ ((i + 1) * 8).to!string ~ "]\n";
                }
                return "    mov    r8, qword [rbp-"
                    ~ ((i + 1) * 8).to!string ~ "]\n"
                    ~ "    mov    r9, qword [rbp-"
                    ~ ((i + 1) * 8 + 8).to!string ~ "]\n";
            }
        }
        assert(false);
        return "";
    }

    string compileVarAddress(string varName)
    {
        const environOffset = (closureVars.length > 0)
                           ? ENVIRON_PTR_SIZE
                           : 0;
        const retValOffset = retType.size;
        foreach (i, var; funcArgs)
        {
            if (varName == var.varName)
            {
                if (var.type.size <= 8)
                {
                    return "    mov    r8, rbp\n"
                         ~ "    add    r8, "
                         ~ (STACK_PROLOGUE_SIZE
                            + environOffset
                            + retValOffset
                            + getOffset(funcArgs, i)).to!string
                         ~ "\n";
                }
                return "    mov    r8, rbp\n"
                     ~ "    add    r8, "
                     ~ (STACK_PROLOGUE_SIZE
                        + environOffset
                        + retValOffset
                        + getOffset(funcArgs, i)).to!string
                     ~ "\n"
                     ~ "    mov    r9, rbp\n"
                     ~ "    add    r9, "
                     ~ (STACK_PROLOGUE_SIZE
                        + environOffset
                        + retValOffset
                        + getOffset(funcArgs, i) + 8).to!string
                     ~ "\n";
            }
        }
        foreach (i, var; closureVars)
        {
            if (varName == var.varName)
            {
                auto str = "    mov    r10, [rbp+8]\n";
                if (var.type.size <= 8)
                {
                    str ~= "    mov    r8, r10\n";
                    str ~= "    add    r8, "
                        ~ getOffset(closureVars, i).to!string ~ "\n";
                    return str;
                }
                str ~= "    mov    r8, r10\n";
                str ~= "    add    r8, " ~ getOffset(funcArgs, i).to!string
                                         ~ "\n";
                str ~= "    mov    r9, r10\n";
                str ~= "    add    r9, " ~ getOffset(funcArgs, i).to!string
                                         ~ "\n";
                return str;
            }
        }
        foreach (i, var; stackVars)
        {
            if (varName == var.varName)
            {
                if (var.type.size <= 8)
                {
                    return "    mov    r8, rbp\n"
                         ~ "    sub    r8, " ~ ((i + 1) * 8).to!string ~ "\n";
                }
                return "    mov    r8, rbp\n"
                     ~ "    sub    r8, " ~ ((i + 1) * 8).to!string ~ "\n"
                     ~ "    mov    r9, rbp\n"
                     ~ "    sub    r9, " ~ ((i + 1) * 8 + 8).to!string ~ "]n";
            }
        }
        assert(false);
        return "";
    }

    // We assume that the value we're setting is either in r8, when the type is
    // 1, 2, 4, or 8 bytes, or it is split across r8 and r9 in the case of a fat
    // pointer. We then store the value back into its allocated memory location
    string compileVarSet(string varName)
    {
        const environOffset = (closureVars.length > 0)
                           ? ENVIRON_PTR_SIZE
                           : 0;
        const retValOffset = retType.size;
        foreach (i, var; funcArgs)
        {
            if (varName == var.varName)
            {
                if (var.type.size <= 8)
                {
                    return "    mov    qword [rbp+"
                        ~ (STACK_PROLOGUE_SIZE + environOffset + retValOffset +
                           getOffset(funcArgs, i)).to!string ~ "], r8\n";
                }
                return "    mov    qword [rbp+"
                    ~ (STACK_PROLOGUE_SIZE + environOffset + retValOffset +
                       getOffset(funcArgs, i)).to!string ~ "], r8\n"
                    ~ "    mov    qword [rbp+"
                    ~ (STACK_PROLOGUE_SIZE + environOffset + retValOffset +
                       getOffset(funcArgs, i) + 8).to!string ~ "], r9\n";
            }
        }
        foreach (i, var; closureVars)
        {
            if (varName == var.varName)
            {
                auto str = "    mov    r10, [rbp+" ~ 8.to!string ~ "]\n";
                if (var.type.size <= 8)
                {
                    str ~= "    mov    qword [r10+"
                        ~ getOffset(closureVars, i).to!string ~ "], r8\n";
                    return str;
                }
                str ~= "    mov    qword [r10+"
                    ~ getOffset(funcArgs, i).to!string ~ "], r8\n"
                    ~ "    mov    qword [r10+"
                    ~ getOffset(funcArgs, i).to!string ~ "], r9\n";
                return str;
            }
        }
        foreach (i, var; stackVars)
        {
            if (varName == var.varName)
            {
                if (var.type.size <= 8)
                {
                    return "    mov    qword [rbp-"
                        ~ ((i + 1) * 8).to!string ~ "], r8\n";
                }
                return "    mov    qword [rbp-"
                    ~ ((i + 1) * 8).to!string ~ "], r8\n"
                    ~ "    mov    qword [rbp-"
                    ~ ((i + 1) * 8 + 8).to!string ~ "], r9\n";
            }
        }
        assert(false);
        return "";
    }
}

string compileFunction(FuncSig* sig, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto funcHeader = "";
    funcHeader ~= sig.funcName ~ ":\n";
    funcHeader ~= "    push   rbp         ; set up stack frame\n";
    funcHeader ~= "    mov    rbp, rsp\n";
    auto funcHeader_2 = "";
    auto intRegIndex = 0;
    auto floatRegIndex = 0;
    vars.resetState(sig);
    foreach (arg; sig.funcArgs)
    {
        if (arg.type.isFloat)
        {
            if (floatRegIndex >= FLOAT_REG.length)
            {
                vars.funcArgs ~= arg;
            }
            else
            {
                vars.stackVars ~= arg;
                funcHeader_2 ~= "    movsd  qword [rbp-" ~ vars.getTop
                                                               .to!string
                                                 ~ "], "
                                                 ~ FLOAT_REG[floatRegIndex]
                                                 ~ "\n";
                floatRegIndex++;
            }
        }
        else
        {
            if (intRegIndex >= INT_REG.length)
            {
                vars.funcArgs ~= arg;
            }
            else
            {
                vars.stackVars ~= arg;
                funcHeader_2 ~= "    mov    qword [rbp-" ~ vars.getTop
                                                               .to!string
                                                 ~ "], "
                                                 ~ INT_REG[intRegIndex]
                                                 ~ "\n";
                intRegIndex++;
            }
        }
    }
    auto funcDef = compileBlock(
        cast(BareBlockNode)sig.funcBodyBlocks.children[0], vars
    );
    // Determine the total amount of stack space used by the function at max
    auto totalStackSpaceUsed = sig.stackVarAllocSize + vars.maxTempSpaceUsed;
    // Allocate space on the stack, keeping the stack in 16-byte alignment
    auto stackAlignedAlloc = totalStackSpaceUsed + (totalStackSpaceUsed % 16);
    auto stackRestoreStr = "    add    rsp, " ~ stackAlignedAlloc.to!string
                                           ~ "\n";
    funcHeader ~= "    sub    rsp, " ~ stackAlignedAlloc.to!string ~ "\n";
    funcDef = replace(funcDef, STACK_RESTORE_PLACEHOLDER, stackRestoreStr);
    auto funcFooter = "";
    funcFooter ~= stackRestoreStr;
    funcFooter ~= "    mov    rsp, rbp    ; takedown stack frame\n";
    funcFooter ~= "    pop    rbp\n";
    funcFooter ~= "    ret\n";
    return funcHeader ~ funcHeader_2 ~ funcDef ~ funcFooter;
}

string compileBlock(BareBlockNode block, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto code = "";
    foreach (statement; block.children)
    {
        code ~= compileStatement(cast(StatementNode)statement, vars);
    }
    return code;
}

string compileStatement(StatementNode statement, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto child = statement.children[0];
    if (cast(BareBlockNode)child)
        return compileBlock(cast(BareBlockNode)child, vars);
    else if (cast(ReturnStmtNode)child)
        return compileReturn(cast(ReturnStmtNode)child, vars);
    else if (cast(IfStmtNode)child)
        return compileIfStmt(cast(IfStmtNode)child, vars);
    else if (cast(WhileStmtNode)child)
        return compileWhileStmt(cast(WhileStmtNode)child, vars);
    else if (cast(ForStmtNode)child)
        return compileForStmt(cast(ForStmtNode)child, vars);
    else if (cast(ForeachStmtNode)child)
        return compileForeachStmt(cast(ForeachStmtNode)child, vars);
    else if (cast(MatchStmtNode)child)
        return compileMatchStmt(cast(MatchStmtNode)child, vars);
    else if (cast(DeclarationNode)child)
        return compileDeclaration(cast(DeclarationNode)child, vars);
    else if (cast(AssignExistingNode)child)
        return compileAssignExisting(cast(AssignExistingNode)child, vars);
    else if (cast(SpawnStmtNode)child)
        return compileSpawnStmt(cast(SpawnStmtNode)child, vars);
    else if (cast(YieldStmtNode)child)
        return compileYieldStmt(cast(YieldStmtNode)child, vars);
    else if (cast(ChanWriteNode)child)
        return compileChanWrite(cast(ChanWriteNode)child, vars);
    else if (cast(FuncCallNode)child)
        return compileFuncCall(cast(FuncCallNode)child, vars);
    assert(false);
    return "";
}

string compileReturn(ReturnStmtNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    if (node.children.length == 0)
    {
       return STACK_RESTORE_PLACEHOLDER
            ~ "    mov    rsp, rbp    ; takedown stack frame\n"
            ~ "    pop    rbp\n"
            ~ "    ret\n";
    }
    const environOffset = (vars.closureVars.length > 0)
                        ? ENVIRON_PTR_SIZE
                        : 0;
    auto str = "";
    str ~= compileExpression(cast(BoolExprNode)node.children[0], vars);
    if (vars.retType.size <= 8)
    {
        str ~= "    mov    rax, r8\n";
    }
    // Handle the fat ptr case
    else if (vars.retType.size == 16)
    {

    }
    // Handle the tuple case
    else
    {

    }
    str ~= STACK_RESTORE_PLACEHOLDER;
    str ~= "    mov    rsp, rbp    ; takedown stack frame\n";
    str ~= "    pop    rbp\n";
    str ~= "    ret\n";
    return str;
}

string compileIfStmt(IfStmtNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto str = "";
    str ~= compileCondAssignments(
        cast(CondAssignmentsNode)node.children[0], vars
    );
    if (cast(IsExprNode)node.children[1])
    {
        str ~= compileIsExpr(cast(IsExprNode)node.children[1], vars);
    }
    else
    {
        str ~= compileBoolExpr(cast(BoolExprNode)node.children[1], vars);
    }
    auto blockEndLabel = vars.getUniqLabel();
    auto blockNextLabel = vars.getUniqLabel();
    vars.blockEndLabels ~= blockEndLabel;
    str ~= "    cmp    r8, 0\n";
    // If it's zero, then it's false, meaning go to the next label
    str ~= "    je     " ~ blockNextLabel ~ "\n";
    str ~= compileBlock(cast(BareBlockNode)node.children[2], vars);
    str ~= "    jmp    " ~ blockEndLabel ~ "\n";
    str ~= blockNextLabel ~ ":\n";
    str ~= compileElseIfs(cast(ElseIfsNode)node.children[3], vars);
    str ~= compileElseStmt(cast(ElseStmtNode)node.children[4], vars);
    str ~= blockEndLabel ~ ":\n";
    vars.blockEndLabels.length--;
    return str;
}

string compileElseIfs(ElseIfsNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto str = "";
    foreach (child; node.children)
    {
        str ~= compileElseIfStmt(cast(ElseIfStmtNode)child, vars);
    }
    return str;
}

string compileElseIfStmt(ElseIfStmtNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto str = "";
    str ~= compileCondAssignments(
        cast(CondAssignmentsNode)node.children[0], vars
    );
    if (cast(IsExprNode)node.children[1])
    {
        str ~= compileIsExpr(cast(IsExprNode)node.children[1], vars);
    }
    else
    {
        str ~= compileBoolExpr(cast(BoolExprNode)node.children[1], vars);
    }
    auto blockNextLabel = vars.getUniqLabel();
    str ~= "    cmp    r8, 0\n";
    // If it's zero, then it's false, meaning go to the next label
    str ~= "    je     " ~ blockNextLabel ~ "\n";
    str ~= compileBlock(cast(BareBlockNode)node.children[2], vars);
    str ~= "    jmp    " ~ vars.blockEndLabels[$-1] ~ "\n";
    str ~= blockNextLabel ~ ":\n";
    return str;
}

string compileElseStmt(ElseStmtNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto str = "";
    if (node.children.length > 0)
    {
        str ~= compileBlock(cast(BareBlockNode)node.children[0], vars);
    }
    return str;
}

string compileWhileStmt(WhileStmtNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto blockLoopLabel = vars.getUniqLabel();
    auto blockEndLabel = vars.getUniqLabel();
    auto str = "";
    str ~= compileCondAssignments(
        cast(CondAssignmentsNode)node.children[0], vars
    );
    str ~= blockLoopLabel ~ ":\n";
    if (cast(IsExprNode)node.children[1])
    {
        str ~= compileIsExpr(cast(IsExprNode)node.children[1], vars);
    }
    else
    {
        str ~= compileBoolExpr(cast(BoolExprNode)node.children[1], vars);
    }
    str ~= "    cmp    r8, 0\n";
    // If it's zero, then it's false, meaning don't enter the loop
    str ~= "    je     " ~ blockEndLabel ~ "\n";
    str ~= compileBlock(cast(BareBlockNode)node.children[2], vars);
    str ~= "    jmp    " ~ blockLoopLabel ~ "\n";
    str ~= blockEndLabel ~ ":\n";
    return str;
}

string compileForStmt(ForStmtNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    return "";
}

string compileForeachStmt(ForeachStmtNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto str = "";
    auto loopType = node.data["type"].get!(Type*);
    auto foreachArgs = node.data["argnames"].get!(string[]);
    auto hasIndex = node.data["hasindex"].get!(bool);
    auto indexVarName = "";
    if (hasIndex)
    {
        indexVarName = foreachArgs[0];
        foreachArgs = foreachArgs[1..$];
        auto indexType = new Type();
        indexType.tag = TypeEnum.INT;
        auto indexVar = new VarTypePair();
        indexVar.varName = indexVarName;
        indexVar.type = indexType;
        vars.stackVars ~= indexVar;
    }
    str ~= compileBoolExpr(cast(BoolExprNode)node.children[1], vars);
    if (loopType.tag == TypeEnum.ARRAY)
    {
        auto loopVarName = foreachArgs[0];
        auto loopVar = new VarTypePair();
        loopVar.varName = loopVarName;
        loopVar.type = loopType.array.arrayType.copy;
        vars.stackVars ~= loopVar;
        auto elemSize = loopType.array.arrayType.size;
        vars.allocateStackSpace(8);
        auto arrayLoc = vars.getTop.to!string;
        vars.allocateStackSpace(8);
        auto countLoc = vars.getTop.to!string;
        scope (exit) vars.deallocateStackSpace(16);
        auto foreachLoop = vars.getUniqLabel;
        auto endForeach = vars.getUniqLabel;
        // The array is in r8
        // Initialize internal count variable
        str ~= "    mov    r10, 0\n";
        str ~= foreachLoop ~ ":\n";
        // Set the index variable if there is one
        if (hasIndex)
        {
            // Save value in r8
            str ~= "    mov    r11, r8\n";
            // Set index value with counter value
            str ~= "    mov    r8, r10\n";
            str ~= vars.compileVarSet(indexVarName);
            // Restore value in r8
            str ~= "    mov    r8, r11\n";
        }
        // Get the array size
        str ~= "    mov    r9, 0\n";
        str ~= "    mov    r9d, dword [r8+4]\n";
        str ~= "    cmp    r10, r9\n";
        str ~= "    jge    " ~ endForeach
                             ~ "\n";
        str ~= "    mov    qword [rbp-" ~ countLoc
                                        ~ "], r10\n";
        // Multiply counter by size of the array elements to get the elem offset
        str ~= "    imul   r10, " ~ elemSize.to!string
                                  ~ "\n";
        // Add 8 to get past the ref count and array length bytes
        str ~= "    add    r10, 8\n";
        // Actually add in the array pointer value
        str ~= "    add    r10, r8\n";
        // Get the element in r11
        str ~= "    mov    r11" ~ getRRegSuffix(elemSize)
                                ~ ", "
                                ~ getWordSize(elemSize)
                                ~ " [r10]\n";
        // Preserve the array
        str ~= "    mov    qword [rbp-" ~ arrayLoc
                                        ~ "], r8\n";
        // Set the loop var
        str ~= "    mov    r8, r11\n";
        str ~= vars.compileVarSet(loopVarName);
        str ~= compileBlock(cast(BareBlockNode)node.children[2], vars);
        // Restore counter and array
        str ~= "    mov    r8, qword [rbp-" ~ arrayLoc
                                            ~ "]\n";
        str ~= "    mov    r10, qword [rbp-" ~ countLoc
                                             ~ "]\n";
        str ~= "    add    r10, 1\n";
        str ~= "    jmp    " ~ foreachLoop
                             ~ "\n";
        str ~= endForeach ~ ":\n";
    }
    else if (loopType.tag == TypeEnum.TUPLE)
    {
        // TODO After we've determined how tuples are handled, this is
        // basically just the ARRAY case but for more than one variable. Also
        // need to determine if it's a runtime error for the arrays to not all
        // be the same length, or if it just ends after the first array is
        // exhausted
    }
    return str;
}

string compileMatchStmt(MatchStmtNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    return "";
}

string compileDeclaration(DeclarationNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto child = node.children[0];
    if (cast(DeclTypeInferNode)child) {
        return compileDeclTypeInfer(cast(DeclTypeInferNode)child, vars);
    }
    else if (cast(DeclAssignmentNode)child) {
        return compileDeclAssignment(cast(DeclAssignmentNode)child, vars);
    }
    else if (cast(VariableTypePairNode)child) {
        return compileVariableTypePair(cast(VariableTypePairNode)child, vars);
    }
    return "";
}

string compileDeclTypeInfer(DeclTypeInferNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto left = node.children[0];
    auto right = node.children[1];
    auto str = compileExpression(cast(BoolExprNode)right, vars);
    auto type = right.data["type"].get!(Type*);
    if (cast(IdentifierNode)left)
    {
        auto varName = getIdentifier(cast(IdentifierNode)left);
        auto var = new VarTypePair;
        var.varName = varName;
        var.type = type;
        vars.stackVars ~= var;
        // Increase the ref-count by 1 for dynamically allocated types
        if (type.tag == TypeEnum.ARRAY || type.tag == TypeEnum.STRING
            || type.tag == TypeEnum.VARIANT || type.tag == TypeEnum.STRUCT
            || type.tag == TypeEnum.HASH || type.tag == TypeEnum.SET)
        {
            str ~= "    add    dword [r8], 1\n";
        }
        // Note the use of str in the expression, which is why we're not ~=ing
        str = "    ; var infer assign [" ~ varName
                                         ~ "]\n"
                                         ~ str
                                         ~ vars.compileVarSet(varName);
    }
    else
    {

    }
    return str;
}

string compileVariableTypePair(VariableTypePairNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto str = "";
    auto pair = node.data["pair"].get!(VarTypePair*);
    vars.stackVars ~= pair;
    final switch (pair.type.tag)
    {
    case TypeEnum.STRING:
        str ~= "    ; allocate empty string\n";
        str ~= "    mov    rdi, " ~ (REF_COUNT_SIZE
                                   + CLAM_STR_SIZE).to!string
                                  ~ "\n";
        str ~= "    call   malloc\n";
        // Set the refcount to 1, as we're assigning this empty string to a
        // variable
        str ~= "    mov    dword [rax], 1\n";
        // Set the length of the string, where the string size location is just
        // past the ref count
        str ~= "    mov    dword [rax+" ~ REF_COUNT_SIZE.to!string
                                        ~ "], 0\n";
        // The string value ptr sits in r8
        str ~= "    mov    r8, rax\n";
        break;
    case TypeEnum.SET:
        break;
    case TypeEnum.HASH:
        break;
    case TypeEnum.ARRAY:
        auto elemSize = pair.type.array.arrayType.size;
        auto typeIdNode = cast(TypeIdNode)node.children[1];
        auto arrayTypeNode = cast(ArrayTypeNode)typeIdNode.children[0];
        if (arrayTypeNode.children.length > 1)
        {
            auto allocBoolExpr = cast(BoolExprNode)arrayTypeNode.children[0];
            str ~= compileBoolExpr(allocBoolExpr, vars);
            vars.allocateStackSpace(8);
            scope (exit) vars.deallocateStackSpace(8);
            auto arrayLenLoc = vars.getTop.to!string;
            str ~= "    mov    qword [rbp-" ~ arrayLenLoc ~ "], r8\n";
            auto allocLength = getAllocSizeAsm("r8", "rdi");
            str ~= "    imul   rdi, " ~ elemSize.to!string ~ "\n";
            str ~= "    add    rdi, 8\n";
            str ~= "    call   malloc\n";
            // Set the refcount to 1, as we're assigning this array to a
            // variable
            str ~= "    mov    dword [rax], 1\n";
            // Retrive the array length value
            str ~= "    mov    r8, qword [rbp-" ~ arrayLenLoc ~ "]\n";
            // Set array length to number of elements
            str ~= "    mov    dword [rax+4], r8d\n";
            str ~= "    mov    r8, rax\n";
        }
        else
        {
            str ~= "    mov    rdi, 8\n";
            str ~= "    call   malloc\n";
            str ~= "    mov    dword [rax], 1\n";
            str ~= "    mov    dword [rax+4], 0\n";
            str ~= "    mov    r8, rax\n";
        }
        break;
    case TypeEnum.FUNCPTR:
        break;
    case TypeEnum.STRUCT:
        str ~= "    mov    rdi, " ~ getStructAllocSize(
                                        pair.type.structDef
                                    ).to!string
                                  ~ "\n";
        str ~= "    call   malloc\n";
        // Set the refcount to 1, as we're assigning this array to a variable
        str ~= "    mov    dword [rax], 1\n";
        str ~= "    mov    r8, rax\n";
        break;
    case TypeEnum.VARIANT:
        break;
    case TypeEnum.CHAN:
        auto elemSize = pair.type.chan.chanType.size;
        auto totalAllocSize = REF_COUNT_SIZE
                            + CHAN_VALID_SIZE
                            + elemSize;
        str ~= "    mov    rdi, " ~ totalAllocSize.to!string
                                  ~ "\n";
        str ~= "    call   malloc\n";
        // Set the refcount to 1, as we're assigning this chan to a variable
        str ~= "    mov    dword [rax], 1\n";
        // Set chan valid-element segment to false
        str ~= "    mov    dword [rax+4], 0\n";
        str ~= "    mov    r8, rax\n";
        break;
    case TypeEnum.LONG:
    case TypeEnum.INT:
    case TypeEnum.SHORT:
    case TypeEnum.BYTE:
    case TypeEnum.CHAR:
    case TypeEnum.BOOL:
        str ~= "    mov    r8, 0\n";
        break;
    case TypeEnum.FLOAT:
    case TypeEnum.DOUBLE:
        break;
    case TypeEnum.TUPLE:
    case TypeEnum.AGGREGATE:
    case TypeEnum.VOID:
        break;
    }
    str ~= vars.compileVarSet(pair.varName);
    return str;
}

string compileAssignExisting(AssignExistingNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto str = "";
    auto op = (cast(ASTTerminal)node.children[1]).token;
    auto leftType = node.children[0].data["type"].get!(Type*);
    auto rightType = node.children[2].data["type"].get!(Type*);
    str ~= compileBoolExpr(cast(BoolExprNode)node.children[2], vars);
    // Set the refcount for array and string temporaries to 1, since we're
    // actually storing the value now
    if (rightType.tag == TypeEnum.ARRAY || rightType.tag == TypeEnum.STRING)
    {
        auto label = vars.getUniqLabel();
        str ~= "    cmp    dword [r8], 0\n";
        str ~= "    jnz    " ~ label ~ "\n";
        str ~= "    mov    dword [r8], 1\n";
        str ~= label ~ ":\n";
    }
    vars.allocateStackSpace(8);
    auto valLoc = vars.getTop.to!string;
    str ~= "    mov    qword [rbp-" ~ valLoc ~ "], r8\n";
    // Assume it's true to begin with
    vars.isStackAligned = true;
    str ~= compileLorRValue(cast(LorRValueNode)node.children[0], vars);
    str ~= "    mov    r9, qword [rbp-" ~ valLoc ~ "]\n";
    vars.deallocateStackSpace(8);
    final switch (op)
    {
    case "=":
        if (vars.isStackAligned)
        {
            str ~= "    mov    qword [r8], r9\n";
        }
        else
        {
            str ~= "    mov    " ~ getWordSize(rightType.size)
                                 ~ " [r8], r9"
                                 ~ getRRegSuffix(rightType.size) ~ "\n";
        }
        break;
    case "+=":
        assert(false, "Unimplemented");
        break;
    case "-=":
        assert(false, "Unimplemented");
        break;
    case "/=":
        assert(false, "Unimplemented");
        break;
    case "*=":
        assert(false, "Unimplemented");
        break;
    case "%=":
        assert(false, "Unimplemented");
        break;
    case "~=":
        str ~= compileAppendEquals(leftType, rightType, vars);
        break;
    }
    return str;
}

// The _address_ of the pointer is in r8, and the new element is in r9
string compileAppendEquals(Type* leftType, Type* rightType, Context* vars)
{
    auto str = "";
    if (leftType.tag == TypeEnum.STRING)
    {
        if (leftType.cmp(rightType))
        {
            str ~= compileStringStringAppendEquals(vars);
        }
        else
        {
            str ~= compileStringCharAppendEquals(vars);
        }
    }
    else
    {
        if (leftType.cmp(rightType))
        {
            str ~= compileArrayArrayAppendEquals(
                vars,
                rightType.array.arrayType.size
            );
        }
        else
        {
            str ~= compileArrayElemAppendEquals(vars, rightType.size);
        }
    }
    return str;
}

string compileStringStringAppendEquals(Context* vars)
{
    auto str = "";
    assert(false, "Unimplemented");
    return "";
}

string compileStringCharAppendEquals(Context* vars)
{
    auto str = "";
    assert(false, "Unimplemented");
    return str;
}

string compileArrayArrayAppendEquals(Context* vars, uint typeSize)
{
    auto str = "";
    assert(false, "Unimplemented");
    return str;
}

string compileArrayElemAppendEquals(Context* vars, uint typeSize)
{
    auto str = "";
    // Get actual array pointer from the address of the pointer in r8
    str ~= "    mov    r13, [r8]\n";
    // Get array length
    str ~= "    mov    r10, 0\n";
    str ~= "    mov    r10d, dword [r13+4]\n";
    // Get alloc size in r12
    str ~= "    mov    r11, r10\n";
    str ~= getAllocSizeAsm("r11", "r12");
    // Restore array length in r11
    str ~= "    mov    r11, r10\n";
    // Get the total array size and the total array alloc size
    str ~= "    imul   r11, " ~ typeSize.to!string ~ "\n";
    str ~= "    imul   r12, " ~ typeSize.to!string ~ "\n";
    // If they're the same size, the array is full and needs to be realloc'd,
    // otherwise we can just stick the new element in the next available slot
    str ~= "    cmp    r11, r12\n";
    auto newAlloc = vars.getUniqLabel;
    str ~= "    je     " ~ newAlloc ~ "\n";
    // Move the new element in r9 into the next empty spot in the array in r13
    str ~= "    add    r11, 8\n";
    str ~= "    add    r11, r13\n";
    str ~= "    mov    " ~ getWordSize(typeSize)
                         ~ " [r11], r9"
                         ~ getRRegSuffix(typeSize)
                         ~ "\n";
    // Increment array length
    str ~= "    add    dword [r13+4], 1\n";
    auto endAppend = vars.getUniqLabel;
    str ~= "    jmp    " ~ endAppend ~ "\n";
    str ~= newAlloc ~ ":\n";
    // If we get here, the array is full, and needs to be realloc'd with more
    // space. r11 and r12 are the same value, so if we just increment one of
    // them by the size of one array element and then pass it through the
    // alloc size algorithm, we'll get the new alloc size, one step larger.
    // The array length is still in r10
    str ~= "    add    r11, 1\n";
    str ~= getAllocSizeAsm("r11", "rsi");
    // Add back the ref count and array length portions
    str ~= "    add    rsi, 8\n";
    // r13 contains the original array pointer
    str ~= "    mov    rdi, r13\n";
    str ~= compileRegSave(["r8", "r9", "r12"], vars);
    str ~= "    call   realloc\n";
    str ~= compileRegRestore(["r8", "r9", "r12"], vars);
    // r12 still contains the old array alloc length, which happens to be where
    // the new element needs to go, minus the ref count and array length offset
    str ~= "    add    r12, 8\n";
    // Add in the actual array pointer
    str ~= "    add    r12, rax\n";
    // Mov the new element into its spot
    str ~= "    mov    " ~ getWordSize(typeSize)
                         ~ " [r12], r9"
                         ~ getRRegSuffix(typeSize)
                         ~ "\n";
    // Increment realloc'd array length
    str ~= "    add    dword [rax+4], 1\n";
    // r8 contains the address within which the array pointer is stored, so
    // we can just shove the new rax pointer back into [r8]
    str ~= "    mov    qword [r8], rax\n";
    str ~= endAppend ~ ":\n";
    return str;
}

string compileLorRValue(LorRValueNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto str = "";
    auto id = getIdentifier(cast(IdentifierNode)node.children[0]);
    str ~= vars.compileVarAddress(id);
    if (node.children.length > 1)
    {
        str ~= compileLorRTrailer(cast(LorRTrailerNode)node.children[1], vars);
        vars.isStackAligned = false;
    }
    // This check is hit when we're either checking the top-level LoRValue id,
    // or when it's a struct member. A struct member may be the same id as
    // a stack variable, so we can tell that we're referring to a stack
    // variable if isStackAligned is still set to the default true value from
    // compileAssignExisting()
    else if (vars.isStackAligned && !vars.isStackAlignedVar(id))
    {
        vars.isStackAligned = false;
    }
    return str;
}

string compileLorRTrailer(LorRTrailerNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto type = node.data["type"].get!(Type*);
    auto parentType = node.data["parenttype"].get!(Type*);
    auto str = "";
    vars.allocateStackSpace(8);
    auto valLoc = vars.getTop.to!string;
    str ~= "    mov    qword [rbp-" ~ valLoc ~ "], r8\n";
    auto child = node.children[0];
    if (cast(IdentifierNode)child) {
        assert(false, "Unimplemented");
    }
    else if (cast(SingleIndexNode)child) {
        str ~= compileSingleIndex(cast(SingleIndexNode)child, vars);
        str ~= "    mov    r9, qword [rbp-" ~ valLoc ~ "]\n";
        // [r9] is the actual variable we're indexing, so
        // [r9]+(header offset + r8 * type.size) is the address we want
        str ~= "    mov    r9, [r9]\n";
        // Add offset for ref count and array length
        str ~= "    add    r9, 8\n";
        // Get index offset
        str ~= "    imul   r8, " ~ type.size.to!string ~ "\n";
        // Get completed address in r8
        str ~= "    add    r8, r9\n";
        if (node.children.length > 1)
        {
            str ~= compileLorRTrailer(
                cast(LorRTrailerNode)node.children[1],
                vars
            );
        }
    }
    vars.deallocateStackSpace(8);
    return str;
}

string compileCondAssignments(CondAssignmentsNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto str = "";
    foreach (child; node.children)
    {
        str ~= compileCondAssign(cast(CondAssignNode)child, vars);
    }
    return str;
}

string compileCondAssign(CondAssignNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    return compileAssignment(cast(AssignmentNode)node.children[0], vars);
}

string compileAssignment(AssignmentNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto str = "";
    auto child = node.children[0];
    if (cast(DeclTypeInferNode)child) {
        str ~= compileDeclTypeInfer(cast(DeclTypeInferNode)child, vars);
    }
    else if (cast(AssignExistingNode)child) {
        str ~= compileAssignExisting(cast(AssignExistingNode)child, vars);
    }
    else if (cast(DeclAssignmentNode)child) {
        str ~= compileDeclAssignment(cast(DeclAssignmentNode)child, vars);
    }
    return str;
}

string compileDeclAssignment(DeclAssignmentNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto str = "";
    return str;
}

string compileSpawnStmt(SpawnStmtNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    vars.runtimeExterns["newProc"] = true;
    auto sig = node.data["sig"].get!(FuncSig*);
    auto argExprs = (cast(ASTNonTerminal)node.children[1]).children;
    auto funcArgs = sig.funcArgs;
    auto str = "";

    // TODO update this to handle large types, namely funcptrs

    if (funcArgs.length > 0)
    {
        vars.allocateStackSpace(8);
        auto r12Loc = vars.getTop;
        vars.allocateStackSpace(8);
        auto r13Loc = vars.getTop;
        // Allocate newProc argLens
        str ~= "    mov    rdi, " ~ funcArgs.length.to!string ~ "\n";
        str ~= "    call   malloc\n";
        str ~= "    mov    r12, rax\n";
        foreach (i, arg; funcArgs)
        {
            auto size = arg.type.size;
            // argLens contains a negative size if the value is a floating
            // point argument
            if (arg.type.isFloat)
            {
                size *= -1;
            }
            str ~= "    mov    byte [r12+" ~ i.to!string
                                           ~ "], "
                                           ~ size.to!string
                                           ~ "\n";
        }
        // Store argLens on stack
        str ~= "    mov    qword [rbp-" ~ r12Loc.to!string
                                        ~ "], r12\n";
        // Allocate newProc args
        str ~= "    mov    rdi, " ~ (funcArgs.length * 8).to!string
                                  ~ "\n";
        str ~= "    call   malloc\n";
        str ~= "    mov    r13, rax\n";
        // Store args on stack
        str ~= "    mov    qword [rbp-" ~ r13Loc.to!string
                                        ~ "], r13\n";
        // Populate args with actual arguments
        foreach (i, argExpr; argExprs)
        {
            if (argExpr.data["type"].get!(Type*).size > 8)
            {
                assert(false, "Unimplemented");
            }
            str ~= compileBoolExpr(cast(BoolExprNode)argExpr, vars);
            str ~= "    mov    r13, qword [rbp-" ~ r13Loc.to!string
                                                 ~ "]\n";
            str ~= "    mov    qword [r13+" ~ (i * 8).to!string
                                            ~ "], r8\n";
        }
        // Populate newProc args
        str ~= "    mov    rdi, " ~ funcArgs.length.to!string ~ "\n";
        str ~= "    mov    rsi, " ~ sig.funcName ~ "\n";
        // Retrieve argLens from stack
        str ~= "    mov    rdx, qword [rbp-" ~ r12Loc.to!string
                                             ~ "]\n";
        // Retrieve args from stack
        str ~= "    mov    rcx, qword [rbp-" ~ r13Loc.to!string
                                             ~ "]\n";
        str ~= "    call   newProc\n";
        // Free args and argLens
        str ~= "    mov    rdi, qword [rbp-" ~ r12Loc.to!string
                                             ~ "]\n";
        str ~= "    call   free\n";
        str ~= "    mov    rdi, [rbp-" ~ r13Loc.to!string
                                       ~ "]\n";
        str ~= "    call   free\n";
        vars.deallocateStackSpace(16);
    }
    else
    {
        str ~= "    mov    rdi, 0\n";
        str ~= "    mov    rsi, " ~ sig.funcName ~ "\n";
        str ~= "    mov    rdx, 0\n";
        str ~= "    mov    rcx, 0\n";
        str ~= "    call   newProc\n";
    }
    return str;
}

string compileYieldStmt(YieldStmtNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    vars.runtimeExterns["yield"] = true;
    auto str = "";
    str ~= "    call   yield\n";
    return str;
}

string compileChanWrite(ChanWriteNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    vars.runtimeExterns["yield"] = true;
    auto str = "";
    auto valSize = node.children[1].data["type"].get!(Type*).size;
    str ~= compileBoolExpr(cast(BoolExprNode)node.children[0], vars);
    vars.allocateStackSpace(8);
    auto chanLoc = vars.getTop;
    vars.allocateStackSpace(8);
    auto valLoc = vars.getTop;
    str ~= "    mov    qword [rbp-" ~ chanLoc.to!string
                                    ~ "], r8\n";
    str ~= compileBoolExpr(cast(BoolExprNode)node.children[1], vars);
    // Chan is in r9, value is in r8
    str ~= "    mov    r9, qword [rbp-" ~ chanLoc.to!string
                                        ~ "]\n";
    auto tryWrite = vars.getUniqLabel;
    auto cannotWrite = vars.getUniqLabel;
    auto successfulWrite = vars.getUniqLabel;
    str ~= tryWrite ~ ":\n";
    str ~= "    ; Test if the channel has a valid value in it already,\n";
    str ~= "    ; yield if yes, write if not\n";
    str ~= "    cmp    dword [r9+4], 0\n";
    str ~= "    jnz    " ~ cannotWrite
                         ~ "\n";
    str ~= "    mov    " ~ getWordSize(valSize)
                         ~ " [r9+8], r8"
                         ~ getRRegSuffix(valSize)
                         ~ "\n";
    // Set the channel to declare it contains valid data
    str ~= "    mov    dword [r9+4], 1\n";
    str ~= "    jmp    " ~ successfulWrite
                         ~ "\n";
    str ~= cannotWrite ~ ":\n";
    // Store channel and value on stack, then yield
    str ~= "    mov    qword [rbp-" ~ chanLoc.to!string
                                    ~ "], r9\n";
    str ~= "    mov    qword [rbp-" ~ valLoc.to!string
                                    ~ "], r8\n";
    str ~= "    call   yield\n";
    // Restore channel and value, reattempt write
    str ~= "    mov    r9, qword [rbp-" ~ chanLoc.to!string
                                        ~ "]\n";
    str ~= "    mov    r8, qword [rbp-" ~ valLoc.to!string
                                        ~ "]\n";
    str ~= "    jmp    " ~ tryWrite
                         ~ "\n";
    str ~= successfulWrite ~ ":\n";
    vars.deallocateStackSpace(16);
    return str;
}

string compileFuncCall(FuncCallNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);
    auto funcName = getIdentifier(cast(IdentifierNode)node.children[0]);
    auto str = compileArgList(cast(FuncCallArgListNode)node.children[1], vars);
    auto numArgs = (cast(ASTNonTerminal)node.children[1]).children.length;
    str ~= "    call   " ~ funcName ~ "\n";
    if (numArgs > 6)
    {

        // TODO replace this with something that doesn't directly affect the
        // stack

        str ~= "    add    rsp, " ~ ((numArgs - 6) * 8).to!string ~ "\n";
    }
    str ~= "    mov    r8, rax\n";
    return str;
}

string compileArgList(FuncCallArgListNode node, Context* vars)
{
    debug (COMPILE_TRACE) mixin(tracer);

    // If there are more than 6 args, then after we pop off the top 48 bytes,
    // the remaining arguments are on the top of the stack.

    // TODO Might need to ensure things are in the right order, and might need
    // to handle fat ptrs in a special way

    // TODO The space for the return value should be just before the arguments,
    // not just after, so that I can clear the stack of the arguments, and in
    // the case of an extern func, I can just populate the empty space with the
    // value in RAX

    auto str = "";
    TypeEnum[] types;
    foreach_reverse (child; node.children)
    {
        str ~= compileExpression(child, vars);
        auto type = child.data["type"].get!(Type*).tag;
        types ~= type;
        switch (type)
        {
        case TypeEnum.FUNCPTR:
            assert(false, "unimplemented");
            vars.allocateStackSpace(8);
            str ~= "    mov    qword [rbp-" ~ vars.getTop.to!string ~ "], "
                                            ~ "r8\n";
            vars.allocateStackSpace(8);
            str ~= "    mov    qword [rbp-" ~ vars.getTop.to!string ~ "], "
                                            ~ "r9\n";
            break;
        case TypeEnum.DOUBLE:
            vars.allocateStackSpace(8);
            str ~= "    movsd  qword [rbp-" ~ vars.getTop.to!string ~ "], "
                                            ~ "xmm0\n";
            break;
        case TypeEnum.FLOAT:
            vars.allocateStackSpace(8);
            str ~= "    cvtss2sd xmm0, xmm0\n";
            str ~= "    movsd  qword [rbp-" ~ vars.getTop.to!string ~ "], "
                                            ~ "xmm0\n";
            break;
        default:
            vars.allocateStackSpace(8);
            str ~= "    mov    qword [rbp-" ~ vars.getTop.to!string ~ "], "
                                            ~ "r8\n";
            break;
        }
    }


    // TODO need to ensure that all func call registers are properly populated.
    // This will involve keeping track of the types of the things taken off the
    // stack, so that the correct corresponding rxx or xmmx register is
    // populated, and to ensure that any remaining arguments are left on the
    // stack


    auto intRegIndex = 0;
    auto floatRegIndex = 0;
    auto numArgs = node.children.length;
    foreach (i; 0..numArgs)
    {
        switch (types[$ - 1 - i])
        {
        case TypeEnum.FUNCPTR:
            assert(false, "unimplemented");
            break;
        case TypeEnum.FLOAT:
        case TypeEnum.DOUBLE:
            if (floatRegIndex < FLOAT_REG.length)
            {
                str ~= "    movsd  " ~ FLOAT_REG[floatRegIndex]
                                     ~ ", qword [rbp-"
                                     ~ vars.getTop.to!string
                                     ~ "]\n";
                vars.deallocateStackSpace(8);
                floatRegIndex++;
            }
            else
            {
                // TODO handle the case where we've run out of float registers
                // and need this argument to remain on the stack
            }
            break;
        default:
            if (intRegIndex < INT_REG.length)
            {
                str ~= "    mov    " ~ INT_REG[intRegIndex]
                                     ~ ", qword [rbp-"
                                     ~ vars.getTop.to!string
                                     ~ "]\n";
                vars.deallocateStackSpace(8);
                intRegIndex++;
            }
            else
            {
                // TODO handle the case where we've run out of int registers
                // and need this argument to remain on the stack
            }
            break;
        }
    }
    return str;
}
