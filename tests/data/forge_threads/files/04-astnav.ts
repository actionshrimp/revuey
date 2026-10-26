                        const flags = scanner.getTokenFlags();
                        lastToken = getOrCreateToken(sourceFile, token, tokenFullStart, tokenEnd, n, flags);
                        pos = tokenEnd;
                        scanner.scan();
                    }
                    return lastToken;
                });
                if (lastScannedToken !== undefined) {
                    return lastScannedToken;
                }
            }
        }

        if (!hasChildren) {
            if (n !== containingNode) {
                return n;
            }
            return undefined;
        }

        if (rightmostValidNode !== undefined) {
            return find(rightmostValidNode, rightmostValidNode.end);
        }
        return undefined;
    };

    return find(containingNode, endPos);
}

function isValidPrecedingNode(node: Node, sourceFile: SourceFile): boolean {
    if (node.kind === SyntaxKind.EndOfFile) {
        return false;
    }
    const start = getTokenPosOfNode(node, sourceFile);
    const width = node.end - start;
    return width > 0;
}

function shouldSkipChild(node: Node): boolean {
    return node.kind === SyntaxKind.JSDoc ||
        node.kind === SyntaxKind.JSDocText ||
        node.kind === SyntaxKind.JSDocTypeLiteral ||
        node.kind === SyntaxKind.JSDocSignature ||
        node.kind === SyntaxKind.JSDocLink ||
        node.kind === SyntaxKind.JSDocLinkCode ||
        node.kind === SyntaxKind.JSDocLinkPlain ||
        isJSDocTag(node);
}

function isJSDocTag(node: Node): boolean {
    return node.kind >= SyntaxKind.FirstJSDocTagNode && node.kind <= SyntaxKind.LastJSDocTagNode;
}

// In Strada, if a JSDoc node has a single comment, that comment is represented as a string
// property as a simplification, and therefore that comment is not visited by forEachChild.
// To match, we skip single-element comment NodeLists within JSDoc/JSDocTag nodes.
function isJSDocCommentChildKind(kind: SyntaxKind): boolean {
    switch (kind) {
        case SyntaxKind.JSDocText:
        case SyntaxKind.JSDocLink:
        case SyntaxKind.JSDocLinkCode:
        case SyntaxKind.JSDocLinkPlain:
            return true;
        default:
            return false;
    }
}

function isJSDocSingleCommentNodeList(nodes: NodeArray<Node>): boolean {
    return nodes.length === 1 && isJSDocCommentChildKind(nodes[0].kind);
}

// Idle scanners available for reuse, keyed by the source file whose text they scan.
// A scanner is removed from its pool while in use, so nested or reentrant traversals
// always receive distinct scanners. Pooled scanners retain only the source file's text.
interface ScannerLease extends Disposable {
    readonly scanner: Scanner;
}

const scannerPools = new WeakMap<SourceFile, ScannerLease[]>();

function acquireScanner(sourceFile: SourceFile): ScannerLease {
    let pool = scannerPools.get(sourceFile);
    if (pool === undefined) {
        pool = [];
        scannerPools.set(sourceFile, pool);
    }
    const lease = pool.pop();
    if (lease === undefined) {
        return createPooledScanner(sourceFile, pool);
    }
    // setText resets the token state (position, token, value, flags) to the start of the text.
    lease.scanner.setText(sourceFile.text);
    lease.scanner.setLanguageVariant(sourceFile.languageVariant);
    return lease;
}

function createPooledScanner(sourceFile: SourceFile, pool: ScannerLease[]): ScannerLease {
    return {
        scanner: createScanner(/*skipTrivia*/ true, sourceFile.languageVariant, sourceFile.text),
        [Symbol.dispose]() {
            // Drop per-use state so an idle scanner holds no token values or comment directives.
            // The JSDoc leading-asterisk depth is never changed by this module, so it stays zero.
            this.scanner.clearCommentDirectives();
            this.scanner.resetTokenState(0);
            pool.push(this);
        },
    };
}

