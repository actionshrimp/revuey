
	constructor(
		private readonly _gitHubService: ISessionsGitHubService,
		private readonly _logService: ILogService,
	) {
		super();
	}

	get(target: IGitHubCommitTarget): IObservable<GitHubCommit | undefined> {
		const key = this._key(target);
		let entry = this._entries.get(key);
		if (!entry) {
			entry = {
				target,
				value: observableValue<GitHubCommit | undefined>(this, undefined),
				store: undefined,
			};
			this._entries.set(key, entry);
		}
		if (!entry.store) {
			const currentEntry = entry;
			const store = entry.store = new DisposableStore();
			const token = cancelOnDispose(store);
			void this._gitHubService.getCommit(target.owner, target.repo, target.sha, token).then(commit => {
				if (!store.isDisposed) {
					currentEntry.value.set(commit, undefined);
				}
			}, error => {
				if (!token.isCancellationRequested) {
					this._logService.warn('[SessionGitHubCommitResolver] Failed to resolve GitHub commit', error);
					store.dispose();
					if (currentEntry.store === store) {
						currentEntry.store = undefined;
					}
				}
			});
		}
		return entry.value;
	}

	retain(targets: readonly IGitHubCommitTarget[]): void {
		const retained = new Set(targets.map(target => this._key(target)));
		for (const [key, entry] of this._entries) {
			if (!retained.has(key)) {
				entry.store?.dispose();
				this._entries.delete(key);
			}
		}
	}

	override dispose(): void {
		for (const entry of this._entries.values()) {
			entry.store?.dispose();
		}
		this._entries.clear();
		super.dispose();
	}

	private _key(target: IGitHubCommitTarget): string {
		return `${target.owner.toLowerCase()}/${target.repo.toLowerCase()}@${target.sha.toLowerCase()}`;
	}
}

/** Publishes a session's artifact and reference sections for the chat input pills. */
export class SessionArtifacts extends Disposable {
	private readonly presentations = observableValue<ReadonlyMap<string, ArtifactIntegrationPresentation>>(this, new Map());

	/** Sections for the artifacts pill: what the session produced. */
	readonly sections: IObservable<readonly IChatPillSection[]>;
	/** Sections for the references pill: what the session points the user at. */
	readonly referenceSections: IObservable<readonly IChatPillSection[]>;
	readonly integratedEntries: IObservable<readonly IChatPillEntry[]>;

