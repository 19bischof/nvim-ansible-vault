# ansible-vault

A Neovim plugin for seamlessly working with Ansible Vault encrypted files. This plugin automatically detects vault-encrypted content in YAML files and provides commands to decrypt/encrypt them directly within Neovim.

## Features

- **Auto-detection**: Automatically detects Ansible vault content in YAML files
- **Inline vault support**: Handles individual encrypted values within YAML files (e.g., `key: !vault |`)
- **Full file vault support**: Also supports entirely encrypted vault files
- **Auto-decrypt**: Automatically decrypts vault files when opened (configurable)
- **Auto-encrypt**: Automatically encrypts vault files when saved (configurable)
- **Manual commands**: Provides commands for manual vault operations
- **Flexible configuration**: Supports vault password files and vault IDs
- **Buffer tracking**: Keeps track of which buffers contain vault content

## Requirements

- Neovim 0.7+
- `ansible-vault` command available in PATH
- Ansible vault password configured (via password file or interactive prompt)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
      "path/to/ansible-vault",
  config = function()
    require("ansible-vault").setup({
      vault_password_file = "~/.ansible/vault_pass", -- optional
      auto_decrypt = true,
      auto_encrypt = true,
      vault_id = nil, -- optional: specify vault ID
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
      "path/to/ansible-vault",
  config = function()
    require("ansible-vault").setup()
  end
}
```

### Manual Installation

1. Clone this repository to your Neovim configuration directory:
   ```bash
   git clone <repository-url> ~/.config/nvim/pack/plugins/start/ansible-vault
   ```

2. Add the setup call to your `init.lua`:
   ```lua
   require("ansible-vault").setup()
   ```

## Configuration

The plugin can be configured by passing options to the `setup()` function:

```lua
require("ansible-vault").setup({
  vault_password_file = "~/.ansible/vault_pass", -- Path to vault password file
  auto_decrypt = true,                           -- Auto-decrypt on file open
  auto_encrypt = true,                           -- Auto-encrypt on file save
  vault_id = nil,                               -- Vault ID (optional)
  vault_executable = "ansible-vault",           -- Path to ansible-vault executable
})
```

### Configuration Options

- `vault_password_file` (string, optional): Path to the Ansible vault password file
- `auto_decrypt` (boolean, default: true): Automatically decrypt vault content when opening files
- `auto_encrypt` (boolean, default: true): Automatically encrypt vault content when saving files
- `vault_id` (string, optional): Specify a vault ID for multi-vault setups (required when using multiple vault IDs)
- `vault_executable` (string, default: "ansible-vault"): Path to the ansible-vault executable

**Note on vault_id**: When `vault_id` is specified, the plugin uses `--encrypt-vault-id` for encryption operations and `--vault-id` for decryption operations, which resolves the "Specify the vault-id to encrypt with --encrypt-vault-id" error.

## Usage

### Automatic Operation

When `auto_decrypt` and `auto_encrypt` are enabled (default), the plugin will:

1. **On file open**: Detect vault content and automatically decrypt it
2. **On file save**: Automatically encrypt the content back to vault format

### Manual Commands

The plugin provides several commands for manual operation:

- `:AnsibleVaultDecrypt` - Decrypt the current buffer
- `:AnsibleVaultEncrypt` - Encrypt the current buffer
- `:AnsibleVaultToggle` - Toggle between encrypted and decrypted state

### Default Keymaps

The plugin sets up default keymaps (can be disabled with `g:ansible_vault_no_default_mappings = 1`):

- `<leader>vd` - Decrypt current buffer
- `<leader>ve` - Encrypt current buffer
- `<leader>vt` - Toggle vault state

### Custom Keymaps

You can set up your own keymaps:

```lua
vim.keymap.set('n', '<leader>ad', ':AnsibleVaultDecrypt<CR>', { desc = 'Decrypt Ansible vault' })
vim.keymap.set('n', '<leader>ae', ':AnsibleVaultEncrypt<CR>', { desc = 'Encrypt Ansible vault' })
vim.keymap.set('n', '<leader>at', ':AnsibleVaultToggle<CR>', { desc = 'Toggle Ansible vault' })
```

## Usage Examples

### Working with Inline Vaults

1. **Opening a file with inline vaults:**
   ```yaml
   # File: secrets.yml
   database_host: localhost
   database_password: !vault |
       $ANSIBLE_VAULT;1.1;AES256
       66386439653161663...
   ```

   When you open this file, the plugin automatically detects and decrypts the vault values:
   ```yaml
   # Decrypted view in Neovim
   database_host: localhost
   database_password: "my_secret_password"
   ```

2. **Editing and saving:**
   - Edit the decrypted values as normal text
   - When you save (`:w`), the plugin automatically re-encrypts the values back to vault format

3. **Manual operations:**
   - `:AnsibleVaultDecrypt` - Decrypt all vault values in the current buffer
   - `:AnsibleVaultEncrypt` - Encrypt all quoted string values in the current buffer
   - `:AnsibleVaultToggle` - Toggle between encrypted and decrypted state

### Working with Full File Vaults

For entirely encrypted files, the plugin works as before:
- Opens and decrypts the entire file content
- Saves and encrypts the entire file content

## How It Works

The plugin supports two types of Ansible vault content:

### Inline Vaults (Recommended)

Individual encrypted values within YAML files:

```yaml
database_host: localhost
database_password: !vault |
    $ANSIBLE_VAULT;1.1;AES256
    66386439653...
    (encrypted content)
api_key: !vault |
    $ANSIBLE_VAULT;1.1;AES256
    38316538623...
    (encrypted content)
debug_mode: true
```

**How inline vaults work:**

1. **Detection**: The plugin scans for `key: !vault |` patterns followed by indented encrypted content
2. **Decryption**: Each vault block is extracted and decrypted individually using `ansible-vault decrypt`
3. **Display**: Vault blocks are replaced with `key: "decrypted_value"` format for editing
4. **Encryption**: When saving, quoted values are re-encrypted using `ansible-vault encrypt_string`

### Full File Vaults (Legacy Support)

Entirely encrypted YAML files:

1. **Detection**: The plugin scans YAML files for vault content patterns:
   - Lines containing `!vault |`
   - Lines containing `$ANSIBLE_VAULT;`

2. **Decryption**: When vault content is detected:
   - Creates a temporary file with the encrypted content
   - Runs `ansible-vault decrypt` on the temporary file
   - Replaces buffer content with decrypted text
   - Marks the buffer as containing vault content

3. **Encryption**: When saving vault buffers:
   - Creates a temporary file with the current buffer content
   - Runs `ansible-vault encrypt` on the temporary file
   - Replaces buffer content with encrypted text

## Vault Password Setup

The plugin uses the standard `ansible-vault` command, so you need to configure your vault password using one of these methods:

### Method 1: Password File
```lua
require("ansible-vault").setup({
  vault_password_file = "~/.ansible/vault_pass"
})
```

### Method 2: Environment Variable
```bash
export ANSIBLE_VAULT_PASSWORD_FILE=~/.ansible/vault_pass
```

### Method 3: Interactive Prompt
If no password file is configured, `ansible-vault` will prompt for the password interactively.

## Troubleshooting

### Common Issues

1. **"ansible-vault command not found"**
   - Ensure Ansible is installed and `ansible-vault` is in your PATH

2. **"Failed to decrypt vault file"**
   - Check that your vault password is correct
   - Verify the vault password file path
   - Ensure the file contains valid vault content

3. **Plugin not loading**
   - Verify the plugin is installed correctly
   - Check that you've called `require("ansible-vault").setup()`

### Debug Mode

You can enable debug notifications by checking the Neovim messages:
```vim
:messages
```

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

MIT License - see LICENSE file for details.
