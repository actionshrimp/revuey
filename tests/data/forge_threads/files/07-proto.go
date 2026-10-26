package api

//go:generate npx hereby generate:api

import (
	"errors"
	"fmt"
	"sync/atomic"

	"github.com/microsoft/TypeScript/tsc/internal/api/requestfilesystem"
	"github.com/microsoft/TypeScript/tsc/internal/ast"
	"github.com/microsoft/TypeScript/tsc/internal/checker"
	"github.com/microsoft/TypeScript/tsc/internal/collections"
	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/diagnostics"
	"github.com/microsoft/TypeScript/tsc/internal/diagnosticwriter"
	"github.com/microsoft/TypeScript/tsc/internal/execute/tsc"
	"github.com/microsoft/TypeScript/tsc/internal/jsnum"
	"github.com/microsoft/TypeScript/tsc/internal/json"
	"github.com/microsoft/TypeScript/tsc/internal/locale"
	"github.com/microsoft/TypeScript/tsc/internal/ls/lsconv"
	"github.com/microsoft/TypeScript/tsc/internal/ls/lsutil"
	"github.com/microsoft/TypeScript/tsc/internal/lsp/lsproto"
	"github.com/microsoft/TypeScript/tsc/internal/module"
	"github.com/microsoft/TypeScript/tsc/internal/packagejson"
	"github.com/microsoft/TypeScript/tsc/internal/project"
	"github.com/microsoft/TypeScript/tsc/internal/scanner"
	"github.com/microsoft/TypeScript/tsc/internal/tsoptions"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
)

var (
	ErrInvalidRequest = errors.New("api: invalid request")
	ErrClientError    = errors.New("api: client error")
)

type Method string

type (
	SnapshotID          uint64
	ModuleResolverID    uint64
	SourceFileLeaseID   uint64
	BuildOrchestratorID uint64
	SymbolID            uint64
	TypeID              uint32
	SignatureID         uint64
	// NodeHandle identifies a node in an exact source-file AST. Requests use
	// "index.#sourceFileID"; responses use "index.kind.#sourceFileID.path".
	NodeHandle string
)

var nextBuildOrchestratorId atomic.Uint64

func NewBuildOrchestratorID() BuildOrchestratorID {
	return BuildOrchestratorID(nextBuildOrchestratorId.Add(1))
}

func SymbolHandle(symbol *ast.Symbol) SymbolID {
	return SymbolID(ast.GetSymbolId(symbol))
}

func TypeHandle(t *checker.Type) TypeID {
	return TypeID(t.Id())
}

func SignatureHandle(sig *checker.Signature) SignatureID {
	return SignatureID(sig.Id())
}

