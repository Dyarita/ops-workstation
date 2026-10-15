function yy --description 'yazi con cd al salir'
    set -l tmp (mktemp -t yazi-cwd.XXXXXX)
    yazi $argv --cwd-file="$tmp"
    if set -l cwd (command cat -- "$tmp"); and test -n "$cwd"; and test -d "$cwd"
        cd -- "$cwd"
    end
    rm -f -- "$tmp"
end
