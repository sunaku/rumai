# File system abstractions over the 9P2000 protocol.
#--
# Copyright protects this work.
# See LICENSE file for details.
#++

require 'rumai/ixp'
require 'socket'

module Rumai
  # address of the IXP server socket on this machine
  display = ENV['DISPLAY'] || ':0.0'

  IXP_SOCK_ADDR = ENV['WMII_ADDRESS'].sub(/.*!/, '') rescue
    "/tmp/ns.#{ENV['USER']}.#{display[/:\d+/]}/wmii"

  begin
    # We use a single, global connection to wmii's IXP server.
    IXP_AGENT = IXP::Agent.new UNIXSocket.new(IXP_SOCK_ADDR)

  rescue => error
    error.message << %{
      Ensure that (1) the WMII_ADDRESS environment variable is set and that (2)
      it correctly specifies the filesystem path of wmii's IXP socket file,
      which is typically located at "/tmp/ns.$USER.:$DISPLAY/wmii".
    }.gsub(/^ +/, '').gsub(/\A|\z/, "\n")

    raise error
  end

  ##
  # An entry in the IXP file system.
  #
  class Node
    @@cache = Hash.new {|h,k| h[k] = Node.new(k) }

    attr_reader :path

    def initialize path
      @path = path.to_s.squeeze('/')
    end

    ##
    # Returns file statistics about this node.
    #
    # See Rumai::IXP::Client#stat for details.
    #
    def stat
      IXP_AGENT.stat @path
    end

    ##
    # Tests if this node exists on the IXP server.
    #
    def exist?
      begin
        true if stat
      rescue IXP::Error
        false
      end
    end

    ##
    # Tests if this node is a directory.
    #
    def directory?
      exist? and stat.directory?
    end

    ##
    # Returns the names of all files in this directory.
    #
    def entries
      IXP_AGENT.entries @path rescue []
    end

    ##
    # Opens this node for I/O access.
    #
    # See Rumai::IXP::Client#open for details.
    #
    def open mode = 'r', &block
      IXP_AGENT.open @path, mode, &block
    end

    ##
    # Returns the entire content of this node.
    #
    # See Rumai::IXP::Client#read for details.
    #
    def read *args
      IXP_AGENT.read @path, *args
    end

    ##
    # Invokes the given block for every line in the content of this node.
    #
    def each_line &block #:yields: line
      open do |file|
        until (chunk = file.read(true)).empty?
          chunk.each_line(&block)
        end
      end
    end

    ##
    # Writes the given content to this node.
    #
    def write content
      IXP_AGENT.write @path, content
    end

    ##
    # Creates a file corresponding to this node on the IXP server.
    #
    # See Rumai::IXP::Client#create for details.
    #
    def create *args
      IXP_AGENT.create @path, *args
    end

    ##
    # Deletes the file corresponding to this node on the IXP server.
    #
    def remove
      IXP_AGENT.remove @path
    end

    ##
    # Returns the given sub-path as a Node object.
    #
    def [] sub_path
      @@cache[ File.join(@path, sub_path.to_s) ]
    end

    ##
    # Returns the parent node of this node.
    #
    def parent
      @@cache[ File.dirname(@path) ]
    end

    ##
    # Returns all child nodes of this node.
    #
    def children
      entries.map! {|c| self[c] }
    end

    include Enumerable

      ##
      # Iterates through each child of this directory.
      #
      def each &block
        children.each(&block)
      end

    ##
    # Deletes all child nodes.
    #
    def clear
      children.each do |c|
        c.remove
      end
    end

    ##
    # Provides access to child nodes through method calls.
    #
    # :call-seq: node.child -> Node
    #
    def method_missing meth, *args
      child = self[meth]

      # speed up future accesses
      (class << self; self; end).instance_eval do
        define_method meth do
          child
        end
      end

      child
    end
  end

  ##
  # Makes instance methods accessible through class
  # methods. This is done to emulate the File class:
  #
  #   File.exist? "foo"
  #   File.new("foo").exist?
  #
  # Both of the above expressions are equivalent.
  #
  module ExportInstanceMethods
    def self.extended target #:nodoc:
      target.instance_methods(false).each do |meth|
        (class << target; self; end).instance_eval do
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
  Node.extend ExportInstanceMethods
end
