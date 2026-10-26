		name,
		maps.Values(m),
		func(option *CommandLineOption) string { return option.Name },
		func(a *CommandLineOption, b *CommandLineOption) int { return strings.Compare(a.Name, b.Name) },
	)
}

func commandLineOptionsToMap(compilerOptions []*CommandLineOption) CommandLineOptionNameMap {
	result := make(map[string]*CommandLineOption, len(compilerOptions)*2)
	for i := range compilerOptions {
		result[compilerOptions[i].Name] = compilerOptions[i]
		result[strings.ToLower(compilerOptions[i].Name)] = compilerOptions[i]
	}
	return result
}

var CommandLineCompilerOptionsMap CommandLineOptionNameMap = commandLineOptionsToMap(OptionsDeclarations)

func convertMapToOptions[O optionParser](compilerOptions *collections.OrderedMap[string, any], result O) O {
	// Values have already been validated and converted.
	for key, value := range compilerOptions.Entries() {
		result.ParseOption(key, value)
	}
	return result
}

func convertOptionsFromJson[O optionParser](optionsNameMap CommandLineOptionNameMap, jsonOptions any, basePath tspath.RootedDirectoryPath, result O) (O, []*ast.Diagnostic) {
	if jsonOptions == nil {
		return result, nil
	}
	jsonMap, ok := jsonOptions.(*collections.OrderedMap[string, any])
	if !ok {
		// !!! probably should be an error
		return result, nil
	}
	var errors []*ast.Diagnostic
	for key, value := range jsonMap.Entries() {
		opt := optionsNameMap.Get(key)
		if opt != nil && opt.Name != key {
			// Case-insensitive match found but exact case doesn't match - provide "did you mean" suggestion
			errors = append(errors, CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(nil, nil, result.UnknownDidYouMeanDiagnostic(), key, opt.Name))
			continue
		}
		if opt == nil {
			errors = append(errors, createUnknownOptionError(key, result.UnknownOptionDiagnostic(), "", nil, nil, nil, result.UnknownDidYouMeanDiagnostic(), optionsNameMap))
			continue
		}

		convertJson, err := convertJsonOption(opt, value, basePath, nil, nil, nil)
		errors = append(errors, err...)
		result.ParseOption(key, convertJson)
	}
	return result, errors
}

func convertArrayLiteralExpressionToJson(
	sourceFile *ast.SourceFile,
	elements []*ast.Expression,
	elementOption *CommandLineOption,
	returnValue bool,
) (any, []*ast.Diagnostic) {
	if !returnValue {
		for _, element := range elements {
			convertPropertyValueToJson(sourceFile, element, elementOption, returnValue, nil)
		}
		return nil, nil
	}
	// Filter out invalid values
	if len(elements) == 0 {
		// Always return an empty array, even if elements is nil.
		// The parser will produce nil slices instead of allocating empty ones.
		return []any{}, nil
	}
	var errors []*ast.Diagnostic
	var value []any
	for _, element := range elements {
		convertedValue, err := convertPropertyValueToJson(sourceFile, element, elementOption, returnValue, nil)
		errors = append(errors, err...)
		if convertedValue != nil {
			value = append(value, convertedValue)
		}
	}
	return value, errors
}

// ParseConfigFileTextToJson parses the text of the tsconfig.json file
// fileName is the path to the config file
// jsonText is the text of the config file
func ParseConfigFileTextToJson(fileName tspath.RootedFilePath, path tspath.PathKey, jsonText string) (any, []*ast.Diagnostic) {
	jsonSourceFile := parser.ParseSourceFile(ast.SourceFileParseOptions{
		FileName: fileName,
		PathKey:  path,
	}, jsonText, core.ScriptKindJSON)
	config, errors := convertConfigFileToObject(jsonSourceFile /*jsonConversionNotifier*/, nil)
	if len(jsonSourceFile.Diagnostics()) > 0 {
		errors = []*ast.Diagnostic{jsonSourceFile.Diagnostics()[0]}
	}
	return config, errors
}

type ParseConfigHost interface {
	FS() vfs.FS
	IsContentMapperPackageAllowed(packageDirectory tspath.RootedDirectoryPath) bool
}

type defaultParseConfigHost struct {
	fs vfs.FS
}

// NewDefaultParseConfigHost leaves external code authorization to the runExternalCode option.
func NewDefaultParseConfigHost(fs vfs.FS) ParseConfigHost {
	return &defaultParseConfigHost{fs: fs}
}

