# Abstractions for the window manager.
#--
# Copyright 2006 Suraj N. Kurapati
# See the file named LICENSE for details.

require 'fs'
require 'enumerator'

class Object
  # prevent these deprecated properties from clashing with our usage below
  undef id, type
end

module Rumai
  ##
  #
  # access to global WM state
  #
  ##

  # Returns the root of IXP file system hierarchy.
  def fs
    Node.new '/'
  end

  # Returns the current set of tags.
  def tags
    fs.tag.entries.sort - %w[sel]
  end

  # Returns the current set of views.
  def views
    tags.map! {|t| View.new t}
  end

  module ClientContainer
    # see definition below!
  end

  include ClientContainer
    # Returns the IDs of the current set of clients.
    def client_ids
      fs.client.entries - %w[sel]
    end

  # Returns the name of the currently focused tag.
  def current_tag
    current_view.id
  end

  # Returns the name of the next tag.
  def next_tag
    next_view.id
  end

  # Returns the name of the previous tag.
  def prev_tag
    prev_view.id
  end


  ##
  #
  # multiple client grouping: allows you to group a set of clients
  # together and perform operations on all of them simultaneously.
  #
  ##

  GROUPING_TAG = '@'

  # Returns a list of all grouped clients in
  # the currently focused view. If there are
  # no grouped clients, then the currently
  # focused client is returned in the list.
  def grouping
    list = current_view.clients.select {|c| c.group? }
    list << current_client if list.empty? and current_client.exist?
    list
  end


  ##
  #
  # abstraction of WM components
  #
  ##

  # NOTE: Inheritors must override the 'chain' method.
  module Chain
    # Returns an array of objects related to this one.
    def chain
      [self]
    end

    # Returns the object after this one in the chain.
    def next
      arr = chain

      if pos = arr.index(self)
        arr[(pos + 1) % arr.length]
      end
    end

    # Returns the object before this one in the chain.
    def prev
      arr = chain

      if pos = arr.index(self)
        arr[(pos - 1) % arr.length]
      end
    end
  end

  # The basic building block of the WM hierarchy.
  #
  # NOTE: Inheritors must have a 'current' class method.
  # NOTE: Inheritors must override the 'focus' method.
  #
  module WidgetImpl #:nodoc:
    attr_reader :id

    def == aOther
      @id == aOther.id
    end

    # Checks if this widget currently has focus.
    def current?
      self == self.class.current
    end

    alias focus? current?
  end

  # A widget that has a corresponding representation in the IXP file system.
  class WidgetNode < Node #:nodoc:
    include WidgetImpl

    def initialize aId, aPathPrefix
      super "#{aPathPrefix}/#{aId}"

      if aId.to_sym == :sel and ctl.exist?
        @id = ctl.read 
        @path = File.join(File.dirname(@path), @id)
      else
        @id = File.basename(@path)
      end
    end
  end

  # A graphical program that is running in your current X Windows session.
  class Client < WidgetNode
    def initialize aClientId
      super aClientId, '/client'
    end

    # Returns the currently focused client.
    def self.current
      new :sel
    end

    include Chain
      # Returns a list of clients in the current view.
      def chain
        View.current.clients
      end

    ##
    #
    # WM operations
    #
    ##

    # Focuses this client within the given view.
    def focus aView = nil
      if exist? and not focus?
        (aView ? [aView] : self.views).each do |v|
          if a = self.area(v)
            v.focus
            a.focus

            # slide focus from the current client onto this client
            arr = a.client_ids
            src = arr.index Client.current.id
            dst = arr.index @id

            distance = (src - dst).abs
            direction = src < dst ? :down : :up

            distance.times do
              v.ctl.write "select #{direction}"
            end

            break
          end
        end
      end
    end

    # Sends this client to the given destination within the given view.
    def send aDst, aView = View.current
      if aDst.to_sym != :toggle
        # XXX: it is an error to send a floating client directly to a
        #      managed area, so we gotta "ground" it first and then send it
        #      to the desired managed area. John-Galt will fix this someday.
        if area(aView).float?
          aView.ctl.write "send #{@id} toggle"
        end
      end

      aView.ctl.write "send #{@id} #{aDst}"
    end

    # Swaps this client with the given destination within the given view.
    def swap aDst, aView = View.current
      aView.ctl.write "swap #{@id} #{aDst}"
    end

    ##
    #
    # WM hierarchy
    #
    ##

    # Returns the area that contains this client within the given view.
    def area aView = View.current
      aView.area_of_client self
    end

    # Returns the views that contain this client.
    def views
      tags.map! {|t| View.new t}
    end

    ##
    #
    # tag manipulations
    #
    ##

    TAG_DELIMITER = '+'.freeze

    # Returns the tags associated with this client.
    def tags
      self[:tags].read.split TAG_DELIMITER
    end

    # Modifies the tags associated with this client.
    def tags= *aTags
      arr = aTags.flatten.compact.uniq
      self[:tags].write arr.join(TAG_DELIMITER)
    end

    # Evaluates the given block within the
    # context of this client's list of tags.
    def with_tags &aBlock
      arr = self.tags
      arr.instance_eval(&aBlock)
      self.tags = arr
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

    ##
    #
    # multiple client grouping
    #
    ##

    # Checks if this client is included in the current grouping.
    def group?
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
    def toggle_group
      if group?
        ungroup
      else
        group
      end
    end
  end

  # NOTE: Inheritors should override the 'client_ids' method.
  module ClientContainer
    # Returns the IDs of the clients in this container.
    def client_ids
      []
    end

    # Returns the clients contained in this container.
    def clients
      client_ids.map! {|i| Client.new i}
    end

    # multiple client grouping
    %w[group ungroup toggle_group].each do |meth|
      define_method meth do
        clients.each do |c|
          c.__send__ meth
        end
      end
    end

    # Returns all grouped clients in this container.
    def grouping
      clients.select {|c| c.group? }
    end
  end

  # A region that contains clients. This can be either
  # the floating area or a column in the managed area.
  class Area
    attr_reader :view

    # aView:: the view which contains this area.
    def initialize aAreaId, aView = View.current
      @id = aAreaId.to_i
      @view = aView
    end

    # Checks if this area is the floating area.
    def float?
      @id == 0
    end

    # Checks if this area is a column in the managed area.
    def column?
      not float?
    end

    include WidgetImpl
      # Returns the currently focused area.
      def self.current
        View.current.area_of_client Client.current
      end

    include Chain
      def chain
        @view.areas
      end

      # Checks if this object exists in the chain.
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

    # Sets the layout of clients in this column.
    def layout= aMode
      @view.ctl.write "colmode #{ctl_id} #{aMode}"
    end

    ##
    #
    # WM operations
    #
    ##

    # Puts focus on this area.
    def focus
      @view.ctl.write "select #{ctl_id}"
    end

    ##
    #
    # array abstraction: area is an array of clients
    #
    ##

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

    # Ensures that this area has at most the given number of clients.
    # Areas to the right of this one serve as a buffer into which excess
    # clients are evicted and from which deficit clients are imported.
    def length= aMaxClients
      return unless aMaxClients > 0
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
      float? ? '~' : @id
    end

    # Moves the given client into this area.
    def import_client c
      if exist?
        @view.ctl.write "send #{c.id} #{@id+1}" #XXX: +1 until John-Galt fixes this: right now, index 1 is floating area; but ~ should be floating area.

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
  class View < WidgetNode
    include WidgetImpl
      # Returns the currently focused view.
      def self.current
        new :sel
      end

      # Focuses this view.
      def focus
        Rumai.fs.ctl.write "view #{@id}"
      end

    include Chain
      def chain
        Rumai.views
      end

    include ClientContainer
      # Returns the IDs of the clients contained
      # in the given area within this view.
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
      index.read || ''
    end

    ##
    #
    # WM hierarchy
    #
    ##

    # Returns the area which contains the given client in this view.
    def area_of_client aClientOrId
      arg = aClientOrId.id rescue aClientOrId

      manifest =~ /^(\S+) #{arg}/
      if areaId = $1
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

    # Returns the floating area of this view.
    def floating_area
      areas.first
    end

    # Returns all columns (managed areas) in this view.
    def columns
      areas[1..-1]
    end

    # Resiliently iterates through possibly destructive changes to
    # each column.  That is, if the given block creates new
    # columns, then those will also be processed in the iteration.
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

    ##
    #
    # visual arrangement of clients
    #
    ##

    # Arranges the clients in this view, while maintaining
    # their relative order, in the tiling fashion of
    # LarsWM.  Only the first client in the primary column
    # is kept; all others are evicted to the *top* of the
    # secondary column.  Any subsequent columns are
    # squeezed into the *bottom* of the secondary column.
    def arrange_as_larswm
      float, main, *extra = areas
      main.length = 1
      squeeze extra
    end

    # Arranges the clients in this view, while maintaining
    # their relative order, in a (at best) square grid.
    def arrange_in_grid aMaxClientsPerColumn = nil
      # compute client distribution
      unless aMaxClientsPerColumn
        numClients = num_managed_clients
        return unless numClients > 0

        numColumns = Math.sqrt(numClients)
        aMaxClientsPerColumn = (numClients / numColumns).round
      end

      return unless aMaxClientsPerColumn > 1

      # apply the distribution
      each_column do |a|
        a.length = aMaxClientsPerColumn
        a.layout = :default
      end
    end

    # Arranges the clients in this view, while maintaining their relative order,
    # in a (at best) equilateral triangle.  However, the resulting arrangement
    # appears like a diamond because wmii does not waste screen space.
    def arrange_in_diamond
      numClients = num_managed_clients
      return unless numClients > 1

      # determine dimensions of the rising sub-triangle
      rise = numClients / 2

      span = sum = 0
      1.upto rise do |h|
        if sum + h > rise
          break
        else
          sum += h
          span += 1
        end
      end

      peak = numClients - (sum * 2)

      # describe the overall triangle as a sequence of heights
      riseSeq = (1..span).to_a
      fallSeq = riseSeq.reverse

      heights = riseSeq
      heights << peak if peak > 0
      heights.concat fallSeq

      # apply the heights
      each_column do |col|
        if h = heights.shift
          col.length = h
          col.layout = :default
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


  ##
  #
  # shortcuts for interactive WM manipulation (via IRB)
  #
  ##

  # provide easy access to container state information
  [Client, Area, View].each do |c|
    c.extend ExportInstMethods
  end

  def current_client
    Client.current
  end

  def next_client
    current_client.next
  end

  def prev_client
    current_client.prev
  end

  def current_area
    Area.current
  end

  def next_area
    current_area.next
  end

  def prev_area
    current_area.prev
  end

  def current_view
    View.current
  end

  def next_view
    current_view.next
  end

  def prev_view
    current_view.prev
  end

  def focus_client aId
    Client.focus(aId)
  end

  def focus_area aId
    Area.focus(aId)
  end

  def focus_view aId
    View.focus(aId)
  end

  # provide easy access to this module's instance methods
  module_function(*instance_methods)
end
