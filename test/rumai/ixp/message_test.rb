require 'rumai/fs'
require 'pp' if $VERBOSE

D 'IXP' do
  extend Rumai::IXP

  D .<< do
    # connect to the wmii IXP server
    @conn = UNIXSocket.new(Rumai::IXP_SOCK_ADDR)

    # at_exit do
    #   puts "just making sure there is no more data in the pipe"
    #   while c = @conn.getc
    #     puts c
    #   end
    # end

    D 'establish a new session' do
      request, response = talk(Tversion,
        :tag     => Fcall::NOTAG,
        :msize   => Tversion::MSIZE,
        :version => Tversion::VERSION
      )
      T response.type == Rversion.type
      T response.version == request.version
    end
  end

  D 'can read a directory' do
    D 'attach to FS root' do
      request, response = talk(Tattach,
        :tag   => 0,
        :fid   => 0,
        :afid  => Fcall::NOFID,
        :uname => ENV['USER'],
        :aname => ''
      )
      T response.type == Rattach.type
    end

    D 'stat FS root' do
      request, response = talk(Tstat,
        :tag => 0,
        :fid => 0
      )
      T response.type == Rstat.type
    end

    D 'open the FS root for reading' do
      request, response = talk(Topen,
        :tag  => 0,
        :fid  => 0,
        :mode => Topen::OREAD
      )
      T response.type == Ropen.type
    end

    D 'fetch a Stat for every file in FS root' do
      request, response = talk(Tread,
        :tag    => 0,
        :fid    => 0,
        :offset => 0,
        :count  => Tversion::MSIZE
      )
      T response.type == Rread.type

      if $VERBOSE
        buffer = StringIO.new(response.data, 'r')
        stats = []

        until buffer.eof?
          stats << Stat.from_9p(buffer)
        end

        puts '--- stats'
        pp stats
      end
    end

    D 'close the fid for FS root' do
      request, response = talk(Tclunk,
        :tag    => 0,
        :fid    => 0
      )
      T response.type == Rclunk.type
    end

    D 'closed fid should not be readable' do
      request, response = talk(Tread,
        :tag    => 0,
        :fid    => 0,
        :offset => 0,
        :count  => Tversion::MSIZE
      )
      T response.type == Rerror.type
    end
  end

  D 'can read & write a file' do
    D 'attach to /' do
      request, response = talk(Tattach,
        :tag   => 0,
        :fid   => 0,
        :afid  => Fcall::NOFID,
        :uname => ENV['USER'],
        :aname => ''
      )
      T response.type == Rattach.type
    end

    file = %W[rbar temp#{$$}]
    root = file[0..-2]
    leaf = file.last

    D "walk to #{root.inspect}" do
      request, response = talk(Twalk,
        :tag    => 0,
        :fid    => 0,
        :newfid => 1,
        :wname => root
      )
      T response.type == Rwalk.type
    end

    D "create #{leaf.inspect}" do
      request, response = talk(Tcreate,
        :tag  => 0,
        :fid  => 1,
        :name => leaf,
        :perm => 0644,
        :mode => Topen::ORDWR
      )
      T response.type == Rcreate.type
    end

    D "close the fid for #{root.inspect}" do
      request, response = talk(Tclunk,
        :tag => 0,
        :fid => 1
      )
      T response.type == Rclunk.type
    end

    D "walk to #{file.inspect} from /" do
      request, response = talk(Twalk,
        :tag    => 0,
        :fid    => 0,
        :newfid => 1,
        :wname => file
      )
      T response.type == Rwalk.type
    end

    D 'close the fid for /' do
      request, response = talk(Tclunk,
        :tag => 0,
        :fid => 0
      )
      T response.type == Rclunk.type
    end

    D "open #{file.inspect} for writing" do
      request, response = talk(Topen,
        :tag  => 0,
        :fid  => 1,
        :mode => Topen::ORDWR
      )
      T response.type == Ropen.type
    end

    D "write to #{file.inspect}" do
      message = "\u{266A} hello world \u{266B}"
      write_request, write_response = talk(Twrite,
        :tag    => 0,
        :fid    => 1,
        :offset => 0,
        :data   => (
          require 'rumai/wm'
          if Rumai::Barlet::SPLIT_FILE_FORMAT
            "colors #000000 #000000 #000000\nlabel #{message}"
          else
            "#000000 #000000 #000000 #{message}"
          end
        )
      )
      T write_response.type == Rwrite.type
      T write_response.count == write_request.data.bytesize

      D "verify the write" do
        read_request, read_response = talk(Tread,
          :tag    => 0,
          :fid    => 1,
          :offset => 0,
          :count  => write_response.count
        )
        T read_response.type == Rread.type

        # wmii responds in ASCII-8BIT whereas we requested in UTF-8
        read_response.data.force_encoding message.encoding

        T read_response.data == write_request.data
      end
    end

    D "remove #{file.inspect}" do
      request, response = talk(Tremove,
        :tag => 0,
        :fid => 1
      )
      T response.type == Rremove.type
    end

    D "fid for #{file.inspect} should have been closed by Tremove" do
      request, response = talk(Tclunk,
        :tag => 0,
        :fid => 1
      )
      T response.type == Rerror.type
    end
  end

  ##
  # Transmits the given request and returns the received response.
  #
  def talk request_type, request_options
    request = request_type.new(request_options)

    # send the request
    if $VERBOSE
      puts '--- sending'
      pp request, request.to_9p
    end

    @conn << request.to_9p

    # receive the response
    response = Fcall.from_9p(@conn)

    if $VERBOSE
      puts '--- received'
      pp response, response.to_9p
    end

    if response.type == Rerror.type
      T response.kind_of? Rerror
    else
      T response.type == request.type + 1
    end

    T response.tag == request.tag

    # return the conversation
    [request, response]
  end
end
