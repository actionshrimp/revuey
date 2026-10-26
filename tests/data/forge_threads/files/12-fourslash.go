			}
		}
		f.activeFilename = f.testData.Files[0].fileName
	}

	return f, func() {
		t.Helper()
		err := closeClient()
		if err != nil {
			t.Errorf("goroutine error: %v", err)
		}
		f.verifyBaselines(t, testPath)
	}
}

// handleServerRequest handles requests initiated by the server (e.g., workspace/configuration).
func (f *FourslashTest) handleServerRequest(_ context.Context, req *lsproto.RequestMessage) *lsproto.ResponseMessage {
	switch req.Method {
	case lsproto.MethodWorkspaceConfiguration:
		// Return current user preferences for each requested section.
		// The server requests multiple sections (js/ts, typescript, javascript, editor);
		// we return user preferences for "js/ts" and nil for others.
		params, err := req.UnmarshalParams[*lsproto.ConfigurationParams]()
		if err != nil || params == nil || params.Items == nil {
			return &lsproto.ResponseMessage{
				ID:      req.ID,
				JSONRPC: req.JSONRPC,
				Result:  []any{f.userPreferences},
			}
		}
		results := make([]any, len(params.Items))
		for i, item := range params.Items {
			if item.Section != nil && *item.Section == "js/ts" {
				results[i] = f.userPreferences
			}
		}
		return &lsproto.ResponseMessage{
			ID:      req.ID,
			JSONRPC: req.JSONRPC,
			Result:  results,
		}

	case lsproto.MethodClientRegisterCapability:
		// Accept all capability registrations
		return &lsproto.ResponseMessage{
			ID:      req.ID,
			JSONRPC: req.JSONRPC,
			Result:  lsproto.Null{},
		}

	case lsproto.MethodClientUnregisterCapability:
		// Accept all capability unregistrations
		return &lsproto.ResponseMessage{
			ID:      req.ID,
			JSONRPC: req.JSONRPC,
			Result:  lsproto.Null{},
		}

	default:
		// Unknown server request
		return &lsproto.ResponseMessage{
			ID:      req.ID,
			JSONRPC: req.JSONRPC,
			Error: &jsonrpc.ResponseError{
				Code:    int32(lsproto.ErrorCodeMethodNotFound),
				Message: fmt.Sprintf("Unknown method: %s", req.Method),
			},
		}
	}
}

func getBaseFileNameFromTest(t *testing.T) string {
	name := t.Name()
	name = core.LastOrNil(strings.Split(name, "/"))
	name = strings.TrimPrefix(name, "Test")
	name = stringutil.LowerFirstChar(name)

	// Special case: TypeScript has "callHierarchyFunctionAmbiguity.N" with periods
	switch name {
	case "callHierarchyFunctionAmbiguity1":
		name = "callHierarchyFunctionAmbiguity.1"
	case "callHierarchyFunctionAmbiguity2":
		name = "callHierarchyFunctionAmbiguity.2"
	case "callHierarchyFunctionAmbiguity3":
		name = "callHierarchyFunctionAmbiguity.3"
	case "callHierarchyFunctionAmbiguity4":
		name = "callHierarchyFunctionAmbiguity.4"
	case "callHierarchyFunctionAmbiguity5":
		name = "callHierarchyFunctionAmbiguity.5"
	}

	return name
}

const showCodeLensLocationsCommandName = "typescript.showCodeLensLocations"

func (f *FourslashTest) initialize(t *testing.T, options *FourslashOptions) {
	initializationOptions := &lsproto.InitializationOptions{
		CodeLensShowLocationsCommandName: new(showCodeLensLocationsCommandName),
		TrackFlakyDiagnostics:            options.TrackFlakyDiagnostics,
	}
	if options.RunExternalCode {
		initializationOptions.RunExternalCode = new(true)
	}
	params := &lsproto.InitializeParams{
		Locale: new("en-US"),
		InitializationOptions: &lsproto.InitializationOptionsOrNull{
			InitializationOptions: initializationOptions,
		},
	}
	if options.RunExternalCode {
		params.RootUri = lsproto.DocumentUriOrNull{DocumentUri: new(lsproto.DocumentUri("file:///"))}
	}
	params.Capabilities = getCapabilitiesWithDefaults(options.Capabilities)
	f.capabilities = params.Capabilities
	resp, _, ok := f.client.SendRequest(t, lsproto.InitializeInfo, params)
	if !ok {
		t.Fatalf("Initialize request failed")
	}
	if resp.AsResponse().Error != nil {
		t.Fatalf("Initialize request returned error: %s", resp.AsResponse().Error.String())
	}
	f.client.SendNotification(t, lsproto.InitializedInfo, &lsproto.InitializedParams{})

	// Wait for the initial configuration exchange to complete
	// The server will send workspace/configuration as part of handleInitialized
	<-f.client.Server.InitComplete()
}

