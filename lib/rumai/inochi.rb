module Rumai

  ##
  # Official name of this project.
  #
  PROJECT = 'Rumai'

  ##
  # Short single-line description of this project.
  #
  TAGLINE = 'Ruby interface to the wmii window manager'

  ##
  # Address of this project's official home page.
  #
  WEBSITE = 'http://snk.tuxfamily.org/lib/rumai/'

  ##
  # Number of this release of this project.
  #
  VERSION = '4.1.3'

  ##
  # Date of this release of this project.
  #
  RELDATE = '2011-08-21'

  ##
  # Description of this release of this project.
  #
  def self.inspect
    "#{PROJECT} #{VERSION} (#{RELDATE})"
  end

  ##
  # Location of this release of this project.
  #
  INSTDIR = File.expand_path('../../..', __FILE__)

  ##
  # RubyGems required by this project during runtime.
  #
  # @example
  #
  #   GEMDEPS = {
  #     # this project needs exactly version 1.2.3 of the "an_example" gem
  #     'an_example' => [ '1.2.3' ],
  #
  #     # this project needs at least version 1.2 (but not
  #     # version 1.2.4 or newer) of the "another_example" gem
  #     'another_example' => [ '>= 1.2' , '< 1.2.4' ],
  #
  #     # this project needs any version of the "yet_another_example" gem
  #     'yet_another_example' => [],
  #   }
  #
  GEMDEPS = {}

end