func (h *defaultParseConfigHost) FS() vfs.FS {
	return h.fs
}

func (h *defaultParseConfigHost) IsContentMapperPackageAllowed(packageDirectory tspath.RootedDirectoryPath) bool {
	return true
}

func ParseJsonSourceFileConfigFileContent(
	sourceFile *TsConfigSourceFile,
	host ParseConfigHost,
	basePath tspath.RootedDirectoryPath,
	existingOptions *core.CompilerOptions,
	existingOptionsRaw *collections.OrderedMap[string, any],
	resolutionStack []tspath.PathKey,
	extendedConfigCache ExtendedConfigCache,
) *ParsedCommandLine {
	// tracing?.push(tracing.Phase.Parse, "parseJsonSourceFileConfigFileContent", { path: sourceFile.fileName });
	result := parseJsonConfigFileContentWorker(nil /*json*/, sourceFile, host, basePath, existingOptions, existingOptionsRaw, sourceFile.SourceFile.FileName(), resolutionStack, extendedConfigCache)
	// tracing?.pop();
	return result
}

func convertObjectLiteralExpressionToJson(
	sourceFile *ast.SourceFile,
	returnValue bool,
	node *ast.ObjectLiteralExpression,
	objectOption *CommandLineOption,
	jsonConversionNotifier *jsonConversionNotifier,
) (*collections.OrderedMap[string, any], []*ast.Diagnostic) {
	var result *collections.OrderedMap[string, any]
	if returnValue {
		result = &collections.OrderedMap[string, any]{}
	}
	var errors []*ast.Diagnostic
	for _, element := range node.Properties.Nodes {
		if element.Kind != ast.KindPropertyAssignment {
			errors = append(errors, ast.NewDiagnostic(sourceFile, element.Loc, diagnostics.Property_assignment_expected))
			continue
		}

		if token := element.QuestionToken(); token != nil {
			errors = append(errors, ast.NewDiagnostic(sourceFile, token.Loc, diagnostics.The_0_modifier_can_only_be_used_in_TypeScript_files, "?"))
		}
		textOfKey := ""
		if !ast.IsComputedNonLiteralName(element.Name()) {
			textOfKey, _ = ast.TryGetTextOfPropertyName(element.Name())
		}
		keyText := textOfKey
		var option *CommandLineOption = nil
		if keyText != "" && objectOption != nil && objectOption.ElementOptions != nil {
			option = objectOption.ElementOptions.Get(keyText)
			if option != nil && option.Name != keyText {
				option = nil
			}
		}
		value, err := convertPropertyValueToJson(sourceFile, element.AsPropertyAssignment().Initializer, option, returnValue, jsonConversionNotifier)
		errors = append(errors, err...)
		if keyText != "" {
			if returnValue {
				result.Set(keyText, value)
			}
			// Notify key value set, if user asked for it
			if jsonConversionNotifier != nil {
				_, err := jsonConversionNotifier.onPropertySet(keyText, value, element.AsPropertyAssignment(), objectOption, option)
				errors = append(errors, err...)
			}
		}
	}
	return result, errors
}

// convertToJson converts the json syntax tree into the json value and report errors
// This returns the json value (apart from checking errors) only if returnValue provided is true.
// Otherwise it just checks the errors and returns undefined
func convertToJson(
	sourceFile *ast.SourceFile,
	rootExpression *ast.Expression,
	returnValue bool,
	jsonConversionNotifier *jsonConversionNotifier,
) (any, []*ast.Diagnostic) {
	if rootExpression == nil {
		if returnValue {
			return struct{}{}, nil
		} else {
			return nil, nil
		}
	}
	var rootOptions *CommandLineOption
	if jsonConversionNotifier != nil {
		rootOptions = jsonConversionNotifier.rootOptions
	}
	return convertPropertyValueToJson(sourceFile, rootExpression, rootOptions, returnValue, jsonConversionNotifier)
}

func isDoubleQuotedString(node *ast.Node) bool {
	return ast.IsStringLiteral(node)
}

func convertPropertyValueToJson(sourceFile *ast.SourceFile, valueExpression *ast.Expression, option *CommandLineOption, returnValue bool, jsonConversionNotifier *jsonConversionNotifier) (any, []*ast.Diagnostic) {
	switch valueExpression.Kind {
	case ast.KindTrueKeyword:
		return true, nil
	case ast.KindFalseKeyword:
		return false, nil
	case ast.KindNullKeyword: // todo: how to manage null
		return nil, nil
