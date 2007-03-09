# Abstractions for wmii's IXP file system interface.
=begin
  Copyright 2006, 2007 Suraj N. Kurapati

  This program is free software; you can redistribute it and/or
  modify it under the terms of the GNU General Public License
  as published by the Free Software Foundation; either version 2
  of the License, or (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
=end

$: << File.join(File.dirname(__FILE__), 'ruby-ixp', 'lib')
require 'ixp'

# Encapsulates access to the IXP file system.
module Ixp
  # We use a single, global connection.
  Client = IXP::Client.new ENV['WMII_ADDRESS']

  # An entry in the IXP file system.
  class Node
    include Enumerable
      # Iterates through each child of this directory.
      def each &aBlock
        children.each(&aBlock)
      end

    attr_reader :path

    # Obtains the IXP node at the given path. Unless it already exists, the given path is created when aCreateIt is asserted.
    def initialize aPath, aCreateIt = false
      @path = aPath.to_s.squeeze('/')
      create if aCreateIt && !exist?
    end

    # delegate file-system operations to the IXP client
      meths = Client.public_methods(false)
      meths.delete 'write'
      meths.delete 'read'

      meths.each do |m|
        class_eval %{
          def #{m} *a, &b
            Client.#{m}(@path, *a, &b)
          end
        }
      end

    # Writes the given text to this file.
    def write aText
      begin # XXX: protect against needless 'File not found' errors
        Client.write @path, aText
      rescue IXP::IXPException
        puts $!.inspect, $!.backtrace
      end
    end

    alias << write
    alias < write

    # Returns the contents of this node or the names of all entries if this is a directory.
    def read
      begin # XXX: protect against needless 'File not found' errors
        val = Client.read(@path)

        if val.respond_to? :to_ary
          val.map {|stat| stat.name}
        else
          val
        end
      rescue IXP::IXPException
        puts $!.inspect, $!.backtrace
      end
    end

    # Returns the basename of this file's path.
    def basename
      File.basename @path
    end

    # Returns the dirname of this file's path.
    def dirname
      File.dirname @path
    end

    # Accesses the given sub-path and dereferences it (reads its contents) if specified.
    def [] aSubPath
      Node.new("#{@path}/#{aSubPath}")
    end

    # Writes the given content to the given sub-path.
    def []= aSubPath, aContent
      self[aSubPath].write aContent
    end

    # Returns the parent node of this node.
    def parent
      Node.new File.dirname(@path)
    end

    # Returns all child nodes of this node.
    def children
      if directory?
        read.map! {|i| self[i]}
      else
        []
      end
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
    #   node.child = value  -> value
    #   node.child          -> Node
    #
    def method_missing aMeth, *aArgs
      case aMeth.to_s
        when /=$/
          self[$`] = *aArgs

        else
          self[aMeth]
      end
    end
  end

  # Makes instance methods accessible through class
  # methods. This is done to emulate the File class:
  #
  #   File.exist? "foo"
  #   File.new("foo").exist?
  #
  # Both of these expressions are equivalent.
  #
  module ExternalizeInstanceMethods
    def self.extended aTarget
      (class << aTarget; self; end).class_eval do
        aTarget.instance_methods(false).each do |meth|
          define_method meth do |path, *args|
            aTarget.new(path).__send__(meth, *args)
          end
        end
      end
    end
  end

  Node.extend ExternalizeInstanceMethods
end
