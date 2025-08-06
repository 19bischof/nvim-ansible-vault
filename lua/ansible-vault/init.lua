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
  -- Strip leading whitespace from vault content lines
  local stripped_content = {}
  for _, line in ipairs(vault_content) do
    local stripped_line = line:gsub("^%s+", "") -- Remove leading whitespace
    table.insert(stripped_content, stripped_line)
  end

  -- Create temporary file for decryption
  local temp_file = vim.fn.tempname()
  vim.fn.writefile(stripped_content, temp_file)

  -- Decrypt the vault content
  local cmd = get_vault_command("decrypt", temp_file)
  local decrypt_result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    vim.fn.delete(temp_file)
    return nil, "Failed to decrypt vault content: " .. decrypt_result
  end

  local decrypted_lines = vim.fn.readfile(temp_file)
  vim.fn.delete(temp_file)

  -- Join lines and return as single value
  return table.concat(decrypted_lines, "\n"), nil
end

-- Function to encrypt content as raw vault
local function encrypt_content_as_vault(value)
  -- Create temporary file with the content to encrypt
  local temp_input_file = vim.fn.tempname()
  vim.fn.writefile(vim.split(value, "\n"), temp_input_file)

  local cmd = { M.config.vault_executable, "encrypt" }

  if M.config.vault_password_file then
    table.insert(cmd, "--vault-password-file")
    table.insert(cmd, M.config.vault_password_file)
  end

  -- Add default vault-id to avoid the "specify vault-id" error
  table.insert(cmd, "--encrypt-vault-id")
  table.insert(cmd, "default")

  table.insert(cmd, temp_input_file)

  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    vim.fn.delete(temp_input_file)
    return nil, "Failed to encrypt content: " .. result
  end

  -- Read the encrypted file content
  local encrypted_lines = vim.fn.readfile(temp_input_file)
  vim.fn.delete(temp_input_file)
  
  return encrypted_lines, nil
end

-- Main functions
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Create autocommands
  local group = vim.api.nvim_create_augroup("AnsibleVault", { clear = true })



  -- Clean up tracking on buffer delete
  vim.api.nvim_create_autocmd({ "BufDelete" }, {
    group = group,
    callback = function(args)
      vault_buffers[args.buf] = nil
    end,
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

  if not vault_block then
    vim.notify("No vault found at cursor position", vim.log.levels.WARN)
    return
  end

  vault_buffers[bufnr] = true
  local decrypted_value, err = decrypt_vault_content(vault_block.vault_content)

  if not decrypted_value then
    vim.notify("Failed to decrypt " .. vault_block.key .. ": " .. (err or "unknown error"), vim.log.levels.ERROR)
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
    title = " Edit Vault: " .. vault_block.key .. " ",
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
      -- Encrypt the new content
      local vault_lines, encrypt_err = encrypt_content_as_vault(current_content)
      
      if vault_lines then
        -- Replace the vault block directly in the buffer
        local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local modified_lines = vim.deepcopy(current_lines)
        
        -- Get the original vault content indentation from the first vault content line
        local original_content_indent = ""
        if #vault_block.vault_content > 0 then
          original_content_indent = vault_block.vault_content[1]:match("^(%s*)") or ""
        end
        
        -- Remove only the vault content lines (keep the header line)
        for j = vault_block.end_line, vault_block.start_line + 1, -1 do
          table.remove(modified_lines, j)
        end
        
        -- Insert the new vault content after the header line
        for j = #vault_lines, 1, -1 do
          local indented_line = original_content_indent .. vault_lines[j]
          table.insert(modified_lines, vault_block.start_line + 1, indented_line)
        end
        
        -- Update the buffer
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, modified_lines)
        vim.api.nvim_buf_set_option(bufnr, "modified", false)
        vim.notify(string.format("Updated and encrypted vault value: %s", vault_block.key), vim.log.levels.INFO)
      else
        vim.notify("Failed to encrypt new content: " .. (encrypt_err or "unknown error"), vim.log.levels.ERROR)
      end
    end
    
    -- Close popup
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
  
  vim.notify(string.format("Editing vault: %s (Ctrl-S/Enter: save & close, ESC/q: close, y: copy)", vault_block.key), vim.log.levels.INFO)
end



return M