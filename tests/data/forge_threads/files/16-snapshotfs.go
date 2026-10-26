				file.hash = xxh3.HashString128(content)
				file.needsReload = false
			})
		} else {
			e.Delete()
		}
	})
	if entry.Value() == nil {
		return nil
	}
	return entry.Value()
}

func (s *snapshotFSBuilder) reloadEntryIfNeeded(entry *dirty.SyncMapEntry[tspath.PathKey, *cachedFile]) FileHandle {
	var fileName tspath.RootedFilePath
	entry.Locked(func(e dirty.Value[*cachedFile]) {
		if e.Value() != nil && !e.Value().MatchesDiskText() {
			fileName = e.Value().fileName
		}
	})
	if fileName != "" {
		// Read file outside the lock to avoid blocking other goroutines.
		content, ok := s.fs.ReadFile(fileName)
		entry.Locked(func(e dirty.Value[*cachedFile]) {
			if e.Value() == nil || e.Value().MatchesDiskText() {
				return // another goroutine already reloaded it
			}
			if ok {
				e.Change(func(file *cachedFile) {
					file.content = content
					file.hash = xxh3.HashString128(content)
					file.needsReload = false
				})
			} else {
				e.Delete()
			}
		})
	}
	if entry.Value() == nil {
		return nil
	}
	return entry.Value()
}

func (s *snapshotFSBuilder) watchChangesOverlapCache(change FileChangeSummary, previousOpenFiles map[tspath.PathKey]FileHandle, openFiles map[tspath.PathKey]FileHandle) bool {
	for _, changes := range []collections.Set[lsproto.DocumentUri]{change.Changed, change.Created, change.Deleted} {
		for uri := range changes.Keys() {
			path := s.caseSensitivity.PathKey(uri.FileName().AsPath())
			if previousOpenFiles[path] != nil || openFiles[path] != nil {
				return true
			}
			if _, ok := s.cacheFiles.Load(path); ok {
				return true
			}
			if _, ok := s.nodeModulesRealpathAliases.Load(path); ok {
				return true
			}
		}
	}
	return false
}

func (s *snapshotFSBuilder) expandCreatedCacheEntries(change FileChangeSummary) FileChangeSummary {
	if change.Created.Len() == 0 {
		return change
	}
	createdDirectories := collections.NewSetWithSizeHint[tspath.PathKey](change.Created.Len())
	for uri := range change.Created.Keys() {
		path := s.caseSensitivity.PathKey(uri.FileName().AsPath())
		if _, ok := s.cacheDirectories.Get(path); ok {
			createdDirectories.Add(path)
		}
	}
	for path := range createdDirectories.Keys() {
		s.collectFilesRecursive(path, &change.Created, nil, nil)
	}
	return change
}

func (s *snapshotFSBuilder) invalidateCache() {
	s.cacheFiles.Range(func(entry *dirty.SyncMapEntry[tspath.PathKey, *cachedFile]) bool {
		entry.Change(func(file *cachedFile) {
			file.needsReload = true
		})
		return true
	})
}

func (s *snapshotFSBuilder) invalidateNodeModulesCache() {
	s.cacheFiles.Range(func(entry *dirty.SyncMapEntry[tspath.PathKey, *cachedFile]) bool {
		if strings.Contains(string(entry.Key()), "/node_modules/") {
			entry.Change(func(file *cachedFile) {
				file.needsReload = true
			})
		}
		return true
	})
}

func (s *snapshotFSBuilder) markDirtyFiles(change FileChangeSummary) FileChangeSummary {
	filterChanges := func(changes collections.Set[lsproto.DocumentUri], created bool) collections.Set[lsproto.DocumentUri] {
		if changes.Len() == 0 {
			return changes
		}
		var filteredChanged collections.SyncSet[lsproto.DocumentUri]
		wg := core.NewWorkGroup(false)
		for uri := range changes.Keys() {
			path := s.caseSensitivity.PathKey(uri.FileName().AsPath())
			if created {
				// Cached Created paths represent replacements of files we already knew about.
				// If the disk content is unchanged, registries already contain the path and
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
