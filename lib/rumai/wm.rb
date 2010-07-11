# Abstractions for the window manager.

require 'rumai/fs'
require 'enumerator'

class Object # @private
  # prevent these deprecated properties
  # from clashing with our usage below
  undef id   if respond_to? :id
  undef type if respond_to? :type
end

module Rumai
  IXP_FS_ROOT         = Node.new('/')
  FOCUSED_WIDGET_ID   = 'sel'.freeze
  FLOATING_AREA_ID    = '~'.freeze
  CLIENT_GROUPING_TAG = '@'.freeze
  CLIENT_STICKY_TAG   = '/./'.freeze

  #---------------------------------------------------------------------------
  # abstraction of WM components
  #---------------------------------------------------------------------------

  ##
  # @note Inheritors must override the {Chain#chain} method.
  #
  module Chain
    ##
    # Returns an array of objects related to this one.
    #
    def chain
      [self]
    end

    ##
    # Returns the object after this one in the chain.
    #
    def next
      sibling(+1)
    end

    ##
    # Returns the object before this one in the chain.
    #
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

  ##
  # The basic building block of the WM hierarchy.
  #
  # @note Inheritors must define a {curr} class method.
  # @note Inheritors must override the {focus} method.
  #
  module WidgetImpl
    attr_reader :id

    def == other
      @id == other.id
    end

    ##
    # Checks if this widget currently has focus.
    #
    def current?
      self == self.class.curr
    end

    alias focus? current?
  end

  ##
  # A widget that has a corresponding representation in the IXP file system.
  #
  class WidgetNode < Node
    include WidgetImpl

    def initialize id, path_prefix
      super "#{path_prefix}/#{id}"

      if id == FOCUSED_WIDGET_ID and ctl.exist?
        @id = ctl.read.split.first
        super "#{path_prefix}/#{@id}"
      else
        @id = id.to_s
      end
    end
  end

  ##
  # A graphical program that is running in your current X Windows session.
  #
  class Client < WidgetNode
    def initialize client_id
      super client_id, '/client'
    end

    ##
    # Returns the currently focused client.
    #
    def self.curr
      new FOCUSED_WIDGET_ID
    end

    #-------------------------------------------------------------------------
    include Chain
    #-------------------------------------------------------------------------

    ##
    # Returns a list of all clients in the current view.
    #
    def chain
      View.curr.clients
    end

    #-------------------------------------------------------------------------
    # WM operations
    #-------------------------------------------------------------------------

    ##
    # Focuses this client within the given view.
    #
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

            distance.times { v.select direction }
            break
          end
        end
      end
    end

    ##
    # Sends this client to the given destination within the given view.
    #
    def send area_or_id, view = View.curr
      dst = area_to_id(area_or_id)
      view.ctl.write "send #{@id} #{dst}"
    end

    alias move send

    ##
    # Swaps this client with the given destination within the given view.
    #
    def swap area_or_id, view = View.curr
      dst = area_to_id(area_or_id)
      view.ctl.write "swap #{@id} #{dst}"
    end

    ##
    # Moves this client in the given direction on the given view.
    #
    def nudge direction, view = View.curr
      reshape :nudge, direction, view
    end

    ##
    # Grows this client in the given direction on the given view.
    #
    def grow direction, view = View.curr
      reshape :grow, direction, view
    end

    ##
    # Terminates this client nicely (requests this window to be closed).
    #
    def kill
      ctl.write :kill
    end

    ##
    # Terminates this client forcefully.
    #
    def slay
      ctl.write :slay
    end

    ##
    # Maximizes this client to occupy the
    # entire screen on the current view.
    #
    def fullscreen
      ctl.write 'Fullscreen on'
    end

    ##
    # Restores this client back to its original size on the current view.
    #
    def unfullscreen
      ctl.write 'Fullscreen off'
    end

    ##
    # Toggles the fullscreen status of this client on the current view.
    #
    def fullscreen!
      ctl.write 'Fullscreen toggle'
    end

    ##
    # Checks if this client is currently fullscreen on the current view.
    #
    def fullscreen?
      #
      # If the client's dimensions match those of the
      # floating area, then we know it is fullscreen.
      #
      View.curr.manifest =~ /^# #{FLOATING_AREA_ID} (\d+) (\d+)\n.*^#{FLOATING_AREA_ID} #{@id} \d+ \d+ \1 \2 /m
    end

    ##
    # Checks if this client is sticky (appears in all views).
    #
    def stick?
      tags.include? CLIENT_STICKY_TAG
    end

    ##
    # Makes this client sticky (appears in all views).
    #
    def stick
      tag CLIENT_STICKY_TAG
    end

    ##
    # Makes this client unsticky (does not appear in all views).
    #
    def unstick
      untag CLIENT_STICKY_TAG
    end

    ##
    # Toggles the stickyness of this client.
    #
    def stick!
      if stick?
        unstick
      else
        stick
      end
    end

    ##
    # Checks if this client is in the floating area of the given view.
    #
    def float? view = View.curr
      area(view).floating?
    end

    ##
    # Puts this client into the floating area of the given view.
    #
    def float view = View.curr
      send :toggle, view unless float? view
    end

    ##
    # Puts this client into the managed area of the given view.
    #
    def unfloat view = View.curr
      send :toggle, view if float? view
    end

    ##
    # Toggles the floating status of this client in the given view.
    #
    def float! view = View.curr
      send :toggle, view
    end

    ##
    # Checks if this client is in the managed area of the given view.
    def manage? view = View.curr
      not float? view
    end

    alias manage unfloat

    alias unmanage float

    alias manage! float!

    #-------------------------------------------------------------------------
    # WM hierarchy
    #-------------------------------------------------------------------------

    ##
    # Returns the area that contains this client within the given view.
    #
    def area view = View.curr
      view.area_of_client self
    end

    ##
    # Returns the views that contain this client.
    #
    def views
      tags.map! {|t| View.new t }
    end

    #-------------------------------------------------------------------------
    # tag manipulations
    #-------------------------------------------------------------------------

    TAG_DELIMITER = '+'.freeze

    ##
    # Returns the tags associated with this client.
    #
    def tags
      self[:tags].read.split TAG_DELIMITER
    end

    ##
    # Modifies the tags associated with this client.
    #
    # If a tag name is '~', this client is placed
    # into the floating layer of the current view.
    #
    # If a tag name begins with '~', then this
    # client is placed into the floating layer
    # of the view corresponding to that tag.
    #
    # If a tag name is '!', this client is placed
    # into the managed layer of the current view.
    #
    # If a tag name begins with '!', then this
    # client is placed into the managed layer
    # of the view corresponding to that tag.
    #
    def tags= *tags
      float = []
      manage = []
      inherit = []

      tags.join(TAG_DELIMITER).split(TAG_DELIMITER).each do |tag|
        case tag
        when '~'  then float   << Rumai.curr_tag
        when /^~/ then float   << $'
        when '!'  then manage  << Rumai.curr_tag
        when /^!/ then manage  << $'
        else           inherit << tag
        end
      end

      self[:tags].write((float + manage + inherit).uniq.join(TAG_DELIMITER))

      float.each do |tag|
        self.float View.new(tag)
      end

      manage.each do |tag|
        self.manage View.new(tag)
      end
    end

    ##
    # Evaluates the given block within the
    # context of this client's list of tags.
    #
    def with_tags &block
      arr = self.tags
      arr.instance_eval(&block)
      self.tags = arr
    end

    ##
    # Adds the given tags to this client.
    #
    def tag *tags
      with_tags do
        concat tags
      end
    end

    ##
    # Removes the given tags from this client.
    #
    def untag *tags
      with_tags do
        tags.flatten.each do |tag|
          delete tag.to_s
        end
      end
    end

    #-------------------------------------------------------------------------
    # multiple client grouping
    #-------------------------------------------------------------------------

    ##
    # Checks if this client is included in the current grouping.
    #
    def group?
      tags.include? CLIENT_GROUPING_TAG
    end

    ##
    # Adds this client to the current grouping.
    #
    def group
      with_tags do
        push CLIENT_GROUPING_TAG
      end
    end

    ##
    # Removes this client to the current grouping.
    #
    def ungroup
      untag CLIENT_GROUPING_TAG
    end

    ##
    # Toggles the presence of this client in the current grouping.
    #
    def group!
      if group?
        ungroup
      else
        group
      end
    end

    private

    def reshape method, direction, view
      area = self.area(view)
      index = area.client_ids.index(@id) + 1 # numbered as 1..N
      view.ctl.write "#{method} #{area.id} #{index} #{direction}"
    end

    ##
    # Returns the wmii ID of the given area.
    #
    def area_to_id area_or_id
      if area_or_id.respond_to? :id
        id = area_or_id.id
        id == FLOATING_AREA_ID ? :toggle : id
      else
        area_or_id
      end
    end
  end

  ##
  # @note Inheritors should override the {client_ids} method.
  #
  module ClientContainer
    ##
    # Returns the IDs of the clients in this container.
    #
    def client_ids
      []
    end

    ##
    # Returns the clients contained in this container.
    #
    def clients
      client_ids.map! {|i| Client.new i }
    end

    # multiple client grouping
    %w[group ungroup group!].each do |meth|
      define_method meth do
        clients.each do |c|
          c.__send__ meth
        end
      end
    end

    ##
    # Returns all grouped clients in this container.
    #
    def grouping
      clients.select {|c| c.group? }
    end
  end

  ##
  # A region that contains clients. This can be either
  # the floating area or a column in the managed area.
  #
  class Area
    attr_reader :view

    ##
    # @param [Rumai::View] view
    #   the view object which contains this area
    #
    def initialize area_id, view = View.curr
      @id = Integer(area_id) rescue area_id
      @view = view
    end

    ##
    # Checks if this area is the floating area.
    #
    def floating?
      @id == FLOATING_AREA_ID
    end

    ##
    # Checks if this is a managed area (a column).
    #
    def column?
      not floating?
    end

    alias managed? column?

    #-------------------------------------------------------------------------
    include WidgetImpl
    #-------------------------------------------------------------------------

    ##
    # Returns the currently focused area.
    #
    def self.curr
      View.curr.area_of_client Client.curr
    end

    ##
    # Returns the floating area in the given view.
    #
    def self.floating view = View.curr
      new FLOATING_AREA_ID, view
    end

    #-------------------------------------------------------------------------
    include Chain
    #-------------------------------------------------------------------------

    ##
    # Returns a list of all areas in the current view.
    #
    def chain
      @view.areas
    end

    ##
    # Checks if this object exists in the chain.
    #
    def exist?
      chain.include? self
    end

    #-------------------------------------------------------------------------
    include ClientContainer
    #-------------------------------------------------------------------------

    ##
    # Returns the IDs of the clients in this area.
    #
    def client_ids
      @view.client_ids @id
    end

    #-------------------------------------------------------------------------
    include Enumerable
    #-------------------------------------------------------------------------

    ##
    # Iterates through each client in this container.
    #
    def each &block
      clients.each(&block)
    end

    #-------------------------------------------------------------------------
    # WM operations
    #-------------------------------------------------------------------------

    ##
    # Puts focus on this area.
    #
    def focus
      @view.ctl.write "select #{@id}"
    end

    ##
    # Sets the layout of clients in this column.
    #
    def layout= mode
      case mode
      when :stack then mode = 'stack-max'
      when :max   then mode = 'stack+max'
      end

      @view.ctl.write "colmode #{@id} #{mode}"
    end

    #-------------------------------------------------------------------------
    # array abstraction: area is an array of clients
    #-------------------------------------------------------------------------

    ##
    # Returns the number of clients in this area.
    #
    def length
      client_ids.length
    end

    ##
    # Inserts the given clients at the bottom of this area.
    #
    def push *clients
      clients.flatten!
      return if clients.empty?

      insert clients

      # move inserted clients to bottom
      clients.reverse.each_with_index do |c, i|
        until c.id == self.client_ids[-i.succ]
          c.send :down
        end
      end
    end

    alias << push

    ##
    # Inserts the given clients after the
    # currently focused client in this area.
    #
    def insert *clients
      clients.flatten!
      return if clients.empty?

      clients.each do |c|
        import_client c
      end
    end

    ##
    # Inserts the given clients at the top of this area.
    #
    def unshift *clients
      clients.flatten!
      return if clients.empty?

      insert clients

      # move inserted clients to top
      clients.each_with_index do |c, i|
        until c.id == self.client_ids[i]
          c.send :up
        end
      end
    end

    ##
    # Concatenates the given area to the bottom of this area.
    #
    def concat area
      push area.clients
    end

    ##
    # Ensures that this area has at most the given number of clients.
    #
    # Areas to the right of this one serve as a buffer into which excess
    # clients are evicted and from which deficit clients are imported.
    #
    def length= max_clients
      return unless max_clients > 0
      len, out = length, fringe

      if len > max_clients
        out.unshift clients[max_clients..-1]

      elsif len < max_clients
        until (diff = max_clients - length) == 0
          importable = out.clients[0, diff]
          break if importable.empty?

          push importable
        end
      end
    end

    private

    ##
    # Moves the given client into this area.
    #
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

    ##
    # Returns the next area, which may or may not exist.
    #
    def fringe
      Area.new @id.next, @view
    end
  end

  ##
  # The visualization of a tag.
  #
  class View < WidgetNode
    def initialize view_id
      super view_id, '/tag'
    end

    #-------------------------------------------------------------------------
    include WidgetImpl
    #-------------------------------------------------------------------------

    ##
    # Returns the currently focused view.
    #
    def self.curr
      new FOCUSED_WIDGET_ID
    end

    ##
    # Focuses this view.
    #
    def focus
      IXP_FS_ROOT.ctl.write "view #{@id}"
    end

    #-------------------------------------------------------------------------
    include Chain
    #-------------------------------------------------------------------------

    ##
    # Returns a list of all views.
    #
    def chain
      Rumai.views
    end

    #-------------------------------------------------------------------------
    include ClientContainer
    #-------------------------------------------------------------------------

    ##
    # Returns the IDs of the clients contained
    # in the given area within this view.
    #
    def client_ids area_id = '\S+'
      manifest.scan(/^#{area_id} (0x\S+)/).flatten
    end

    #-------------------------------------------------------------------------
    include Enumerable
    #-------------------------------------------------------------------------

    ##
    # Iterates through each area in this view.
    #
    def each &block
      areas.each(&block)
    end

    #-----------------------------------------------------------------------
    # WM operations
    #-----------------------------------------------------------------------

    ##
    # Returns the manifest of all areas and clients in this view.
    #
    def manifest
      index.read || ''
    end

    ##
    # Moves the focus from the current client in the given direction.
    #
    def select direction
      ctl.write "select #{direction}"
    end

    #-----------------------------------------------------------------------
    # WM hierarchy
    #-----------------------------------------------------------------------

    ##
    # Returns the area which contains the given client in this view.
    #
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

    ##
    # Returns the IDs of all areas in this view.
    #
    def area_ids
      manifest.scan(/^# (\d+)/).flatten.unshift(FLOATING_AREA_ID)
    end

    ##
    # Returns all areas in this view.
    #
    def areas
      area_ids.map! {|i| Area.new i, self }
    end

    ##
    # Returns the floating area of this view.
    #
    def floating_area
      Area.floating self
    end

    ##
    # Returns all columns (managed areas) in this view.
    #
    def columns
      areas[1..-1]
    end

    alias managed_areas columns

    ##
    # Resiliently iterates through possibly destructive changes to
    # each column.  That is, if the given block creates new
    # columns, then those will also be processed in the iteration.
    #
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

    alias each_managed_area each_column

    #-------------------------------------------------------------------------
    # visual arrangement of clients
    #-----------------------------------------------------------------------

    ##
    # Arranges the clients in this view, while maintaining
    # their relative order, in the tiling fashion of LarsWM.
    #
    # Only the first client in the primary column is kept; all others
    # are evicted to the *top* of the secondary column.  Any subsequent
    # columns are squeezed into the *bottom* of the secondary column.
    #
    def arrange_as_larswm
      maintain_focus do
        # keep only one client in the primary column
        main = Area.new(1, self)
        main.length = 1
        main.layout = :default

        # collapse remaining areas into secondary column
        extra = squeeze_columns(1..-1)

        if dock = extra.first
          dock.layout = :default
        end
      end
    end

    ##
    # Arranges the clients in this view, while maintaining
    # their relative order, in a (at best) square grid.
    #
    def arrange_in_grid max_clients_per_column = nil
      # compute client distribution
      unless max_clients_per_column
        num_clients = num_managed_clients
        return unless num_clients > 0

        num_columns = Math.sqrt(num_clients)
        max_clients_per_column = (num_clients / num_columns).round
      end

      return if max_clients_per_column < 1

      # apply the distribution
      maintain_focus do
        each_column do |a|
          a.length = max_clients_per_column
          a.layout = :default
        end
      end
    end

    ##
    # Arranges the clients in this view, while maintaining
    # their relative order, in the given number of columns.
    #
    def arrange_in_stacks num_stacks
      return if num_stacks < 1

      # compute client distribution
      num_clients = num_managed_clients
      return unless num_clients > 0

      stack_length = num_clients / num_stacks
      return if stack_length < 1

      # apply the distribution
      maintain_focus do
        each_column do |a|
          a.length = stack_length
          a.layout = :stack
        end

        squeeze_columns num_stacks-1..-1
      end
    end

    ##
    # Arranges the clients in this view, while
    # maintaining their relative order, in a (at
    # best) equilateral triangle.  However, the
    # resulting arrangement appears like a diamond
    # because wmii does not waste screen space.
    #
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

      # quantify overall triangle as a sequence of heights
      rise_seq = (1..span).to_a
      fall_seq = rise_seq.reverse

      heights = rise_seq
      heights << peak if peak > 0
      heights.concat fall_seq

      # apply the heights
      maintain_focus do
        each_column do |col|
          if h = heights.shift
            col.length = h
            col.layout = :default
          end
        end
      end
    end

    private

    ##
    # Squeezes all columns in the given index range into a single one.
    #
    def squeeze_columns range
      extra = columns[range]

      if extra.length > 1
        extra.reverse.each_cons(2) do |src, dst|
          dst.concat src
        end
      end

      extra
    end

    ##
    # Executes the given block and restores
    # focus to the client that had focus
    # before the given block was executed.
    #
    def maintain_focus
      c, v = Client.curr, View.curr
      yield
      c.focus v
    end

    ##
    # Returns the number of clients in the non-floating areas of this view.
    #
    def num_managed_clients
      manifest.scan(/^\d+ 0x/).length
    end
  end

  ##
  # Subdivision of the bar---the thing that spans the width of the
  # screen---useful for displaying information and system controls.
  #
  class Barlet < Node
    attr_reader :side

    def initialize file_name, side
      prefix =
        case @side = side
        when :left then '/lbar'
        when :right then '/rbar'
        else raise ArgumentError, side
        end

      super "#{prefix}/#{file_name}"
    end

    COLORS_REGEXP = /^\S+ \S+ \S+/

    def label
      case read
      when /^label (.*)$/ then $1
      when /#{COLORS_REGEXP} (.*)$/o then $1
      end
    end

    def colors
      case read
      when /^colors (.*)$/ then $1
      when COLORS_REGEXP then $&
      end
    end

    # detect the new bar file format introduced in wmii-hg2743
    temp_barlet = IXP_FS_ROOT.rbar["temp_barlet_#{object_id}"]
    begin
      temp_barlet.create
      SPLIT_FILE_FORMAT = temp_barlet.read =~ /\Acolors/
    ensure
      temp_barlet.remove
    end

    def label= label
      if SPLIT_FILE_FORMAT
        write "label #{label}"
      else
        write "#{colors} #{label}"
      end
    end

    def colors= colors
      if SPLIT_FILE_FORMAT
        write "colors #{colors}"
      else
        write "#{colors} #{label}"
      end
    end
  end

  #---------------------------------------------------------------------------
  # access to global WM state
  #---------------------------------------------------------------------------

  ##
  # Returns the root of IXP file system hierarchy.
  #
  def fs
    IXP_FS_ROOT
  end

  ##
  # Returns the current set of tags.
  #
  def tags
    ary = IXP_FS_ROOT.tag.entries.sort
    ary.delete FOCUSED_WIDGET_ID
    ary
  end

  ##
  # Returns the current set of views.
  #
  def views
    tags.map! {|t| View.new t }
  end

  ##
  # Returns a list of all grouped clients in
  # the currently focused view. If there are
  # no grouped clients, then the currently
  # focused client is returned in the list.
  #
  def grouping
    list = curr_view.clients.select {|c| c.group? }
    list << curr_client if list.empty? and curr_client.exist?
    list
  end

  #---------------------------------------------------------------------------
  include ClientContainer
  #---------------------------------------------------------------------------

  ##
  # Returns the IDs of the current set of clients.
  #
  def client_ids
    ary = IXP_FS_ROOT.client.entries
    ary.delete FOCUSED_WIDGET_ID
    ary
  end

  #---------------------------------------------------------------------------
  # shortcuts for interactive WM manipulation (via IRB)
  #---------------------------------------------------------------------------

  def curr_client ; Client.curr       ; end
  def next_client ; curr_client.next  ; end
  def prev_client ; curr_client.prev  ; end

  def curr_area   ; Area.curr         ; end
  def next_area   ; curr_area.next    ; end
  def prev_area   ; curr_area.prev    ; end

  def curr_view   ; View.curr         ; end
  def next_view   ; curr_view.next    ; end
  def prev_view   ; curr_view.prev    ; end

  def curr_tag    ; curr_view.id      ; end
  def next_tag    ; next_view.id      ; end
  def prev_tag    ; prev_view.id      ; end

  # provide easy access to container state information
  [Client, Area, View].each {|c| c.extend ExportInstanceMethods }

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
  extend self
end
