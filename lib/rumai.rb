require 'rubygems'
gem 'inochi', '~> 0'
require 'inochi'

Inochi.init :Rumai,
  :version => '2.0.2',
  :release => '2009-02-26',
  :website => 'http://snk.tuxfamily.org/lib/rumai',
  :tagline => 'Ruby interface to the wmii window manager'

require 'rumai/fs'
require 'rumai/wm'
