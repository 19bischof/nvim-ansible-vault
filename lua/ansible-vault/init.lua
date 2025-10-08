---@diagnostic disable: undefined-global
local Core = require("ansible-vault.core")
local Popup = require("ansible-vault.popup")

local M = {}

M.config = {
    vault_password_file = nil,
    ansible_cfg_directory = nil,
    vault_executable = "ansible-vault",
    debug = false,
}

local vault_buffers = {}

function M.setup(opts)
    vim.validate({ opts = { opts, "table", true } })
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    local group = vim.api.nvim_create_augroup("AnsibleVault", { clear = true })
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
    local vault_block = Core.find_inline_vault_block_at_cursor(lines)
    local vault_type = Core.VaultType.inline
    ---@type string
    local vault_name = vault_block and vault_block.key or file_path

    if not vault_block then
        local file_is_vault = Core.check_is_file_vault(M.config, file_path)
        if file_is_vault then
            vault_type = Core.VaultType.file
            vault_name = vim.fs.basename(file_path)
        else
            vim.notify("No vault found at cursor position", vim.log.levels.WARN)
            return
        end
    end

    vault_buffers[bufnr] = true
    Core.debug(M.config, string.format("access vault_type=%s file=%s", vault_type, file_path))
    local decrypted_value, err
    if vault_type == Core.VaultType.inline then
        if not vault_block then
            vim.notify("Internal error: missing vault block for inline vault", vim.log.levels.ERROR)
            return
        end
        decrypted_value, err = Core.decrypt_inline_content(M.config, vault_block.vault_content)
    else
        decrypted_value, err = Core.decrypt_file_vault(M.config, file_path)
    end
    if not decrypted_value then
        vim.notify("Failed to decrypt " .. vault_name .. ": " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
    end
    Core.debug(M.config, string.format("decrypted length=%d", #decrypted_value))

    Popup.open(M.config, {
        bufnr = bufnr,
        file_path = file_path,
        vault_type = vault_type,
        vault_name = vault_name,
        decrypted_value = decrypted_value,
        vault_block = vault_block,
    })
end

function M.encrypt_current_file(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local file_path = vim.api.nvim_buf_get_name(bufnr)
    if file_path == "" then
        vim.notify("Cannot encrypt without a file path", vim.log.levels.ERROR)
        return
    end
    Core.debug(M.config, string.format("encrypt_current_file (file only) file=%s", file_path))
    local cmd = Core.get_vault_command(M.config, "encrypt", file_path)
    local cwd = (M.config.ansible_cfg_directory and M.config.ansible_cfg_directory ~= "")
        and vim.fn.expand(M.config.ansible_cfg_directory)
        or nil
    local proc = vim.system(cmd, { text = true, cwd = cwd })
    local res = proc:wait()
    if res.code ~= 0 then
            local ids = Core.extract_encrypt_vault_ids((res.stderr or res.stdout or ""))
            if ids and #ids > 0 then
                pcall(vim.cmd, "stopinsert")
                vim.schedule(function()
                    vim.ui.select(ids, { prompt = "Select vault-id for file encryption" }, function(choice)
                    if not choice then
                        vim.notify("Encryption cancelled (no vault-id selected)", vim.log.levels.WARN)
                        return
                    end
                    local retry_cmd = Core.get_vault_command(M.config, "encrypt", file_path, { encrypt_vault_id = choice })
                    local retry_proc = vim.system(retry_cmd, { text = true, cwd = cwd })
                    local retry_res = retry_proc:wait()
                    if retry_res.code ~= 0 then
                        vim.notify("Failed to encrypt file: " .. (retry_res.stderr or "unknown error"), vim.log.levels.ERROR)
                        return
                    end
                    vim.notify("File encrypted successfully", vim.log.levels.INFO)
                    vim.api.nvim_buf_call(bufnr, function()
                        vim.cmd("edit!")
                    end)
                    end)
                end)
                return
            end
            vim.notify("Failed to encrypt file: " .. (res.stderr or "unknown error"), vim.log.levels.ERROR)
            return
    end
    vim.notify("File encrypted successfully", vim.log.levels.INFO)
    -- reload buffer to reflect on-disk encrypted content
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("edit!")
    end)
end

---Encrypt the YAML scalar value at cursor into an inline vault block
---@param bufnr? integer
function M.encrypt_inline_at_cursor(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_nr = cursor[1]
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local line = lines[line_nr]
    if not line then
        return
    end

    -- Match `key: value` on a single line, ignoring existing !vault
    local indent, key, value = line:match("^(%s*)([%w_-]+):%s*(.-)%s*$")
    if not indent or not key or not value or value == "" or value:match("!vault") then
        vim.notify("No simple YAML scalar at cursor to encrypt", vim.log.levels.WARN)
        return
    end

    local function apply_inline_enc(vault_lines)
        local content_indent = indent .. "  "
        local new_header = string.format("%s%s: !vault |-", indent, key)
        local to_insert = {}
        for _, l in ipairs(vault_lines) do
            table.insert(to_insert, content_indent .. l)
        end
        -- Replace current line with header, then insert vault lines below
        vim.api.nvim_buf_set_lines(bufnr, line_nr - 1, line_nr, false, { new_header })
        vim.api.nvim_buf_set_lines(bufnr, line_nr, line_nr, false, to_insert)
        vim.notify("Inline value encrypted", vim.log.levels.INFO)
    end

    local vault_lines, err = Core.encrypt_content(M.config, value)
    if not vault_lines then
        local ids = Core.extract_encrypt_vault_ids(err or "")
        if ids and #ids > 0 then
            pcall(vim.cmd, "stopinsert")
            vim.schedule(function()
                vim.ui.select(ids, { prompt = "Select vault-id for inline encryption" }, function(choice)
                    if not choice then
                        vim.notify("Inline encryption cancelled", vim.log.levels.WARN)
                        return
                    end
                    local retry_lines, retry_err = Core.encrypt_content(M.config, value, { encrypt_vault_id = choice })
                    if not retry_lines then
                        vim.notify(retry_err or "Failed to encrypt inline value", vim.log.levels.ERROR)
                        return
                    end
                    apply_inline_enc(retry_lines)
                end)
            end)
            return
        end
        vim.notify(err or "Failed to encrypt inline value", vim.log.levels.ERROR)
        return
    end
    apply_inline_enc(vault_lines)
end
return M
