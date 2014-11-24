import std.stdio;
import std.variant;
import std.algorithm;
import std.conv;
import std.range;
import std.array;
import parser;
import visitor;
import SymTab;
import ASTUtils;
import typedecl;
import Record;
import utils;

class FunctionSigBuilder : Visitor
{
    private RecordBuilder records;
    private string id;
    private string[] idTuple;
    private string funcName;
    private VarTypePair*[] funcArgs;
    private Type* returnType;
    private VarTypePair*[] decls;
    FuncSig*[] toplevelFuncs;

    mixin TypeVisitors;

    this (ProgramNode node, RecordBuilder records)
    {
        this.records = records;
        builderStack.length++;
        // Just do function definitions
        auto funcDefs = node.children
                            .filter!(a => typeid(a) == typeid(FuncDefNode));
        foreach (funcDef; funcDefs)
        {
            funcDef.accept(this);
        }
    }

    private auto collectMultiples(T)(T[] elems)
    {
        bool[T] found;
        bool[T] multiples;
        foreach (elem; elems)
        {
            if (elem in found)
            {
                multiples[elem] = true;
            }
            found[elem] = true;
        }
        return multiples.keys;
    }

    void visit(FuncDefNode node)
    {
        // Visit FuncSignatureNode
        node.children[0].accept(this);
        auto funcSig = new FuncSig();
        funcSig.funcName = funcName;
        funcSig.funcArgs = funcArgs;
        funcSig.returnType = returnType;
        funcSig.templateParams = templateParams;
        funcSig.funcBodyBlocks = cast(FuncBodyBlocksNode)node.children[1];
        toplevelFuncs ~= funcSig;
        funcName = "";
        funcArgs = [];
        returnType = null;
        templateParams = [];
    }

    void visit(FuncSignatureNode node)
    {
        // Visit IdentifierNode, populate 'id'
        node.children[0].accept(this);
        funcName = id;
        writeln("FuncName: ", id);
        // Visit TemplateTypeParamsNode
        node.children[1].accept(this);
        // Visit FuncDefArgListNode
        node.children[2].accept(this);
        // Visit FuncReturnTypeNode
        node.children[3].accept(this);
    }

    void visit(IdentifierNode node)
    {
        id = (cast(ASTTerminal)node.children[0]).token;
    }

    void visit(IdTupleNode node)
    {
        idTuple = [];
        foreach (child; node.children)
        {
            child.accept(this);
            idTuple ~= id;
        }
    }

    void visit(FuncDefArgListNode node)
    {
        foreach (child; node.children)
        {
            // Visit FuncSigArgNode
            child.accept(this);
        }
    }

    void visit(FuncSigArgNode node)
    {
        // Visit IdentifierNode, populate 'id'
        node.children[0].accept(this);
        string argName = id;
        // Visit TypeIdNode. Note going out of order here
        node.children[$-1].accept(this);
        auto argType = builderStack[$-1][$-1];
        builderStack[$-1] = builderStack[$-1][0..$-1];
        argType.refType = false;
        argType.constType = false;
        if (node.children.length > 2)
        {
            // Visit StorageClassNode
            foreach (storageClass; node.children[1..$-1])
            {
                if (typeid(storageClass) == typeid(RefClassNode))
                {
                    argType.refType = true;
                }
                else if (typeid(storageClass) == typeid(ConstClassNode))
                {
                    argType.constType = true;
                }
            }
        }
        auto pair = new VarTypePair();
        pair.varName = argName;
        pair.type = argType;
        funcArgs ~= pair;
    }

    void visit(FuncReturnTypeNode node)
    {
        if (node.children.length > 0)
        {
            node.children[0].accept(this);
            returnType = builderStack[$-1][$-1];
            builderStack[$-1] = builderStack[$-1][0..$-1];
        }
    }

    void visit(VariableTypePairNode node)
    {
        // Visit IdentifierNode, populate 'id'
        node.children[0].accept(this);
        auto varName = id;
        // Visit TypeIdNode
        node.children[1].accept(this);
        auto varType = builderStack[$-1][$-1];
        builderStack[$-1] = builderStack[$-1][0..$-1];
        auto pair = new VarTypePair();
        pair.varName = varName;
        pair.type = varType;
        decls ~= pair;
    }

    void visit(VariableTypePairTupleNode node)
    {
        foreach (child; node.children)
        {
            child.accept(this);
        }
    }

