--- Tests for pi-pipe.selection
--- Run with: nvim --headless -c "PlenaryBustedFile spec/selection_spec.lua"

local selection = require("pi-pipe.selection")

describe("get_visual_selection", function()
  it("returns nil when not in visual mode", function()
    -- Normal mode by default in headless test
    local result = selection.get_visual_selection()
    assert.is_nil(result, "expected nil in normal mode")
  end)
end)

describe("get_cursor_position", function()
  it("returns a zero-width selection at cursor", function()
    -- Create a scratch buffer with some content
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world", "second line" })

    -- Name the buffer so file_path is non-empty
    local tmp = vim.fn.tempname()
    vim.api.nvim_buf_set_name(buf, tmp)

    -- Set cursor to line 1, col 0 (zero-indexed col 0)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local result = selection.get_cursor_position()
    assert.is_not_nil(result)
    assert.equals(0, result.start_line)
    assert.equals(0, result.start_char)
    assert.equals(0, result.end_line)
    assert.equals(0, result.end_char)
    assert.equals("", result.text)
    assert.truthy(result.fileUrl:match("^file://"))

    vim.api.nvim_buf_delete(buf, { force = true })
    os.remove(tmp)
  end)

  it("returns nil when buffer has no name", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "no name" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local result = selection.get_cursor_position()
    assert.is_nil(result)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("has_selection_changed", function()
  local function mkSel(line, char, text)
    return {
      fileUrl = "file:///tmp/x.lua",
      text = text or "",
      start_line = line,
      start_char = char,
      end_line = line,
      end_char = char,
    }
  end

  it("returns true when previous is nil", function()
    selection.state.latest_selection = nil
    assert.is_true(selection.has_selection_changed(mkSel(1, 0)))
  end)

  it("returns true when previous is nil (even if new is also nil)", function()
    -- nil->nil is unreachable from update_and_broadcast (it returns early
    -- when get_current_selection() returns nil), but has_selection_changed
    -- itself returns true whenever there is no previous selection recorded.
    selection.state.latest_selection = nil
    assert.is_true(selection.has_selection_changed(nil))
  end)

  it("returns false when identical", function()
    selection.state.latest_selection = mkSel(1, 0, "abc")
    assert.is_false(selection.has_selection_changed(mkSel(1, 0, "abc")))
  end)

  it("returns true when text differs", function()
    selection.state.latest_selection = mkSel(1, 0, "abc")
    assert.is_true(selection.has_selection_changed(mkSel(1, 0, "xyz")))
  end)

  it("returns true when file differs", function()
    selection.state.latest_selection = mkSel(1, 0, "abc")
    local other = vim.tbl_deep_extend("force", mkSel(1, 0, "abc"), { fileUrl = "file:///tmp/y.lua" })
    assert.is_true(selection.has_selection_changed(other))
  end)

  it("returns true when position differs", function()
    selection.state.latest_selection = mkSel(1, 0, "abc")
    assert.is_true(selection.has_selection_changed(mkSel(2, 0, "abc")))
    assert.is_true(selection.has_selection_changed(mkSel(1, 5, "abc")))
  end)
end)

describe("get_relative_path", function()
  it("returns nil when no file is open", function()
    -- In a scratch buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local result = selection.get_relative_path()
    assert.is_nil(result)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("set_config", function()
  it("applies debounce_ms from config", function()
    selection.set_config({ debounce_ms = 250 })
    assert.equals(250, selection.state.debounce_ms)
  end)

  it("defaults to 100 when not specified", function()
    selection.set_config({})
    assert.equals(100, selection.state.debounce_ms)
  end)
end)
