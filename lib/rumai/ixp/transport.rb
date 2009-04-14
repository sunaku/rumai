# Transport layer for 9P2000 protocol.

require 'rumai/ixp/message'
require 'thread' # for Mutex

module Rumai
  module IXP
    # A thread-safe proxy that multiplexes many
    # threads onto a single 9P2000 connection.
    class Agent
      attr_reader :msize

      def initialize stream
        @stream   = stream
        @send_lock = Mutex.new
        @recv_bays = Hash.new {|h,k| h[k] = Queue.new } # tag => Queue(message)

        # background thread which continuously receives
        # and dispatches messages from the 9P2000 server
        Thread.new do
          while true
            msg = Fcall.from_9p @stream
            @recv_bays[msg.tag] << msg
          end
        end.priority = -1

        @tag_pool = RangedPool.new(0...BYTE2_MASK)
        @fid_pool = RangedPool.new(0...BYTE4_MASK)

        # establish connection with 9P2000 server
        req = Tversion.new(
          :tag     => Fcall::NOTAG,
          :msize   => Tversion::MSIZE,
          :version => Tversion::VERSION
        )
        rsp = talk(req)

        unless req.version == rsp.version
          raise Error, "protocol mismatch: self=#{req.version.inspect} server=#{rsp.version.inspect}"
        end

        @msize = rsp.msize

        # authenticate the connection (not necessary for wmii)
        @auth_fid = Fcall::NOFID

        # attach to filesystem root
        @root_fid = @fid_pool.obtain
        attach @root_fid, @auth_fid
      end

      # A finite, thread-safe pool of range members.
      class RangedPool
        # how many new members should be added
        # to the pool when the pool is empty?
        FILL_RATE = 10

        def initialize range
          @pos = range.first
          @lim = range.last
          @lim = @lim.succ unless range.exclude_end?

          @pool = Queue.new
        end

        # Returns an unoccupied range member from the pool.
        def obtain
          begin
            @pool.deq true

          rescue ThreadError
            # pool is empty, so fill it
            FILL_RATE.times do
              if @pos != @lim
                @pool << @pos
                @pos = @pos.succ
              else
                # range is exhausted, so give other threads
                # a chance to fill the pool before retrying
                Thread.pass
                break
              end
            end

            retry
          end
        end

        # Marks the given member as being unoccupied so
        # that it may be occupied again in the future.
        def release member
          @pool << member
        end
      end

      # Sends the given message (Rumai::IXP::Fcall) and returns its response.
      #
      # This method allows you to perform a 9P2000 transaction without
      # worrying about the details of tag collisions and thread safety.
      #
      def talk request
        # send the request
        tag = @tag_pool.obtain
        bay = @recv_bays[tag]

        request.tag = tag
        output = request.to_9p
        @send_lock.synchronize do
          @stream << output
        end

        # receive the response
        response = bay.shift
        @tag_pool.release tag

        if response.is_a? Rerror
          raise Error, "#{response.ename.inspect} in response to #{request.inspect}"
        else
          return response
        end
      end

      MODES = {
        'r' => Topen::OREAD,
        'w' => Topen::OWRITE,
        't' => Topen::ORCLOSE,
        '+' => Topen::ORDWR,
      }

      # Converts the given mode string into an integer.
      def MODES.parse mode
        if mode.respond_to? :split
          mode.split(//).inject(0) { |m,c| m | self[c].to_i }
        else
          mode.to_i
        end
      end

      # Opens the given path for I/O access through a FidStream
      # object.  If a block is given, it is invoked with a
      # FidStream object and the stream is closed afterwards.
      #
      # See File::open in the Ruby documentation.
      def open path, mode = 'r' # :yields: FidStream
        mode = MODES.parse(mode)

        # open the file
        path_fid = walk(path)

        talk Topen.new(
          :fid  => path_fid,
          :mode => mode
        )

        stream = FidStream.new(self, path_fid, @msize)

        # return the file stream
        if block_given?
          begin
            yield stream
          ensure
            stream.close
          end
        else
          stream
        end
      end

      # Encapsulates I/O access over a file handle (fid).
      # NOTE that this class is NOT thread-safe.
      class FidStream
        attr_reader :fid, :stat

        attr_reader :eof
        alias eof? eof

        attr_accessor :pos
        alias tell pos

        def initialize agent, path_fid, message_size
          @agent  = agent
          @fid    = path_fid
          @msize  = message_size
          @stat   = @agent.stat_fid @fid
          @closed = false
          rewind
        end

        # Rewinds the stream to the beginning.
        def rewind
          @pos = 0
          @eof = false
        end

        # Closes this stream.
        def close
          unless @closed
            @agent.clunk @fid
            @closed = true
            @eof = true
          end
        end

        # Returns true if this stream is closed.
        def closed?
          @closed
        end

        # Reads some data from this stream at the current position.
        #
        # partial:: When false, the entire content of this stream
        #            is read and returned.  When true, the maximum
        #            amount of content that can fit inside a
        #            single 9P2000 message is read and returned.
        #
        # If this stream corresponds to a directory, then an Array of
        # Stat (one for each file in the directory) will be returned.
        #
        def read partial = false
          raise 'cannot read from a closed stream' if @closed

          content = ''
          begin
            req = Tread.new(
              :fid    => @fid,
              :offset => @pos,
              :count  => @msize
            )
            rsp = @agent.talk(req)

            content << rsp.data
            count = rsp.count
            @pos += count
          end until @eof = count.zero? or partial

          # the content of a directory is a sequence
          # of Stat for all files in that directory
          if @stat.directory?
            buffer = StringIO.new(content)
            content = []

            until buffer.eof?
              content << Stat.from_9p(buffer)
            end
          end

          content
        end

        # Writes the given content at the current position in this stream.
        def write content
          raise 'closed streams cannot be written to' if @closed
          raise 'directories cannot be written to' if @stat.directory?

          data = content.to_s
          limit = data.length + @pos

          while @pos < limit
            chunk = data[@pos, @msize]

            req = Twrite.new(
              :fid    => @fid,
              :offset => @pos,
              :count  => chunk.length,
              :data   => chunk
            )
            rsp = @agent.talk(req)

            @pos += rsp.count
          end
        end

        alias << write
      end

      # Returns the content of the file/directory at the given path.
      def read path, *args
        open path do |f|
          f.read(*args)
        end
      end

      # Returns the names of all files inside the directory whose path is given.
      def entries path
        unless stat(path).directory?
          raise ArgumentError, "#{path.inspect} is not a directory"
        end

        read(path).map! {|t| t.name}
      end

      # Returns the content of the file/directory at the given path.
      def write path, content
        open path, 'w' do |f|
          f << content
        end
      end

      # Creates a new file at the given path that is accessible using
      # the given modes for a user having the given permission bits.
      def create path, mode = 'rw', perm = 0644
        prefix = File.dirname(path)
        target = File.basename(path)

        mode = MODES.parse(mode)

        with_fid do |prefix_fid|
          walk_fid prefix_fid, prefix

          # create the file
          talk Tcreate.new(
            :fid => prefix_fid,
            :name => target,
            :perm => perm,
            :mode => mode
          )
        end
      end

      # Deletes the file at the given path.
      def remove path
        path_fid = walk(path)
        remove_fid path_fid # remove also does clunk
      end

      # Deletes the file corresponding to the
      # given FID and clunks the given FID.
      def remove_fid path_fid
        talk Tremove.new(:fid => path_fid)
      end

      # Returns information about the file at the given path.
      def stat path
        with_fid do |path_fid|
          walk_fid path_fid, path
          stat_fid path_fid
        end
      end

      # Returns information about the file referenced by the given FID.
      def stat_fid path_fid
        req = Tstat.new(:fid => path_fid)
        rsp = talk(req)
        rsp.stat
      end

      # Returns an FID corresponding to the given path.
      def walk path
        fid = @fid_pool.obtain
        walk_fid fid, path
        fid
      end

      # Associates the given FID to the given path.
      def walk_fid path_fid, path
        talk Twalk.new(
          :fid    => @root_fid,
          :newfid => path_fid,
          :wname  => path.to_s.split(%r{/+}).reject { |s| s.empty? }
        )
      end

      # Associates the given FID with the FS root.
      def attach root_fid, auth_fid = Fcall::NOFID, auth_name = ENV['USER']
        talk Tattach.new(
          :fid    => root_fid,
          :afid   => auth_fid,
          :uname  => ENV['USER'],
          :aname  => auth_name
        )
      end

      # Retires the given FID from use.
      def clunk fid
        talk Tclunk.new(:fid => fid)
        @fid_pool.release fid
      end

      private

      # Invokes the given block with a temporary FID.
      def with_fid # :yields: fid
        begin
          fid = @fid_pool.obtain
          yield fid
        ensure
          clunk fid
        end
      end
    end
  end
end