    void visit(UserTypeNode node)
    {
        node.children[0].accept(this);
        string userTypeName = id;
        auto aggregate = new AggregateType();
        aggregate.typeName = userTypeName;
        if (node.children.length > 1)
        {
            builderStack.length++;
            node.children[1].accept(this);
            aggregate.templateInstantiations = builderStack[$-1];
            builderStack.length--;
        }
        builderStack[$-1] ~= instantiateAggregate(records, aggregate);
    }

    void visit(FuncBodyBlocksNode node) {}
    void visit(BareBlockNode node) {}
    void visit(StatementNode node) {}
    void visit(ReturnStmtNode node) {}
    void visit(BoolExprNode node) {}
    void visit(OrTestNode node) {}
    void visit(AndTestNode node) {}
    void visit(NotTestNode node) {}
    void visit(ComparisonNode node) {}
    void visit(ExprNode node) {}
    void visit(OrExprNode node) {}
    void visit(XorExprNode node) {}
    void visit(AndExprNode node) {}
    void visit(ShiftExprNode node) {}
    void visit(SumExprNode node) {}
    void visit(ProductExprNode node) {}
    void visit(ValueNode node) {}
    void visit(ParenExprNode node) {}
    void visit(NumberNode node) {}
    void visit(IntNumNode node) {}
    void visit(FloatNumNode node) {}
    void visit(CharLitNode node) {}
    void visit(StringLitNode node) {}
    void visit(BooleanLiteralNode node) {}
    void visit(ArrayLiteralNode node) {}
    void visit(DeclarationNode node) {}
    void visit(DeclAssignmentNode node) {}
    void visit(AssignExistingNode node) {}
    void visit(DeclTypeInferNode node) {}
    void visit(AssignmentNode node) {}
    void visit(ValueTupleNode node) {}
    void visit(LorRValueNode node) {}
    void visit(LorRTrailerNode node) {}
    void visit(LorRMemberAccessNode node) {}
    void visit(SlicingNode node) {}
    void visit(SingleIndexNode node) {}
    void visit(IndexRangeNode node) {}
    void visit(StartToIndexRangeNode node) {}
    void visit(IndexToEndRangeNode node) {}
    void visit(IndexToIndexRangeNode node) {}

    void visit(LambdaNode node) {}
    void visit(LambdaArgsNode node) {}
    void visit(StructFunctionNode node) {}
    void visit(InBlockNode node) {}
    void visit(OutBlockNode node) {}
    void visit(ReturnModBlockNode node) {}
    void visit(BodyBlockNode node) {}
    void visit(StorageClassNode node) {}
    void visit(RefClassNode node) {}
    void visit(ConstClassNode node) {}
    void visit(InterfaceDefNode node) {}
    void visit(InterfaceBodyNode node) {}
    void visit(InterfaceEntryNode node) {}
    void visit(IfStmtNode node) {}
    void visit(ElseIfsNode node) {}
    void visit(ElseIfStmtNode node) {}
    void visit(ElseStmtNode node) {}
    void visit(WhileStmtNode node) {}
    void visit(ForStmtNode node) {}
    void visit(ForInitNode node) {}
    void visit(ForConditionalNode node) {}
    void visit(ForPostExpressionNode node) {}
    void visit(ForeachStmtNode node) {}
    void visit(ForeachArgsNode node) {}
    void visit(SpawnStmtNode node) {}
    void visit(YieldStmtNode node) {}
    void visit(ChanWriteNode node) {}
    void visit(FuncCallNode node) {}
    void visit(AssignExistingOpNode node) {}
    void visit(CondAssignmentsNode node) {}
    void visit(CondAssignNode node) {}
    void visit(SliceLengthSentinelNode node) {}
    void visit(ChanReadNode node) {}
    void visit(TrailerNode node) {}
    void visit(DynArrAccessNode node) {}
    void visit(TemplateInstanceMaybeTrailerNode node) {}
    void visit(FuncCallTrailerNode node) {}
    void visit(FuncCallArgListNode node) {}
    void visit(DotAccessNode node) {}
    void visit(MatchStmtNode node) {}
    void visit(MatchExprNode node) {}
    void visit(MatchWhenNode node) {}
    void visit(MatchWhenExprNode node) {}
    void visit(MatchDefaultNode node) {}

    void visit(ASTTerminal node) {}
    void visit(StructDefNode node) {}
    void visit(StructBodyNode node) {}
    void visit(StructEntryNode node) {}
    void visit(VariantDefNode node) {}
    void visit(VariantBodyNode node) {}
    void visit(VariantEntryNode node) {}
    void visit(CharRangeNode node) {}
    void visit(IntRangeNode node) {}
    void visit(CompOpNode node) {}
    void visit(SumOpNode node) {}
    void visit(SpNode node) {}
    void visit(ProgramNode node) {}
}