		await reset;
	}

	/** Keeping or undoing a single change goes through the agent host as well. */
	override get diffInfo() {
		return super.diffInfo.map(diff => ({
			...diff,
			keep: (change: DetailedLineRangeMapping) => this._operations?.keep(this, change) ?? Promise.resolve(false),
			undo: (change: DetailedLineRangeMapping) => this._operations?.undo(this, change) ?? Promise.resolve(false),
		}));
	}

	protected override async _doAccept(): Promise<void> {
		if (!await this._operations?.keep(this)) {
			throw new CancellationError();
		}
	}

	protected override async _doReject(): Promise<void> {
		if (!await this._operations?.undo(this)) {
			throw new CancellationError();
		}
	}

	/** Changes the agent host didn't keep stay undecided. */
	override acceptDeferred() {
		const file = this.file;
		return completeIfCurrent(super.acceptDeferred(), () => isSameWorkingSetFile(this.file, file));
	}

	/** Changes the agent host didn't undo stay undecided. */
	override rejectDeferred() {
		const file = this.file;
		return completeIfCurrent(super.rejectDeferred(), () => isSameWorkingSetFile(this.file, file));
	}

	/** Whether an agent's edit tool call is writing the file, see {@link setEditing}. */
	get isAgentEditing(): boolean {
		return this._agentEditing;
	}

	private _agentEditing = false;
	private _agentReloads = 0;

	/**
	 * Marks the file as being written by an agent's edit tool call, or not.
	 * As while local chat edits stream into a file, the editor is read-only,
	 * the changes can't be kept or undone, and changes of the document, as
	 * when it reloads what the agent wrote, are the agent's meanwhile. The
	 * agent host reports which file is written, not which chat response
	 * writes it.
	 */
	setEditing(editing: boolean): void {
		this._agentEditing = editing;
		this._updateExternalEdit();
		if (!!this._isCurrentlyBeingModifiedByObs.get() === editing) {
			return;
		}
		transaction(tx => {
			this._isCurrentlyBeingModifiedByObs.set(editing ? { responseModel: undefined, undoStopId: undefined } : undefined, tx);
			this._waitsForLastEdits.set(editing, tx);
		});
	}

	/** Runs `task`, which reloads what the agent wrote into the document, with the document's changes counting as the agent's. */
	async runAsAgentEdit(task: () => Promise<void>): Promise<void> {
		this._agentReloads++;
		this._updateExternalEdit();
		try {
			await task();
		} finally {
			this._agentReloads--;
			this._updateExternalEdit();
		}
	}

	/** Local chat counts the changes of a document as an agent's while the agent edits its file on disk. */
	private _updateExternalEdit(): void {
		if (this._agentEditing || this._agentReloads > 0) {
			this.startExternalEdit();
		} else {
			this.stopExternalEdit();
		}
	}

	private _matchLineEndings(): void {
		this.originalModel.setEOL(this.modifiedModel.getEndOfLineSequence());
	}
}

/**
 * Reviews the agent host session's Working Set in the editor, so its changes
 * can be kept or undone like local chat edits: in the editor, with the
 * editor's Keep and Undo, and in the working set above the chat input.
 *
 * The agent host owns the review. Its Working Set changeset holds the tool
 * edits the user hasn't kept, and its Accept Changes and Discard Changes
 * operations keep or undo a file's changes, or the changes of one hunk. Each
 * entry follows a file of the Working Set: it compares the document with the
 * file's baseline, and keeping or undoing asks the host, whose updated
 * Working Set the entries then follow. The host updates the Working Set after
 * each of the agent's edits, so changes can be kept or undone while the agent
 * works, and an operation names the version of the changes the editor showed.
 * Session, turn and branch changesets reflect an undo as soon as the host
 * records it.
 */
export class AgentHostEditReview extends Disposable implements IWorkingSetOperations {

	private readonly _entries = new ResourceMap<AgentHostEditReviewEntry>();
	private readonly _entriesObs = observableValue<readonly AgentHostEditReviewEntry[]>(this, []);
	readonly entries: IObservable<readonly IModifiedFileEntry[]> = derived(this, reader => this._entriesObs.read(reader).filter(entry => this._isFileVisible(entry, reader)));
	private readonly _checkpointReview = observableValue<AgentHostCheckpointReview | undefined>(this, undefined);

	private readonly _rawChanges = derived<IAgentHostCheckpointReviewSource | undefined>(this, reader => {
		const workingSet = this._workingSet.read(reader);
		const state = workingSet?.state.read(reader);
		return workingSet ? { channel: workingSet.channel, ready: state?.status === ChangesetStatus.Ready, failed: workingSet.failed.read(reader) || state?.status === ChangesetStatus.Error, files: state ? toWorkingSetFileChanges(state, workingSet.connectionAuthority) : [] } : undefined;
	});
	readonly fileChanges = derived(this, reader => {
		const current = this._rawChanges.read(reader);
		return current ? (this._checkpointReview.read(reader)?.project(current.channel, current.files, reader) ?? current.files).map(file => file.diff) : [];
	});

