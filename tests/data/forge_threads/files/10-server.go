			},
			CodeActionProvider: &lsproto.BooleanOrCodeActionOptions{
				CodeActionOptions: &lsproto.CodeActionOptions{
					CodeActionKinds: new(supportedCodeActionKinds()),
				},
			},
			CallHierarchyProvider: &lsproto.BooleanOrCallHierarchyOptionsOrCallHierarchyRegistrationOptions{
				Boolean: new(true),
			},
			Experimental: &lsproto.ExperimentalServerCapabilities{
				CustomSourceDefinitionProvider:       new(true),
				CustomMultiDocumentHighlightProvider: new(true),
			},
			VSReferencesProvider: new(true),
			VSOnAutoInsertProvider: &lsproto.VSOnAutoInsertOptions{
				VSTriggerCharacters: []string{">"},
			},
			Workspace: &lsproto.WorkspaceOptions{
				FileOperations: &lsproto.FileOperationOptions{
					WillRename: &lsproto.FileOperationRegistrationOptions{
						Filters: fileRenameFilters,
					},
				},
			},
			SemanticTokensProvider: &lsproto.SemanticTokensOptionsOrRegistrationOptions{
				Options: &lsproto.SemanticTokensOptions{
					Legend: ls.SemanticTokensLegend(s.clientCapabilities.TextDocument.SemanticTokens),
					Full: &lsproto.BooleanOrSemanticTokensFullDelta{
						Boolean: new(true),
					},
					Range: &lsproto.BooleanOrEmptyObject{
						Boolean: new(true),
					},
				},
			},
		},
	}

	return response, nil
}

func (s *Server) handleInitialized(ctx context.Context, params *lsproto.InitializedParams) error {
	var disablePushDiagnostics bool
	var enableTelemetry bool
	if s.initializationOptions.DisablePushDiagnostics != nil {
		disablePushDiagnostics = *s.initializationOptions.DisablePushDiagnostics
	}
	if s.initializationOptions.EnableTelemetry != nil {
		enableTelemetry = *s.initializationOptions.EnableTelemetry
	}
	var runExternalCode bool
	if s.initializationOptions.RunExternalCode != nil {
		runExternalCode = *s.initializationOptions.RunExternalCode
	}
	hasDynamicWatchRegistration := s.clientCapabilities.Workspace.DidChangeWatchedFiles.DynamicRegistration
	if hasDynamicWatchRegistration {
		s.logger.Logf("file watching: using LSP client-side watching (client supports dynamic registration)")
		s.watchEnabled = true
	} else if fswatch.Default().HasFastRecursiveBackend() {
		// The client cannot watch files itself, but the builtin watcher has a
		// backend with efficient recursive watching (Windows or FSEvents), so
		// fall back to watching files in-process.
		s.logger.Logf("file watching: using builtin in-process watcher (client lacks dynamic watch registration)")
		s.watchEnabled = true
		s.builtinWatcher = lspwatcher.New(s.fs, func(changes []*lsproto.FileEvent) {
			if s.session != nil {
				s.session.DidChangeWatchedFiles(s.backgroundCtx, changes)
			}
		}, s.logger)
	} else {
		// The client cannot watch files and the builtin watcher backend lacks
		// efficient recursive watching, so file watching is disabled.
		s.logger.Logf("file watching: disabled (client lacks dynamic watch registration and builtin watcher backend is not fast-recursive)")
	}

	workspaceRoots := getInitialWorkspaceRoots(s.initializeParams)

	cwd := s.cwd
	if s.clientCapabilities.Workspace.WorkspaceFolders &&
		s.initializeParams.WorkspaceFolders != nil &&
		s.initializeParams.WorkspaceFolders.WorkspaceFolders != nil &&
		len(*s.initializeParams.WorkspaceFolders.WorkspaceFolders) == 1 {
		if fileName := lsproto.DocumentUri((*s.initializeParams.WorkspaceFolders.WorkspaceFolders)[0].Uri).FileName(); fileName != "" {
			cwd = tspath.RootedDirectoryPathFromPath(tspath.RootedPath(fileName))
		}
	} else if s.initializeParams.RootUri.DocumentUri != nil {
		if fileName := s.initializeParams.RootUri.DocumentUri.FileName(); fileName != "" {
			cwd = tspath.RootedDirectoryPathFromPath(tspath.RootedPath(fileName))
		}
	} else if s.initializeParams.RootPath != nil && s.initializeParams.RootPath.String != nil {
		if rootPath := *s.initializeParams.RootPath.String; tspath.PathIsAbsolute(rootPath) {
			cwd = tspath.RootedDirectoryPathFromAbsolute(rootPath)
		}
	}

	s.telemetryEnabled = enableTelemetry

	s.session = project.NewSession(&project.SessionInit{
		BackgroundCtx: lsproto.WithClientCapabilities(s.backgroundCtx, &s.clientCapabilities),
		Options: &project.SessionOptions{
			CurrentDirectory:       cwd,
			DefaultLibraryPath:     s.defaultLibraryPath,
			TypingsLocation:        s.typingsLocation,
			PositionEncoding:       s.positionEncoding,
			WatchEnabled:           s.watchEnabled,
			LoggingEnabled:         true,
			TelemetryEnabled:       enableTelemetry,
			DebounceDelay:          500 * time.Millisecond,
			PushDiagnosticsEnabled: !disablePushDiagnostics,
			RunExternalCode:        runExternalCode,
			InitialWorkspaceRoots:  workspaceRoots,
		},
		FS:                  s.fs,
		Logger:              s.logger,
		Client:              s,
		NpmExecutor:         s,
		Spawner:             s.contentMapperSpawner(),
		ContentMapperLogger: s.contentMapperLogger(),
		ParseCache:          s.parseCache,
	})

	userPreferences, err := s.RequestConfiguration(ctx)
	if err != nil {
		return err
	}
	s.session.InitializeWithUserConfig(userPreferences)

	_, err = s.sendClientRequest(ctx, lsproto.ClientRegisterCapabilityInfo, &lsproto.RegistrationParams{
		Registrations: []*lsproto.Registration{
			{
				Id: "typescript-config-watch-id",
				RegisterOptions: &lsproto.RegisterOptions{
					WorkspaceDidChangeConfiguration: &lsproto.DidChangeConfigurationRegistrationOptions{
						Section: &lsproto.StringOrStrings{
							Strings: &[]string{"js/ts", "typescript", "javascript", "editor"},
						},
					},
				},
			},
		},
	})
	if err != nil {
		return fmt.Errorf("failed to register configuration change watcher: %w", err)
	}

	// !!! temporary.
	// Remove when we have `handleDidChangeConfiguration`/implicit project config support
	// derived from 'js/ts.implicitProjectConfig.*'.
	if s.compilerOptionsForInferredProjects != nil {
		s.session.DidChangeCompilerOptionsForInferredProjects(ctx, s.compilerOptionsForInferredProjects)
	}

	s.session.StartPerformanceTelemetry()

	close(s.initComplete)
	return nil
}

