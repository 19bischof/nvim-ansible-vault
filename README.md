# nvim-ansible-vault

A Neovim plugin for editing Ansible Vault — supports inline YAML values and whole-file vaults.

## Installation (Lazy.nvim)

```lua
{
  "19bischof/nvim-ansible-vault",
  config = function()
    require("ansible-vault").setup({
      -- Omit ansible_cfg_directory to auto-detect nearest ansible.cfg (or .ansible.cfg)
      -- ansible_cfg_directory = "/path/to/ansible",        -- optionally set explicitly
      vault_password_file = "/path/to/your/.vaultpass",     -- optional if ansible_cfg_directory resolves vault-ids
      vault_executable = "/absolute/path/to/ansible-vault", -- optional, defaults to "ansible-vault"
    })
  end,
}
```

## Usage

### Default keybindings
| Key | Action |
|-----|--------|
| `<leader>va` | Open inline/file vault in a secure popup (auto-detect at cursor) |
| `<leader>vE` | Encrypt the entire current file |
| `<leader>ve` | Encrypt YAML scalar at cursor into inline `!vault |-` |

These are provided by default. To disable the defaults, set `vim.g.ansible_vault_no_default_mappings = 1` before the plugin loads (see below).

### Commands
- `:AnsibleVaultAccess` — open inline/file vault at cursor in a popup
- `:AnsibleVaultEncryptFile` — encrypt the current file in-place
- `:AnsibleVaultEncryptInline` — encrypt the YAML scalar at cursor into inline vault

### How it works
1. Place the cursor on the vault header (e.g. `password: !vault |`) or anywhere inside the vault block, then press `<leader>va`.
2. The plugin decrypts via `ansible-vault view` and opens an editable popup.
3. On save (`<C-s>` / `<CR>`), content is re‑encrypted using `ansible-vault encrypt_string` and written back.

### Popup controls
| Action                | Key(s)                |
|-----------------------|-----------------------|
| Save & encrypt        | `<C-s>` or `<CR>`     |
| Cancel / close        | `<Esc>` or `q`        |
| Copy to clipboard     | `y`                   |
| Show help             | `?`                   |

## Configuration

```lua
require("ansible-vault").setup({
  -- Omit ansible_cfg_directory to auto-detect nearest ansible.cfg (or .ansible.cfg)
  -- ansible_cfg_directory = "/path/to/ansible",       -- optionally set explicitly
  vault_password_file = "/path/to/ansible/.vaultpass", -- only needed if you have a single password and no ansible.cfg
  vault_executable = "ansible-vault",                  -- optional absolute path; defaults to this name
  debug = false,                                       -- debug notifications (metadata only)
})
```

Notes:
- If `ansible_cfg_directory` is omitted, the plugin will automatically search upward from the current file to find `ansible.cfg` or `.ansible.cfg` and use that directory for commands. This enables multiple vault-ids without hardcoding a password file.
  - `vault_identity_list` (preferred for multiple vault-ids)
  - or `vault_password_file`

Example `ansible.cfg`:

```ini
[defaults]
vault_identity_list = default@~/.ansible/.vault_pass.txt,prod@~/.ansible/.vault_pass_prod.txt
# or, for a single password file
# vault_password_file = ~/.ansible/.vault_pass.txt
```

### Disabling default keymaps
Add this before the plugin loads, then set your own mappings:

```lua
vim.g.ansible_vault_no_default_mappings = 1
vim.keymap.set("n", "<leader>va", "<Cmd>AnsibleVaultAccess<CR>", { desc = "Ansible Vault: access at cursor" })
vim.keymap.set("n", "<leader>vE", "<Cmd>AnsibleVaultEncryptFile<CR>", { desc = "Ansible Vault: encrypt file" })
vim.keymap.set("n", "<leader>ve", "<Cmd>AnsibleVaultEncryptInline<CR>", { desc = "Ansible Vault: encrypt inline" })
```


That's it! 🔐
