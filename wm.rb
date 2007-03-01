# Abstractions for the window manager.
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

$: << File.dirname(__FILE__)
require 'fs'
require 'enumerator'

class Object #:nodoc:
  # Get rid of this deprecated property so that it does not clash with our usage in the classes below.
  undef id
end

# Encapsulates access to the window manager.
module Wmii
  ## state access

  # Returns the root of IXP file system hierarchy.
  def fs
    Ixp::Node.new '/'
  end

  # Returns the name of the currently focused tag.
  def current_tag
    fs['/tag/sel/ctl'].read
  end

  def next_tag
    next_view.id
  end

  def prev_tag
    prev_view.id
  end

  # Returns the current set of tags.
  def tags
    ary = fs['/tag'].read
    ary.delete 'sel'
    ary.sort!
    ary
  end

  # Returns the current set of views.
  def views
    tags.map! {|t| View.new t}
  end

  # Returns the current set of clients.
  def client_ids
    ary = fs['/client'].read
    ary.delete 'sel'
    ary
  end

  # Returns the current set of clients.
  def clients
    client_ids.map! {|i| Client.new i}
  end


  ## Multiple client grouping
  # Allows you to group a set of clients together and perform operations on all of them simultaneously.

  GROUPING_TAG = '@'

  # Returns a list of all grouped clients in the currently focused view. If there are no grouped clients, then the currently focused client is returned in the list.
  def grouped_clients
    list = current_view.clients.select {|c| c.grouped?}
    list << current_client if list.empty?
    list
  end

  alias grouping grouped_clients

  # Un-groups all grouped clients so that there is nothing grouped.
  def ungroup_all
    g = View.new GROUPING_TAG
    g.ungroup if g.exist?
  end


  ## subclasses for abstraction

  module Identifiable
    # Returns the identification for this object.
    # NOTE: Override this method!
    def id
      self
    end

    def == aOther
      id == aOther.id
    end
  end

  module Chainable
    # Returns an array of objects related to this one.
    # NOTE: Override this method!
    def chain *args
      [self]
    end

    # Returns the object after this one in the chain.
    def next *args
      ary = chain(*args)
      pos = ary.index(self)
      ary[(pos + 1) % ary.length]
    end

    # Returns the object before this one in the chain.
    def prev *args
      ary = chain(*args)
      pos = ary.index(self)
      ary[(pos - 1) % ary.length]
    end
  end

  # The basic building block of the WM hierarchy.
  # NOTE: inheritors must have a 'current' class method.
  module Common
    include Identifiable
      attr_reader :id

    # Checks if this object is currently focused.
    def current?
      self == self.class.current
    end

    alias focused? current?
  end

  class FsNode < Ixp::Node #:nodoc:
    def initialize aId, aPathPrefix
      super "#{aPathPrefix}/#{aId}"

      @id = if aId.to_sym == :sel
        self[:ctl].read
      else
        basename
      end
    end
  end


  # A graphical program that is running in your current X Windows session.
  class Client < FsNode
    include Common
      # Returns the currently focused client.
      def Client.current
        Client.new :sel
      end

      # Focuses this client within the given view.
      def focus aView = nil
        if exist? and not focused?
          haystack = if aView
            [aView]
          else
            views
          end

          haystack.each do |v|
            if a = self.area(v)
              v.focus
              a.focus

              # slide the focus (from the current view in the area) onto this client
                ary = a.client_ids
                src = ary.index Client.current.id
                dst = ary.index id

                distance = (src - dst).abs
                direction = src < dst ? :down : :up

                distance.times do
                  v.ctl = "select #{direction}"
                end

              break
            end
          end
        end
      end

    include Chainable
      def chain aView = View.current
        aView.clients
      end

    def initialize aClientId
      super aClientId, '/client'
    end


    ## WM operations

    # Sends this client to the given destination within the given view.
    def send aDst, aView = View.current
      if aDst.to_sym != :toggle
        # XXX: it is an error to send a floating client directly to a managed area, so we gotta "ground" it first and then send it to the desired managed area. John-Galt will fix this someday.
        if area(aView).floating?
          aView.ctl = "send #{id} toggle"
        end
      end

      aView.ctl = "send #{id} #{aDst}"
    end

    # Swaps this client with the given destination within the given view.
    def swap aDst, aView = View.current
      aView.ctl = "swap #{id} #{aDst}"
    end


    ## WM hierarchy

    # Returns the area that contains this client within the given view.
    def area aView = View.current
      aView.area_of_client self
    end

    # Returns the views that contain this client.
    def views
      tags.map! {|t| View.new t}
    end


    ## client tagging stuff

    TAG_DELIMITER = '+'

    # Returns the tags associated with this client.
    def tags
      self[:tags].read.split TAG_DELIMITER
    end

    # Modifies the tags associated with this client.
    def tags= *aTags
      ary = aTags.flatten.compact.uniq
      self[:tags] = ary.join(TAG_DELIMITER)
    end

    # Evaluates the given block within the context of this client's list of tags.
    def with_tags &aBlock
      ary = self.tags
      ary.instance_eval(&aBlock)
      self.tags = ary
    end

    # Adds the given tags to this client.
    def tag *aTags
      with_tags do
        concat aTags
      end
    end

    # Removes the given tags from this client.
    def untag *aTags
      with_tags do
        aTags.flatten.each do |tag|
          delete tag.to_s
        end
      end
    end


    ## multiple client grouping

    # Checks if this client is included in the current grouping.
    def grouped?
      tags.include? GROUPING_TAG
    end

    # Adds this client to the current grouping.
    def group
      with_tags do
        push GROUPING_TAG
      end
    end

    # Removes this client to the current grouping.
    def ungroup
      untag GROUPING_TAG
    end

    # Toggles the presence of this client in the current grouping.
    def toggle_grouping
      if grouped?
        ungroup
      else
        group
      end
    end
  end

  module ClientContainer
    # Returns the IDs of the clients in this container.
    # NOTE: Override this method!
    def client_ids
      []
    end

    # Returns the clients contained in this container.
    def clients
      client_ids.map! {|i| Client.new i}
    end

    # multiple client grouping
    %w[group ungroup toggle_grouping].each do |meth|
      define_method meth do
        clients.each do |c|
          c.__send__ meth
        end
      end
    end
  end


  # A region that contains clients. This can be either the floating area or a column in the managed area.
  class Area
    include Common
      # Returns the currently focused area.
      def Area.current
        View.current.area_of_client Client.current
      end

      # Puts focus on this area.
      def focus
        @view.ctl = "select #{ctl_id}"
      end

    include Chainable
      def chain
        @view.areas
      end

      # Checks if this area really exists.
      def exist?
        chain.include? self
      end

    include ClientContainer
      # Returns the IDs of the clients in this area.
      def client_ids
        @view.client_ids ctl_id
      end

    include Enumerable
      # Iterates through each client in this container.
      def each &aBlock
        clients.each(&aBlock)
      end

    attr_reader :view

    # aView:: the view which contains this area.
    def initialize aAreaId, aView = View.current
      @id = aAreaId.to_i
      @view = aView
    end

    # Checks if this area is the floating area.
    def floating?
      @id == 0
    end

    # Checks if this area is a column in the managed area.
    def managed?
      not floating?
    end

    alias column? managed?

    # Sets the layout of clients in this column.
    def layout= aMode
      @view.ctl = "colmode #{ctl_id} #{aMode}"
    end


    ## array abstraction: area is an array of clients

    # Returns the number of clients in this area.
    def length
      client_ids.length
    end

    # Inserts the given clients at the bottom of this area.
    def push *aClients
      if target = clients.first
        target.focus
      end

      insert aClients
    end

    alias << push

    # Inserts the given clients after the currently focused client in this area.
    def insert *aClients
      aClients.flatten!
      return if aClients.empty?

      aClients.each do |c|
        import_client c
      end
    end

    # Inserts the given clients at the top of this area.
    def unshift *aClients
      aClients.flatten!
      return if aClients.empty?

      if target = clients.first
        target.focus
      end

      aClients.each do |c|
        import_client c
      end
    end

    # Concatenates the given area to the bottom of this area.
    def concat aArea
      push aArea.clients
    end

    # Ensures that this area has at most the given number of clients. Areas to the right of this one serve as a buffer into which excess clients are evicted and from which deficit clients are imported.
    def length= aMaxClients
      return if aMaxClients <= 0
      len, out = length, fringe

      if len > aMaxClients
        out.unshift clients[aMaxClients..-1]

      elsif len < aMaxClients
        until (diff = aMaxClients - length) == 0
          immigrants = out.clients[0...diff]
          break if immigrants.empty?

          push immigrants
        end
      end
    end

    private

    # Makes the ID usable in wmii's /ctl commands.
    def ctl_id
      floating? ? '~' : @id
    end

    def import_client c
      if exist?
        @view.ctl = "send #{c.id} #{@id+1}" #XXX: +1 until John-Galt fixes this: right now, index 1 is floating area; but ~ should be floating area.
      else
        # move the client to the nearest existing column
          src = c.area
          dst = chain.last

          dst.insert c unless src == dst

        # slide the client over to this column
          c.send :right
          @id = dst.id.next

          raise 'column should exist now' unless exist?
      end
    end

    # Returns the next area, which may or may not exist.
    def fringe
      Area.new @id.next, @view
    end
  end

  # The visualization of a tag.
  class View < FsNode
    include Common
      # Returns the currently focused view.
      def View.current
        View.new :sel
      end

      # Focuses this view.
      def focus
        Wmii.fs.ctl = "view #{id}"
      end

    include Chainable
      def chain
        Wmii.views
      end

    include ClientContainer
      # Returns the IDs of the clients contained in the given area within this view.
      def client_ids aAreaId = '\S+'
        manifest.scan(/^#{aAreaId} (0x\S+)/).flatten
      end

    include Enumerable
      # Iterates through each area in this view.
      def each &aBlock
        areas.each(&aBlock)
      end

    def initialize aViewId
      super aViewId, '/tag'
    end

    # Returns the manifest of all areas and clients in this view.
    def manifest
      self[:index].read
    end


    ## WM hierarchy

    # Returns the area which contains the given client in this view.
    def area_of_client aClientOrId
      arg = aClientOrId.id rescue aClientOrId

      if areaId = (manifest =~ /^(\S+) #{arg}/ && $1)
        Area.new areaId, self
      end
    end

    # Returns the IDs of all areas in this view.
    def area_ids
      manifest.scan(/^# (\S+)/).flatten
    end

    # Returns all areas in this view.
    def areas
      area_ids.map! {|i| Area.new i, self}
    end

    # Returns all columns (managed areas) in this view.
    def columns
      areas[1..-1]
    end

    # Resiliently iterates through possibly destructive changes to each column. That is, if the given block creates new columns, then those will also be processed in the iteration.
    def each_column aStartingColumnId = 1
      i = aStartingColumnId
      loop do
        a = Area.new i, self

        if a.exist?
          yield a
        else
          break
        end

        i += 1
      end
    end


    ## visual arrangement of clients

    # Arranges the clients in this view, while maintaining their relative order, in the tiling fashion of LarsWM. Only the first client in the primary column is kept; all others are evicted to the *top* of the secondary column. Any subsequent columns are squeezed into the *bottom* of the secondary column.
    def arrange_as_larswm
      float, main, *extra = areas
      main.length = 1
      squeeze extra
    end

    # Arranges the clients in this view, while maintaining their relative order, in a (at best) square grid.
    def arrange_in_grid aMaxClientsPerColumn = nil
      # determine client distribution
        unless aMaxClientsPerColumn
          numClients = num_managed_clients
          return unless numClients > 1

          numColumns = Math.sqrt(numClients)
          aMaxClientsPerColumn = (numClients / numColumns).round
        end

      # distribute the clients
        if aMaxClientsPerColumn <= 0
          squeeze columns
        else
          columns.each do |a|
            if a.exist?
              a.length = aMaxClientsPerColumn
              a.layout = :default
            else
              break
            end
          end
        end
    end

    # Arranges the clients in this view, while maintaining their relative order, in a (at best) equilateral triangle. However, the resulting arrangement appears like a diamond because wmii does not waste screen space.
    def arrange_in_diamond
      if (numClients = num_managed_clients) > 0
        subtriArea = numClients / 2
        crestArea = numClients % subtriArea

        # build fist sub-triangle upwards
          height = area = 0
          lastCol = nil

          columns.each do |col|
            if area < subtriArea
              height += 1

              col.length = height
              area += height

              col.layout = :default
              lastCol = col
            else
              break
            end
          end

        # build crest of overall triangle
          if crestArea > 0
            lastCol.length = height + crestArea
          end

        # build second sub-triangle downwards
          down = columns
          down.slice! 0..down.index(lastCol)
          down.each do |col|
            if area > 0
              col.length = height
              area -= height

              height -= 1
            else
              break
            end
          end
      end
    end


    private

    # Returns the number of clients in the non-floating areas of this view.
    def num_managed_clients
      manifest.scan(/^\d+ 0x/).length
    end

    # Smashes the given list of areas into the first one.
    # The relative ordering of clients is preserved.
    def squeeze aAreas
      aAreas.reverse.each_cons(2) do |src, dst|
        dst.concat src
      end
    end
  end


  ## shortcuts for interactive WM manipulation (via IRB)

  bricks = [Client, Area, View]

  # provide easy access to container state information
    bricks.each do |c|
      c.extend Ixp::ExternalizeInstanceMethods
    end

  # provide easy access to common WM state information
    common = bricks.map do |c|
      c.methods false
    end.inject do |a, b|
      a & b
    end

    bricks.each do |c|
      target = c.to_s.sub(/.*::/, '').downcase

      common.each do |prop|
        meth = "#{prop}_#{target}"

        define_method meth do |*args|
          c.__send__ prop, *args
        end

        module_function meth
      end

      # complementary properties for 'current' property
      %w[next prev].each do |prop|
        meth = "#{prop}_#{target}"

        define_method meth do |*args|
          c.__send__(:current).__send__(prop, *args)
        end

        module_function meth
      end
    end

  # provide easy access to this module's instance methods
    module_function(*instance_methods(false))
end