func (s *Server) handleShutdown(ctx context.Context, _ lsproto.NoParams, _ *lsproto.RequestMessage) (lsproto.ShutdownResponse, error) {
	if s.builtinWatcher != nil {
		s.builtinWatcher.Close()
	}
	s.closeAPISessions()
	s.session.Close()
	return lsproto.ShutdownResponse{}, nil
}

func (s *Server) handleExit(ctx context.Context, _ lsproto.NoParams) error {
	return io.EOF
}

func getInitialWorkspaceRoots(params *lsproto.InitializeParams) []tspath.RootedDirectoryPath {
	workspaceRoots := []tspath.RootedDirectoryPath{}
	if params.WorkspaceFolders != nil && params.WorkspaceFolders.WorkspaceFolders != nil {
		for _, folder := range *params.WorkspaceFolders.WorkspaceFolders {
			uri := lsproto.DocumentUri(folder.Uri)
			if strings.HasPrefix(string(uri), "file://") {
				workspaceRoots = append(workspaceRoots, tspath.RootedDirectoryPathFromPath(uri.Path()))
			}
		}
	} else if params.RootUri.DocumentUri != nil && strings.HasPrefix(string(*params.RootUri.DocumentUri), "file://") {
		workspaceRoots = append(workspaceRoots, tspath.RootedDirectoryPathFromPath(params.RootUri.DocumentUri.Path()))
	} else if params.RootPath != nil && params.RootPath.String != nil && tspath.PathIsAbsolute(*params.RootPath.String) {
		workspaceRoots = append(workspaceRoots, tspath.RootedDirectoryPathFromAbsolute(*params.RootPath.String))
	}
	return workspaceRoots
}

func (s *Server) handleDidChangeWorkspaceConfiguration(ctx context.Context, params *lsproto.DidChangeConfigurationParams) error {
	if params.Settings == nil {
		return nil
	} else if settings, ok := params.Settings.(map[string]any); ok {
		s.session.Configure(lsutil.ParseUserPreferences(settings))
	}
	return nil
}

func (s *Server) handleDidOpen(ctx context.Context, params *lsproto.DidOpenTextDocumentParams) error {
	s.session.DidOpenFile(ctx, params.TextDocument.Uri, params.TextDocument.Version, params.TextDocument.Text, params.TextDocument.LanguageId)
	return nil
}

func (s *Server) handleDidChange(ctx context.Context, params *lsproto.DidChangeTextDocumentParams) error {
	s.session.DidChangeFile(ctx, params.TextDocument.Uri, params.TextDocument.Version, params.ContentChanges)
	return nil
}

func (s *Server) handleDidSave(ctx context.Context, params *lsproto.DidSaveTextDocumentParams) error {
	s.session.DidSaveFile(ctx, params.TextDocument.Uri)
	return nil
}

func (s *Server) handleDidClose(ctx context.Context, params *lsproto.DidCloseTextDocumentParams) error {
	s.session.DidCloseFile(ctx, params.TextDocument.Uri)
	return nil
}

func (s *Server) handleDidChangeWatchedFiles(ctx context.Context, params *lsproto.DidChangeWatchedFilesParams) error {
	s.session.DidChangeWatchedFiles(ctx, params.Changes)
	return nil
}
