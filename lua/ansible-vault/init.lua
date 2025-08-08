---@class AnsibleVaultConfig
---@field vault_password_file? string
---@field vault_executable string

---@alias VaultType "inline"|"file"

local VaultType = { inline = "inline", file = "file" }

local M = {}

-- Configuration
M.config = {
  vault_password_file = nil,
  vault_executable = "ansible-vault", -- Path to ansible-vault executable
}

-- State tracking
local vault_buffers = {}

-- Utility functions
local function get_vault_command(action, file_path)
  local cmd = { M.config.vault_executable, action }

  if M.config.vault_password_file then
    table.insert(cmd, "--vault-password-file")
    table.insert(cmd, M.config.vault_password_file)
  end

  table.insert(cmd, file_path)
  return cmd
end

local function check_if_file_is_vault(file_path)
  local cmd = get_vault_command("view", file_path)
  local result = vim.fn.system(cmd)
  return vim.v.shell_error == 0
end

-- Function to find vault block at cursor position
local function find_vault_block_at_cursor(lines)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] -- 1-based line number

  if cursor_line > #lines then
    return nil
  end

  local vault_line_num = cursor_line
  local vault_key = nil

  -- Find the vault header line
  local line = lines[cursor_line]
  if line and line:match("^%s*[%w_-]+:%s*!vault%s*|?%-?%s*$") then
    -- Cursor is on vault header line
    vault_key = line:match("^%s*([%w_-]+):%s*!vault%s*|?%-?%s*$")
    vault_line_num = cursor_line
  elseif line and line:match("^%s+%S") then
    -- Cursor is on vault content line, look backwards for header
    for i = cursor_line - 1, 1, -1 do
      local check_line = lines[i]
      if check_line:match("^%s*[%w_-]+:%s*!vault%s*|?%-?%s*$") then
        vault_key = check_line:match("^%s*([%w_-]+):%s*!vault%s*|?%-?%s*$")
        vault_line_num = i
        break
      elseif not check_line:match("^%s*$") and not check_line:match("^%s+") then
        break -- Hit non-vault line
      end
    end
  end

  if not vault_key then
    return nil
  end

  -- Collect vault content lines (indented lines after the header)
  local vault_content = {}
  local vault_indent = #(lines[vault_line_num]:match("^(%s*)") or "")
  local end_line = vault_line_num

  for i = vault_line_num + 1, #lines do
    local content_line = lines[i]
    if content_line:match("^%s+%S") then -- Indented line with content
      local line_indent = #(content_line:match("^(%s*)") or "")
      if line_indent > vault_indent then
        table.insert(vault_content, content_line)
        end_line = i
      else
        break -- Different indentation level, end of vault block
      end
    elseif content_line:match("^%s*$") then -- Empty line, continue
      end_line = i
    else
      break -- Non-indented line, end of vault block
    end
  end

  if #vault_content == 0 then
    return nil
  end

  return {
    key = vault_key,
    start_line = vault_line_num,
    end_line = end_line,
    vault_content = vault_content,
  }
end

