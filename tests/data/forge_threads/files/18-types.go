}

func (t *LiteralType) RegularType() *Type {
	return t.regularType
}

func (t *LiteralType) String() string {
	return ValueToString(t.value)
}

// UniqueESSymbolTypeData

type UniqueESSymbolType struct {
	TypeBase
	name string
}

// ConstrainedType (type with computed base constraint)

type ConstrainedType struct {
	TypeBase
	resolvedBaseConstraint *Type
}

func (t *ConstrainedType) AsConstrainedType() *ConstrainedType { return t }

// StructuredType (base of all types with members)

type StructuredType struct {
	ConstrainedType
	members    ast.SymbolTable
	properties []*ast.Symbol
	extra      *structuredTypeExtra
}

type structuredTypeExtra struct {
	signatures         []*Signature // Signatures (call + construct)
	callSignatureCount int          // Count of call signatures
	indexInfos         []*IndexInfo

	objectTypeWithoutAbstractConstructSignatures *Type
}

func (t *StructuredType) AsStructuredType() *StructuredType { return t }

func (t *StructuredType) CallSignatures() []*Signature {
	if t.extra == nil {
		return nil
	}
	return slices.Clip(t.extra.signatures[:t.extra.callSignatureCount])
}

func (t *StructuredType) ConstructSignatures() []*Signature {
	if t.extra == nil {
		return nil
	}
	return slices.Clip(t.extra.signatures[t.extra.callSignatureCount:])
}

func (t *StructuredType) getMember(name string) *ast.Symbol {
	if t.members != nil {
		return t.members[name]
	}
	lazy := t.getLazyState()
	if lazy == nil {
		return nil
	}
	memberInfo := lazy.layout.memberInfoMap[name]
	if memberInfo == nil {
		return nil
	}
	return t.getPropertyAt(int(memberInfo.slotIndex))
}

func (t *StructuredType) getMembers() ast.SymbolTable {
	if t.members == nil {
		if properties := t.getProperties(); len(properties) != 0 {
			t.members = make(ast.SymbolTable, len(properties))
			for _, member := range properties {
				t.members[member.Name()] = member
			}
		}
	}
	return t.members
}

func (t *StructuredType) getPropertyAt(index int) *ast.Symbol {
	lazy := t.getLazyState()
	if lazy == nil {
		return t.properties[index]
	}
	if t.properties == nil {
		t.properties = make([]*ast.Symbol, len(lazy.layout.memberInfos))
	}
	member := t.properties[index]
	if member == nil {
		memberInfo := lazy.layout.memberInfos[index]
		if memberInfo.baseIndex < 0 {
			member = t.checker.instantiateSymbol(memberInfo.symbol, lazy.mapper)
		} else {
			member = t.checker.getPropertyOfType(lazy.baseTypes[memberInfo.baseIndex], memberInfo.symbol.Name())
		}
		t.properties[index] = member
	}
	return member
}

func (t *StructuredType) getProperties() []*ast.Symbol {
	if lazy := t.getLazyState(); lazy != nil && !lazy.propertiesResolved {
		for i := range lazy.layout.memberInfos {
			t.getPropertyAt(i)
		}
		lazy.propertiesResolved = true
	}
	return t.AsStructuredType().properties
}

func (t *StructuredType) hasProperties() bool {
	if len(t.properties) != 0 {
		return true
	}
	lazy := t.getLazyState()
	if lazy == nil {
		return false
	}
	return len(lazy.layout.memberInfos) != 0
}

func (t *StructuredType) getLazyState() *LazyState {
	if t.objectFlags&(ObjectFlagsClassOrInterface|ObjectFlagsReference) != 0 {
		return t.AsType().AsTypeReference().lazy
	}
	return nil
}

func (t *StructuredType) getSignatures() []*Signature {
	if t.extra == nil {
		return nil
	}
	return t.extra.signatures
}

func (t *StructuredType) getIndexInfos() []*IndexInfo {
	if t.extra == nil {
		return nil
	}
	return t.extra.indexInfos
}

func (t *StructuredType) ensureExtra() *structuredTypeExtra {
	if t.extra == nil {
		t.extra = t.checker.structuredTypeExtraArena.New()
	}
	return t.extra
}

func (t *StructuredType) Properties() []*ast.Symbol {
	return t.getProperties()
}

// Except for tuple type references and reverse mapped types, all object types have an associated symbol.
// Possible object type instances are listed in the following.

// InterfaceType:
// ObjectFlagsClass: Originating non-generic class type
// ObjectFlagsClass|ObjectFlagsReference: Originating generic class type
// ObjectFlagsInterface: Originating non-generic interface type
// ObjectFlagsInterface|ObjectFlagsReference: Originating generic interface type

// TupleType:
// ObjectFlagsReference|ObjectFlagsTuple: Originating generic tuple type (synthesized)

// TypeReference
// ObjectFlagsReference: Instantiated generic class, interface, or tuple type

// ObjectType:
// ObjectFlagsAnonymous: Originating anonymous object type
// ObjectFlagsAnonymous|ObjectFlagsInstantiated: Instantiated anonymous object type

// MappedType:
// ObjectFlagsMapped: Originating mapped type
// ObjectFlagsMapped|ObjectFlagsInstantiated: Instantiated mapped type

// InstantiationExpressionType:
// ObjectFlagsAnonymous|ObjectFlagsInstantiationExpression: Originating instantiation expression type
// ObjectFlagsAnonymous|ObjectFlagsInstantiated|ObjectFlagsInstantiationExpression: Instantiated instantiation expression type

// ReverseMappedType:
// ObjectFlagsAnonymous|ObjectFlagsReverseMapped: Reverse mapped type

// EvolvingArrayType:
// ObjectFlagsEvolvingArray: Evolving array type

type ObjectType struct {
	StructuredType
	target         *Type                  // Target of instantiated type
	mapper         *TypeMapper            // Type mapper for instantiated type
	instantiations map[CacheHashKey]*Type // Map of type instantiations
}

func (t *ObjectType) AsObjectType() *ObjectType { return t }

// TypeReference (instantiation of an InterfaceType)

type TypeReference struct {
	ObjectType
	node                  *ast.Node // TypeReferenceNode | ArrayTypeNode | TupleTypeNode when deferred, else nil
	resolvedTypeArguments []*Type
	lazy                  *LazyState // Resolved member layout and instantiation state
}

type LazyState struct {
	layout             *MemberLayout
	mapper             *TypeMapper
	baseTypes          []*Type
	propertiesResolved bool
}

type MemberLayout struct {
	id               uint32                 // Unique identifier for the member layout
	memberInfoMap    map[string]*MemberInfo // MemberInfos keyed by property name
