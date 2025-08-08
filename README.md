# nvim-ansible-vault

A Neovim plugin for editing Ansible Vault — supports inline YAML values and whole-file vaults.

## Installation

## Installation (Lazy.nvim)

```lua
{
  "19bischof/nvim-ansible-vault",
  config = function()
    require("ansible-vault").setup({
      vault_password_file = "/path/to/your/.vaultpass", -- required
      vault_executable = "/absolute/path/to/ansible-vault", -- optional, defaults to "ansible-vault"
      -- encrypt_vault_id and debug can also be set here (see below)
    })
  end,
}
```

## Usage

### Default keybindings
| Key | Action |
|-----|--------|
| `<leader>va` | Open inline/file vault in a secure popup (auto-detect at cursor) |
| `<leader>ve` | Encrypt the entire current file with `ansible-vault` |

These are provided by default. To disable the defaults, set `vim.g.ansible_vault_no_default_mappings = 1` before the plugin loads (see below).

### Commands
- `:AnsibleVaultAccess` — open inline/file vault at cursor in a popup
- `:AnsibleVaultEncryptFile` — encrypt the current file in-place

### How it works
1. Place the cursor on the vault header (e.g. `password: !vault |`) or anywhere inside the vault block, then press `<leader>va`.
2. The plugin decrypts via `ansible-vault view` and opens an editable popup.
3. On save (`<C-s>` / `<CR>`), content is re‑encrypted using `ansible-vault encrypt_string` and written back, preserving indentation for inline values.

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
  vault_password_file = "/path/to/your/.vaultpass", -- required for all operations
  vault_executable = "ansible-vault",               -- optional absolute path; defaults to this name
  encrypt_vault_id = "default",                      -- string vault id stamped into headers (used with encrypt_string)
  debug = false,                                      -- debug notifications (metadata only)
})
```

Notes:
- This plugin runs `ansible-vault` non‑interactively, so a working `vault_password_file` is required.

### Disabling default keymaps
Add this before the plugin loads, then set your own mappings:

```lua
vim.g.ansible_vault_no_default_mappings = 1
vim.keymap.set("n", "<leader>va", "<Cmd>AnsibleVaultAccess<CR>", { desc = "Ansible Vault: access at cursor" })
vim.keymap.set("n", "<leader>ve", "<Cmd>AnsibleVaultEncryptFile<CR>", { desc = "Ansible Vault: encrypt file" })
```


That's it! 🔐