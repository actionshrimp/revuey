		const fileMenuChanged = observableSignalFromEvent(this, fileMenu.onDidChange);
		this._fileList = this._register(renderChangesSummaryFileList(listContainer, this._diffs, scopedInstantiationService, this._editorService, configurationService, {
			openEditor: (diff, inDiffEditor, options, sideBySide) => {
				if (inDiffEditor) {
					void this._openFileDiff(diff, options, sideBySide).catch(onUnexpectedError);
				} else {
					void this._editorService.openEditor({ resource: diff.modifiedURI, options }, sideBySide ? SIDE_GROUP : ACTIVE_GROUP);
				}
			},
			ariaLabel: localize('chat.sessionWorkingSet.list', "Session changes"),
			rowActionIcons: true,
			getRowActions: (diff, reader) => {
				fileMenuChanged.read(reader);
				// Clicking an action doesn't move focus to its chat, so the commands are told which working set to run on.
				return getActionBarActions(fileMenu.getActions({ args: [diff.modifiedURI, this] }), 'navigation').primary;
			},
		}));
		this._register(button.onDidClick(() => collapsed.set(!collapsed.get(), undefined)));
		this._register(autorun(reader => {
			const isCollapsed = collapsed.read(reader);
			button.icon = isCollapsed ? Codicon.chevronRightCompact : Codicon.chevronDownCompact;
			button.element.setAttribute('aria-expanded', String(!isCollapsed));
			if (isCollapsed && dom.isAncestorOfActiveElement(listContainer)) {
				button.focus();
			}
			listContainer.classList.toggle('collapsed', isCollapsed);
		}));
		this._register(autorun(reader => {
			const changes = this._diffs.read(reader);
			const label = changes.length === 1
				? localize('chat.sessionWorkingSet.oneFile', "1 file changed")
				: localize('chat.sessionWorkingSet.manyFiles', "{0} files changed", changes.length);
			const added = changes.reduce((total, diff) => total + diff.added, 0);
			const removed = changes.reduce((total, diff) => total + diff.removed, 0);
			button.label = label;
			button.element.setAttribute('aria-label', localize('chat.sessionWorkingSet.summary', "Session changes, {0}, {1}", label, getChatFileChangeLineCounts(added, removed)));
			addedLabel.textContent = `+${added}`;
			removedLabel.textContent = `-${removed}`;
		}));
	}

	get keepUndoEnabled(): boolean {
		return this._reviewPreferences.keepUndoEnabled.get();
	}

	/** The files of the selected rows. */
	get selectedResources(): URI[] {
		return this._fileList.getSelectedElements().map(diff => diff.modifiedURI);
	}

	/** Whether the working set lists changes to `resource`. */
	includes(resource: URI): boolean {
		return this._getDiffs([resource]).length > 0;
	}

	/** Keeps the changes to the listed files of `resources`, like Keep on their rows, unless they can't be kept now. */
	async keepFiles(resources: readonly URI[]): Promise<void> {
		const diffs = this._getDiffs(resources);
		if (diffs.length > 0 && this._isKeepEnabled(undefined)) {
			await this._keep(diffs, false);
		}
	}

	/**
	 * Keeps the changes to the listed files of `resources` that were accepted
	 * outside of the working set, as by staging them with Git. Unlike
	 * {@link keepFiles}, a Keep in progress doesn't drop them; the session
	 * decides whether it can keep them.
	 */
	async keepAcceptedFiles(resources: readonly URI[]): Promise<void> {
		const diffs = this._getDiffs(resources);
		if (diffs.length > 0) {
			await this._keep(diffs, true);
		}
	}

	/** Undoes the changes to the listed files of `resources`, like Undo on their rows, unless the session can't undo them now. */
	async undoFiles(resources: readonly URI[]): Promise<void> {
		const sessionUndo = this._fileActions.undo.get();
		const diffs = this._getDiffs(resources);
		if (this.keepUndoEnabled && sessionUndo?.enabled.get() && diffs.length > 0) {
			await this._undo(sessionUndo, diffs, false);
		}
	}

	/** Opens the diffs of the changes to the listed files of `resources`. */
	openFileChanges(resources: readonly URI[]): void {
		for (const diff of this._getDiffs(resources)) {
			void this._openFileDiff(diff).catch(onUnexpectedError);
		}
	}

	private async _openFileDiff(diff: IEditSessionEntryDiff, options?: IEditorOptions, sideBySide = false): Promise<void> {
		const session = this._fileActions.editingSession?.();
		let entry: IModifiedFileEntry | undefined;
		try {
			entry = session?.resolveEntry ? await session.resolveEntry(diff.modifiedURI) : session?.getEntry(diff.modifiedURI);
		} catch (error) {
			if (isCancellationError(error)) {
				return;
			}
			this._notificationService.warn(localize('chat.sessionWorkingSet.liveReviewUnavailable', "The live review could not be loaded. Showing the recorded changes instead: {0}", toErrorMessage(error)));
		}
		if (entry?.state.get() === ModifiedFileEntryState.Modified) {
			void this._editorService.openEditor({
				original: { resource: entry.originalURI },
				modified: { resource: entry.modifiedURI },
				options,
			}, sideBySide ? SIDE_GROUP : ACTIVE_GROUP);
		} else {
			openChatFileChangeDiff(this._editorService, diff, options, sideBySide);
		}
	}

	private _getDiffs(resources: readonly URI[]): IEditSessionEntryDiff[] {
		const diffs = this._diffs.get();
		return diffs.filter(diff => resources.some(resource => isEqual(resource, diff.modifiedURI)));
	}

	private _isKeepEnabled(reader: IReader | undefined): boolean {
		return this._reviewPreferences.keepUndoEnabled.read(reader) && (this._fileActions.keepEnabled?.read(reader) ?? true);
	}

	private async _keep(diffs: readonly IEditSessionEntryDiff[], automatic: boolean): Promise<void> {
		if (!automatic && !this._isKeepEnabled(undefined)) {
			return;
		}
		if (await this._fileActions.keep(diffs, automatic)) {
			this._accessibilitySignalService.playSignal(AccessibilitySignal.editsKept, { allowManyInParallel: true });
		}
	}

	private async _undo(sessionUndo: IChatSessionWorkingSetUndo, diffs: readonly IEditSessionEntryDiff[], all: boolean): Promise<void> {
		if (!this.keepUndoEnabled || !sessionUndo.enabled.get()) {
			return;
		}
		if (await sessionUndo.undo(diffs, all)) {
			this._accessibilitySignalService.playSignal(AccessibilitySignal.editsUndone, { allowManyInParallel: true });
		}
	}
}

