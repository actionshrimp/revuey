		this.layoutTree();
	}

	layout(): void {
		this.layoutTree();
	}

	focus(): void {
		this.searchInput.focus();
	}

	setSearchQuery(query: string): void {
		this.searchInput.value = query;
	}

	private scheduleRender(): void {
		if (this.visible) {
			// Suggestions that appear while the section is visible don't need a badge either.
			this.extensionSuggestionsService.dismissBadge();
			this.render();
		} else {
			this.renderPending = true;
		}
	}

	private render(): void {
		this.renderPending = false;
		const suggested = new Set(this.extensionSuggestionsService.suggestedExtensions.get());
		const isSuggested = (extension: IExtension) => suggested.has(extension);
		const installed = groupAgentsWindowExtensions(this.extensionsWorkbenchService.local, '', extension => this.supportsAgentsWindow(extension), isSuggested);
		this.updateRuntimeAction(installed.flatMap(group => group.entries.map(entry => entry.extension)));

		const groups = this.searchQuery.trim()
			? groupAgentsWindowExtensions(this.extensionsWorkbenchService.local, this.searchQuery, extension => this.supportsAgentsWindow(extension), isSuggested)
			: installed;
		const visibleGroups = groups.filter(group => group.entries.length > 0);
		if (visibleGroups.length === 0) {
			this.tree.setChildren(null, []);
			this.treeContainer.style.display = 'none';
			this.emptyState.style.display = '';
			if (this.searchQuery.trim()) {
				this.emptyStateText.textContent = localize('agentsWindowExtensions.noMatches', "No extensions match '{0}'", this.searchQuery.trim());
				this.emptyStateSubtext.textContent = localize('agentsWindowExtensions.noMatchesHint', "Try a different search term.");
			} else {
				this.emptyStateText.textContent = localize('agentsWindowExtensions.empty', "No extensions installed");
				this.emptyStateSubtext.textContent = localize('agentsWindowExtensions.emptyHint', "Extensions you install in VS Code appear here.");
			}
			return;
		}

		this.emptyState.style.display = 'none';
		this.treeContainer.style.display = '';
		const children: IObjectTreeElement<AgentsWindowExtensionsTreeEntry>[] = visibleGroups.map(group => {
			const collapsed = this.collapsedGroups.has(group.group);
			const element: IAgentsWindowExtensionsGroupEntry = {
				type: 'group-header',
				id: `agents-window-extensions-group-${group.group}`,
				group: group.group,
				label: getGroupLabel(group.group),
				// Describes all installed extensions in the group, so the description doesn't change while searching.
				description: getGroupDescription(installed.find(installedGroup => installedGroup.group === group.group) ?? group),
				icon: Codicon.extensions,
				count: group.entries.length,
				isFirst: false,
				collapsed,
			};
			return {
				element,
				collapsible: true,
				collapsed: collapsed ? ObjectTreeElementCollapseState.PreserveOrCollapsed : ObjectTreeElementCollapseState.PreserveOrExpanded,
				children: group.entries.map(entry => ({ element: entry })),
			};
		});
		this.tree.setChildren(null, children);
		this.layoutTree();
	}

	private layoutTree(): void {
		const { clientHeight, clientWidth } = this.treeContainer;
		if (this.visible && clientHeight > 0 && clientWidth > 0) {
			this.tree.layout(clientHeight, clientWidth);
		}
		this.searchInput.layout();
	}

	private supportsAgentsWindow(extension: IExtension): boolean {
		return !!extension.local && this.extensionManifestPropertiesService.canExecuteOnSessionsWindow(extension.local.manifest, extension.isBuiltin);
	}

	/**
	 * Warns about extensions that haven't declared support for the Agents window and contribute things that it doesn't support.
	 */
	private getWarning(extension: IExtension): string | undefined {
		return extension.local && !this.supportsAgentsWindow(extension)
			? getMissingFeaturesWarning(getSessionsWindowMissingFeatures(extension.local.manifest))
			: undefined;
	}

	private isEnabled(extension: IExtension): boolean {
		return this.extensionEnablementService.isEnabledEnablementState(extension.enablementState);
	}

	private canChangeEnablement(extension: IExtension): boolean {
		return !!extension.local && this.extensionEnablementService.canChangeWorkspaceEnablement(extension.local);
	}

	private async setEnabled(extension: IExtension, enabled: boolean): Promise<void> {
		try {
			// The Agents window has a dedicated workspace, so workspace enablement only applies to the Agents window.
			await this.extensionsWorkbenchService.setEnablement(extension, enabled ? EnablementState.EnabledWorkspace : EnablementState.DisabledWorkspace);
			this.telemetryService.publicLog2<AgentsWindowExtensionEnablementChangedEvent, AgentsWindowExtensionEnablementChangedClassification>('agentsWindowExtensionEnablementChanged', {
				extensionId: ExtensionIdentifier.toKey(extension.identifier.id),
				enabled,
				// Sorted like the suggested contributions of agentsWindowAutoEnableCandidateEnabled, so the events can be joined.
				aiFeatures: extension.local ? getSessionsWindowSuggestedContributions(extension.local.manifest).sort().join(',') : '',
			});
			status(this.isEnabled(extension)
				? localize('agentsWindowExtensions.enabledStatus', "{0} enabled in the Agents window", extension.displayName)
				: localize('agentsWindowExtensions.disabledStatus', "{0} disabled in the Agents window", extension.displayName));
		} catch (error) {
			if (!isCancellationError(error)) {
				this.notificationService.error(error);
			}
		}
		// Re-render so a cancelled or failed change does not leave the switch in the requested state.
		this.scheduleRender();
	}

	private updateRuntimeAction(extensions: readonly IExtension[]): void {
		const actions = new Set(extensions.map(extension => extension.runtimeState?.action));
		this.runtimeAction = actions.has(ExtensionRuntimeActionType.ReloadWindow) ? ExtensionRuntimeActionType.ReloadWindow
			: actions.has(ExtensionRuntimeActionType.RestartExtensions) ? ExtensionRuntimeActionType.RestartExtensions
				: undefined;
		this.runtimeActionButton.label = this.runtimeAction === ExtensionRuntimeActionType.ReloadWindow
			? localize('agentsWindowExtensions.reloadWindow', "Reload Window")
			: localize('agentsWindowExtensions.restartExtensions', "Restart Extensions");
		this.runtimeActionButton.element.style.display = this.runtimeAction ? '' : 'none';
	}

	private async runRuntimeAction(): Promise<void> {
		try {
			if (this.runtimeAction === ExtensionRuntimeActionType.ReloadWindow) {
				await this.hostService.reload();
			} else if (this.runtimeAction === ExtensionRuntimeActionType.RestartExtensions) {
				await this.extensionsWorkbenchService.updateRunningExtensions();
			}
		} catch (error) {
			this.notificationService.error(error);
		}
	}

	private updateDescription(): void {
		this.description.textContent = this.configurationService.getValue<boolean>(EXTENSIONS_AGENTS_WINDOW_AUTO_ENABLE) === true
			? localize('agentsWindowExtensions.descriptionAutoEnabled', "Choose which installed extensions run in the Agents window. Extensions that haven't declared support for the Agents window might not work as expected. They are disabled by default, unless they could be useful there and don't rely on features that are unavailable in the Agents window. Changes only apply to the Agents window.")
			: localize('agentsWindowExtensions.description', "Choose which installed extensions run in the Agents window. Extensions that haven't declared support for the Agents window are disabled by default and might not work as expected. Changes only apply to the Agents window.");
	}

	private updateSearchAriaLabel(): void {
		const keybinding = this.keybindingService.lookupKeybinding('editor.action.accessibilityHelp')?.getAriaLabel();
		this.searchInput.setAriaLabel(this.configurationService.getValue<boolean>(AccessibilityVerbositySettingId.AgentsWindowExtensions) && keybinding
			? localize('agentsWindowExtensions.searchAriaLabelWithHelp', "Search extensions. Use {0} for accessibility help.", keybinding)
			: localize('agentsWindowExtensions.searchAriaLabel', "Search extensions"));
	}

	private getAriaLabel(entry: AgentsWindowExtensionsTreeEntry): string {
		if (entry.type === 'group-header') {
			return localize('agentsWindowExtensions.groupAriaLabel', "{0}, {1} extensions. {2}", entry.label, entry.count, entry.description);
		}
		const { extension } = entry;
		const state = this.isEnabled(extension)
			? localize('agentsWindowExtensions.enabled', "Enabled")
			: localize('agentsWindowExtensions.disabled', "Disabled");
		const runtimeStateLabel = getRuntimeStateLabel(extension);
		const label = runtimeStateLabel
			? localize('agentsWindowExtensions.rowAriaLabelWithRuntimeState', "{0}, {1}, {2}, {3}", extension.displayName, extension.publisherDisplayName, state, runtimeStateLabel)
			: localize('agentsWindowExtensions.rowAriaLabel', "{0}, {1}, {2}", extension.displayName, extension.publisherDisplayName, state);
		const warning = this.getWarning(extension);
		const labelWithWarning = warning ? localize('agentsWindowExtensions.rowAriaLabelWithWarning', "{0}. Warning: {1}", label, warning) : label;
		const contributionLabels = getEntryContributionLabels(entry);
		return contributionLabels.length
			? localize('agentsWindowExtensions.rowAriaLabelWithContributions', "{0}. Contributes {1}", labelWithWarning, contributionLabels.join(', '))
			: labelWithWarning;
	}
}
