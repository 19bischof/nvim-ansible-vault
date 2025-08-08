---@class AnsibleVaultConfig
---@field vault_password_file? string
---@field vault_executable string

---@alias VaultType "inline"|"file"

---@diagnostic disable: undefined-global
local Core = {}

Core.VaultType = { inline = "inline", file = "file" }

function Core.debug(config, message)
  if config and config.debug then
    vim.notify("[nvim-ansible-vault] " .. message, vim.log.levels.DEBUG)
  end
end

-- Always deletes the tempfile, even on error
local function with_tempfile(lines, fn)
  local tmp = vim.fn.tempname()
  local ok_write, write_err = pcall(vim.fn.writefile, lines, tmp)
  if not ok_write then
    return nil, ("Failed to write tempfile: %s"):format(write_err or "unknown error")
  end
  local ok, res, err = xpcall(fn, debug.traceback, tmp)
  vim.fn.delete(tmp)
  if not ok then
    return nil, res
  end
  return res, err
end

local function supports_vim_system()
  return type(vim.system) == "function"
end

-- Run ansible-vault with stdin. For decrypt/encrypt from stdin we direct result to stderr to avoid
-- mixing with the tool's status messages that are printed to stdout.
---@param args string[]
---@param stdin string
---@return { code: integer, stdout: string, stderr: string }
local function run_with_stdin(args, stdin)
  local proc = vim.system(args, { stdin = stdin, text = true })
  local res = proc:wait()
  -- Normalize fields if older signatures change
  res.stdout = res.stdout or ""
  res.stderr = res.stderr or ""
  -- Avoid logging stdin content; only sizes
  return res
end

function Core.get_vault_command(config, action, file_path)
  local cmd = { config.vault_executable, action }
  if config.vault_password_file then
    table.insert(cmd, "--vault-password-file")
    table.insert(cmd, config.vault_password_file)
  end
  table.insert(cmd, file_path)
  Core.debug(config, string.format("cmd=%s action=%s file=%s", config.vault_executable, action, file_path))
  return cmd
end

function Core.check_if_file_is_vault(config, file_path)
  local cmd = Core.get_vault_command(config, "view", file_path)
  vim.fn.system(cmd)
  return vim.v.shell_error == 0
end

