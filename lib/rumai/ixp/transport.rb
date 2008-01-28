# Transport layer for 9P2000 protocol.
#--
# Copyright 2007 Suraj N. Kurapati
# See the file named LICENSE for details.

require 'message'
require 'thread' # for Mutex

module Rumai
  module IXP
    # A thread-safe proxy that multiplexes many
    # threads onto a single 9P2000 connection.
    class Agent
      attr_reader :msize

      def initialize aStream
        @stream   = aStream
        @sendLock = Mutex.new
        @recvBays = Hash.new {|h,k| h[k] = Queue.new } # tag => Queue(message)

        # background thread which continuously receives
        # and dispatches messages from the 9P2000 server
        Thread.new do
          while true
            msg = Fcall.from_9p @stream
            @recvBays[msg.tag] << msg
          end
        end.priority = -1

        @tagPool = RangedPool.new(0...BYTE2_MASK)
        @fidPool = RangedPool.new(0...BYTE4_MASK)

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
        @authFid = Fcall::NOFID

        # attach to filesystem root
        @rootFid = @fidPool.obtain
        attach @rootFid, @authFid
      end

      # A finite, thread-safe pool of range members.
      class RangedPool
        # how many new members should be added to the pool when the pool is empty?
        FILL_RATE = 10

        def initialize aRange
          @pos = aRange.first
          @lim = aRange.last
          @lim = @lim.succ unless aRange.exclude_end?

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
        def release aMember
          @pool << aMember
        end
      end

      # Sends the given message (Rumai::IXP::Fcall) and returns its response.
      #
      # This method allows you to perform a 9P2000 transaction without
      # worrying about the details of tag collisions and thread safety.
      #
      def talk aRequest
        # send the request
        tag = @tagPool.obtain
        bay = @recvBays[tag]

        aRequest.tag = tag
        output = aRequest.to_9p
        @sendLock.synchronize do
          @stream << output
        end

        # receive the response
        response = bay.shift
        @tagPool.release tag

        if response.is_a? Rerror
          raise Error, "#{response.ename.inspect} in response to #{aRequest.inspect}"
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
      def MODES.parse aMode
        if aMode.respond_to? :split
          aMode.split(//).inject(0) { |m,c| m | self[c].to_i }
        else
          aMode.to_i
        end
      end

      # Opens the given path for I/O access through a FidStream
      # object.  If a block is given, it is invoked with a
      # FidStream object and the stream is closed afterwards.
      #
      # See File::open in the Ruby documentation.
      def open aPath, aMode = 'r' # :yields: FidStream
        mode = MODES.parse(aMode)

        # open the file
        pathFid = walk(aPath)

        talk Topen.new(
          :fid  => pathFid,
          :mode => mode
        )

        stream = FidStream.new(self, pathFid, @msize)

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
      class FidStream
        attr_reader :fid

        def initialize aAgent, aPathFid, aMessageSize
          @agent  = aAgent
          @fid    = aPathFid
          @msize  = aMessageSize
          @stat   = @agent.stat_fid @fid
          @closed = false
        end

        # Closes this stream.
        def close
          unless @closed
            @agent.clunk @fid
            @closed = true
          end
        end

        # Returns the entire content of this stream.  If this
        # stream corresponds to a directory, then an Array of Stat
        # (one for each file in the directory) will be returned.
        def read
          raise 'cannot read from a closed stream' if @closed

          content = ''
          offset = 0

          begin
            chunk = read_partial(offset)
            content << chunk

            count = chunk.length
            offset = (offset + count) % BYTE8_LIMIT
          end until count < @msize

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

        # Returns the maximum amount of content that can fit in
        # one 9P2000 message, starting from the given offset.
        #
        # The end of file is reached when the returned
        # content string is empty (has zero length).
        def read_partial aOffset = 0
          raise 'cannot read from a closed stream' if @closed

          req = Tread.new(
            :fid    => @fid,
            :offset => aOffset,
            :count  => @msize
          )
          rsp = @agent.talk(req)
          rsp.data
        end

        # Writes the given content to the beginning of this stream.
        def write aContent
          raise 'closed streams cannot be written to' if @closed
          raise 'directories cannot be written to' if @stat.directory?

          offset = 0
          content = aContent.to_s

          while offset < content.length
            chunk = content[offset, @msize]

            req = Twrite.new(
              :fid    => @fid,
              :offset => offset,
              :count  => chunk.length,
              :data   => chunk
            )
            rsp = @agent.talk(req)

            offset += rsp.count
          end
        end

        alias << write
      end

      # Returns the content of the file/directory at the given path.
      def read aPath
        open aPath do |f|
          f.read
        end
      end

      # Returns the names of all files inside the directory whose path is given.
      def entries aPath
        unless stat(aPath).directory?
          raise ArgumentError, "#{aPath.inspect} is not a directory"
        end

        read(aPath).map! {|t| t.name}
      end

      # Returns the content of the file/directory at the given path.
      def write aPath, aContent
        open aPath, 'w' do |f|
          f << aContent
        end
      end

      # Creates a new file at the given path that is accessible using
      # the given modes for a user having the given permission bits.
      def create aPath, aMode = 'rw', aPerm = 0644
        prefix = File.dirname(aPath)
        target = File.basename(aPath)

        mode = MODES.parse(aMode)

        with_fid do |prefixFid|
          walk_fid prefixFid, prefix

          # create the file
          talk Tcreate.new(
            :fid => prefixFid,
            :name => target,
            :perm => aPerm,
            :mode => mode
          )
        end
      end

      # Deletes the file at the given path.
      def remove aPath
        pathFid = walk(aPath)
        remove_fid pathFid # remove also does clunk
      end

      # Deletes the file corresponding to the
      # given FID and clunks the given FID.
      def remove_fid aPathFid
        talk Tremove.new(:fid => aPathFid)
      end

      # Returns information about the file at the given path.
      def stat aPath
        with_fid do |pathFid|
          walk_fid pathFid, aPath
          stat_fid pathFid
        end
      end

      # Returns information about the file referenced by the given FID.
      def stat_fid aPathFid
        req = Tstat.new(:fid => aPathFid)
        rsp = talk(req)
        rsp.stat
      end

      # Returns an FID corresponding to the given path.
      def walk aPath
        fid = @fidPool.obtain
        walk_fid fid, aPath
        fid
      end

      # Associates the given FID to the given path.
      def walk_fid aPathFid, aPath
        talk Twalk.new(
          :fid    => @rootFid,
          :newfid => aPathFid,
          :wname  => aPath.to_s.split(%r{/+}).reject { |s| s.empty? }
        )
      end

      # Associates the given FID with the FS root.
      def attach aRootFid, aAuthFid = Fcall::NOFID, aAuthName = ENV['USER']
        talk Tattach.new(
          :fid    => aRootFid,
          :afid   => aAuthFid,
          :uname  => ENV['USER'],
          :aname  => aAuthName
        )
      end

      # Retires the given FID from use.
      def clunk aFid
        talk Tclunk.new(:fid => aFid)
        @fidPool.release aFid
      end

      private

      # Invokes the given block with a temporary FID.
      def with_fid # :yields: fid
        begin
          fid = @fidPool.obtain
          yield fid
        ensure
          clunk fid
        end
      end
    end
  end
end
