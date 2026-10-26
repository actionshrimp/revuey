	switch opt.extraValidation {
	case extraValidationLocale:
		if _, ok := locale.Parse(val.(string)); !ok {
			errors = append(errors, CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, valueExpression, diagnostics.Locale_must_be_an_IETF_BCP_47_language_tag_Examples_Colon_0_1, "en", "ja-jp"))
		}
	}

	if len(errors) > 0 {
		return nil, errors
	}
	return val, nil
}

func convertJsonOptionOfListType(
	option *CommandLineOption,
	values any,
	basePath tspath.RootedDirectoryPath,
	propertyAssignment *ast.PropertyAssignment,
	valueExpression *ast.Node,
	sourceFile *ast.SourceFile,
) ([]any, []*ast.Diagnostic) {
	var expression *ast.Node
	var errors []*ast.Diagnostic
	if values, ok := values.([]any); ok {
		mappedValues := core.MapIndex(values, func(v any, index int) any {
			if valueExpression != nil {
				expression = valueExpression.Elements()[index]
			}
			result, err := convertJsonOption(option.Elements(), v, basePath, propertyAssignment, expression, sourceFile)
			errors = append(errors, err...)
			return result
		})
		filteredValues := mappedValues
		if !option.listPreserveFalsyValues {
			filteredValues = core.Filter(mappedValues, func(v any) bool {
				return (v != nil && v != false && v != 0 && v != "")
			})
		}
		return filteredValues, errors
	}
	return nil, errors
}

const configDirTemplate = "${configDir}"

func startsWithConfigDirTemplate(value string) bool {
	return strings.HasPrefix(strings.ToLower(value), strings.ToLower(configDirTemplate))
}

func normalizeNonListOptionValue(option *CommandLineOption, basePath tspath.RootedDirectoryPath, value any) any {
	if option.PathKind.IsRooted() {
		path := tspath.NormalizeSlashes(value.(string))
		if !startsWithConfigDirTemplate(path) {
			path = tspath.GetNormalizedAbsolutePath(path, basePath)
		}
		if path == "" {
			path = "."
		}
		return path
	}
	return value
}

// isNetworkPathValue reports whether a path written in a config file refers
// to a network location once resolved against basePath. Checking the resolved
// path matches what the file system refuses to access, since normalization
// can add or remove a `/??/` prefix.
func isNetworkPathValue(value string, basePath tspath.RootedDirectoryPath) bool {
	return nativepath.IsNetworkPath(tspath.GetNormalizedAbsolutePath(value, basePath))
}

func convertJsonOption(
	opt *CommandLineOption,
	value any,
	basePath tspath.RootedDirectoryPath,
	propertyAssignment *ast.PropertyAssignment,
	valueExpression *ast.Expression,
	sourceFile *ast.SourceFile,
) (any, []*ast.Diagnostic) {
	if opt.IsCommandLineOnly {
		var nodeValue *ast.Node
		if propertyAssignment != nil {
			nodeValue = propertyAssignment.Name()
		}
		if sourceFile == nil && nodeValue == nil {
			return nil, []*ast.Diagnostic{ast.NewCompilerDiagnostic(diagnostics.Option_0_can_only_be_specified_on_command_line, opt.Name)}
		} else {
			return nil, []*ast.Diagnostic{CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, nodeValue, diagnostics.Option_0_can_only_be_specified_on_command_line, opt.Name)}
		}
	}
	if isCompilerOptionsValue(opt, value) {
		switch opt.Kind {
		case CommandLineOptionTypeList:
			return convertJsonOptionOfListType(opt, value, basePath, propertyAssignment, valueExpression, sourceFile) // as ArrayLiteralExpression | undefined
		case CommandLineOptionTypeListOrElement:
			if reflect.TypeOf(value).Kind() == reflect.Slice {
				return convertJsonOptionOfListType(opt, value, basePath, propertyAssignment, valueExpression, sourceFile)
			} else {
				return convertJsonOption(opt.Elements(), value, basePath, propertyAssignment, valueExpression, sourceFile)
			}
		case CommandLineOptionTypeEnum:
			if value == nil {
				return nil, nil
			}
			return convertJsonOptionOfEnumType(opt, value.(string), valueExpression, sourceFile)
		}

		validatedValue, errors := validateJsonOptionValue(opt, value, valueExpression, sourceFile)
		if len(errors) > 0 || validatedValue == nil {
			return validatedValue, errors
		} else if path, ok := validatedValue.(string); ok && opt.PathKind.IsRooted() && isNetworkPathValue(path, basePath) {
			return nil, []*ast.Diagnostic{CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, valueExpression, diagnostics.Network_path_0_is_not_supported, path)}
		} else {
			return normalizeNonListOptionValue(opt, basePath, validatedValue), errors
		}
	} else {
		return nil, []*ast.Diagnostic{CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(sourceFile, valueExpression, diagnostics.Compiler_option_0_requires_a_value_of_type_1, opt.Name, getCompilerOptionValueTypeString(opt))}
	}
}

