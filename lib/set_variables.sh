#!/usr/bin/env bash
: <<DOCXX
Add description
Author: morgan@morganism.dev
Date: Sat 18 Apr 2026 17:20:40 BST
DOCXX

THIS=$(realpath $BASH_SOURCE)
THIS_FILE=$(basename $THIS)
THIS_DIR=$(dirname $THIS)

OS="linux" # default to this
[[ "$(/usr/bin/uname -o)" =~ Darwin ]] && OS="macos"

OS_DIR="${THIS_DIR}/lib/${OS}"


echo "Hello world."
