NVIM ?= nvim
SPECS := tests/guard_spec.lua tests/stack_spec.lua tests/stack_remote_spec.lua tests/stack_notes_spec.lua tests/stack_view_spec.lua tests/switch_spec.lua tests/forge_spec.lua tests/forge_threads_spec.lua tests/forge_post_spec.lua tests/forge_corpus_spec.lua tests/forge_corpus_e2e_spec.lua tests/forge_description_spec.lua tests/forge_check_spec.lua tests/diff_spec.lua tests/layout_spec.lua tests/state_spec.lua tests/lock_spec.lua tests/units_spec.lua tests/comments_spec.lua tests/linemap_spec.lua tests/syntax_spec.lua tests/e2e_spec.lua tests/fold_spec.lua tests/marks_spec.lua tests/worktree_spec.lua tests/worktree_edge_spec.lua tests/guide_spec.lua tests/diagram_spec.lua tests/attribution_spec.lua tests/guide_view_spec.lua tests/guide_diagram_spec.lua tests/lsp_spec.lua tests/lsp_ready_spec.lua tests/lsp_proxy_spec.lua tests/comments_view_spec.lua tests/comments_cli_spec.lua tests/key_help_spec.lua tests/agent_comment_spec.lua tests/ai_review_spec.lua tests/ai_review_view_spec.lua tests/import_review_spec.lua tests/sessions_spec.lua tests/agent_link_spec.lua tests/edit_spec.lua tests/edit_float_spec.lua tests/pr_spec.lua tests/screen_spec.lua tests/bin_spec.lua

.PHONY: test fixture

# Each spec runs in a fresh `nvim --headless --clean`. Everything a run writes goes to its own run
# dir: the specs' files (REVUEY_TEST_TMP) and, through TMPDIR (with XDG_RUNTIME_DIR unset), the
# temp dirs and server sockets of every process they start, so nothing is left in the real TMPDIR.
# Every process the specs start inherits REVUEY_TEST_RUN; any still alive at the end fails the
# run. The run dir is removed when the run passes and kept (path printed) when it fails.
test:
	@run=$$(mktemp -d); status=0; mkdir "$$run/tmp"; unset XDG_RUNTIME_DIR; \
	for spec in $(SPECS); do \
		TMPDIR=$$run/tmp REVUEY_TEST_RUN=$$run REVUEY_TEST_TMP=$$run $(NVIM) --headless --clean -l $$spec || status=1; \
	done; \
	scripts/check-leaks.sh $$run || status=1; \
	if [ $$status -eq 0 ]; then rm -rf "$$run"; echo "all tests passed"; \
	else echo "TESTS FAILED (run dir kept: $$run)"; fi; \
	exit $$status

# make fixture DIR=/tmp/revuey-fixture
fixture:
	scripts/make-fixture.sh $(DIR)
