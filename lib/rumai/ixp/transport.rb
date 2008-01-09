# Transport layer for 9P2000 protocol.
#--
# Copyright 2007 Suraj N. Kurapati
# See the file named LICENSE for details.

require 'message'
require 'thread' # for Mutex

module IXP
  # A thread-safe proxy that multiplexes many
  # threads onto a single 9P2000 connection.
  class Agent
    attr_reader :msize

    def initialize aStream
      @stream    = aStream
      @sendLock  = Mutex.new
      @recvLock  = Mutex.new

      @responses = {} # tag => message
      @tagPool   = RangePool.new(0...BYTE2_MASK)

      @fidPool   = RangePool.new(0...BYTE4_MASK)
      @msize     = Tversion::MSIZE

      # establish connection with 9P2000 server
      req = Tversion.new(
        :tag     => Fcall::NOTAG,
        :msize   => Tversion::MSIZE,
        :version => Tversion::VERSION
      )
      rsp = talk(req)

      unless req.version == rsp.version
        raise IXP::Exception, "protocol mismatch: self=#{req.version.inspect} server=#{rsp.version.inspect}"
      end

      @msize = rsp.msize

      # authenticate the connection (not necessary for wmii)
      @authFid = Fcall::NOFID

      # attach to filesystem root
      @rootFid = @fidPool.obtain
      attach @rootFid, @authFid
    end

    # A thread-safe pool of range members.
    class RangePool
      def initialize aRange
        @range = aRange
        @used = []
        @lock = Mutex.new
      end

      # Returns an unoccupied member of the
      # range and marks it as being occupied.
      def obtain
        key = nil

        @lock.synchronize do
          key = @range.find {|r| not @used.include? r}
          raise RangeError, 'all members occupied' unless key

          @used << key
        end

        key
      end

      # Marks the given member as being unoccupied so
      # that it may be occupied again in the future.
      def release aKey
        @lock.synchronize do
          @used.delete aKey
        end
      end
    end

    # Sends the given message (IXP::Fcall) and returns its response.
    #
    # This method allows you to perform a 9P2000 transaction without
    # worrying about the details of tag collisions and thread safety.
    def talk aRequest
      # send the messsage
      aRequest.tag = @tagPool.obtain

      @sendLock.synchronize do
        @stream << aRequest.to_9p
      end

      # receive the response
      loop do
        # check for *my* response in the bucket
        if response = @recvLock.synchronize { @responses.delete aRequest.tag }
          @tagPool.release aRequest.tag

          if response.is_a? Rerror
            raise IXP::Exception, "#{response.ename.inspect} in response to #{aRequest.inspect}"

          elsif response.type != aRequest.type + 1
            raise IXP::Exception, "response's type must equal request's type + 1; request=#{aRequest.inspect} response=#{response.inspect}"

          else
            return response
          end

        # put the next response into the bucket
        else
          @recvLock.synchronize do
            response = Fcall.from_9p @stream
            @responses[response.tag] = response
          end
        end
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

      stream = FidStream.new(self, pathFid)

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

      def initialize aAgent, aPathFid
        @agent  = aAgent
        @fid    = aPathFid
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
        raise IXP::Exception, 'cannot read from a closed stream' if @closed

        content = ''
        offset = 0

        begin
          chunk = read_partial(offset)
          content << chunk

          count = chunk.length
          offset = (offset + count) % BYTE8_LIMIT

        end until count.zero?

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
        raise IXP::Exception, 'cannot read from a closed stream' if @closed

        req = Tread.new(
          :fid    => @fid,
          :offset => aOffset,
          :count  => @agent.msize
        )
        rsp = @agent.talk(req)
        rsp.data
      end

      # Writes the given content to the beginning of this stream.
      def write aContent
        raise IXP::Exception, 'closed streams cannot be written to' if @closed
        raise IXP::Exception, 'directories cannot be written to' if @stat.directory?

        offset = 0
        content = aContent.to_s

        while offset < content.length
          chunk = content[offset, @agent.msize]

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

    # Deletes the file corresponding to the given FID and clunks the given FID.
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
