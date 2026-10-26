				// there is no filesystem change to propagate. Open overlays remain authoritative,
				// so a Created event cannot change their active contents either.
				if s.fs.Overlays()[path] != nil {
					continue
				}
			} else if file := s.fs.GetFileByPath(uri.FileName(), path); file != nil && file.IsOverlay() {
				filteredChanged.Add(uri)
				continue
			}
			entry, ok := s.cacheFiles.Load(path)
			if !ok {
				filteredChanged.Add(uri)
				continue
			}
			wg.Queue(func() {
				if s.reloadEntryIfContentChanged(entry) {
					filteredChanged.Add(uri)
				}
			})
		}
		wg.RunAndWait()
		newSet := collections.NewSetWithSizeHint[lsproto.DocumentUri](filteredChanged.Size())
		for uri := range filteredChanged.Keys() {
			newSet.Add(uri)
		}
		return *newSet
	}

	change.Changed = filterChanges(change.Changed, false)
	change.Created = filterChanges(change.Created, true)

	for uri := range change.Deleted.Keys() {
		path := s.caseSensitivity.PathKey(uri.FileName().AsPath())
		if entry, ok := s.cacheFiles.Load(path); ok {
			s.deleteCacheEntry(entry)
		}
	}
	return change
}

func (s *snapshotFSBuilder) reloadEntryIfContentChanged(entry *dirty.SyncMapEntry[tspath.PathKey, *cachedFile]) (changed bool) {
	file := entry.Value()
	if file == nil {
		return true
	}
	content, ok := s.fs.ReadFile(file.fileName)
	changed = true
	entry.Locked(func(e dirty.Value[*cachedFile]) {
		cur := e.Value()
		if cur == nil {
			return
		}
		if !ok {
			e.Delete()
			return
		}
		if content == cur.content {
			changed = false
			if !cur.MatchesDiskText() {
				e.Change(func(file *cachedFile) {
					file.needsReload = false
				})
			}
			return
		}
		e.Change(func(file *cachedFile) {
			file.content = content
			file.hash = xxh3.HashString128(content)
			file.needsReload = false
		})
	})
	return changed
}

// expandRealpathAliases adds synthetic URIs to the Changed, Created, and Deleted sets for
// files that were accessed through node_modules symlinks. When a watch event arrives
// using a realpath, this expands it to include the symlink-based path so that
// downstream consumers (markDirtyFiles, markFilesChanged) can find cached entries.
func (s *SnapshotFS) expandRealpathAliases(change FileChangeSummary) FileChangeSummary {
	if len(s.nodeModulesRealpathAliases) == 0 {
		return change
	}

	expandSet := func(set *collections.Set[lsproto.DocumentUri]) {
		if set.Len() == 0 {
			return
		}
		var additional collections.Set[lsproto.DocumentUri]
		for uri := range set.Keys() {
			path := s.caseSensitivity.PathKey(uri.FileName().AsPath())
			if aliases, ok := s.nodeModulesRealpathAliases[path]; ok {
				for _, aliasFileName := range aliases.paths {
					additional.Add(lsconv.FileNameToDocumentURI(aliasFileName))
				}
			}
		}
		for uri := range additional.Keys() {
			set.Add(uri)
		}
	}

	expandSet(&change.Changed)
	expandSet(&change.Created)
	expandSet(&change.Deleted)

	if change.Created.Len() > 0 {
		createdDirectories := collections.NewSetWithSizeHint[tspath.PathKey](change.Created.Len())
		for uri := range change.Created.Keys() {
			createdDirectories.Add(s.caseSensitivity.PathKey(uri.FileName().AsPath()))
		}
		for realpath, aliases := range s.nodeModulesRealpathAliases {
			path := realpath
			for {
				if createdDirectories.Has(path) {
					for _, aliasFileName := range aliases.paths {
						change.Created.Add(lsconv.FileNameToDocumentURI(aliasFileName))
					}
					break
				}
				parent := path.Parent()
				if parent == path {
					break
				}
				path = parent
			}
		}
	}

	return change
}

