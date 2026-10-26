			events.openChange = &change
			events.watchChanged = false
			events.changes = nil
			events.saved = false
			events.created = false
			events.deleted = false
		case FileChangeKindClose:
			events.closeChange = &change
			events.changes = nil
			events.saved = false
			events.watchChanged = false
		case FileChangeKindChange:
			if events.closeChange != nil {
				panic("should see no changes after close")
			}
			events.changes = append(events.changes, &change)
			events.saved = false
			events.watchChanged = false
		case FileChangeKindSave:
			events.saved = true
		case FileChangeKindWatchCreate:
			if events.deleted {
				// Delete followed by create becomes a change
				events.deleted = false
				events.watchChanged = true
			} else {
				events.created = true
			}
		case FileChangeKindWatchChange:
			if !events.created {
				events.watchChanged = true
				events.saved = false
			}
		case FileChangeKindWatchDelete:
			events.watchChanged = false
			events.saved = false
			// Delete after create cancels out
			if events.created {
				events.created = false
			} else {
				events.deleted = true
			}
		}
	}

	// Process deduplicated events per file
	for uri, events := range fileEventMap {
		path := uri.PathKey(fs.caseSensitivity)
		o := newOverlays[path]

		if events.openChange != nil {
			if result.Opened != "" || result.Reopened != "" {
				panic("can only process one file open event at a time")
			}
			if o != nil && o.Content() != events.openChange.Content {
				result.Changed.Add(uri)
			} else if o == nil {
				result.Opened = uri
			} else {
				result.Reopened = uri
			}
			scriptKind := lsconv.LanguageKindToScriptKind(events.openChange.LanguageKind)
			if scriptKind == core.ScriptKindUnknown {
				scriptKind = core.GetScriptKindFromFileName(uri.FileName())
			}
			newOverlays[path] = newOverlay(
				uri.FileName(),
				events.openChange.Content,
				events.openChange.Version,
				scriptKind,
			)
			continue
		}

		if events.closeChange != nil && o != nil {
			result.Closed.Add(uri)
			delete(newOverlays, path)
			o = nil
		}

		if events.watchChanged && o == nil {
			result.Changed.Add(uri)
		}

		if len(events.changes) > 0 && o != nil {
			result.Changed.Add(uri)
			for _, change := range events.changes {
				converters := lsconv.NewConverters(fs.positionEncoding, func(fileName tspath.RootedFilePath) *lsconv.LSPLineMap {
					return o.LSPLineMap()
				})
				for _, textChange := range change.Changes {
					if partialChange := textChange.Partial; partialChange != nil {
						ranges := converters.FromLSPRange(o, partialChange.Range, spanmap.FeatureAll)
						debug.Assert(len(ranges) == 1, "expected exactly one range for partial change")
						textChange := core.TextChange{TextRange: ranges[0].Span, NewText: partialChange.Text}
						newContent := textChange.ApplyTo(o.content)
						o = newOverlay(o.fileName, newContent, change.Version, o.kind)
					} else if wholeChange := textChange.WholeDocument; wholeChange != nil {
						o = newOverlay(o.fileName, wholeChange.Text, change.Version, o.kind)
					}
				}
				if len(change.Changes) > 0 {
					o.version = change.Version
					o.hash = xxh3.HashString128(o.content)
					o.matchesDiskText = false
					newOverlays[path] = o
				}
			}
		}

		if o != nil && (events.watchObserved || events.saved) {
			if matchesDiskText, _ := o.computeMatchesDiskText(fs.host); matchesDiskText != o.MatchesDiskText() {
				o = newOverlay(o.FileName(), o.Content(), o.Version(), o.kind)
				o.matchesDiskText = matchesDiskText
				newOverlays[path] = o
			}
		} else if events.saved && o == nil && !events.watchChanged {
			// File was saved but never opened via didOpen; treat as a disk change.
			result.Changed.Add(uri)
		}

		if events.created && o == nil {
			result.Created.Add(uri)
		}

		if events.deleted && o == nil {
			result.Deleted.Add(uri)
		}
	}

	fs.overlays = newOverlays
	fs.overlayDirectories = createOverlayDirectories(newOverlays)
	return result, newOverlays
}