-- Function to decrypt vault content directly
local function decrypt_vault_content(vault_content)
  local stripped = {}
  for _, line in ipairs(vault_content) do
    stripped[#stripped + 1] = (line:gsub("^%s+", ""))
  end
  return with_tempfile(stripped, function(tmp)
    local cmd = get_vault_command("decrypt", tmp)
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      return nil, "Failed to decrypt vault content: " .. (out or "")
    end
    return table.concat(vim.fn.readfile(tmp), "\n")
  end)
end

-- Function to encrypt content as raw vault
local function encrypt_content_as_vault(value)
  local lines = vim.split(value, "\n")
  return with_tempfile(lines, function(tmp)
    local cmd = { M.config.vault_executable, "encrypt", "--encrypt-vault-id", "default" }
    if M.config.vault_password_file then
      table.insert(cmd, "--vault-password-file")
      table.insert(cmd, M.config.vault_password_file)
    end
    table.insert(cmd, tmp)
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      return nil, "Failed to encrypt content: " .. (out or "")
    end
    return vim.fn.readfile(tmp) -- caller decides how to insert
  end)
end

local function decrypt_file(file_path)
  local cmd = get_vault_command("view", file_path)
  local plaintext = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, "Failed to view/decrypt file"
  end
  return plaintext
end

local function encrypt_file_with_content(file_path, plaintext)
  local enc_lines, err = encrypt_content_as_vault(plaintext)
  if not enc_lines then return nil, err end
  vim.fn.writefile(enc_lines, file_path)
  return true
end

-- Always deletes the tempfile, even on error
local function with_tempfile(lines, fn)
  local tmp = vim.fn.tempname()
  local ok_write, write_err = pcall(vim.fn.writefile, lines, tmp)
  if not ok_write then
    -- no file to delete if write failed before creation
    return nil, ("Failed to write tempfile: %s"):format(write_err or "unknown error")
  end
  local ok, res, err = xpcall(fn, debug.traceback, tmp)
  vim.fn.delete(tmp) -- best-effort cleanup
  if not ok then
    return nil, res -- traceback string
  end
  return res, err
end

-- Main functions
function M.setup(opts)
  vim.validate({ opts = { opts, "table", true } })
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local group = vim.api.nvim_create_augroup("AnsibleVault", { clear = true })
  vim.api.nvim_create_autocmd({ "BufDelete" }, {
    group = group,
    callback = function(args) vault_buffers[args.buf] = nil end,
  })
end

function M.vault_access(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(bufnr)

  if file_path == "" then
    vim.notify("Cannot access vault without a file path", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local vault_block = find_vault_block_at_cursor(lines)
  local vault_type = VaultType.inline
  local vault_name = vault_block and vault_block.key or nil

  local file_is_vault = check_if_file_is_vault(file_path)

  if not vault_block then
    if file_is_vault then
      vault_type = VaultType.file
      vault_name = file_path
    else
      vim.notify("No vault found at cursor position", vim.log.levels.WARN)
      return
    end
  end

  vault_buffers[bufnr] = true
  local decrypted_value, err
  if vault_type == VaultType.inline then
    decrypted_value, err = decrypt_vault_content(vault_block.vault_content) -- inline only
  else -- "file"
    decrypted_value, err = decrypt_file(file_path) -- don't strip whitespace
  end
  if not decrypted_value then
    vim.notify("Failed to decrypt " .. vault_name .. ": " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end
  
  -- Show decrypted content in an editable popup
  local popup_lines = vim.split(decrypted_value, "\n")
  local original_content = decrypted_value
  
  -- Create popup buffer
  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, popup_lines)
  vim.api.nvim_buf_set_option(popup_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(popup_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(popup_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(popup_buf, "filetype", "text")
  vim.api.nvim_buf_set_option(popup_buf, "modifiable", true)
  vim.api.nvim_buf_set_name(popup_buf, "VaultEdit-" .. vim.fn.localtime())
  
  -- Calculate popup size
  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#popup_lines + 4, math.floor(vim.o.lines * 0.8))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  
  -- Create popup window
  local popup_win = vim.api.nvim_open_win(popup_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Edit Vault: " .. vault_name .. " ",
    title_pos = "center",
  })
  
  -- Set popup window options
  vim.api.nvim_win_set_option(popup_win, "wrap", true)
  vim.api.nvim_win_set_option(popup_win, "cursorline", true)
  
  -- Function to check if content changed and handle save/close
  local function handle_save_and_close()
    local current_lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
    local current_content = table.concat(current_lines, "\n")

    if current_content ~= original_content then
      if vault_type == VaultType.inline then
        local vault_lines, encrypt_err = encrypt_content_as_vault(current_content)
        if not vault_lines then
          vim.notify("Failed to encrypt new content: " .. (encrypt_err or "unknown error"), vim.log.levels.ERROR)
          return
        end

        local current_src = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local modified_lines = vim.deepcopy(current_src)

        local original_content_indent = ""
        if #vault_block.vault_content > 0 then
          original_content_indent = vault_block.vault_content[1]:match("^(%s*)") or ""
        end

        for j = vault_block.end_line, vault_block.start_line + 1, -1 do
          table.remove(modified_lines, j)
        end
        for j = #vault_lines, 1, -1 do
          table.insert(modified_lines, vault_block.start_line + 1, original_content_indent .. vault_lines[j])
        end

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, modified_lines)
        -- leave buffer 'modified' so user can :w (or write automatically if you prefer)
      else -- file
        local ok, enc_err = encrypt_file_with_content(file_path, current_content)
        if not ok then
          vim.notify(enc_err or "Failed to encrypt file", vim.log.levels.ERROR)
          return
        end
        vim.notify("File encrypted successfully", vim.log.levels.INFO)
      end
    end

    if vim.api.nvim_win_is_valid(popup_win) then
      vim.api.nvim_win_close(popup_win, true)
    end
  end
  
  -- Simple close without save
  local function close_popup()
    if vim.api.nvim_win_is_valid(popup_win) then
      vim.api.nvim_win_close(popup_win, true)
    end
  end
  
  -- Copy to clipboard
  local function copy_to_clipboard()
    local current_lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
    local current_content = table.concat(current_lines, "\n")
    vim.fn.setreg('+', current_content)
    vim.notify("Copied to clipboard", vim.log.levels.INFO)
  end
  
  -- Keybindings
  vim.keymap.set("n", "<Esc>", close_popup, { buffer = popup_buf, nowait = true })
  vim.keymap.set("n", "q", close_popup, { buffer = popup_buf, nowait = true })
  vim.keymap.set("n", "<C-s>", handle_save_and_close, { buffer = popup_buf, nowait = true })
  vim.keymap.set("i", "<C-s>", handle_save_and_close, { buffer = popup_buf, nowait = true })
  vim.keymap.set("n", "<CR>", handle_save_and_close, { buffer = popup_buf, nowait = true })
  vim.keymap.set("n", "y", copy_to_clipboard, { buffer = popup_buf, nowait = true })
  
  -- Show keybindings help when user presses 'h' or '?'
  local function show_help()
    local help_lines = {
      "Ansible Vault Popup Keybindings:",
      "",
      "  <C-s> / <Enter> : Save & encrypt, close popup",
      "  <Esc> / q       : Cancel/close popup",
      "  y               : Copy to clipboard",
      "  ?          : Show this help",
      "",
      "Start typing to edit decrypted content.",
    }
    vim.notify(table.concat(help_lines, "\n"), vim.log.levels.INFO)
  end

  vim.keymap.set("n", "?", show_help, { buffer = popup_buf, nowait = true })
end



return M