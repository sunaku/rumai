#--
# Copyright 2008 Suraj N. Kurapati
# See the LICENSE file for details.
#++

require 'rubygems'
gem 'inochi', '~> 1'
require 'inochi'

Inochi.init :Rumai,
  :version => '2.1.0',
  :release => '2009-05-09',
  :website => 'http://snk.tuxfamily.org/lib/rumai/',
  :tagline => 'Ruby interface to the wmii window manager',
  :develop => {
    :dfect => nil, # for unit testing
  }

require 'rumai/fs'
require 'rumai/wm'