	private readonly _workingSet: IObservable<(IWorkingSet & { readonly subscription: IAgentSubscription<ChangesetState>; readonly state: IObservable<ChangesetState | undefined>; readonly failed: IObservable<boolean> }) | undefined>;
	/** Follows the Working Set one update at a time. */
	private readonly _updates = new Sequencer();
	/** Runs operations one at a time, since each one changes the Working Set the next one checks. */
	private readonly _operations = new Sequencer();
	private readonly _blockedFiles = new ResourceSet();
	private readonly _lifetimeToken = cancelOnDispose(this._store);

	constructor(
		readonly chatSessionResource: URI,
		@IAgentHostConnectionsService connectionsService: IAgentHostConnectionsService,
		@IAgentHostUntitledProvisionalSessionService provisionalSessions: IAgentHostUntitledProvisionalSessionService,
		@IInstantiationService private readonly _instantiationService: IInstantiationService,
		@ITextModelService private readonly _textModelService: ITextModelService,
		@ITextFileService private readonly _textFileService: ITextFileService,
		@IFileService private readonly _fileService: IFileService,
		@IChatService private readonly _chatService: IChatService,
		@IEditorService private readonly _editorService: IEditorService,
		@INotificationService private readonly _notificationService: INotificationService,
		@IAccessibilitySignalService private readonly _accessibilitySignalService: IAccessibilitySignalService,
		@INotebookService private readonly _notebookService: INotebookService,
		@IUriIdentityService private readonly _uriIdentityService: IUriIdentityService,
		@ILogService private readonly _logService: ILogService,
		@IEditorWorkerService private readonly _editorWorkerService: IEditorWorkerService,
	) {
		super();
		this._register(this._textFileService.files.retainResolvedContent());

		const resolutionChanged = observableSignalFromEvent(this, Event.any<unknown>(connectionsService.onDidChangeSessionResolution, provisionalSessions.onDidChange));
		const resolution = derivedOpts<IAgentHostSessionResolution | undefined>({ owner: this, equalsFn: resolutionEquals }, reader => {
			resolutionChanged.read(reader);
			const provisionalBackend = provisionalSessions.get(chatSessionResource);
			if (isUntitledChatSession(chatSessionResource) && !provisionalBackend) {
				return undefined;
			}
			const resolved = connectionsService.resolveSessionResource(chatSessionResource);
			return resolved && provisionalBackend ? { ...resolved, backendSession: provisionalBackend } : resolved;
		});
		const sessionState = derived(this, reader => {
			const current = resolution.read(reader);
			if (!current) {
				return constObservable<SessionState | undefined>(undefined);
			}
			const subscription = reader.store.add(current.connection.getSubscription(StateComponents.Session, current.backendSession, 'AgentHostEditReview'));
			return observableFromSubscription(this, subscription.object);
		});
		const workingSet = derivedOpts<IWorkingSet | undefined>({ owner: this, equalsFn: workingSetEquals }, reader => {
			const current = resolution.read(reader);
			const state = sessionState.read(reader).read(reader);
			const changeset = state?.changesets?.find(candidate => candidate.changeKind === ChangesetKind.WorkingSet && !candidate.uriTemplate.includes('{'));
			return current && changeset
				? { connection: current.connection, connectionAuthority: current.connectionAuthority, channel: URI.parse(resolveChangesetUriTemplate(current.backendSession.toString(), changeset.uriTemplate)) }
				: undefined;
		});
		this._workingSet = derived(this, reader => {
			const current = workingSet.read(reader);
			if (!current) {
				return undefined;
			}
			const subscription = reader.store.add(current.connection.getSubscription(StateComponents.Changeset, current.channel, 'AgentHostEditReview')).object;
			return {
				...current,
				subscription,
				state: observableFromSubscription(this, subscription),
				failed: observableFromEvent(this, Event.any(subscription.onDidChange, subscription.onDidError ?? Event.None), () => subscription.value instanceof Error),
			};
		});
		const retryBlockedFiles = observableSignalFromEvent(this, Event.filter(Event.any(
			Event.map(this._textFileService.files.onDidSave, event => event.model),
			this._textFileService.files.onDidRevert,
		), model => this._blockedFiles.has(model.resource)));
		this._register(autorun(reader => {
			retryBlockedFiles.read(reader);
			const current = this._workingSet.read(reader);
			const state = current?.state.read(reader);
			const rawFiles = current && state ? toWorkingSetFileChanges(state, current.connectionAuthority) : [];
			const files = current ? this._checkpointReview.read(reader)?.project(current.channel, rawFiles, reader) ?? rawFiles : rawFiles;
			for (const file of files) {
				if (file.editing) {
					// An edit starts immediately, even while an earlier update is being read or diffed.
					this._entries.get(this._uriIdentityService.asCanonicalUri(file.diff.modifiedURI))?.setEditing(true);
				}
			}
			if (current && state?.status !== ChangesetStatus.Ready) {
				// While the Working Set updates, its files are the previous ones.
				return;
			}
			const token = cancelOnDispose(reader.store);
			this._updates.queue(() => this._update(files, token));
		}));
	}

	getEntry(uri: URI): IModifiedFileEntry | undefined {
		const entry = this._entries.get(uri);
		return entry && this._isFileVisible(entry) ? entry : undefined;
	}

	setCheckpointReview(review: AgentHostCheckpointReview): void {
