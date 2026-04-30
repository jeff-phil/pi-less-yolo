FROM cgr.dev/chainguard/node:latest-dev
#FROM cgr.dev/chainguard/node:latest-dev@sha256:af34bc7d6af4365c480fe99098222eeea7d989a814681a67cf5f993de8a9dde5

# openssh-client: ssh binary for git-over-SSH (PI_SSH_AGENT=1) and ssh-add.
USER root

RUN --mount=type=bind,source=xterm-ghostty.terminfo,target=/tmp/xterm-ghostty.terminfo <<'EOF'
tic -x /tmp/xterm-ghostty.terminfo
EOF

RUN apk update && \
    apk add --no-cache \
        curl \
        ca-certificates \
        zsh \
        git \
        openssh-client \
        tmux \
        tailscale \
        go \
        libffi-dev \
        sqlite sqlite-libs py3-sqlite-utils \
        jq \
        file \
        fd \
        util-linux-misc \
        playwright \
        chromium \
        htop \
        tree \
        rust \
        typescript \
        bun \
        gh \
        snyk-cli \
        delta \
        less \
        ripgrep \
        vim \
        emacs \
        && rm -rf /var/cache/apk/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
        && mv /root/.local/bin/uv /usr/local/bin/uv \
        && mv /root/.local/bin/uvx /usr/local/bin/uvx \
        && chmod +x /usr/local/bin/uv /usr/local/bin/uvx

ENV UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python

# Install Python via uv and expose it on PATH, with tools
RUN uv python install 3.14.4 \
      && ln -s "$(uv python find 3.14.4)" /usr/local/bin/python3

# Prepend extension binaries (host-mounted via /pi-agent). Security: binaries
# here can shadow any command; no privilege escalation (--cap-drop=ALL,
# --no-new-privileges), but review ~/.pi/agent/npm-global/bin/ after installs.
ENV PATH="/pi-agent/npm-global/bin:${PATH}"

ENV HOME=/home/piuser

# /home/piuser: world-writable (1777) so any runtime UID can write here.
# /home/piuser/.ssh: root-owned 755; SSH accepts it and the runtime user can
#   read mounts inside it (700 would block a non-matching UID).
# /etc/passwd: world-writable so the entrypoint can add the runtime UID.
#   SSH calls getpwuid(3) and hard-fails without a passwd entry. Safe here
#   because --cap-drop=ALL and --no-new-privileges block privilege escalation.
RUN mkdir -p /home/piuser /home/piuser/.ssh \
             /home/piuser/.pi \
    && ln -s /pi-agent /home/piuser/.pi/agent \
    && ln -s /pi-agent/agent-skills-global /home/piuser/.agents \
    && chmod 1777 /home/piuser \
    && chmod 755 /home/piuser/.ssh \
    && chmod a+w /etc/passwd \
    && touch /home/piuser/.ssh/known_hosts \
    && chmod 666 /home/piuser/.ssh/known_hosts 

# .npmrc sets prefix=/pi-agent/npm-global so extensions persist across restarts,
# and legacy-peer-deps=true in so that every pi package doesn't (re-)install
# pi-coding-agent due to peerDependencies.
RUN cat > /home/piuser/.npmrc << 'EOF'
prefix=/pi-agent/npm-global
legacy-peer-deps=true
EOF

RUN << 'EOF'
cat > /home/piuser/.zshrc << 'ZSHRC'
alias ls="ls -Ah --color"
alias vi="vim"
alias less="/usr/share/vim/vim92/macros/less.sh"
alias lessx="/usr/share/vim/vim92/macros/less.sh"

export EDITOR=vim
export VISUAL=emacs

export PATH=$PATH:/home/piuser/go/bin:/home/piuser/.local/bin:

# Enable vi mode
bindkey -v

autoload -Uz colors
colors
setopt prompt_subst

function zle-keymap-select {
  if [[ $KEYMAP == vicmd ]]; then
    MODE="%{$fg[red]%}N%{$reset_color%}"
  else
    MODE="%{$fg[green]%}I%{$reset_color%}"
  fi
  zle reset-prompt
}
zle -N zle-keymap-select

function zle-line-init {
  MODE="%{$fg[green]%}I%{$reset_color%}"
}
zle -N zle-line-init

PROMPT='[%{$fg[cyan]%}${MODE}%{$reset_color%}] %~ %# '

if [ -f "$PI_CODING_AGENT_DIR/.env" ]; then
  . "$PI_CODING_AGENT_DIR/.env"
fi

ZSHRC

cat > /home/piuser/.vimrc << 'VIMRC'
let mapleader=","
nnoremap <leader>a :echo("\<leader\> works! It is set to <leader>")<CR>
syntax on
set mouse=v
nnoremap <C-g> :Ag<Cr>
VIMRC

EOF

COPY tmux.conf /home/piuser/.tmux.conf

# Install some tmux and agent tools, fix perms
ENV GOPATH=/home/piuser/go
ENV PATH=$PATH:/home/piuser/go/bin
RUN << 'EOF'
go install github.com/tmuxpack/tpack/cmd/tpack@latest
go install github.com/ericchiang/pup@latest
tmux new-session -d && tmux -v run 'tpack install' && rm -rf /tmp/tmux-0 2>/dev/null
uv tool install ruff
uv tool install ty
uv tool install skills-ref
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
cargo install htmlq ekphos
mv /home/piuser/.cargo/bin/* /usr/local/bin
rm -rf /home/piuser/.cache /home/piuser/go/pkg /home/piuser/.cargo
npm install playwright && npx playwright install chromium --only-shell
find . -name '.git' -type d -prune -exec rm -rf {} \;
chown -R 501 /home/piuser
rm -rf /root
mkdir /root
EOF

# Register the runtime UID in /etc/passwd before starting pi.
# SSH calls getpwuid(3) and hard-fails without an entry; nss_wrapper is
# unavailable in Wolfi so we append directly.
RUN <<'EOF'
cat > /usr/local/bin/entrypoint.sh << 'ENTRYPOINT'
#!/bin/sh
set -e

if ! grep -q "^[^:]*:[^:]*:$(id -u):" /etc/passwd; then
    printf 'piuser:x:%d:%d:piuser:%s:/bin/zsh\n' \
        "$(id -u)" "$(id -g)" "${HOME}" >> /etc/passwd
fi

# Install this first time to /pi-agent if not there, that allows for upgrading
# without rebuilding the container, since will be in users mounted ~/.pi dir
if ! [ `which pi` ]; then
    echo "Please wait while Pi is installed to your host ~/.pi/agent/bin directory..."
    npm install -g @mariozechner/pi-coding-agent
fi

# Pass through to a shell when invoked via `pi:shell`; otherwise run pi.
case "${1:-}" in
    tmux|zsh|bash|sh) exec "$@" ;;
    *) exec pi "$@" ;;
esac
ENTRYPOINT
chmod +x /usr/local/bin/entrypoint.sh
EOF

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
