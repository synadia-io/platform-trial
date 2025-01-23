#!/usr/bin/env bash

set -euo pipefail

# Print text in bold
bold() {
  echo -e "\033[1m$1\033[22m"
}

# Print text in red
red() {
  echo -e "\033[31m$1\033[0m"
}

# Print a clickable link with display text
link() {
  link="$1"
  text="${2-$link}"
  printf "\e]8;;%s\a%s\e]8;;\a" "$link" "$text"
}
