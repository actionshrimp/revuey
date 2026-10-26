
	/** Loads authoritative turn snapshots for providers that do not report edits on tool calls. */
	private async _resolveCheckpointEdits(checkpoint: IAgentHostCheckpoint): Promise<void> {
		if (checkpoint.turnEditsResolved) {
			return;
		}
		const edits = await this._turnEdits?.resolve(checkpoint.requestId);
		if (!edits) {
			return;
		}
		const fileEdits: IToolCallFileEdit[] = [];
		for (const edit of edits) {
			const normalized = normalizeFileEdit(edit);
			if (normalized) {
				fileEdits.push({
					...normalized,
					originalResource: normalized.kind === FileEditKind.Rename ? normalized.beforeUri : undefined,
					undoStopId: checkpoint.requestId,
					diff: edit.diff,
				});
			}
		}
		this._addCheckpointEdits(checkpoint, fileEdits, true);
		checkpoint.turnEditsResolved = true;
	}

	private async _writeCheckpointContent(checkpoint: IAgentHostCheckpoint, direction: 'before' | 'after'): Promise<void> {
		const ops = checkpoint.edits.map(async edit => {
			try {
				if (direction === 'before') {
					// Undoing this edit
					switch (edit.kind) {
						case FileEditKind.Create:
							await this._deleteCheckpointFile(edit.resource);
							break;
						case FileEditKind.Delete:
							if (edit.beforeContentUri) {
								await this._writeCheckpointFile(edit.resource, edit.beforeContentUri);
							}
							break;
						case FileEditKind.Rename:
							if (edit.originalResource) {
								await this._moveCheckpointFile(edit.resource, edit.originalResource, edit.beforeContentUri);
							}
							if (edit.beforeContentUri && edit.originalResource) {
								await this._writeCheckpointFile(edit.originalResource, edit.beforeContentUri);
							}
							break;
						case FileEditKind.Edit:
							if (edit.beforeContentUri) {
								await this._writeCheckpointFile(edit.resource, edit.beforeContentUri);
							}
							break;
					}
				} else {
					// Redoing this edit
					switch (edit.kind) {
						case FileEditKind.Create:
							if (edit.afterContentUri) {
								await this._writeCheckpointFile(edit.resource, edit.afterContentUri);
							}
							break;
						case FileEditKind.Delete:
							await this._deleteCheckpointFile(edit.resource);
							break;
						case FileEditKind.Rename:
							if (edit.originalResource) {
								await this._moveCheckpointFile(edit.originalResource, edit.resource, edit.afterContentUri);
							}
							if (edit.afterContentUri) {
								await this._writeCheckpointFile(edit.resource, edit.afterContentUri);
							}
							break;
						case FileEditKind.Edit:
							if (edit.afterContentUri) {
								await this._writeCheckpointFile(edit.resource, edit.afterContentUri);
							}
							break;
					}
				}
			} catch (err) {
				this._logService.warn(`[AgentHostSnapshotController] Failed to ${direction === 'before' ? 'undo' : 'redo'} ${edit.kind} for ${edit.resource.toString()}`, err);
				throw err;
			}
		});
		await Promises.settled(ops);
	}

	private async _readCheckpointFile(resource: URI): Promise<VSBuffer | undefined> {
		try {
			return (await this._fileService.readFile(resource)).value;
		} catch (error) {
			if (error instanceof FileOperationError && error.fileOperationResult === FileOperationResult.FILE_NOT_FOUND) {
				return undefined;
			}
			throw error;
		}
	}

	private async _writeCheckpointFile(resource: URI, snapshot: URI): Promise<void> {
		const content = (await this._fileService.readFile(snapshot)).value;
		if (!(await this._readCheckpointFile(resource))?.equals(content)) {
			await this._fileService.writeFile(resource, content);
		}
	}

	private async _deleteCheckpointFile(resource: URI): Promise<void> {
		try {
			await this._fileService.del(resource);
		} catch (error) {
			if (!(error instanceof FileOperationError) || error.fileOperationResult !== FileOperationResult.FILE_NOT_FOUND) {
				throw error;
			}
			if (await this._checkpointFileExists(resource)) {
				throw new Error(localize('agentHostSnapshot.deleteFailed', "Could not delete '{0}'.", basename(resource)), { cause: error });
			}
		}
	}

	private async _checkpointFileExists(resource: URI): Promise<boolean> {
		try {
			await this._fileService.resolve(resource);
			return true;
		} catch (error) {
			if (error instanceof FileOperationError && error.fileOperationResult === FileOperationResult.FILE_NOT_FOUND) {
				return false;
			}
			throw error;
		}
	}

	private async _moveCheckpointFile(source: URI, target: URI, snapshot: URI | undefined): Promise<void> {
		if (snapshot && !await this._checkpointFileExists(source)) {
			const expected = (await this._fileService.readFile(snapshot)).value;
			if ((await this._readCheckpointFile(target))?.equals(expected)) {
				return;
			}
		}
		await this._fileService.move(source, target, true);
	}
}

/**
 * Combines two edits to the same file (in arrival order) into a single net
 * edit. The merged entry keeps the earlier `before` snapshot and the later
 * `after` snapshot, and derives a net `kind` based on whether the file
 * exists at the start and end of the combined operation.
 *
 * A create-then-delete collapses to a no-op edit (no before, no after) — we
 * still keep the entry so the file is restored to "absent" on undo, but
 * `_writeCheckpointContent` will skip the write since both URIs are absent.
 */
function mergeFileEdit(prev: IToolCallFileEdit, next: IToolCallFileEdit): IToolCallFileEdit {
	const startsAbsent = prev.kind === FileEditKind.Create;
	const endsAbsent = next.kind === FileEditKind.Delete;

	let kind: FileEditKind;
	if (startsAbsent && endsAbsent) {
		kind = FileEditKind.Edit; // create+delete collapses to no-op
	} else if (startsAbsent) {
		kind = FileEditKind.Create;
	} else if (endsAbsent) {
		kind = FileEditKind.Delete;
	} else {
		kind = FileEditKind.Edit;
	}

	return {
		kind,
		resource: next.resource,
		// Renames within a single request are uncommon; if the second edit
		// is itself a rename keep its originalResource, otherwise carry
		// forward the first one.
		originalResource: next.originalResource ?? prev.originalResource,
		beforeContentUri: prev.beforeContentUri,
		afterContentUri: next.afterContentUri,
		undoStopId: prev.undoStopId,
		diff: next.diff ?? prev.diff,
	};
}