function withScanner<T>(sourceFile: SourceFile, pos: number | undefined, callback: (scanner: Scanner) => T): T {
    using lease = acquireScanner(sourceFile);
    const { scanner } = lease;
    if (pos !== undefined) {
        scanner.resetTokenState(pos);
        scanner.scan();
    }
    return callback(scanner);
}

/**
 * Returns the idle scanners pooled for `sourceFile`. Exposed for tests only.
 * @internal
 */
export function getPooledScannersForTesting(sourceFile: SourceFile): readonly Scanner[] {
    return scannerPools.get(sourceFile)?.map(lease => lease.scanner) ?? emptyScannerArray;
}

const emptyScannerArray: readonly Scanner[] = [];

type Mutable<T> = { -readonly [K in keyof T]: T[K]; };

function getOrCreateToken(sourceFile: SourceFile, kind: SyntaxKind, pos: number, end: number, parent: Node, _flags: number): Node {
    const key = `${pos}_${end}`;
    if (!sourceFile.tokenCache) {
        sourceFile.tokenCache = new Map<string, Node>();
    }

    const existing = sourceFile.tokenCache.get(key);
    if (existing !== undefined) {
        return existing;
    }

    const token: Mutable<Node> = createToken(kind as TokenSyntaxKind);
    token.pos = pos;
    token.end = end;
    token.parent = parent;
    sourceFile.tokenCache.set(key, token);
    return token;
}

const emptyArray: readonly Node[] = [];

function assertHasRealPosition(node: Node): void {
    if (node.pos < 0 || node.end < 0) {
        throw new Error("Node without a real position cannot be scanned and thus has no token nodes - use forEachChild and collect the result if that's fine");
    }
}

export function getChildren(node: Node, sourceFile: SourceFile = node.getSourceFile()): readonly Node[] {
    // A SyntaxList already holds its (pre-materialized) children.
    if (node.kind === SyntaxKind.SyntaxList) {
        return (node as unknown as { children: readonly Node[]; }).children;
    }

    if (isTokenKind(node.kind)) {
        // EndOfFile may carry leading JSDoc; every other token has no children. The EndOfFile
        // result must go through the cache: remote nodes rebuild .jsDoc on every access.
        if (node.kind !== SyntaxKind.EndOfFile) {
            return emptyArray;
        }
    }
    else {
        assertHasRealPosition(node);
    }

    const cache = (sourceFile.childrenCache ??= new Map<Node, readonly Node[]>());
    const cached = cache.get(node);

    if (cached !== undefined) {
        return cached;
    }

    const children = node.kind === SyntaxKind.EndOfFile
        ? node.jsDoc ?? emptyArray
        : createChildren(node, sourceFile);
    cache.set(node, children);
    return children;
}

function createChildren(node: Node, sourceFile: SourceFile): readonly Node[] {
    const children: Node[] = [];

    // Inside a JSDoc comment there are no real tokens to synthesize.
    if (shouldSkipChild(node)) {
        node.forEachChild(child => void children.push(child));
        return children;
    }

    // One scanner serves every run of synthetic tokens materialized for this node.
    using lease = acquireScanner(sourceFile);
    const { scanner } = lease;
    let pos = node.pos;
    const processNode = (child: Node): undefined => {
        // Reparsed subtrees (JSDoc types materialized into the AST) have positions inside
        // the comment, not in this node's token range.
        if (child.flags & NodeFlags.Reparsed) {
            return;
        }
        addSyntheticNodes(children, pos, child.pos, node, sourceFile, scanner);
        children.push(child);
        pos = child.end;
    };
    const processNodes = (nodes: NodeArray<Node>): undefined => {
        if (nodes.length > 0 && !nodes.some(child => !(child.flags & NodeFlags.Reparsed))) {
            return;
        }
        addSyntheticNodes(children, pos, nodes.pos, node, sourceFile, scanner);
        children.push(createSyntaxListNode(nodes, node, sourceFile, scanner));
        pos = nodes.end;
    };
