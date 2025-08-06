" ansible-vault.vim - Neovim plugin for Ansible Vault files
" Maintainer: Auto-generated
" Version: 1.0

if exists('g:loaded_ansible_vault')
  finish
endif
let g:loaded_ansible_vault = 1

" Define commands
command! AnsibleVaultAccess lua require('ansible-vault').vault_access()

" Setup function to be called by user
command! -nargs=? AnsibleVaultSetup lua require('ansible-vault').setup(<args>)

" Default keymaps (can be overridden by user)
if !exists('g:ansible_vault_no_default_mappings')
  nnoremap <leader>va :AnsibleVaultAccess<CR>
endif
