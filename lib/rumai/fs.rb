# File system abstractions over the 9P2000 protocol.
#--
# Copyright 2006 Suraj N. Kurapati
# See the file named LICENSE for details.

require 'ixp'

module Rumai
  # We use a single, global connection to wmii's IXP server.
  CLIENT = IXP::Client.new

  # An entry in the IXP file system.
  class Node
    include Enumerable
      # Iterates through each child of this directory.
      def each &aBlock
        children.each(&aBlock)
      end

    attr_reader :path

    def initialize aPath
      @path = aPath.to_s.squeeze('/')
    end

    # Returns file statistics about this node.
    # See IXP::Client#stat for details.
    def stat
      CLIENT.stat @path
    end

    # Tests if this node exists on the IXP server.
    def exist?
      begin
        true if stat
      rescue IXP::Exception
        false
      end
    end

    # Tests if this node is a directory.
    def directory?
      exist? and stat.directory?
    end

    # Opens this node for I/O access.
    # See IXP::Client#open for details.
    def open aMode = 'r', &aBlock
      CLIENT.open @path, aMode, aBlock
    end

    # Returns the entire content of this node.
    # See IXP::Client#read for details.
    def read
      CLIENT.read @path
    end

    # Writes the given content to this node.
    def write aContent
      CLIENT.write @path, aContent
    end

    # Creates a file corresponding to this node on the IXP server.
    # See IXP::Client#create for details.
    def create *aArgs
      CLIENT.create @path, *aArgs
    end

    # Deletes the file corresponding to this node on the IXP server.
    def remove
      CLIENT.remove @path
    end

    # Returns the given sub-path as a Node object.
    def [] aSubPath
      Node.new "#{@path}/#{aSubPath}"
    end

    # Returns the parent node of this node.
    def parent
      Node.new File.dirname(@path)
    end

    # Returns all child nodes of this node.
    def children
      ls.map! {|c| Node.new c}
    end

    # Returns the names of all files in this directory.
    def ls
      CLIENT.ls @path rescue []
    end

    # Deletes all child nodes.
    def clear
      children.each do |c|
        c.remove
      end
    end

    # Provides access to child nodes through method calls.
    #
    # :call-seq:
    #   node.child -> Node
    #
    def method_missing aMeth, *aArgs
      self[aMeth]
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
  module ExternalizeInstanceMethods
    def self.extended aTarget
      aTarget.instance_methods(false).each do |meth|
        (class << aTarget; self; end).instance_eval do
          define_method meth do |path, *args|
            new(path).__send__(meth, *args)
          end
        end
      end
    end
  end

  Node.extend ExternalizeInstanceMethods
end