function Core.find_vault_block_at_cursor(lines)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  if cursor_line > #lines then
    return nil
  end

  local vault_line_num = cursor_line
  local vault_key = nil
  local line = lines[cursor_line]

  if line and line:match("^%s*[%w_-]+:%s*!vault%s*|?%-?%s*$") then
    vault_key = line:match("^%s*([%w_-]+):%s*!vault%s*|?%-?%s*$")
    vault_line_num = cursor_line
  elseif line and line:match("^%s+%S") then
    for i = cursor_line - 1, 1, -1 do
      local check_line = lines[i]
      if check_line:match("^%s*[%w_-]+:%s*!vault%s*|?%-?%s*$") then
        vault_key = check_line:match("^%s*([%w_-]+):%s*!vault%s*|?%-?%s*$")
        vault_line_num = i
        break
      elseif not check_line:match("^%s*$") and not check_line:match("^%s+") then
        break
      end
    end
  end

  if not vault_key then
    return nil
  end

  local vault_content = {}
  local vault_indent = #(lines[vault_line_num]:match("^(%s*)") or "")
  local end_line = vault_line_num

  for i = vault_line_num + 1, #lines do
    local content_line = lines[i]
    if content_line:match("^%s+%S") then
      local line_indent = #(content_line:match("^(%s*)") or "")
      if line_indent > vault_indent then
        vault_content[#vault_content + 1] = content_line
        end_line = i
      else
        break
      end
    elseif content_line:match("^%s*$") then
      end_line = i
    else
      break
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

---@param config AnsibleVaultConfig
---@param vault_content string[]
---@return string|nil, string|nil
function Core.decrypt_vault_content(config, vault_content)
  local stripped = {}
  for _, l in ipairs(vault_content) do
    stripped[#stripped + 1] = (l:gsub("^%s+", ""))
  end
  if supports_vim_system() then
    Core.debug(config, string.format("decrypt_inline via stdin lines=%d", #stripped))
    local args = { config.vault_executable, "decrypt", "/dev/stdin", "--output=/dev/stderr" }
    if config.vault_password_file then
      table.insert(args, "--vault-password-file")
      table.insert(args, config.vault_password_file)
    end
    local res = run_with_stdin(args, table.concat(stripped, "\n"))
    Core.debug(config, string.format("decrypt_inline exit=%d out_len=%d err_len=%d", res.code or -1, #res.stdout, #res.stderr))
    if res.code ~= 0 then
      return nil, (res.stdout ~= "" and res.stdout) or res.stderr or "decrypt failed"
    end
    return res.stderr
  end
  Core.debug(config, string.format("decrypt_inline via tempfile lines=%d", #stripped))
  return with_tempfile(stripped, function(tmp)
    local cmd = Core.get_vault_command(config, "decrypt", tmp)
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      return nil, "Failed to decrypt vault content: " .. (out or "")
    end
    return table.concat(vim.fn.readfile(tmp), "\n")
  end)
end

---@param config AnsibleVaultConfig
---@param value string
---@return string[]|nil, string|nil
function Core.encrypt_content_as_vault(config, value)
  if supports_vim_system() then
    Core.debug(config, string.format("encrypt_inline via stdin bytes=%d", #value))
    local args = { config.vault_executable, "encrypt", "/dev/stdin", "--encrypt-vault-id", "default", "--output=/dev/stderr" }
    if config.vault_password_file then
      table.insert(args, "--vault-password-file")
      table.insert(args, config.vault_password_file)
    end
    local res = run_with_stdin(args, value)
    Core.debug(config, string.format("encrypt_inline exit=%d out_len=%d err_len=%d", res.code or -1, #res.stdout, #res.stderr))
    if res.code ~= 0 then
      return nil, (res.stdout ~= "" and res.stdout) or res.stderr or "encrypt failed"
    end
    -- Return lines array for caller
    return vim.split(res.stderr, "\n", { plain = true })
  end
  Core.debug(config, string.format("encrypt_inline via tempfile bytes=%d", #value))
  local lines = vim.split(value, "\n")
  return with_tempfile(lines, function(tmp)
    local cmd = { config.vault_executable, "encrypt", "--encrypt-vault-id", "default" }
    if config.vault_password_file then
      table.insert(cmd, "--vault-password-file")
      table.insert(cmd, config.vault_password_file)
    end
    table.insert(cmd, tmp)
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      return nil, "Failed to encrypt content: " .. (out or "")
    end
    return vim.fn.readfile(tmp)
  end)
end

---@param config AnsibleVaultConfig
---@param file_path string
---@return string|nil, string|nil
function Core.decrypt_file(config, file_path)
  if supports_vim_system() then
    Core.debug(config, string.format("decrypt_file via system file=%s", file_path))
    local args = { config.vault_executable, "view", file_path }
    if config.vault_password_file then
      table.insert(args, "--vault-password-file")
      table.insert(args, config.vault_password_file)
    end
    local proc = vim.system(args, { text = true })
    local res = proc:wait()
    Core.debug(config, string.format("decrypt_file exit=%d out_len=%d err_len=%d", res.code or -1, #(res.stdout or ""), #(res.stderr or "")))
    if res.code ~= 0 then
      return nil, res.stderr or "Failed to view/decrypt file"
    end
    return res.stdout
  end
  local cmd = Core.get_vault_command(config, "view", file_path)
  local plaintext = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, "Failed to view/decrypt file"
  end
  return plaintext
end

---@param config AnsibleVaultConfig
---@param file_path string
---@param plaintext string
---@return boolean|nil, string|nil
function Core.encrypt_file_with_content(config, file_path, plaintext)
  Core.debug(config, string.format("encrypt_file_with_content file=%s bytes=%d", file_path, #plaintext))
  local enc_lines, err = Core.encrypt_content_as_vault(config, plaintext)
  if not enc_lines then
    return nil, err
  end
  vim.fn.writefile(enc_lines, file_path)
  Core.debug(config, string.format("wrote encrypted file lines=%d", #enc_lines))
  return true
end

return Core


