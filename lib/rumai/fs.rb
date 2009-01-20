# File system abstractions over the 9P2000 protocol.

require 'rumai/ixp'
require 'socket'

module Rumai
  begin
    addr = ENV['WMII_ADDRESS'].to_s.sub(/.*!/, '')
    sock = UNIXSocket.new(addr)

    # We use a single, global connection to wmii's IXP server.
    AGENT = IXP::Agent.new(sock)

  rescue
    $!.message << %{
      Ensure that (1) the WMII_ADDRESS environment variable is set and that (2)
      it correctly specifies the filesystem path of wmii's IXP socket file,
      which is typically located at "/tmp/ns.$USER.:$DISPLAY/wmii".
    }.gsub(/^ +/, '').gsub(/\A|\z/, "\n")

    raise
  end

  # An entry in the IXP file system.
  class Node
    @@cache = Hash.new {|h,k| h[k] = Node.new(k) }

    attr_reader :path

    def initialize aPath
      @path = aPath.to_s.squeeze('/')
    end

    # Returns file statistics about this node.
    # See Rumai::IXP::Client#stat for details.
    def stat
      AGENT.stat @path
    end

    # Tests if this node exists on the IXP server.
    def exist?
      begin
        true if stat
      rescue IXP::Error
        false
      end
    end

    # Tests if this node is a directory.
    def directory?
      exist? and stat.directory?
    end

    # Returns the names of all files in this directory.
    def entries
      AGENT.entries @path rescue []
    end

    # Opens this node for I/O access.
    # See Rumai::IXP::Client#open for details.
    def open aMode = 'r', &aBlock
      AGENT.open @path, aMode, &aBlock
    end

    # Returns the entire content of this node.
    # See Rumai::IXP::Client#read for details.
    def read *aArgs
      AGENT.read @path, *aArgs
    end

    # Invokes the given block for every line in the content of this node.
    def each_line &aBlock #:yields: line
      open do |file|
        until (chunk = file.read(true)).empty?
          chunk.each_line(&aBlock)
        end
      end
    end

    # Writes the given content to this node.
    def write aContent
      AGENT.write @path, aContent
    end

    # Creates a file corresponding to this node on the IXP server.
    # See Rumai::IXP::Client#create for details.
    def create *aArgs
      AGENT.create @path, *aArgs
    end

    # Deletes the file corresponding to this node on the IXP server.
    def remove
      AGENT.remove @path
    end

    # Returns the given sub-path as a Node object.
    def [] aSubPath
      @@cache[ File.join(@path, aSubPath.to_s) ]
    end

    # Returns the parent node of this node.
    def parent
      @@cache[ File.dirname(@path) ]
    end

    # Returns all child nodes of this node.
    def children
      entries.map! {|c| self[c] }
    end

    include Enumerable
      # Iterates through each child of this directory.
      def each &aBlock
        children.each(&aBlock)
      end

    # Deletes all child nodes.
    def clear
      children.each do |c|
        c.remove
      end
    end

    # Provides access to child nodes through method calls.
    #
    # :call-seq: node.child -> Node
    #
    def method_missing aMeth, *aArgs
      child = self[aMeth]

      # speed up future accesses
      (class << self; self; end).instance_eval do
        define_method aMeth do
          child
        end
      end

      child
    end
  end

  # Makes instance methods accessible through class
  # methods. This is done to emulate the File class:
  #
  #   File.exist? "foo"
  #   File.new("foo").exist?
  #
  # Both of the above expressions are equivalent.
  #
  module ExportInstMethods
    def self.extended aTarget #:nodoc:
      aTarget.instance_methods(false).each do |meth|
        (class << aTarget; self; end).instance_eval do
          define_method meth do |path, *args|
            new(path).__send__(meth, *args)
          end
        end
      end
    end
  end

  # We use extend() AFTER all methods have been defined in the class so
  # that the Externalize* module can do its magic.  If we include()d
  # the module instead before all methods in the class have been
  # defined, then the magic would only apply to SOME of the methods!
  Node.extend ExportInstMethods
end
