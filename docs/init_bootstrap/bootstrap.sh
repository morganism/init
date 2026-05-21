#!/usr/bin/env bash
: <<DOCXX
Add description
Author: morgan@morganism.dev
Date: Thu 16 Apr 2026 18:19:36 BST
DOCXX

set -euo pipefail

# 1. clone dotfiles
git clone https://github.com/morganism/dotfiles ~/.dotfiles

# 2. symlink configs
~/.dotfiles/install.sh

# 3. install ruby tooling
gem install mksfx memvault   # etc

# 4. pull down further assets if needed
# mksfx extract bootstrap.run
