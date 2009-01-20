require 'rubygems'
gem 'inochi', '~> 0'
require 'inochi'

Inochi.init :Rumai,
  :version => '2.0.0',
  :release => '2008-02-04',
  :website => 'http://snk.tuxfamily.org/lib/rumai',
  :tagline => 'Ruby interface to the wmii window manager'

require 'rumai/fs'
require 'rumai/wm'
