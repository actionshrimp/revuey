			resp.Value = literalValueToJSON(lit.Value())
		}
		if lit.FreshType() != nil {
			resp.FreshType = TypeHandle(lit.FreshType())
		}
		if lit.RegularType() != nil {
			resp.RegularType = TypeHandle(lit.RegularType())
		}
	case flags&checker.TypeFlagsObject != 0:
		resp.ObjectFlags = uint32(t.ObjectFlags())
		resp.IsTupleType = checker.IsTupleType(t)
		objectFlags := t.ObjectFlags()
		if objectFlags&checker.ObjectFlagsReference != 0 {
			ref := t.AsTypeReference()
			if checker.IsTupleTypeTarget(t) {
				tuple := t.AsTupleType()
				resp.ElementFlags = tuple.ElementFlags()
				fixedLen := tuple.FixedLength()
				resp.FixedLength = &fixedLen
				isReadonly := tuple.IsReadonly()
				resp.TupleReadonly = &isReadonly
			}
			if ref.Target() != nil {
				resp.Target = TypeHandle(ref.Target())
			}
		}
		if objectFlags&checker.ObjectFlagsClassOrInterface != 0 {
			iface := t.AsInterfaceType()
			resp.TypeParameters = typeHandles(iface.TypeParameters())
			resp.OuterTypeParameters = typeHandles(iface.OuterTypeParameters())
			resp.LocalTypeParameters = typeHandles(iface.LocalTypeParameters())
			if iface.ThisType() != nil {
				resp.ThisType = TypeHandle(iface.ThisType())
			}
		}
	case flags&checker.TypeFlagsUnionOrIntersection != 0:
		// types omitted; fetched via separate request
	case flags&checker.TypeFlagsIndex != 0:
		resp.Target = TypeHandle(t.AsIndexType().Target())
	case flags&checker.TypeFlagsIndexedAccess != 0:
		data := t.AsIndexedAccessType()
		resp.ObjectType = TypeHandle(data.ObjectType())
		resp.IndexType = TypeHandle(data.IndexType())
	case flags&checker.TypeFlagsConditional != 0:
		data := t.AsConditionalType()
		resp.CheckType = TypeHandle(data.CheckType())
		resp.ExtendsType = TypeHandle(data.ExtendsType())
	case flags&checker.TypeFlagsSubstitution != 0:
		data := t.AsSubstitutionType()
		resp.BaseType = TypeHandle(data.BaseType())
		resp.SubstConstraint = TypeHandle(data.SubstConstraint())
	case flags&checker.TypeFlagsTemplateLiteral != 0:
		tl := t.AsTemplateLiteralType()
		resp.Texts = tl.Texts()
		// types omitted; fetched via separate request
	case flags&checker.TypeFlagsStringMapping != 0:
		resp.Target = TypeHandle(t.AsStringMappingType().Target())
	case flags&checker.TypeFlagsTypeParameter != 0:
		resp.IsThisType = t.AsTypeParameter().IsThisType()
	case flags&checker.TypeFlagsIntrinsic != 0:
		resp.IntrinsicName = t.AsIntrinsicType().IntrinsicName()
	}

	return resp
}

func typeHandles(types []*checker.Type) []TypeID {
	if len(types) == 0 {
		return nil
	}
	handles := make([]TypeID, len(types))
	for i, t := range types {
		handles[i] = TypeHandle(t)
	}
	return handles
}

func literalValueToJSON(value any) any {
	switch v := value.(type) {
	case string:
		return v
	case jsnum.Number:
		if v.IsInf() {
			if v > 0 {
				return "+Infinity"
			}
			return "-Infinity"
		}
		if v.IsNaN() {
			return "NaN"
		}
		return float64(v)
	case bool:
		return v
	case jsnum.PseudoBigInt:
		// Encode bigint literals as a signed decimal string (e.g. "-123"); the
		// API client decodes this back into a real bigint. JSON has no bigint.
		return v.String()
	default:
		return nil
	}
}

type ConstantValueResponse struct {
	IsNumber bool `json:"isNumber"`
	Value    any  `json:"value"`
}

type SignatureResponse struct {
	Id             SignatureID              `json:"id"`
	Flags          uint32                   `json:"flags,omitzero"`
	Declaration    NodeHandle               `json:"declaration,omitempty"`
	TypeParameters []TypeID                 `json:"typeParameters,omitempty"`
	Parameters     []CompactSymbolReference `json:"parameters,omitempty"`
	ThisParameter  *CompactSymbolReference  `json:"thisParameter,omitempty"`
	Target         SignatureID              `json:"target,omitzero"`
}

