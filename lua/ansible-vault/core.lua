---@class AnsibleVaultConfig
---@field vault_password_file? string
---@field ansible_cfg_directory? string
---@field vault_executable string

---@alias VaultType "inline"|"file"

---@diagnostic disable: undefined-global
local Core = {}

-- Derive working directory and executable from provided config
local function get_cwd(config)
    if config and config.ansible_cfg_directory and config.ansible_cfg_directory ~= "" then
        return vim.fn.expand(config.ansible_cfg_directory)
    end
    return nil
end

local function get_executable(config)
    if config and config.vault_executable then
        return vim.fn.expand(config.vault_executable)
    end
    return "ansible-vault"
end

Core.VaultType = { inline = "inline", file = "file" }

---Parse ansible-vault error output to extract available encrypt vault-ids
---@param output string
---@return string[]|nil
function Core.extract_encrypt_vault_ids(output)
    if not output or output == "" then
        return nil
    end
    -- Example: "ERROR! The vault-ids prod,default are available to encrypt. Specify the vault-id..."
    local list = output:match("[Tt]he vault%-ids%s+([^%s]+)%s+are available to encrypt")
    if not list then
        return nil
    end
    local ids = {}
    for id in list:gmatch("[^,]+") do
        local trimmed = (id:gsub("^%s+", ""):gsub("%s+$", ""))
        if trimmed ~= "" then
            table.insert(ids, trimmed)
        end
    end
    if #ids == 0 then
        return nil
    end
    return ids
end

function Core.debug(config, message)
    if config.debug then
        vim.notify("[nvim-ansible-vault] " .. message, vim.log.levels.DEBUG)
    end
end

-- Run ansible-vault with stdin. For decrypt/encrypt from stdin we direct result to stderr to avoid
-- mixing with the tool's status messages that are printed to stdout.
---@param args string[]
---@param stdin string
---@return { code: integer, stdout: string, stderr: string }
local function run_with_stdin(args, stdin, cwd)
    local proc = vim.system(args, { stdin = stdin, text = true, cwd = cwd })
    local res = proc:wait()
    -- Normalize fields if older signatures change
    res.stdout = res.stdout or ""
    res.stderr = res.stderr or ""
    -- Avoid logging stdin content; only sizes
    return res
end

---Build ansible-vault command
---@param config AnsibleVaultConfig
---@param action string
---@param file_path string
---@param opts? { encrypt_vault_id?: string }
function Core.get_vault_command(config, action, file_path, opts)
    local executable = get_executable(config)
    local cmd = { executable, action }
    if config.vault_password_file then
        table.insert(cmd, "--vault-password-file")
        table.insert(cmd, config.vault_password_file)
    end
    if opts and opts.encrypt_vault_id and action == "encrypt" then
        table.insert(cmd, "--encrypt-vault-id")
        table.insert(cmd, opts.encrypt_vault_id)
    end
    table.insert(cmd, file_path)
    Core.debug(config, string.format("cmd=%s action=%s file=%s", executable, action, file_path))
    return cmd
end

function Core.check_is_file_vault(config, file_path)
    local cmd = Core.get_vault_command(config, "view", file_path)
    local proc = vim.system(cmd, { text = true, cwd = get_cwd(config)})
    local res = proc:wait()
    return res.code == 0
end

function Core.find_inline_vault_block_at_cursor(lines)
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
function Core.decrypt_inline_content(config, vault_content)
    local stripped = {}
    for _, l in ipairs(vault_content) do
        stripped[#stripped + 1] = (l:gsub("^%s+", ""))
    end
    Core.debug(config, string.format("decrypt_inline via stdin(view) lines=%d", #stripped))
    local args = { get_executable(config), "view", "/dev/stdin" }
    if config.vault_password_file then
        table.insert(args, "--vault-password-file")
        table.insert(args, config.vault_password_file)
    end
    local res = run_with_stdin(args, table.concat(stripped, "\n"), get_cwd(config))
    Core.debug(
        config,
        string.format("decrypt_inline(view) exit=%d out_len=%d err_len=%d", res.code or -1, #res.stdout, #res.stderr)
    )
    if res.code ~= 0 then
        return nil, res.stderr ~= "" and res.stderr or res.stdout or "decrypt failed"
    end
    return res.stdout
end

---Encrypt text content using ansible-vault encrypt_string
---@param config AnsibleVaultConfig
---@param value string
---@param opts? { encrypt_vault_id?: string }
function Core.encrypt_content(config, value, opts)
    Core.debug(config, string.format("encrypt_content via encrypt_string bytes=%d", #value))
    local args = { get_executable(config), "encrypt_string" }
    if config.vault_password_file then
        table.insert(args, "--vault-password-file")
        table.insert(args, config.vault_password_file)
    end
    if opts and opts.encrypt_vault_id then
        table.insert(args, "--encrypt-vault-id")
        table.insert(args, opts.encrypt_vault_id)
    end
    table.insert(args, "--stdin-name")
    table.insert(args, "value")
    local res = run_with_stdin(args, value, get_cwd(config))
    Core.debug(
        config,
        string.format(
            "encrypt_content (encrypt_string) exit=%d out_len=%d err_len=%d",
            res.code or -1,
            #res.stdout,
            #res.stderr
        )
    )
    if res.code ~= 0 then
        return nil, res.stderr ~= "" and res.stderr or res.stdout or "encrypt failed"
    end
    local output = res.stdout or ""
    local out_lines = vim.split(output, "\n", { plain = true })
    if #out_lines > 0 and out_lines[1]:match("^[^:]+:%s*!vault%s*|%s*$") then
        local vault_lines = {}
        for i = 2, #out_lines do
            local l = out_lines[i]
            if l ~= "" then
                l = l:gsub("^%s+", "")
            end
            table.insert(vault_lines, l)
        end
        return vault_lines
    end
    return out_lines
end

---@param config AnsibleVaultConfig
---@param file_path string
---@return string|nil, string|nil
function Core.decrypt_file_vault(config, file_path)
    Core.debug(config, string.format("decrypt_file via system file=%s", file_path))
    local args = Core.get_vault_command(config, "view", file_path)
    local proc = vim.system(args, { text = true, cwd = get_cwd(config)  })
    local res = proc:wait()
    Core.debug(
        config,
        string.format(
            "decrypt_file exit=%d out_len=%d err_len=%d",
            res.code or -1,
            #(res.stdout or ""),
            #(res.stderr or "")
        )
    )
    if res.code ~= 0 then
        return nil, res.stderr or "Failed to view/decrypt file"
    end
    return res.stdout
end

---Encrypt a file by first encrypting provided plaintext and writing it to file
---@param config AnsibleVaultConfig
---@param file_path string
---@param plaintext string
---@param opts? { encrypt_vault_id?: string }
function Core.encrypt_file_with_content(config, file_path, plaintext, opts)
    Core.debug(config, string.format("encrypt_file_with_content file=%s bytes=%d", file_path, #plaintext))
    local enc_lines, err = Core.encrypt_content(config, plaintext, opts)
    if not enc_lines then
        return nil, err
    end
    vim.fn.writefile(enc_lines, file_path)
    Core.debug(config, string.format("wrote encrypted file lines=%d", #enc_lines))
    return true
end

return Core
