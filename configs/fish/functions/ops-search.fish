function ops-search --description 'Búsqueda universal: archivos (fd) + contenido (rg) via fzf'
    set -l mode (test (count $argv) -gt 0; and echo $argv[1]; or echo files)
    switch $mode
        case files f
            set -l dest (fd --hidden --follow --exclude .git | fzf --preview 'bat --color=always --style=numbers --line-range=:200 {} 2>/dev/null || eza -la {}')
            if test -n "$dest"
                if test -d "$dest"
                    cd "$dest"
                else
                    $EDITOR "$dest"
                end
            end
        case content c rg
            set -l q (test (count $argv) -gt 1; and echo $argv[2]; or echo '')
            set -l hit (rg --line-number --no-heading --color=always "$q" | fzf --ansi --delimiter : --preview 'bat --color=always {1} --highlight-line {2}' --preview-window 'up,60%,border-bottom,+{2}+3/3')
            if test -n "$hit"
                set -l file (echo $hit | cut -d: -f1)
                set -l line (echo $hit | cut -d: -f2)
                $EDITOR "+$line" "$file"
            end
        case dirs d
            set -l dest (fd --type d --hidden --follow --exclude .git | fzf)
            and cd "$dest"
        case '*'
            echo "uso: ops-search [files|content|dirs]"
    end
end
