# Ops Workstation — Fish entrypoint
set -g fish_greeting

# Local bins (mise, cargo, ops)
fish_add_path -g $HOME/.local/bin
fish_add_path -g $HOME/.cargo/bin
if test -d $HOME/.atuin/bin
    fish_add_path -g $HOME/.atuin/bin
end

# Core integrations loaded from conf.d/
# Aliases / abbreviations
abbr -a -g g git
abbr -a -g lg lazygit
abbr -a -g j just
abbr -a -g v nvim
abbr -a -g c clear

# Modern replacements
if type -q eza
    abbr -a -g ls 'eza --group-directories-first --icons=auto'
    abbr -a -g ll 'eza -l --group-directories-first --icons=auto --git'
    abbr -a -g la 'eza -la --group-directories-first --icons=auto --git'
    abbr -a -g tree 'eza --tree --level=2 --icons=auto'
end

if type -q bat
    abbr -a -g cat bat
    set -gx BAT_THEME 'ansi'
    set -gx MANPAGER "sh -c 'col -bx | bat -l man -p'"
end

if type -q rg; and not set -q RIPGREP_CONFIG_PATH
    set -gx RIPGREP_CONFIG_PATH $HOME/.config/ripgreprc
end

# Editor — whichever exists on this machine
if not set -q EDITOR
    if type -q nvim
        set -gx EDITOR nvim
    else if type -q vim
        set -gx EDITOR vim
    else
        set -gx EDITOR nano
    end
end
set -gx VISUAL $EDITOR

# Quiet fzf defaults — universal search feel
set -gx FZF_DEFAULT_COMMAND 'fd --type f --hidden --follow --exclude .git'
set -gx FZF_CTRL_T_COMMAND $FZF_DEFAULT_COMMAND
set -gx FZF_ALT_C_COMMAND 'fd --type d --hidden --follow --exclude .git'
set -gx FZF_DEFAULT_OPTS '--height 40% --layout=reverse --border --info=inline'