	constructor(
		session: IObservable<IActiveSession | undefined>,
		chat: IObservable<IChat | undefined>,
		/** The URLs the browsers pill lists; website entries for them are left out. */
		private readonly _browserUrls: IObservable<ReadonlySet<string>>,
		private readonly _gitHubReferences: IObservable<ISessionGitHubReferences>,
		detailsHost: IArtifactDetailsHost,
		@IClipboardService private readonly _clipboardService: IClipboardService,
		@IConfigurationService private readonly _configurationService: IConfigurationService,
		@ILabelService private readonly _labelService: ILabelService,
		@INotificationService private readonly _notificationService: INotificationService,
		@IOpenerService private readonly _openerService: IOpenerService,
		@ISessionsManagementService private readonly _sessionsManagementService: ISessionsManagementService,
		@IWorkspaceContextService workspaceContextService: IWorkspaceContextService,
		@ISessionsGitHubService gitHubService: ISessionsGitHubService,
		@IInstantiationService instantiationService: IInstantiationService,
		@IWorkbenchGitHubService workbenchGitHubService: IWorkbenchGitHubService,
		@ILogService logService: ILogService,
		@ITelemetryService private readonly _telemetryService: ITelemetryService,
		@IChatService chatService: IChatService,
		@IChatImageCarouselService private readonly _chatImageCarouselService: IChatImageCarouselService,
		@IFileService private readonly _fileService: IFileService,
		@IFileDialogService private readonly _fileDialogService: IFileDialogService,
		@ISharedWebContentExtractorService private readonly _webContentExtractorService: ISharedWebContentExtractorService,
	) {
		super();

		const commitResolver = this._register(new SessionGitHubCommitResolver(gitHubService, logService));
		const commitHoverCache = this._register(new ChatPillHoverCache());
		const gitHubResolver = this._register(new GitHubResourceDetailsResolver(workbenchGitHubService, logService));
		// The session publishes every chat's records; this surface shows only the focused chat's, like the GitHub pills.
		const chatArtifacts = derived(this, reader => {
			const focusedChat = chat.read(reader);
			return (session.read(reader)?.artifacts?.read(reader) ?? []).filter(artifact => isSessionArtifactVisibleInChat(artifact, focusedChat));
		});
		this._register(autorun(reader => {
			const current = session.read(reader);
			const artifacts = chatArtifacts.read(reader);
			commitHoverCache.retain(new Set(artifacts.filter(artifact => artifact.kind === SessionArtifactKind.Commit).map(artifact => artifact.id)), current?.sessionId);
			gitHubResolver.retain(artifacts.flatMap(artifact =>
				!artifact.isArtifact && artifact.isGitHub === true && artifact.link ? [{ identity: artifact, resource: artifact.link }] : []), current && !current.loading.read(reader) ? current.sessionId : undefined);
			const commitTargets = artifacts
				.flatMap(artifact => artifact.kind === SessionArtifactKind.Commit && artifact.link ? [parseGitHubCommitTarget(artifact.link)] : [])
				.filter(isDefined);
			if (commitTargets.length === 0) {
				commitResolver.retain([]);
				return;
			}
			commitResolver.retain(commitTargets);
		}));

		const lifetimes = this._register(new DisposableMap<string, DisposableStore>());
		const presentations = this.presentations;
		const sessionChanges = observableSignalFromEvent(this, this._sessionsManagementService.onDidChangeSessions);
		const integrationsEnabled = observableConfigValue(ArtifactIntegrationsSettingId, false, this._configurationService);
		let owner: IActiveSession | undefined;
		this._register(autorun(reader => {
			const current = session.read(reader);
			if (current !== owner) {
				lifetimes.clearAndDisposeAll();
				presentations.set(new Map(), undefined);
				owner = current;
			}
			const artifacts = chatArtifacts.read(reader);
			const ids = new Set(artifacts.map(artifact => artifact.id));
			for (const id of lifetimes.keys()) {
				if (!ids.has(id)) {
					lifetimes.deleteAndDispose(id);
					const next = new Map(presentations.read(undefined));
					next.delete(id);
					presentations.set(next, undefined);
				}
			}
			if (!current) {
				return;
			}
			if (!integrationsEnabled.read(reader) || !current.capabilities.read(reader).supportsArtifactIntegrations) {
				lifetimes.clearAndDisposeAll();
				presentations.set(new Map(), undefined);
				return;
			}
			sessionChanges.read(reader);
			for (const artifact of artifacts) {
				if (lifetimes.has(artifact.id) || (!artifact.link && !artifact.uri)) {
					continue;
				}
				const lifetime = new DisposableStore();
				lifetimes.set(artifact.id, lifetime);
				void this._sessionsManagementService.acquireArtifactIntegration(current, artifact.id).then(reference => {
					if (!reference) {
						return;
					}
					lifetime.add(reference);
					if (lifetime.isDisposed) {
						return;
					}
					const presentation = lifetime.add(instantiationService.createInstance(ArtifactIntegrationPresentation, reference.object, reader => {
						const invokingChat = chat.read(reader);
						return session.read(reader) === current ? invokingChat?.resource.toString() : undefined;
					}, detailsHost));
					presentations.set(new Map(presentations.read(undefined)).set(artifact.id, presentation), undefined);
				}).catch(error => {
					if (!lifetime.isDisposed) {
						logService.error('[ArtifactIntegrations] Could not acquire artifact presentation', error);
						lifetimes.deleteAndDispose(artifact.id);
					}
				});
			}
		}));

		const imageCarouselEnabled = observableConfigValue<boolean>(ChatConfiguration.ImageCarouselEnabled, true, this._configurationService);
		const generatedImageModel = derived(this, reader => {
			const resource = chat.read(reader)?.resource;
			return resource && [...chatService.chatModels.read(reader)].find(model => isEqual(model.sessionResource, resource));
		});
		// Restored history mutates the model and its responses synchronously and repeatedly; coalesce
		// those bursts so the transcript is scanned once afterwards rather than once per mutation.
		const generatedImageChanges = derived(this, reader => {
			const model = generatedImageModel.read(reader);
			if (!model) {
				return undefined;
			}
			const store = reader.store;
			const raw = store.add(new Emitter<void>());
			const responseListeners = store.add(new DisposableMap<IChatResponseModel, IDisposable>());
			const track = () => {
				const current = new Set<IChatResponseModel>();
				for (const request of model.getRequests()) {
					if (request.response) {
						current.add(request.response);
						if (!responseListeners.has(request.response)) {
							responseListeners.set(request.response, request.response.onDidChange(() => raw.fire()));
						}
					}
				}
				for (const response of [...responseListeners.keys()]) {
					if (!current.has(response)) {
						responseListeners.deleteAndDispose(response);
					}
				}
			};
			track();
			store.add(model.onDidChange(() => raw.fire()));
			const coalesced = Event.map(Event.accumulate(raw.event, 0, false, store), () => {
				track();
			});
			return observableSignalFromEvent(this, coalesced);
		});