const KEPT_CHANGES_STORAGE_KEY = 'chat.sessionWorkingSet.keptChanges';

/** How many sessions remember their kept changes; the one kept in least recently is forgotten first. */
const MAX_SESSIONS_WITH_KEPT_CHANGES = 100;

/** Each session's kept change by file, all as digests, with the session kept in most recently last. */
type KeptChanges = readonly (readonly [session: string, changes: Readonly<Record<string, string>>])[];

function isKeptSessionChanges(value: unknown): value is KeptChanges[number] {
	return Array.isArray(value)
		&& value.length === 2
		&& typeof value[0] === 'string'
		&& isObject(value[1])
		&& Object.values(value[1]).every(change => typeof change === 'string');
}

function readKeptChanges(value: string | undefined): KeptChanges {
	if (!value) {
		return [];
	}
	try {
		const parsed: unknown = JSON.parse(value);
		return Array.isArray(parsed) ? parsed.filter(isKeptSessionChanges) : [];
	} catch {
		return [];
	}
}

/** A short, collision-resistant digest of `parts`, which identifies them in storage. */
function digest(parts: readonly (string | number | boolean)[]): string {
	const sha = new StringSHA1();
	sha.update(JSON.stringify(parts));
	return sha.digest();
}

function getSessionKey(session: URI): string {
	return digest([session.toString()]);
}

function getFileKey(diff: IEditSessionEntryDiff): string {
	return digest([getComparisonKey(diff.modifiedURI)]);
}

/** The parts of a file's change that differ once the file changes again. A deletion has no snapshot after it, so deleting a file again matches its earlier deletion. */
function getChangeParts(diff: IEditSessionEntryDiff): readonly (string | number | boolean)[] {
	return [
		diff.originalURI.toString(),
		diff.modifiedSnapshotURI?.toString() ?? '',
		diff.added,
		diff.removed,
		!!diff.isCreated,
		!!diff.isDeleted,
	];
}

/** Identifies a file's change by its snapshots and counts, which differ once the file changes again. */
function getChangeKey(diff: IEditSessionEntryDiff): string {
	return digest(getChangeParts(diff));
}

/** Whether `a` and `b` are the same change to the same file. */
export function isSameSessionFileChange(a: IEditSessionEntryDiff, b: IEditSessionEntryDiff): boolean {
	return isEqual(a.modifiedURI, b.modifiedURI) && equals(getChangeParts(a), getChangeParts(b));
}

/**
 * Remembers the changes kept in each session's working set, so a kept file
 * stays hidden until its changes differ from the ones that were kept.
 */
export class ChatSessionWorkingSetKeptChanges extends Disposable {

	private _keptChanges: KeptChanges | undefined;
	private readonly _onDidChange = observableSignal(this);

	constructor(
		@IStorageService private readonly _storageService: IStorageService,
	) {
		super();
		this._register(this._storageService.onDidChangeValue(StorageScope.PROFILE, KEPT_CHANGES_STORAGE_KEY, this._store)(() => {
