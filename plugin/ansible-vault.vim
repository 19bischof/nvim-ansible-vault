" ansible-vault.vim - Neovim plugin for Ansible Vault files
" Maintainer: Auto-generated
" Version: 1.0

if exists('g:loaded_ansible_vault')
  finish
endif
let g:loaded_ansible_vault = 1

" Define commands
command! AnsibleVaultAccess lua require('ansible-vault').vault_access()
command! AnsibleVaultEncryptFile lua require('ansible-vault').encrypt_current_file()

" Default keymaps (can be overridden by user)
if !exists('g:ansible_vault_no_default_mappings')
  nnoremap <silent> <leader>va <Cmd>AnsibleVaultAccess<CR>
  nnoremap <silent> <leader>ve <Cmd>AnsibleVaultEncryptFile<CR>
endif
