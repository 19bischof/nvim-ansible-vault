# nvim-ansible-vault

A Neovim plugin for editing Ansible Vault encrypted values inline within YAML files.

## Installation

### LazyVim / Lazy.nvim

```lua
{
  "19bischof/nvim-ansible-vault",
  config = function()
    require("ansible-vault").setup({
      vault_password_file = "/path/to/your/.vaultpass",
      vault_executable = "/path/to/ansible-vault"
    })
  end,
}
```

## Usage

### Keybinding
- `<leader>va` - Vault Access (decrypt, edit, encrypt)

### How it works
1. Place cursor on a vault header line (e.g., `password: !vault |`) or within vault content
2. Press `<leader>va` to open popup with decrypted content
**Popup Controls:**

| Action                | Key(s)                |
|-----------------------|-----------------------|
| Edit content          | *(Start typing)*      |
| Save & encrypt        | `Ctrl+S` or `Enter`   |
| Cancel/close popup    | `Esc` or `q`          |
| Copy to clipboard     | `y`                   |

## Configuration

```lua
require("ansible-vault").setup({
  vault_password_file = "/path/to/your/.vaultpass",
  vault_executable = "ansible-vault"
})
```

That's it! 🔐