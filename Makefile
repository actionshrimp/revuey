NVIM ?= nvim
SPECS := tests/guard_spec.lua tests/stack_spec.lua tests/stack_remote_spec.lua tests/stack_notes_spec.lua tests/stack_view_spec.lua tests/diff_spec.lua tests/layout_spec.lua tests/state_spec.lua tests/lock_spec.lua tests/units_spec.lua tests/comments_spec.lua tests/linemap_spec.lua tests/syntax_spec.lua tests/e2e_spec.lua tests/fold_spec.lua tests/marks_spec.lua tests/worktree_spec.lua tests/worktree_edge_spec.lua tests/guide_spec.lua tests/diagram_spec.lua tests/attribution_spec.lua tests/guide_view_spec.lua tests/guide_diagram_spec.lua tests/lsp_spec.lua tests/lsp_ready_spec.lua tests/lsp_proxy_spec.lua tests/comments_view_spec.lua tests/comments_cli_spec.lua tests/sessions_spec.lua tests/agent_link_spec.lua tests/screen_spec.lua tests/bin_spec.lua

.PHONY: test fixture

# Each spec runs in a fresh `nvim --headless --clean`; temp files go to a throwaway dir.
test:
	@tmp=$$(mktemp -d); status=0; \
	for spec in $(SPECS); do \
		REVUEY_TEST_TMP=$$tmp $(NVIM) --headless --clean -l $$spec || status=1; \
	done; \
	rm -rf $$tmp; \
	if [ $$status -eq 0 ]; then echo "all tests passed"; else echo "TESTS FAILED"; fi; \
	exit $$status

# make fixture DIR=/tmp/revuey-fixture
fixture:
	scripts/make-fixture.sh $(DIR)