type GetSourceFileParams struct {
	Snapshot SnapshotID         `json:"snapshot"`
	Project  project.Handle     `json:"project"`
	File     DocumentIdentifier `json:"file"`
}

type GetSourceFileNamesParams struct {
	Snapshot SnapshotID     `json:"snapshot"`
	Project  project.Handle `json:"project"`
}

type GetModeForUsageLocationParams struct {
	Snapshot SnapshotID         `json:"snapshot"`
	Project  project.Handle     `json:"project"`
	File     DocumentIdentifier `json:"file"`
	Usage    NodeHandle         `json:"usage"`
}

type GetModeForResolutionAtIndexParams struct {
	Snapshot SnapshotID         `json:"snapshot"`
	Project  project.Handle     `json:"project"`
	File     DocumentIdentifier `json:"file"`
	Index    int                `json:"index"`
}

type GetResolvedModuleParams struct {
	Snapshot   SnapshotID          `json:"snapshot"`
	Project    project.Handle      `json:"project"`
	File       DocumentIdentifier  `json:"file"`
	ModuleName string              `json:"moduleName"`
	Mode       core.ResolutionMode `json:"mode"`
}

type GetResolvedModuleFromModuleSpecifierParams struct {
	Snapshot        SnapshotID          `json:"snapshot"`
	Project         project.Handle      `json:"project"`
	ModuleSpecifier NodeHandle          `json:"moduleSpecifier"`
	SourceFile      *DocumentIdentifier `json:"sourceFile,omitempty"`
}

type GetResolvedTypeReferenceDirectiveParams struct {
	Snapshot          SnapshotID          `json:"snapshot"`
	Project           project.Handle      `json:"project"`
	File              DocumentIdentifier  `json:"file"`
	TypeDirectiveName string              `json:"typeDirectiveName"`
	Mode              core.ResolutionMode `json:"mode"`
}

type GetResolvedTypeReferenceDirectiveFromReferenceParams struct {
	Snapshot          SnapshotID          `json:"snapshot"`
	Project           project.Handle      `json:"project"`
	SourceFile        DocumentIdentifier  `json:"sourceFile"`
	TypeDirectiveName string              `json:"typeDirectiveName"`
	ResolutionMode    core.ResolutionMode `json:"resolutionMode"`
}

type PackageId struct {
	Name             string `json:"name"`
	SubModuleName    string `json:"subModuleName"`
	Version          string `json:"version"`
	PeerDependencies string `json:"peerDependencies"`
}

func NewPackageId(packageID module.PackageId) *PackageId {
	if packageID.Name == "" {
		return nil
	}
	return &PackageId{
		Name:             packageID.Name,
		SubModuleName:    packageID.SubModuleName,
		Version:          packageID.Version,
		PeerDependencies: packageID.PeerDependencies,
	}
}

type ResolvedModule struct {
	ResolvedFileName             string     `json:"resolvedFileName"`
	OriginalPath                 string     `json:"originalPath,omitempty"`
	Extension                    string     `json:"extension"`
	ResolvedUsingTsExtension     bool       `json:"resolvedUsingTsExtension,omitempty"`
	ResolvedUsingExtraExtensions bool       `json:"resolvedUsingExtraExtensions,omitempty"`
	PackageId                    *PackageId `json:"packageId,omitempty"`
	IsExternalLibraryImport      bool       `json:"isExternalLibraryImport,omitempty"`
	AlternateResult              string     `json:"alternateResult,omitempty"`
}

type ResolvedTypeReferenceDirective struct {
	Primary                 bool       `json:"primary"`
	ResolvedFileName        string     `json:"resolvedFileName"`
	OriginalPath            string     `json:"originalPath,omitempty"`
	PackageId               *PackageId `json:"packageId,omitempty"`
	IsExternalLibraryImport bool       `json:"isExternalLibraryImport,omitempty"`
}

// SourceFileMetadata carries program-stored metadata about a single source file.
type SourceFileMetadata struct {
	IsDefaultLibrary      bool                       `json:"isDefaultLibrary"`
	IsFromExternalLibrary bool                       `json:"isFromExternalLibrary"`
	PackageJsonType       string                     `json:"packageJsonType"`
	PackageJsonDirectory  tspath.RootedDirectoryPath `json:"packageJsonDirectory"`
	ImpliedNodeFormat     core.ResolutionMode        `json:"impliedNodeFormat"`
}

