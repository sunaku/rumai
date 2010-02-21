# Transport layer for 9P2000 protocol.
#--
# Copyright protects this work.
# See LICENSE file for details.
#++

require 'rumai/ixp/message'
require 'thread' # for Mutex and Queue

module Rumai
  module IXP
    ##
    # A thread-safe channel that multiplexes many
    # threads onto a single 9P2000 connection.
    #
    # The send/recv implementation is based on the XCB cookie approach:
    # http://www.x.org/releases/X11R7.5/doc/libxcb/tutorial/#requestsreplies
    #
    class Agent
      attr_reader :msize

      ##
      # [stream]
      #   I/O stream on which a 9P2000 server is listening.
      #
      def initialize stream
        @stream = stream

        @recv_buf = {} # tag => message
        @recv_lock = Mutex.new

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

      ##
      # A finite, thread-safe pool of range members.
      #
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

        ##
        # Returns an unoccupied range member from the pool.
        #
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

        ##
        # Marks the given member as being unoccupied so
        # that it may be occupied again in the future.
        #
        def release member
          @pool << member
        end
      end

      ##
      # Sends the given request (Rumai::IXP::Fcall) and returns
      # a ticket that you can use later to receive the reply.
      #
      def send request
        tag = @tag_pool.obtain

        request.tag = tag
        @stream << request.to_9p

        tag
      end

      ##
      # Returns the reply for the given ticket, which was previously given
      # to you when you sent the corresponding request (Rumai::IXP::Fcall).
      #
      def recv tag
        loop do
          reply = @recv_lock.synchronize do
            if @recv_buf.key? tag
              @recv_buf.delete tag
            else
              # reply was not in receive buffer, so read
              # the next reply... hoping that it is ours

              next_reply_available =
                @recv_buf.empty? || begin
                  # check (in a non-blocking fashion) if
                  # the stream has reply for us right now
                  @stream.ungetc @stream.read_nonblock(1)
                  true
                rescue Errno::EAGAIN
                  # the stream is empty
                end

              if next_reply_available
                msg = Fcall.from_9p(@stream)

                if msg.tag == tag
                  msg
                else
                  # we got someone else's reply, so buffer
                  # it (for them to receive) and try again
                  @recv_buf[msg.tag] = msg
                  nil
                end
              end
            end
          end

          if reply
            @tag_pool.release tag

            if reply.is_a? Rerror
              raise Error, reply.ename
            end

            return reply
          else
            # give other threads a chance to receive
            Thread.pass
          end
        end
      end

      ##
      # Sends the given request (Rumai::IXP::Fcall) and returns its reply.
      #
      def talk request
        tag = send(request)

        begin
          recv tag
        rescue Error => e
          e.message << " -- in reply to #{request.inspect}"
          raise
        end
      end

      MODES = {
        'r' => Topen::OREAD,
        'w' => Topen::OWRITE,
        't' => Topen::ORCLOSE,
        '+' => Topen::ORDWR,
      }

      ##
      # Converts the given mode string into an integer.
      #
      def MODES.parse mode
        if mode.respond_to? :split
          mode.split(//).inject(0) {|m,c| m | self[c].to_i }
        else
          mode.to_i
        end
      end

      ##
      # Opens the given path for I/O access through a FidStream
      # object.  If a block is given, it is invoked with a
      # FidStream object and the stream is closed afterwards.
      #
      # See File::open in the Ruby documentation.
      #
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

      ##
      # Encapsulates I/O access over a file handle (fid).
      #
      # NOTE: this class is NOT thread safe!
      #
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
          @stat   = @agent.stat_fid(@fid)
          @closed = false
          rewind
        end

        ##
        # Rewinds the stream to the beginning.
        #
        def rewind
          @pos = 0
          @eof = false
        end

        ##
        # Closes this stream.
        #
        def close
          unless @closed
            @agent.clunk @fid
            @closed = true
            @eof = true
          end
        end

        ##
        # Returns true if this stream is closed.
        #
        def closed?
          @closed
        end

        ##
        # Reads some data from this stream at the current position.
        #
        # [partial]
        #   When false, the entire content of
        #   this stream is read and returned.
        #
        #   When true, the maximum amount of content that can fit
        #   inside a single 9P2000 message is read and returned.
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

        ##
        # Writes the given content at the current position in this stream.
        #
        def write content
          raise 'cannot write to a closed stream' if @closed
          raise 'cannot write to a directory' if @stat.directory?

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

      ##
      # Returns the content of the file/directory at the given path.
      #
      def read path, *args
        open path do |f|
          f.read(*args)
        end
      end

      ##
      # Returns the basenames of all files
      # inside the directory at the given path.
      #
      # See Dir::entries in the Ruby documentation.
      #
      def entries path
        unless stat(path).directory?
          raise ArgumentError, "#{path.inspect} is not a directory"
        end

        read(path).map! {|t| t.name}
      end

      ##
      # Writes the given content to
      # the file at the given path.
      #
      def write path, content
        open path, 'w' do |f|
          f << content
        end
      end

      ##
      # Creates a new file at the given path that is accessible using
      # the given modes for a user having the given permission bits.
      #
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

      ##
      # Deletes the file at the given path.
      #
      def remove path
        path_fid = walk(path)
        remove_fid path_fid # remove also does clunk
      end

      ##
      # Deletes the file corresponding to the
      # given FID and clunks the given FID.
      #
      def remove_fid path_fid
        talk Tremove.new(:fid => path_fid)
      end

      ##
      # Returns information about the file at the given path.
      #
      def stat path
        with_fid do |path_fid|
          walk_fid path_fid, path
          stat_fid path_fid
        end
      end

      ##
      # Returns information about the file referenced by the given FID.
      #
      def stat_fid path_fid
        req = Tstat.new(:fid => path_fid)
        rsp = talk(req)
        rsp.stat
      end

      ##
      # Returns an FID corresponding to the given path.
      #
      def walk path
        fid = @fid_pool.obtain
        walk_fid fid, path
        fid
      end

      ##
      # Associates the given FID to the given path.
      #
      def walk_fid path_fid, path
        talk Twalk.new(
          :fid    => @root_fid,
          :newfid => path_fid,
          :wname  => path.to_s.split(%r{/+}).reject {|s| s.empty? }
        )
      end

      ##
      # Associates the given FID with the FS root.
      #
      def attach root_fid, auth_fid = Fcall::NOFID, auth_name = ENV['USER']
        talk Tattach.new(
          :fid    => root_fid,
          :afid   => auth_fid,
          :uname  => ENV['USER'],
          :aname  => auth_name
        )
      end

      ##
      # Retires the given FID from use.
      #
      def clunk fid
        talk Tclunk.new(:fid => fid)
        @fid_pool.release fid
      end

      private

      ##
      # Invokes the given block with a temporary FID.
      #
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