// isRelevantFileName returns true if the given URI refers to a file that
// could affect the project: it has a TypeScript-relevant or configured content-mapper extension,
// is dynamic (e.g. untitled), or is present in the supplied open-file state.
func (s *snapshotFSBuilder) isRelevantFileName(uri lsproto.DocumentUri, contentMapperExtensions []string, contentMapperWatchedFiles *collections.Set[tspath.PathKey], openFiles map[tspath.PathKey]FileHandle) bool {
	fileName := uri.FileName()
	if contentMapperWatchedFiles != nil && contentMapperWatchedFiles.Has(s.caseSensitivity.PathKey(fileName.AsPath())) {
		return true
	}
	if fileName.ExtensionIsOneOf(contentMapperExtensions) {
		return true
	}
	if fileName.IsDynamic() {
		return true
	}
	if _, ok := openFiles[s.caseSensitivity.PathKey(fileName.AsPath())]; ok {
		return true
	}
	return isRelevantExtension(fileName.AnyExtension(nil, tspath.CaseSensitive))
}

// isRelevantExtension returns true if the given extension is a known TypeScript
// or JavaScript extension that can affect the project.
func isRelevantExtension(ext string) bool {
	switch ext {
	case ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts", ".json":
		return true
	}
	return false
}

// expandAndFilterWatchEvents expands directory deletion URIs into individual
// file deletion URIs using the cached directory structure, and filters out
// watch events for paths that are neither known directories nor have relevant
// file extensions.
func (s *snapshotFSBuilder) expandAndFilterWatchEvents(change FileChangeSummary, contentMapperExtensions []string, contentMapperWatchedFiles *collections.Set[tspath.PathKey], previousOpenFiles map[tspath.PathKey]FileHandle, openFiles map[tspath.PathKey]FileHandle) FileChangeSummary {
	if change.Deleted.Len() > 0 {
		var filteredDeleted collections.Set[lsproto.DocumentUri]
		for uri := range change.Deleted.Keys() {
			path := s.caseSensitivity.PathKey(uri.FileName().AsPath())
			if _, ok := s.cacheDirectories.Get(path); ok || hasOpenFileWithin(path, previousOpenFiles, openFiles) {
				s.collectFilesRecursive(path, &filteredDeleted, previousOpenFiles, openFiles)
			} else if s.isRelevantFileName(uri, contentMapperExtensions, contentMapperWatchedFiles, openFiles) || isNodeModulesPath(path) {
				// node_modules deletions must always be preserved for auto-import registry change handlers.
				// They won't be in cacheDirectories since the registry doesn't use the snapshotFSBuilder for
				// its file system, since we don't want to retain files read there.
				filteredDeleted.Add(uri)
			}
		}
		change.Deleted = filteredDeleted
	}

	if change.Changed.Len() > 0 {
		var filteredChanged collections.Set[lsproto.DocumentUri]
		for uri := range change.Changed.Keys() {
			if s.isRelevantFileName(uri, contentMapperExtensions, contentMapperWatchedFiles, openFiles) {
				filteredChanged.Add(uri)
			}
		}
		change.Changed = filteredChanged
	}

	// We can't filter created events because any created path could be a directory symlink
	// that includes relevant files. configFileRegistryBuilder will do check if these paths
	// are directories if they fall within a config's wildcard directories.

	return change
}

// isNodeModulesPath reports whether path is a node_modules directory itself or
// lives inside one. Used to preserve node_modules watch deletions, whose package
// files are read transiently and therefore never tracked in cacheDirectories.
func isNodeModulesPath(path tspath.PathKey) bool {
	s := string(path)
	return strings.HasSuffix(s, "/node_modules") || strings.Contains(s, "/node_modules/")
}

func hasOpenFileWithin(path tspath.PathKey, previousOpenFiles map[tspath.PathKey]FileHandle, openFiles map[tspath.PathKey]FileHandle) bool {
	for openFilePath := range openFiles {
		if path.ContainsPath(openFilePath) {
			return true
		}
	}
	for openFilePath := range previousOpenFiles {
		if path.ContainsPath(openFilePath) {
			return true
		}
	}
	return false
}

