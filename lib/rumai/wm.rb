# Abstractions for the window manager.

require 'rumai/fs'
require 'enumerator'

class Object
  # prevent these deprecated properties from clashing with our usage below
  undef id if respond_to? :id
  undef type if respond_to? :type
end

module Rumai
  ##
  #
  # access to global WM state
  #
  ##

  ROOT = Node.new '/'

  # Returns the root of IXP file system hierarchy.
  def fs
    ROOT
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
  def curr_tag
    curr_view.id
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
    list = curr_view.clients.select {|c| c.group? }
    list << curr_client if list.empty? and curr_client.exist?
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
      sibling(+1)
    end

    # Returns the object before this one in the chain.
    def prev
      sibling(-1)
    end

    private

    def sibling offset
      arr = chain

      if pos = arr.index(self)
        arr[(pos + offset) % arr.length]
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

    def == other
      @id == other.id
    end

    # Checks if this widget currently has focus.
    def current?
      self == self.class.curr
    end

    alias focus? current?
  end

  # A widget that has a corresponding representation in the IXP file system.
  class WidgetNode < Node #:nodoc:
    include WidgetImpl

    def initialize id, path_prefix
      super "#{path_prefix}/#{id}"

      if id.to_s == 'sel' and ctl.exist?
        @id = ctl.read.split.first
        @path = File.join(File.dirname(@path), @id)
      else
        @id = File.basename(@path)
      end
    end
  end

  # A graphical program that is running in your current X Windows session.
  class Client < WidgetNode
    def initialize client_id
      super client_id, '/client'
    end

    # Returns the currently focused client.
    def self.curr
      new :sel
    end

    include Chain
      # Returns a list of clients in the current view.
      def chain
        View.curr.clients
      end

    ##
    #
    # WM operations
    #
    ##

    # Focuses this client within the given view.
    def focus view = nil
      if exist? and not focus?
        (view ? [view] : self.views).each do |v|
          if a = self.area(v) and a.exist?
            v.focus
            a.focus

            # slide focus from the current client onto this client
            arr = a.client_ids
            src = arr.index Client.curr.id
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
    def send area_or_id, view = View.curr
      dst = area_to_id(area_or_id)
      view.ctl.write "send #{@id} #{dst}"
    end

    # Swaps this client with the given destination within the given view.
    def swap area_or_id, view = View.curr
      dst = area_to_id(area_or_id)
      view.ctl.write "swap #{@id} #{dst}"
    end

    # Terminates this client nicely (requests this window to be closed).
    def kill
      ctl.write :kill
    end

    ##
    #
    # WM hierarchy
    #
    ##

    # Returns the area that contains this client within the given view.
    def area view = View.curr
      view.area_of_client self
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
    def tags= *tags
      arr = tags.flatten.compact.uniq
      self[:tags].write arr.join(TAG_DELIMITER)
    end

    # Evaluates the given block within the
    # context of this client's list of tags.
    def with_tags &block
      arr = self.tags
      arr.instance_eval(&block)
      self.tags = arr
    end

    # Adds the given tags to this client.
    def tag *tags
      with_tags do
        concat tags
      end
    end

    # Removes the given tags from this client.
    def untag *tags
      with_tags do
        tags.flatten.each do |tag|
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

    private

    def area_to_id area_or_id
      if area_or_id.respond_to? :id
        id = area_or_id.id
        id == '~' ? :toggle : id
      else
        area_or_id
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

    # view:: the view which contains this area.
    def initialize area_id, view = View.curr
      @id = Integer(area_id) rescue area_id
      @view = view
    end

    # Checks if this area is the floating area.
    def float?
      @id == '~'
    end

    # Checks if this area is a column in the managed area.
    def column?
      not float?
    end

    include WidgetImpl
      # Returns the currently focused area.
      def self.curr
        View.curr.area_of_client Client.curr
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
        @view.client_ids @id
      end

    include Enumerable
      # Iterates through each client in this container.
      def each &block
        clients.each(&block)
      end

    # Sets the layout of clients in this column.
    def layout= mode
      @view.ctl.write "colmode #{@id} #{mode}"
    end

    ##
    #
    # WM operations
    #
    ##

    # Puts focus on this area.
    def focus
      @view.ctl.write "select #{@id}"
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
    def push *clients
      if target = clients.last
        target.focus
      end

      insert clients
    end

    alias << push

    # Inserts the given clients after the currently focused client in this area.
    def insert *clients
      clients.flatten!
      return if clients.empty?

      clients.each do |c|
        import_client c
      end
    end

    # Inserts the given clients at the top of this area.
    def unshift *clients
      clients.flatten!
      return if clients.empty?

      if target = clients.first
        target.focus
      end

      clients.each do |c|
        import_client c
        c.send :up if target
      end
    end

    # Concatenates the given area to the bottom of this area.
    def concat area
      push area.clients
    end

    # Ensures that this area has at most the given number of clients.
    # Areas to the right of this one serve as a buffer into which excess
    # clients are evicted and from which deficit clients are imported.
    def length= max_clients
      return unless max_clients > 0
      len, out = length, fringe

      if len > max_clients
        out.unshift clients[max_clients..-1].reverse

      elsif len < max_clients
        until (diff = max_clients - length) == 0
          immigrants = out.clients.first(diff)
          break if immigrants.empty?

          push immigrants
        end
      end
    end

    private

    # Moves the given client into this area.
    def import_client c
      if exist?
        c.send self

      else
        # move the client to the nearest existing column
        src = c.area
        dst = chain.last

        c.send dst unless src == dst

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
      def self.curr
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
      def client_ids area_id = '\S+'
        manifest.scan(/^#{area_id} (0x\S+)/).flatten
      end

    include Enumerable
      # Iterates through each area in this view.
      def each &block
        areas.each(&block)
      end

    def initialize view_id
      super view_id, '/tag'
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
    def area_of_client client_or_id
      arg =
        if client_or_id.respond_to? :id
          client_or_id.id
        else
          client_or_id
        end

      manifest =~ /^(\S+) #{arg}/
      if area_id = $1
        Area.new area_id, self
      end
    end

    # Returns the IDs of all areas in this view.
    def area_ids
      ids = manifest.scan(/^# (\d+)/).flatten
      ids.unshift '~' # always exists in output
      ids
    end

    # Returns all areas in this view.
    def areas
      area_ids.map! {|i| Area.new i, self}
    end

    # Returns the floating area of this view.
    def floater
      areas.first
    end

    # Returns all columns (managed areas) in this view.
    def columns
      areas[1..-1]
    end

    # Resiliently iterates through possibly destructive changes to
    # each column.  That is, if the given block creates new
    # columns, then those will also be processed in the iteration.
    def each_column starting_column_id = 1
      i = starting_column_id
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
    def arrange_in_grid max_clients_per_column = nil
      # compute client distribution
      unless max_clients_per_column
        num_clients = num_managed_clients
        return unless num_clients > 0

        num_columns = Math.sqrt(num_clients)
        max_clients_per_column = (num_clients / num_columns).round
      end

      return unless max_clients_per_column > 1

      # apply the distribution
      each_column do |a|
        a.length = max_clients_per_column
        a.layout = :default
      end
    end

    # Arranges the clients in this view, while maintaining their relative order,
    # in a (at best) equilateral triangle.  However, the resulting arrangement
    # appears like a diamond because wmii does not waste screen space.
    def arrange_in_diamond
      num_clients = num_managed_clients
      return unless num_clients > 1

      # determine dimensions of the rising sub-triangle
      rise = num_clients / 2

      span = sum = 0
      1.upto rise do |h|
        if sum + h > rise
          break
        else
          sum += h
          span += 1
        end
      end

      peak = num_clients - (sum * 2)

      # describe the overall triangle as a sequence of heights
      rise_seq = (1..span).to_a
      fall_seq = rise_seq.reverse

      heights = rise_seq
      heights << peak if peak > 0
      heights.concat fall_seq

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
    def squeeze areas
      areas.reverse.each_cons(2) do |src, dst|
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

  def curr_client
    Client.curr
  end

  def next_client
    curr_client.next
  end

  def prev_client
    curr_client.prev
  end

  def curr_area
    Area.curr
  end

  def next_area
    curr_area.next
  end

  def prev_area
    curr_area.prev
  end

  def curr_view
    View.curr
  end

  def next_view
    curr_view.next
  end

  def prev_view
    curr_view.prev
  end

  def focus_client id
    Client.focus id
  end

  def focus_area id
    Area.focus id
  end

  def focus_view id
    View.focus id
  end

  # provide easy access to this module's instance methods
  module_function(*instance_methods)
end
