import type {
    APIMethodInfo,
    APIRequest,
    APIResponse,
} from "../proto.ts";

export function cacheGeneratorMethod<Sync extends (...args: any[]) => any, Gen extends (...args: any[]) => AnyAPIRequestGenerator>(
    owner: object,
    name: PropertyKey,
    sync: Sync,
    gen: Gen,
): Sync & { readonly gen: Gen; } {
    const method = Object.assign(sync, { gen });
    Object.defineProperty(owner, name, { configurable: true, value: method });
    return method;
}

export function apiRequest<Method extends keyof APIMethodInfo>(
    method: Method,
    params: APIMethodInfo[Method]["params"],
): Generator<APIRequest, APIMethodInfo[Method]["result"], APIResponse["result"]>;
export function* apiRequest(method: PropertyKey, params: unknown): Generator<{ method: PropertyKey; params: unknown; }, unknown, unknown> {
    return yield { method, params };
}
const deferredGeneratorMarker: unique symbol = Symbol();
// Marks executed generators on the generator itself: a WeakSet holding every generator of a long-running batch is
// costly to grow and to process during GC
const executedMarker: unique symbol = Symbol();
interface ExecutedGenerator {
    [executedMarker]?: true;
}
const executedNonExtensibleGenerators = new WeakSet<AnyAPIRequestGenerator>();

/** Marks the generator as executed, returning false if it already was. */
function markExecuted(generator: AnyAPIRequestGenerator): boolean {
    if (!Object.isExtensible(generator)) {
        if (executedNonExtensibleGenerators.has(generator)) return false;
        executedNonExtensibleGenerators.add(generator);
        return true;
    }
    const target = generator as ExecutedGenerator;
    if (target[executedMarker]) return false;
    target[executedMarker] = true;
    return true;
}
const allGeneratorMarker: unique symbol = Symbol();
interface DeferredAPIRequest {
    readonly method: "__defer";
    readonly deferred: APIRequestGenerator;
}
interface AllAPIRequest {
    readonly method: "__all";
    readonly generators: readonly AnyAPIRequestGenerator[];
}
type APIRequestGeneratorYield = APIRequest | readonly APIRequest[] | DeferredAPIRequest | AllAPIRequest;
export type APIRequestGenerator<Return = any> = Generator<APIRequestGeneratorYield, Return, any>;
export type DeferredAPIRequestGenerator = Generator<DeferredAPIRequest, void, unknown> & { readonly [deferredGeneratorMarker]: true; };
export type AllAPIRequestGenerator<Return = any> = Generator<AllAPIRequest, Return, Return>;
export type AnyAPIRequestGenerator<Return = any> = APIRequestGenerator<Return> | DeferredAPIRequestGenerator | AllAPIRequestGenerator<Return>;
type GeneratorReturn<T> = T extends Generator<any, infer R, any> ? R : never;
export type ExecutedGeneratorsResults<T extends readonly AnyAPIRequestGenerator[]> = number extends T["length"] ? GeneratorReturn<Exclude<T[number], DeferredAPIRequestGenerator>>[]
    : T extends readonly [infer Head extends AnyAPIRequestGenerator, ...infer Tail extends readonly AnyAPIRequestGenerator[]] ? Head extends DeferredAPIRequestGenerator ? ExecutedGeneratorsResults<Tail> : [GeneratorReturn<Head>, ...ExecutedGeneratorsResults<Tail>]
    : [];

interface GeneratorResponse {
    result: unknown;
    error?: string | undefined;
}

interface GeneratorState {
    generator: AnyAPIRequestGenerator;
    parent: GeneratorGroup | undefined;
    resultIndex: number;
    previous: GeneratorState | undefined;
    next: GeneratorState | undefined;
    active: boolean;
    request?: APIRequest | readonly APIRequest[] | undefined;
    group?: GeneratorGroup | undefined;
}

interface GeneratorGroup {
    parent: GeneratorState | undefined;
    children: GeneratorState[];
    results: unknown[];
    wrappers?: AllRequestGenerator<unknown>[] | undefined;
    remaining: number;
    initializing: boolean;
    failed: boolean;
    error?: unknown;
}

export function all<const T extends readonly AnyAPIRequestGenerator[]>(
    ...requestGenerators: T
): AllAPIRequestGenerator<ExecutedGeneratorsResults<T>> {
    return new AllRequestGenerator(requestGenerators);
}

/**
 * This single-message iterator avoids native generator setup/resumption overhead.
 * Keeping pending children on the instance also lets the executor collapse nested
 * all helpers without allocating a scheduler group for each wrapper.
 */
class AllRequestGenerator<Return> implements AllAPIRequestGenerator<Return> {
    readonly [allGeneratorMarker] = true;
    generators: readonly AnyAPIRequestGenerator[] | undefined;
    private done = false;

    constructor(generators: readonly AnyAPIRequestGenerator[]) {
        this.generators = generators;
    }

    next(value?: Return): IteratorResult<AllAPIRequest, Return> {
        if (this.generators) {
            const generators = this.generators;
            this.generators = undefined;
            return { done: false, value: { method: "__all", generators } };
        }
        if (this.done) return { done: true, value: undefined as Return };
        this.done = true;
        return { done: true, value: value as Return };
    }

    return(value: Return): IteratorResult<AllAPIRequest, Return> {
        this.generators = undefined;
        this.done = true;
        return { done: true, value };
    }

    throw(error?: unknown): IteratorResult<AllAPIRequest, Return> {
        this.generators = undefined;
        this.done = true;
        throw error;
    }

    [Symbol.iterator](): AllAPIRequestGenerator<Return> {
        return this;
    }

    [Symbol.dispose](): void {
        this.return(undefined as Return);
    }
}

export function executeRequestGenerators<T extends readonly AnyAPIRequestGenerator[]>(
    requestGenerators: T,
    executeRequests: (requests: APIRequest[]) => readonly GeneratorResponse[],
): ExecutedGeneratorsResults<T> {
    let firstGenerator: GeneratorState | undefined;
    let lastGenerator: GeneratorState | undefined;
    const root = startGroup(requestGenerators);
    if (root.failed) throw root.error;
    while (firstGenerator) {
        const requests: APIRequest[] = [];