func defaultSemanticTokenTypes() []string {
	return []string{
		string(lsproto.SemanticTokenTypeNamespace),
		string(lsproto.SemanticTokenTypeClass),
		string(lsproto.SemanticTokenTypeEnum),
		string(lsproto.SemanticTokenTypeInterface),
		string(lsproto.SemanticTokenTypeStruct),
		string(lsproto.SemanticTokenTypeTypeParameter),
		string(lsproto.SemanticTokenTypeType),
		string(lsproto.SemanticTokenTypeParameter),
		string(lsproto.SemanticTokenTypeVariable),
		string(lsproto.SemanticTokenTypeProperty),
		string(lsproto.SemanticTokenTypeEnumMember),
		string(lsproto.SemanticTokenTypeDecorator),
		string(lsproto.SemanticTokenTypeEvent),
		string(lsproto.SemanticTokenTypeFunction),
		string(lsproto.SemanticTokenTypeMethod),
		string(lsproto.SemanticTokenTypeMacro),
		string(lsproto.SemanticTokenTypeLabel),
		string(lsproto.SemanticTokenTypeComment),
		string(lsproto.SemanticTokenTypeString),
		string(lsproto.SemanticTokenTypeKeyword),
		string(lsproto.SemanticTokenTypeNumber),
		string(lsproto.SemanticTokenTypeRegexp),
		string(lsproto.SemanticTokenTypeOperator),
	}
}

func defaultSemanticTokenModifiers() []string {
	return []string{
		string(lsproto.SemanticTokenModifierDeclaration),
		string(lsproto.SemanticTokenModifierDefinition),
		string(lsproto.SemanticTokenModifierReadonly),
		string(lsproto.SemanticTokenModifierStatic),
		string(lsproto.SemanticTokenModifierDeprecated),
		string(lsproto.SemanticTokenModifierAbstract),
		string(lsproto.SemanticTokenModifierAsync),
		string(lsproto.SemanticTokenModifierModification),
		string(lsproto.SemanticTokenModifierDocumentation),
		string(lsproto.SemanticTokenModifierDefaultLibrary),
		"local",
	}
}

// If modifying the defaults, update GetDefaultCapabilities too.
var (
	ptrTrue                       = new(true)
	ptrFalse                      = new(false)
	defaultCompletionCapabilities = &lsproto.CompletionClientCapabilities{
		CompletionItem: &lsproto.ClientCompletionItemOptions{
			SnippetSupport:          ptrFalse,
			CommitCharactersSupport: ptrTrue,
			PreselectSupport:        ptrTrue,
			LabelDetailsSupport:     ptrFalse,
			InsertReplaceSupport:    ptrTrue,
			DocumentationFormat:     &[]lsproto.MarkupKind{lsproto.MarkupKindMarkdown, lsproto.MarkupKindPlainText},
		},
		CompletionList: &lsproto.CompletionListCapabilities{
			ItemDefaults: &[]string{"commitCharacters", "editRange"},
		},
	}
	defaultDefinitionCapabilities = &lsproto.DefinitionClientCapabilities{
		LinkSupport: ptrTrue,
	}
	defaultTypeDefinitionCapabilities = &lsproto.TypeDefinitionClientCapabilities{
		LinkSupport: ptrTrue,
	}
	defaultImplementationCapabilities = &lsproto.ImplementationClientCapabilities{
		LinkSupport: ptrTrue,
	}
	defaultHoverCapabilities = &lsproto.HoverClientCapabilities{
		ContentFormat: &[]lsproto.MarkupKind{lsproto.MarkupKindMarkdown, lsproto.MarkupKindPlainText},
	}
	defaultExperimentalCapabilities = &lsproto.ExperimentalClientCapabilities{
		HoverVerbosityLevel: ptrTrue,
	}
	defaultSignatureHelpCapabilities = &lsproto.SignatureHelpClientCapabilities{
		SignatureInformation: &lsproto.ClientSignatureInformationOptions{
			DocumentationFormat: &[]lsproto.MarkupKind{lsproto.MarkupKindMarkdown, lsproto.MarkupKindPlainText},
			ParameterInformation: &lsproto.ClientSignatureParameterInformationOptions{
				LabelOffsetSupport: ptrTrue,
			},
			ActiveParameterSupport: ptrTrue,
		},
		ContextSupport: ptrTrue,
	}
	defaultDocumentSymbolCapabilities = &lsproto.DocumentSymbolClientCapabilities{
		HierarchicalDocumentSymbolSupport: ptrTrue,
	}
	defaultFoldingRangeCapabilities = &lsproto.FoldingRangeClientCapabilities{
		RangeLimit: new(uint32(5000)),
		// LineFoldingOnly: ptrTrue,
