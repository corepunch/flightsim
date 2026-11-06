#!/bin/zsh
# Use Homebrew's Ruby and bundled gems without changing the system Ruby.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v brew >/dev/null 2>&1; then
    ruby_prefix=$(brew --prefix ruby)
    fastlane_prefix=$(brew --prefix fastlane)
    export PATH="$ruby_prefix/bin:$PATH"
    export GEM_PATH="$fastlane_prefix/libexec:$(ruby -e 'puts Gem.path.join(File::PATH_SEPARATOR)')"
fi

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export FASTLANE_SKIP_UPDATE_CHECK=1
export FASTLANE_OPT_OUT_USAGE=1
export FASTLANE_SKIP_DOCS=1
export BUNDLE_GEMFILE="$PWD/Gemfile"
exec bundle exec fastlane "$@"
