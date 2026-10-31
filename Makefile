NVIM ?= nvim
# Specs run this many at a time (default: one per CPU thread).
JOBS ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
# Slowest first (the summary at the end of `make test` lists every spec's time; lsp_proxy_spec is
# placed by its CI time, where its LSP tests run), so a slow spec never starts last and holds up
# the end of the run; guard_spec, which checks the isolation itself, starts first.
SPECS := tests/guard_spec.lua tests/stack_tree_view_spec.lua tests/forge_post_spec.lua tests/switch_spec.lua \
  tests/agent_link_spec.lua tests/forge_check_spec.lua tests/stack_spec.lua tests/forge_threads_spec.lua \
  tests/forge_description_spec.lua tests/forge_spec.lua tests/lsp_proxy_spec.lua tests/stack_view_spec.lua \
  tests/pr_spec.lua tests/stack_remote_spec.lua tests/agent_comment_spec.lua tests/guide_view_spec.lua \
  tests/e2e_spec.lua tests/lock_spec.lua tests/ai_review_view_spec.lua tests/worktree_edge_spec.lua \
  tests/comments_cli_spec.lua tests/edit_float_spec.lua tests/bin_spec.lua tests/import_review_spec.lua \
  tests/diagram_spec.lua tests/comments_view_spec.lua tests/syntax_spec.lua tests/key_help_spec.lua \
  tests/folders_spec.lua tests/lsp_ready_spec.lua tests/marks_spec.lua tests/worktree_spec.lua \
  tests/guide_diagram_spec.lua tests/forge_corpus_e2e_spec.lua tests/fold_spec.lua tests/stack_tree_spec.lua \
  tests/ai_review_spec.lua tests/diff_spec.lua tests/attribution_spec.lua tests/guide_spec.lua tests/sessions_spec.lua \
  tests/state_spec.lua tests/units_spec.lua tests/comments_spec.lua tests/linemap_spec.lua tests/lsp_spec.lua \
  tests/stack_notes_spec.lua tests/forge_corpus_spec.lua tests/layout_spec.lua tests/edit_spec.lua
# Run alone after the others: screen_spec measures main-loop gaps, which a loaded machine stretches.
ALONE := tests/screen_spec.lua

.PHONY: test fixture

# Each spec runs in a fresh `nvim --headless --clean`, JOBS at a time (scripts/run-tests.lua), its
# output printed as one block when it ends, then a summary with each spec's time. Everything a
# run writes goes to its own run dir: each spec has <run dir>/<spec>/ for its files
# (REVUEY_TEST_TMP) and, through TMPDIR (with XDG_RUNTIME_DIR unset), for the temp dirs and server
# sockets of every process it starts, so nothing is left in the real TMPDIR. Every process the
# specs start inherits REVUEY_TEST_RUN=<run dir>; any still alive at the end fails the run. The
# run dir is removed when the run passes and kept (path printed) when it fails.
test:
	@run=$$(mktemp -d); status=0; mkdir "$$run/tmp"; unset XDG_RUNTIME_DIR; \
	TMPDIR=$$run/tmp $(NVIM) --headless --clean -l scripts/run-tests.lua "$$run" $(JOBS) $(SPECS) --alone $(ALONE) \
		|| status=1; \
	scripts/check-leaks.sh $$run || status=1; \
	if [ $$status -eq 0 ]; then rm -rf "$$run"; echo "all tests passed"; \
	else echo "TESTS FAILED (run dir kept: $$run)"; fi; \
	exit $$status

# make fixture DIR=/tmp/revuey-fixture
fixture:
	scripts/make-fixture.sh $(DIR)
