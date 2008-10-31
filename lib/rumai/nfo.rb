# Project information.

module Rumai
  NFO = {
    :name    => 'Rumai',
    :version => '2.0.0',
    :release => '2008-02-04',
    :website => 'http://rumai.rubyforge.org',
    :home    => File.expand_path(File.join(File.dirname(__FILE__), '..', '..'))
  }

  class << NFO
    # Returns the name and version.
    def to_s
      self[:name] + ' ' + self[:version]
    end

    # throw an exception instead of returning nil
    alias [] fetch
  end
end
