test: test-unit test-nvim-tree

test-unit:
	nvim --headless -u NONE -l tests/archipelago_test.lua

.deps/nvim-tree.lua:
	git clone --depth 1 https://github.com/nvim-tree/nvim-tree.lua .deps/nvim-tree.lua

test-nvim-tree: .deps/nvim-tree.lua
	nvim --headless -u NONE -l tests/nvim_tree_test.lua

.PHONY: test test-unit test-nvim-tree