func getExtendsConfigPathOrArray(
	value CompilerOptionsValue,
	fs vfs.FS,
	basePath tspath.RootedDirectoryPath,
	configFileName tspath.RootedFilePath,
	propertyAssignment *ast.PropertyAssignment,
	valueExpression *ast.Expression,
	sourceFile *ast.SourceFile,
) ([]tspath.RootedFilePath, []*ast.Diagnostic) {
	var extendedConfigPathArray []tspath.RootedFilePath
	newBase := basePath
	if configFileName != "" {
		newBase = configFileName.Directory()
	}
	if value == nil {
		_, errors := convertJsonOption(extendsOptionDeclaration, value, basePath, propertyAssignment, valueExpression, sourceFile)
		return extendedConfigPathArray, errors
	}
	if reflect.TypeOf(value).Kind() == reflect.String {
		val, err := getExtendsConfigPath(value.(string), fs, newBase, valueExpression, sourceFile)
		if val != "" {
			extendedConfigPathArray = append(extendedConfigPathArray, val)
		}
		return extendedConfigPathArray, err
	}
	var errors []*ast.Diagnostic
	if reflect.TypeOf(value).Kind() == reflect.Slice {
		for index, fileName := range value.([]any) {
			var expression *ast.Expression = nil
			if valueExpression != nil {
				expression = valueExpression.Elements()[index]
			}
			if reflect.TypeOf(fileName).Kind() == reflect.String {
				val, err := getExtendsConfigPath(fileName.(string), fs, newBase, expression, sourceFile)
				if val != "" {
					extendedConfigPathArray = append(extendedConfigPathArray, val)
				}
				errors = append(errors, err...)
			} else {
				_, err := convertJsonOption(extendsOptionDeclaration.Elements(), value, basePath, propertyAssignment, expression, sourceFile)
				errors = append(errors, err...)
			}
		}
	} else {
		_, errors = convertJsonOption(extendsOptionDeclaration, value, basePath, propertyAssignment, valueExpression, sourceFile)
	}
	return extendedConfigPathArray, errors
}

func getExtendsConfigPath(
	extendedConfig string,
	fs vfs.FS,
	basePath tspath.RootedDirectoryPath,
	valueExpression *ast.Expression,
	sourceFile *ast.SourceFile,
) (tspath.RootedFilePath, []*ast.Diagnostic) {
	extendedConfig = tspath.NormalizeSlashes(extendedConfig)
	var errors []*ast.Diagnostic
	var errorFile *ast.SourceFile
	if sourceFile != nil {
		errorFile = sourceFile
	}
	if isNetworkPathValue(extendedConfig, basePath) {
		errors = append(errors, CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(errorFile, valueExpression, diagnostics.Network_path_0_is_not_supported, extendedConfig))
		return "", errors
	}
	if tspath.IsRootedDiskPath(extendedConfig) || strings.HasPrefix(extendedConfig, "./") || strings.HasPrefix(extendedConfig, "../") {
		extendedConfigPath := tspath.ToRootedFilePath(extendedConfig, basePath)
		if !fs.FileExists(extendedConfigPath) && !extendedConfigPath.ExtensionIs(tspath.ExtensionJson) {
			extendedConfigPath = extendedConfigPath.AppendSuffix(tspath.ExtensionJson)
			if !fs.FileExists(extendedConfigPath) {
				errors = append(errors, CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(errorFile, valueExpression, diagnostics.File_0_not_found, extendedConfig))
				return "", errors
			}
		}
		return extendedConfigPath, errors
	}
	// If the path isn't a rooted or relative path, resolve like a module
	if resolved := module.ResolveConfig(extendedConfig, basePath.ResolveFile("tsconfig.json"), fs); resolved.IsResolved() {
		return resolved.ResolvedFileName, errors
	}
	if extendedConfig == "" {
		errors = append(errors, CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(errorFile, valueExpression, diagnostics.Compiler_option_0_cannot_be_given_an_empty_string, "extends"))
	} else {
		errors = append(errors, CreateDiagnosticForNodeInSourceFileOrCompilerDiagnostic(errorFile, valueExpression, diagnostics.File_0_not_found, extendedConfig))
	}
	return "", errors
}

type tsConfigOptions struct {
	prop       map[string][]string
	references []*core.ProjectReference
	notDefined string
}

type CommandLineOptionNameMap map[string]*CommandLineOption

func (m CommandLineOptionNameMap) Get(name string) *CommandLineOption {
	opt, ok := m[name]
	if !ok {
		opt, _ = m[strings.ToLower(name)]
	}