const (
	MethodRelease                Method = "release"
	MethodReleaseSourceFile      Method = "releaseSourceFile"
	MethodRetainSourceFile       Method = "retainSourceFile"
	MethodGetCachedSourceFile    Method = "getCachedSourceFile"
	MethodGetSymbolOfDeclaration Method = "getSymbolOfDeclaration"

	MethodBatchRequests                                  Method = "batchRequests"
	MethodInitialize                                     Method = "initialize"
	MethodCreateSnapshot                                 Method = "createSnapshot"
	MethodUpdateSnapshot                                 Method = "updateSnapshot"
	MethodGetCurrentLanguageServerSnapshot               Method = "getCurrentLanguageServerSnapshot"
	MethodCreateBuildOrchestrator                        Method = "createBuildOrchestrator"
	MethodDisposeBuildOrchestrator                       Method = "disposeBuildOrchestrator"
	MethodBuild                                          Method = "build"
	MethodBuildReferences                                Method = "buildReferences"
	MethodCleanBuild                                     Method = "cleanBuild"
	MethodCleanReferences                                Method = "cleanReferences"
	MethodCreateModuleResolver                           Method = "createModuleResolver"
	MethodReleaseModuleResolver                          Method = "releaseModuleResolver"
	MethodResolveModuleName                              Method = "resolveModuleName"
	MethodParseCommandLine                               Method = "parseCommandLine"
	MethodReadConfigFile                                 Method = "readConfigFile"
	MethodParseJsonConfigFile                            Method = "parseJsonConfigFileContent"
	MethodParseConfigFile                                Method = "parseConfigFile"
	MethodCreateSourceFile                               Method = "createSourceFile"
	MethodCreateSourceFileFromFile                       Method = "createSourceFileFromFile"
	MethodTranspileModule                                Method = "transpileModule"
	MethodTranspileModuleFromFile                        Method = "transpileModuleFromFile"
	MethodTranspileDeclaration                           Method = "transpileDeclaration"
	MethodTranspileDeclarationFromFile                   Method = "transpileDeclarationFromFile"
	MethodGetDefaultProjectForFile                       Method = "getDefaultProjectForFile"
	MethodGetSymbolAtPosition                            Method = "getSymbolAtPosition"
	MethodGetSymbolsAtPositions                          Method = "getSymbolsAtPositions"
	MethodGetSymbolAtLocation                            Method = "getSymbolAtLocation"
	MethodGetSymbolsAtLocations                          Method = "getSymbolsAtLocations"
	MethodGetSymbolOfSourceFile                          Method = "getSymbolOfSourceFile"
	MethodGetSymbolsOfSourceFiles                        Method = "getSymbolsOfSourceFiles"
	MethodGetTypeOfSymbol                                Method = "getTypeOfSymbol"
	MethodGetTypesOfSymbols                              Method = "getTypesOfSymbols"
	MethodGetDeclaredTypeOfSymbol                        Method = "getDeclaredTypeOfSymbol"
	MethodGetNonMissingTypeOfSymbol                      Method = "getNonMissingTypeOfSymbol"
	MethodGetSourceFile                                  Method = "getSourceFile"
	MethodGetSourceFileNames                             Method = "getSourceFileNames"
	MethodGetSourceFileMetadata                          Method = "getSourceFileMetadata"
	MethodGetModeForUsageLocation                        Method = "getModeForUsageLocation"
	MethodGetModeForResolutionAtIndex                    Method = "getModeForResolutionAtIndex"
	MethodGetResolvedModule                              Method = "getResolvedModule"
	MethodGetResolvedModuleFromModuleSpecifier           Method = "getResolvedModuleFromModuleSpecifier"
	MethodGetResolvedTypeReferenceDirective              Method = "getResolvedTypeReferenceDirective"
	MethodGetResolvedTypeReferenceDirectiveFromReference Method = "getResolvedTypeReferenceDirectiveFromTypeReferenceDirective"
	MethodGetConfigFileNames                             Method = "getConfigFileNames"
	MethodGetConfigSourceFile                            Method = "getConfigSourceFile"
	MethodResolveName                                    Method = "resolveName"
	MethodGetSymbolsInScope                              Method = "getSymbolsInScope"
	MethodGetSignaturesOfType                            Method = "getSignaturesOfType"
	MethodGetResolvedSignature                           Method = "getResolvedSignature"
	MethodGetTypeAtLocation                              Method = "getTypeAtLocation"
	MethodGetTypeAtLocations                             Method = "getTypeAtLocations"
	MethodGetTypeAtPosition                              Method = "getTypeAtPosition"
	MethodGetTypesAtPositions                            Method = "getTypesAtPositions"

	// Symbol sub-property methods
	MethodGetParentOfSymbol       Method = "getParentOfSymbol"
	MethodGetMembersOfSymbol      Method = "getMembersOfSymbol"
	MethodGetExportsOfSymbol      Method = "getExportsOfSymbol"
	MethodGetExportSymbolOfSymbol Method = "getExportSymbolOfSymbol"

	// Type sub-property methods
	MethodGetSymbolOfType               Method = "getSymbolOfType"
	MethodGetTargetOfType               Method = "getTargetOfType"
	MethodGetFreshTypeOfType            Method = "getFreshTypeOfType"
	MethodGetRegularTypeOfType          Method = "getRegularTypeOfType"
	MethodGetTypesOfType                Method = "getTypesOfType"
	MethodGetTypeParametersOfType       Method = "getTypeParametersOfType"
	MethodGetOuterTypeParametersOfType  Method = "getOuterTypeParametersOfType"
	MethodGetLocalTypeParametersOfType  Method = "getLocalTypeParametersOfType"
	MethodGetThisTypeOfType             Method = "getThisTypeOfType"
	MethodGetAliasTypeArgumentsOfType   Method = "getAliasTypeArgumentsOfType"
	MethodGetAliasSymbolOfType          Method = "getAliasSymbolOfType"
	MethodGetObjectTypeOfType           Method = "getObjectTypeOfType"
	MethodGetIndexTypeOfType            Method = "getIndexTypeOfType"
	MethodGetCheckTypeOfType            Method = "getCheckTypeOfType"
	MethodGetExtendsTypeOfType          Method = "getExtendsTypeOfType"
	MethodGetBaseTypeOfType             Method = "getBaseTypeOfType"
	MethodGetConstraintOfType           Method = "getConstraintOfType"
	MethodGetTypeParameterOfMappedType  Method = "getTypeParameterOfMappedType"
	MethodGetConstraintTypeOfMappedType Method = "getConstraintTypeOfMappedType"
	MethodGetNameTypeOfMappedType       Method = "getNameTypeOfMappedType"
	MethodGetTemplateTypeOfMappedType   Method = "getTemplateTypeOfMappedType"
