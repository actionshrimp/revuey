				undoStopId: edit.undoStopId,
				diff: edit.diff,
			};

			// Multiple tool calls in one request may touch the same file
			// (e.g. create→edit, edit→delete). Fold each new edit into the
			// prior one for the same resource so the checkpoint stores a
			// single net before/after pair per file. Otherwise
			// _writeCheckpointContent would apply duplicate writes in
			// parallel and race to leave the file in an undefined state.
			const existingIdx = cp.edits.findIndex(e => e.resource.toString() === resource.toString());
			if (existingIdx < 0) {
				cp.edits.push(entry);
			} else {
				cp.edits[existingIdx] = replace ? entry : mergeFileEdit(cp.edits[existingIdx], entry);
			}
		}
	}

	// ---- Snapshots ----------------------------------------------------------

	private _findCheckpointIndex(requestId: string): number {
		return this._checkpoints.findIndex(cp => cp.requestId === requestId);
	}

	async restoreSnapshot(requestId: string, _stopId: string | undefined): Promise<void> {
		return this._undoRedoSequencer.queue(async () => {
			const cpIdx = this._findCheckpointIndex(requestId);
			if (cpIdx < 0) {
				this._logService.warn(`[AgentHostSnapshotController] No checkpoint found for requestId=${requestId}`);
				return;
			}

			// Restore to before this request: target one slot before it.
			await this._navigateToCheckpointIndex(cpIdx - 1);
		});
	}

	/**
	 * Steps a single checkpoint backwards, undoing the edits of the current
	 * checkpoint. The "Undo" UI invokes this once per click.
	 */
	async undoInteraction(): Promise<void> {
		return this._undoRedoSequencer.queue(async () => {
			const currentIdx = this._currentCheckpointIndex.get();
			if (currentIdx < 0) {
				return;
			}
			await this._navigateToCheckpointIndex(currentIdx - 1);
		});
	}

	/**
	 * Steps a single checkpoint forwards, redoing the edits of the next
	 * checkpoint.
	 *
	 * Implementing this is essential: the "Redo" action repeatedly calls this
	 * while {@link canRedo} is `true`, so a no-op implementation would spin
	 * forever and hang the window.
	 */
	async redoInteraction(): Promise<void> {
		return this._undoRedoSequencer.queue(async () => {
			const currentIdx = this._currentCheckpointIndex.get();
			if (currentIdx >= this._checkpoints.length - 1) {
				return;
			}
			await this._navigateToCheckpointIndex(currentIdx + 1);
		});
	}

	/**
	 * Moves the on-disk file state and the checkpoint cursor to `targetIdx`,
	 * writing each crossed checkpoint's before/after content. Must run inside
	 * the {@link _undoRedoSequencer} to avoid racing writes.
	 */
	private async _navigateToCheckpointIndex(targetIdx: number): Promise<void> {
		const currentIdx = this._currentCheckpointIndex.get();
		const crossed = this._checkpoints.slice(Math.min(currentIdx, targetIdx) + 1, Math.max(currentIdx, targetIdx) + 1);
		// A failed fetch must leave every file and the checkpoint cursor at the original boundary.
		await Promise.all(crossed.map(checkpoint => this._resolveCheckpointEdits(checkpoint)));
		const undo = targetIdx < currentIdx;
		const affectedResources = crossed.flatMap(checkpoint => checkpoint.edits.flatMap(edit => edit.originalResource ? [edit.resource, edit.originalResource] : [edit.resource]));
		const updateReview = await this.checkpointReview.prepareRestore(
			undo ? this._checkpoints.slice(targetIdx + 1) : crossed,
			undo,
			affectedResources,
		);
		const getDirtyError = () => {
			const resource = affectedResources.find(resource => this._workingCopyService.isDirty(resource));
			return resource ? new Error(localize('agentHostSnapshot.dirtyFile', "Save or revert unsaved changes to '{0}' before restoring a checkpoint.", basename(resource))) : undefined;
		};
		const beforeRestoreError = getDirtyError();
		if (beforeRestoreError) {
			throw beforeRestoreError;
		}
		const failures: Error[] = [];
		for (const checkpoint of undo ? [...crossed].reverse() : crossed) {
			try {
				await this._writeCheckpointContent(checkpoint, undo ? 'before' : 'after');
			} catch (error) {
				failures.push(error instanceof Error ? error : new Error(String(error)));
			}
		}
		const afterRestoreError = getDirtyError();
		if (afterRestoreError) {
			failures.push(afterRestoreError);
		}

		transaction(tx => {
			this._currentCheckpointIndex.set(targetIdx, tx);
			if (!undo || failures.length === 0) {
				updateReview(tx);
			}
		});
		if (failures.length > 0) {
			throw new Error(localize('agentHostSnapshot.restoreFailed', "Could not restore every file. Use Undo or Redo to recover the checkpoint. {0}", failures.map(error => error.message).join(' ')));
		}
	}

	getSnapshotUri(requestId: string, uri: URI, _stopId: string | undefined): URI | undefined {
		const cp = this._checkpoints.find(c => c.requestId === requestId);
		const hasFile = cp?.edits.some(e => e.resource.toString() === uri.toString())
			|| this._turnEdits?.getChanges(requestId)?.get().some(edit => edit.modifiedURI.toString() === uri.toString());
		if (!cp || !hasFile) {
			return undefined;
		}
		return URI.from({
			scheme: Schemas.chatEditingSnapshotScheme,
			path: uri.path,
			query: JSON.stringify({ session: this.chatSessionResource.toString(), requestId, undoStop: '' }),
		});
	}

	async getSnapshotContents(requestId: string, uri: URI, _stopId: string | undefined): Promise<VSBuffer | undefined> {
		const cp = this._checkpoints.find(c => c.requestId === requestId);
		if (!cp) {
			return undefined;
		}
		await this._resolveCheckpointEdits(cp);
		const uriStr = uri.toString();
		// Use the last edit for this file in the request — that's the
		// "after-content" the diff viewer wants to display.
		let edit: IToolCallFileEdit | undefined;
		for (let i = cp.edits.length - 1; i >= 0; i--) {
			if (cp.edits[i].resource.toString() === uriStr) {
				edit = cp.edits[i];
				break;
			}
		}
		if (!edit) {
			return undefined;
		}
		try {
			if (!edit.afterContentUri) {
				return VSBuffer.fromByteArray([]);
			}
			const content = await this._fileService.readFile(edit.afterContentUri);
			return content.value;
		} catch (err) {
			this._logService.warn(`[AgentHostSnapshotController] Failed to fetch snapshot content`, err);
			return undefined;
		}
	}

	async getSnapshotModel(_requestId: string, _undoStop: string | undefined, _snapshotUri: URI): Promise<ITextModel | null> {
		return null;
	}

	hasEditsInRequest(requestId: string, reader?: IReader): boolean {
		const cp = this._checkpoints.find(c => c.requestId === requestId);
		return !!cp && (cp.edits.length > 0 || (this._turnEdits?.getChanges(requestId)?.read(reader).length ?? 0) > 0);
	}

	// ---- Keep / Undo, delegated to the review when attached -----------------

	async show(previousChanges?: boolean): Promise<void> {
		await this._review.get()?.show(this, previousChanges);
	}
	getEntry(uri: URI): IModifiedFileEntry | undefined {
		return this._review.get()?.getEntry(uri);
	}
	async resolveEntry(uri: URI): Promise<IModifiedFileEntry | undefined> {
		return this._review.get()?.resolveEntry(uri);
	}
	readEntry(uri: URI, reader: IReader): IModifiedFileEntry | undefined {
		return this._review.read(reader)?.readEntry(uri, reader);
	}
	async accept(...uris: URI[]): Promise<void> {
		await this._review.get()?.accept(...uris);
	}
	async reject(...uris: URI[]): Promise<void> {
		await this._review.get()?.reject(...uris);
	}

	// ---- Unsupported / no-op (agent host owns edits server-side) ------------

	getEntryDiffBetweenStops(_uri: URI, _requestId: string | undefined, _stopId: string | undefined): IObservable<IEditSessionEntryDiff | undefined> | undefined { return undefined; }
	getEntryDiffBetweenRequests(_uri: URI, _startRequestId: string, _stopRequestId: string): IObservable<IEditSessionEntryDiff | undefined> { return constObservable(undefined); }
	getDiffsForFilesInSession(): IObservable<readonly IEditSessionEntryDiff[]> { return constObservable([]); }
	getDiffsForFilesInRequest(_requestId: string): IObservable<readonly IEditSessionEntryDiff[]> { return constObservable([]); }
	getDiffForSession(): IObservable<IEditSessionDiffStats> { return constObservable({ added: 0, removed: 0 }); }

	async triggerExplanationGeneration(): Promise<void> { /* no-op */ }
	clearExplanations(): void { /* no-op */ }
	hasExplanations(): boolean { return false; }

	startStreamingEdits(_resource: URI, _responseModel: IChatResponseModel, _inUndoStop: string | undefined): IStreamingEdits {
		throw new Error('Not supported for agent host sessions');
	}
	applyWorkspaceEdit(_edit: IChatWorkspaceEdit, _responseModel: IChatResponseModel, _undoStopId: string): void {
		throw new Error('Not supported for agent host sessions');
	}
	async startExternalEdits(_responseModel: IChatResponseModel, _operationId: number, _resources: URI[], _undoStopId: string, _contentFor?: URI[]): Promise<IChatProgress[]> {
		throw new Error('Not supported for agent host sessions');
	}
	async stopExternalEdits(_responseModel: IChatResponseModel, _operationId: number, _contentFor?: URI[]): Promise<IChatProgress[]> {
		throw new Error('Not supported for agent host sessions');
	}

	// ---- Stop / Dispose -----------------------------------------------------

	async stop(_clearState?: boolean): Promise<void> {
		this.dispose();
