#--
# Copyright protects this work.
# See LICENSE file for details.
#++

require 'rubygems'
gem 'inochi', '~> 1'
require 'inochi'

Inochi.init :Rumai,
  :version => '3.1.1',
  :release => '2009-11-16',
  :website => 'http://snk.tuxfamily.org/lib/rumai/',
  :tagline => 'Ruby interface to the wmii window manager',
  :develop => {
    :dfect => nil, # for unit testing
  }

require 'rumai/fs'
require 'rumai/wm'
