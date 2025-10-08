---@diagnostic disable: undefined-global, undefined-field
local Core = require("ansible-vault.core")

local Popup = {}

---@class PopupParams
---@field bufnr integer
---@field file_path string
---@field vault_type "inline"|"file"
---@field vault_name string
---@field decrypted_value string
---@field vault_block? { start_line: integer, end_line: integer, vault_content: string[] }

---@param config table
---@param p PopupParams
function Popup.open(config, p)
    local function select_vault_id(ids, prompt, on_choice)
        -- Ensure the upcoming select UI can capture keys even if user was in insert mode
        pcall(vim.cmd, "stopinsert")
        vim.schedule(function()
            vim.ui.select(ids, { prompt = prompt }, function(choice)
                on_choice(choice)
            end)
        end)
    end

    Core.debug(config, string.format("open popup vault_type=%s name=%s", p.vault_type, p.vault_name))
    -- Split without trimming to preserve genuine empty lines; then drop at most one synthetic trailing empty line
    local popup_lines = vim.split(p.decrypted_value, "\n", { plain = true })
    if #popup_lines > 0 and popup_lines[#popup_lines] == "" then
        table.remove(popup_lines)
    end
    local original_content = p.decrypted_value

    local popup_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, popup_lines)
    vim.api.nvim_buf_set_option(popup_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(popup_buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(popup_buf, "swapfile", false)
    vim.api.nvim_buf_set_option(popup_buf, "filetype", "text")
    vim.api.nvim_buf_set_option(popup_buf, "modifiable", true)
    vim.api.nvim_buf_set_name(popup_buf, "VaultEdit-" .. vim.fn.localtime())

    local ui = (vim.api.nvim_list_uis() or {})[1] or {}
    local editor_cols = ui.width or vim.o.columns
    local editor_lines = ui.height or vim.o.lines

    -- Make the popup large and dynamic relative to the editor size
    -- Calculate width dynamically based on the longest line, with sane bounds
    local content_max_width = 0
    for _, l in ipairs(popup_lines) do
        local w = vim.fn.strdisplaywidth(l)
        if w > content_max_width then
            content_max_width = w
        end
    end
    local max_width = math.floor(editor_cols * 0.9)
    local width = math.min(math.max(60, content_max_width + 4), max_width, editor_cols - 4)
    -- Prefer near-full height: content-based up to almost the full editor height
    local max_height = math.max(10, editor_lines - 4)
    -- Estimate display rows when 'wrap' is enabled by dividing each line's display width by the target width
    local effective_wrap_width = math.max(1, width - 2)
    local display_rows = 0
    for _, l in ipairs(popup_lines) do
        local w = vim.fn.strdisplaywidth(l)
        if w == 0 then
            display_rows = display_rows + 1
        else
            display_rows = display_rows + math.ceil(w / effective_wrap_width)
        end
    end
    local desired_height = display_rows + 2
    local height = math.min(desired_height, max_height)
    local row = math.floor((editor_lines - height) / 2)
    local col = math.floor((editor_cols - width) / 2)

    local popup_win = vim.api.nvim_open_win(popup_buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Edit Vault: " .. p.vault_name .. " ",
        title_pos = "center",
    })

    vim.api.nvim_win_set_option(popup_win, "wrap", true)
    vim.api.nvim_win_set_option(popup_win, "cursorline", true)

    -- Auto-close behavior when focus leaves this popup or another popup takes focus
    local autocmd_group = vim.api.nvim_create_augroup("AnsibleVaultPopup_" .. popup_win, { clear = true })
    vim.api.nvim_create_autocmd("WinEnter", {
        group = autocmd_group,
        callback = function()
            if not vim.api.nvim_win_is_valid(popup_win) then
                return
            end
            local current_win = vim.api.nvim_get_current_win()
            if current_win ~= popup_win then
                if vim.api.nvim_win_is_valid(popup_win) then
                    vim.api.nvim_win_close(popup_win, true)
                end
            end
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = autocmd_group,
        pattern = tostring(popup_win),
        callback = function()
            pcall(vim.api.nvim_del_augroup_by_id, autocmd_group)
        end,
    })

    local function handle_save_and_close()
        local current_lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
        local current_content = table.concat(current_lines, "\n")
        Core.debug(
            config,
            string.format(
                "popup save changed=%s bytes=%d",
                tostring(current_content ~= original_content),
                #current_content
            )
        )

        if current_content ~= original_content then
            local function after_inline_encrypt_and_apply(vault_lines)
                local current_src = vim.api.nvim_buf_get_lines(p.bufnr, 0, -1, false)
                local modified_lines = vim.deepcopy(current_src)

                local original_content_indent = ""
                if #p.vault_block.vault_content > 0 then
                    original_content_indent = p.vault_block.vault_content[1]:match("^(%s*)") or ""
                end

                for j = p.vault_block.end_line, p.vault_block.start_line + 1, -1 do
                    table.remove(modified_lines, j)
                end
                for j = #vault_lines, 1, -1 do
                    table.insert(
                        modified_lines,
                        p.vault_block.start_line + 1,
                        original_content_indent .. vault_lines[j]
                    )
                end

                vim.api.nvim_buf_set_lines(p.bufnr, 0, -1, false, modified_lines)
            end

            if p.vault_type == Core.VaultType.inline and p.vault_block then
                local vault_lines, encrypt_err = Core.encrypt_content(config, current_content)
                if not vault_lines then
                    local ids = Core.extract_encrypt_vault_ids(encrypt_err or "")
                    if ids and #ids > 0 then
                        select_vault_id(ids, "Select vault-id for encryption", function(choice)
                            if not choice then
                                vim.notify("Encryption cancelled (no vault-id selected)", vim.log.levels.WARN)
                                return
                            end
                            local retry_lines, retry_err = Core.encrypt_content(
                                config,
                                current_content,
                                { encrypt_vault_id = choice }
                            )
                            if not retry_lines then
                                vim.notify(
                                    "Failed to encrypt with selected vault-id: " .. (retry_err or "unknown error"),
                                    vim.log.levels.ERROR
                                )
                                return
                            end
                            after_inline_encrypt_and_apply(retry_lines)
                            if vim.api.nvim_win_is_valid(popup_win) then
                                vim.api.nvim_win_close(popup_win, true)
                            end
                        end)
                        return -- wait for async select
                    end
                    vim.notify(
                        "Failed to encrypt new content: " .. (encrypt_err or "unknown error"),
                        vim.log.levels.ERROR
                    )
                    return
                end
                after_inline_encrypt_and_apply(vault_lines)
            else
                local ok, enc_err = Core.encrypt_file_with_content(config, p.file_path, current_content)
                if not ok then
                    local ids = Core.extract_encrypt_vault_ids(enc_err or "")
                    if ids and #ids > 0 then
                        select_vault_id(ids, "Select vault-id for file encryption", function(choice)
                            if not choice then
                                vim.notify("Encryption cancelled (no vault-id selected)", vim.log.levels.WARN)
                                return
                            end
                            local retry_ok, retry_err = Core.encrypt_file_with_content(
                                config,
                                p.file_path,
                                current_content,
                                { encrypt_vault_id = choice }
                            )
                            if not retry_ok then
                                vim.notify(retry_err or "Failed to encrypt file", vim.log.levels.ERROR)
                                return
                            end
                            vim.notify("File encrypted successfully", vim.log.levels.INFO)
                            Core.debug(config, "file encrypted via popup save")
                            if vim.api.nvim_win_is_valid(popup_win) then
                                vim.api.nvim_win_close(popup_win, true)
                            end
                        end)
                        return -- wait for async select
                    end
                    vim.notify(enc_err or "Failed to encrypt file", vim.log.levels.ERROR)
                    return
                end
                vim.notify("File encrypted successfully", vim.log.levels.INFO)
                Core.debug(config, "file encrypted via popup save")
            end
        end

        if vim.api.nvim_win_is_valid(popup_win) then
            vim.api.nvim_win_close(popup_win, true)
        end
    end

    local function close_popup()
        if vim.api.nvim_win_is_valid(popup_win) then
            vim.api.nvim_win_close(popup_win, true)
        end
    end

    local function copy_to_clipboard()
        local current_lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
        vim.fn.setreg("+", table.concat(current_lines, "\n"))
        vim.notify("Copied to clipboard", vim.log.levels.INFO)
        Core.debug(config, "copied popup content to clipboard")
    end

    vim.keymap.set("n", "<Esc>", close_popup, { buffer = popup_buf, nowait = true })
    vim.keymap.set("n", "q", close_popup, { buffer = popup_buf, nowait = true })
    vim.keymap.set("n", "<C-s>", handle_save_and_close, { buffer = popup_buf, nowait = true })
    vim.keymap.set("i", "<C-s>", handle_save_and_close, { buffer = popup_buf, nowait = true })
    vim.keymap.set("n", "<CR>", handle_save_and_close, { buffer = popup_buf, nowait = true })
    vim.keymap.set("n", "y", copy_to_clipboard, { buffer = popup_buf, nowait = true })

    local function show_help()
        local help_lines = {
            "Ansible Vault Popup Keybindings:",
            "",
            "  <C-s> / <Enter> : Save & encrypt, close popup",
            "  <Esc> / q       : Cancel/close popup",
            "  y               : Copy to clipboard",
            "  ?               : Show this help",
            "",
            "Start typing to edit decrypted content.",
        }
        vim.notify(table.concat(help_lines, "\n"), vim.log.levels.INFO)
    end

    vim.keymap.set("n", "?", show_help, { buffer = popup_buf, nowait = true })
end

return Popup
