#!/bin/bash

set -euo pipefail

# Print text in bold
bold() {
  echo -e "\033[1m$1\033[22m"
}

# Print text in red
red() {
  echo -e "\033[31m$1\033[0m"
}
