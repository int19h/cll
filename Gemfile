source "https://rubygems.org"

# The book builds with Ruby 3.2 (Ubuntu 24.04 and the checks workflow).
# Nokogiri 1.18.8 requires Ruby 3.1 or newer. Bundler 4 requires Ruby 3.2.
ruby '>= 3.2'

# These exact versions are the ones the Dockerfiles and the Pages workflow install.
# Those installs call `gem install` directly. They do not run Bundler.
gem 'optimist', '= 3.2.0'
gem 'nokogiri', '= 1.18.8'
gem 'htmlentities', '= 4.3.4'
