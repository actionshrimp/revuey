            }
        }

        w.pop();
        w.write("}");
        w.write("");
    }
}

// ── Generate As*() cast methods ────────────────────────────────────────────

function generateKindCheck(w: CodeWriter, node: NodeType, expression: string, message: string) {
    const kinds = canonicalNodesByKind().get(node) ?? [];
    if (kinds.length === 1) {
        w.write(`if ${expression} != ${kinds[0]} {`);
        w.push();
        w.write(`panic("${message}")`);
        w.pop();
        w.write("}");
    }
    else {
        w.write(`switch ${expression} {`);
        w.write(`case ${kinds.join(", ")}:`);
        w.write("default:");
        w.push();
        w.write(`panic("${message}")`);
        w.pop();
        w.write("}");
    }
}

function generateAsCast(w: CodeWriter, node: NodeType) {
    const structName = node.name;
    w.write(`func (n *Node) As${structName}() *${structName} {`);
    w.push();
    generateKindCheck(w, node, "n.Kind", `Invalid node cast to ${structName}`);
    w.write(`return (*${structName})(unsafe.Pointer(n))`);
    w.pop();
    w.write("}");
    w.write("");
}

// ── Generate New*() factory methods ────────────────────────────────────────

function isNodeFlagsMember(m: MemberInfo): boolean {
    const type = m.type;
    return type.kind === "primitive" && type.name === "NodeFlags";
}

function canonicalNodesByKind(): Map<NodeType, string[]> {
    const nodeByKind = new Map<string, NodeType>();
    for (const node of api.nodes()) {
        for (const kind of node.allKinds()) {
            nodeByKind.set(kind.formatGoConstant(), node);
        }
    }

    const kindsByNode = new Map<NodeType, string[]>();
    for (const [kind, node] of nodeByKind) {
        const kinds = kindsByNode.get(node);
        if (kinds) {
            kinds.push(kind);
        }
        else {
            kindsByNode.set(node, [kind]);
        }
    }
    return kindsByNode;
}

function emitNewFactory(
    w: CodeWriter,
    funcName: string,
    kindName: string,
    structName: string,
    node: NodeType,
    members: MemberInfo[],
    kindMember: MemberInfo | undefined,
    nodeFlagsMembers: MemberInfo[],
) {
    const params = members.map(m => `${m.goParamName()} ${m.type.formatGoReference()}`).join(", ");

    w.write(`func (f *NodeFactory) ${funcName}(${params}) *Node {`);
    w.push();

    if (kindMember) {
        generateKindCheck(w, node, kindMember.goParamName(), `Invalid node kind for ${structName}`);
    }

    if (node.arena) {
        w.write(`data := f.${api.uncapitalize(structName)}Arena.New()`);
    }
    else {
        w.write(`data := &${structName}{}`);
    }

    for (const m of members) {
        if (m.isKindParam()) continue;
        if (isNodeFlagsMember(m)) continue;
        const value = m.bitmask ? `${m.goParamName()} & ${m.bitmask}` : m.goParamName();
        w.write(`data.${m.name} = ${value}`);
    }

    if (hasTextContent(node)) {
        w.write("f.textCount++");
    }

    const kindArg = kindMember ? kindMember.goParamName() : `Kind${kindName}`;

    if (nodeFlagsMembers.length > 0) {
        w.write(`node := f.newNode(${kindArg}, data.AsNode())`);
        for (const m of nodeFlagsMembers) {
            const param = m.goParamName();
            if (m.bitmask) {
                w.write(`node.Flags |= ${param} & ${m.bitmask}`);
            }
            else {
                w.write(`node.Flags = ${param}`);
            }
        }
        w.write("return node");
    }
    else {
        w.write(`return f.newNode(${kindArg}, data.AsNode())`);
    }

    w.pop();
    w.write("}");
    w.write("");
}

function generateNewFactory(w: CodeWriter, node: NodeType) {
    const structName = node.name;
    const members = schemaMembers(node);
    const kindMember = members.find(m => m.isKindParam());
    const nodeFlagsMembers = members.filter(m => isNodeFlagsMember(m));
    if (node.name === "Token") {
        const tokenKinds = new Set(node.allKinds().map(kind => kind.formatGoConstant()));
        w.write("func (f *NodeFactory) NewToken(kind TokenSyntaxKind) *Node {");
        w.push();
        w.write('if !IsTokenKind(kind) { panic("Invalid token kind") }');
        w.write("switch kind {");
        for (const [canonicalNode, kinds] of canonicalNodesByKind()) {
            if (canonicalNode === node) continue;
            const overlappingKinds = kinds.filter(kind => tokenKinds.has(kind));
            if (overlappingKinds.length === 0) continue;
            w.write(`case ${overlappingKinds.join(", ")}:`);
            w.push();
            if (canonicalNode.arena) {
                w.write(`data := f.${api.uncapitalize(canonicalNode.name)}Arena.New()`);
            }
            else {
                w.write(`data := &${canonicalNode.name}{}`);
            }
            w.write("return f.newNode(kind, data.AsNode())");
            w.pop();
        }
        w.write("default:");
        w.push();
        w.write("data := f.tokenArena.New()");
        w.write("return f.newNode(kind, data.AsNode())");
        w.pop();
        w.write("}");
        w.pop();
        w.write("}");
        w.write("");
    }
    else {
        emitNewFactory(w, `New${node.name}`, node.syntaxKindName, structName, node, members, kindMember, nodeFlagsMembers);
    }
    for (const alias of node.kindAliases) {
        emitNewFactory(w, `New${alias}`, alias, structName, node, members, kindMember, nodeFlagsMembers);
    }
}

// ── Generate Update*() factory methods ─────────────────────────────────────

function generateUpdateFactory(w: CodeWriter, node: NodeType) {
    const structName = node.name;
    const members = schemaMembers(node);

    // All non-Kind members participate in Update (both child and data)
    const updateMembers = members.filter(m => !m.isKindParam());
    if (updateMembers.length === 0) return;

    // Leaf nodes (no child AST node members) don't get Update methods.
    if (!updateMembers.some(m => m.isChild())) return;

    // Build parameter list
    const params = [
        `node *${structName}`,
        ...updateMembers.map(m => `${m.goParamName()} ${m.type.formatGoReference()}`),
    ].join(", ");

    w.write(`func (f *NodeFactory) Update${node.name}(${params}) *Node {`);
    w.push();

    // Build comparison (all update members)
    const comparisons = updateMembers.map(m => {
        const type = m.type;
        // Slices can't be compared with != in Go
        if (type.kind === "list" && type.listKind === "raw") {
            return `!core.Same(${m.goParamName()}, node.${m.name})`;
        }
        return `${m.goParamName()} != node.${m.name}`;
    });

    w.write(`if ${comparisons.join(" || ")} {`);
    w.push();

    // Call New with all members (Kind from original, everything else from params)
    const newArgs = members.map(m => {
        if (m.isKindParam()) {
            return "node.Kind";
        }
        return m.goParamName();
    }).join(", ");

    if (node.kindAliases.length > 0) {
        w.write("switch node.Kind {");
        w.push();
