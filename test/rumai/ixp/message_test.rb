require 'rumai/fs'
require 'pp' if $VERBOSE

class MessageTest < MiniTest::Spec
  include Rumai::IXP

  before do
    # connect to the wmii IXP server
    @conn = UNIXSocket.new(Rumai::IXP_SOCK_ADDR)

    # at_exit do
    #   puts "just making sure there is no more data in the pipe"
    #   while c = @conn.getc
    #     puts c
    #   end
    # end

    # establish a new session
    request, response = talk(Tversion,
      :tag     => Fcall::NOTAG,
      :msize   => Tversion::MSIZE,
      :version => Tversion::VERSION
    )
    response.type.must_equal Rversion.type
    response.version.must_equal request.version
  end

  it 'can read a directory' do
    # attach to FS root
    request, response = talk(Tattach,
      :tag   => 0,
      :fid   => 0,
      :afid  => Fcall::NOFID,
      :uname => ENV['USER'],
      :aname => ''
    )
    response.type.must_equal Rattach.type

    # stat FS root
    request, response = talk(Tstat,
      :tag => 0,
      :fid => 0
    )
    response.type.must_equal Rstat.type

    # open the FS root for reading
    request, response = talk(Topen,
      :tag  => 0,
      :fid  => 0,
      :mode => Topen::OREAD
    )
    response.type.must_equal Ropen.type

    # fetch a Stat for every file in FS root
    request, response = talk(Tread,
      :tag    => 0,
      :fid    => 0,
      :offset => 0,
      :count  => Tversion::MSIZE
    )
    response.type.must_equal Rread.type

    if $VERBOSE
      buffer = StringIO.new(response.data, 'r')
      stats = []

      until buffer.eof?
        stats << Stat.from_9p(buffer)
      end

      puts '--- stats'
      pp stats
    end

    # close the fid for FS root
    request, response = talk(Tclunk,
      :tag    => 0,
      :fid    => 0
    )
    response.type.must_equal Rclunk.type

    # closed fid should not be readable
    request, response = talk(Tread,
      :tag    => 0,
      :fid    => 0,
      :offset => 0,
      :count  => Tversion::MSIZE
    )
    response.type.must_equal Rerror.type
  end

  it 'can read & write a file' do
    root_path = ['rbar']
    file_name = "temp#{$$}"
    file_path = root_path + [file_name]

    # attach to /
    request, response = talk(Tattach,
      :tag   => 0,
      :fid   => 0,
      :afid  => Fcall::NOFID,
      :uname => ENV['USER'],
      :aname => ''
    )
    response.type.must_equal Rattach.type

    # walk to /rbar
    request, response = talk(Twalk,
      :tag    => 0,
      :fid    => 0,
      :newfid => 1,
      :wname  => root_path
    )
    response.type.must_equal Rwalk.type

    # create the file
    request, response = talk(Tcreate,
      :tag  => 0,
      :fid  => 1,
      :name => file_name,
      :perm => 0644,
      :mode => Topen::ORDWR
    )
    response.type.must_equal Rcreate.type

    # close the fid for /rbar
    request, response = talk(Tclunk,
      :tag => 0,
      :fid => 1
    )
    response.type.must_equal Rclunk.type

    # walk to the file from /
    request, response = talk(Twalk,
      :tag    => 0,
      :fid    => 0,
      :newfid => 1,
      :wname  => file_path
    )
    response.type.must_equal Rwalk.type

    # close the fid for /
    request, response = talk(Tclunk,
      :tag => 0,
      :fid => 0
    )
    response.type.must_equal Rclunk.type

    # open the file for writing
    request, response = talk(Topen,
      :tag  => 0,
      :fid  => 1,
      :mode => Topen::ORDWR
    )
    response.type.must_equal Ropen.type

    # write to the file
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
    write_response.type.must_equal Rwrite.type
    write_response.count.must_equal write_request.data.bytesize

    # verify the write
    read_request, read_response = talk(Tread,
      :tag    => 0,
      :fid    => 1,
      :offset => 0,
      :count  => write_response.count
    )
    read_response.type.must_equal Rread.type
    # wmii responds in ASCII-8BIT whereas we requested in UTF-8
    read_response.data.force_encoding(message.encoding).must_equal write_request.data

    # remove the file
    request, response = talk(Tremove,
      :tag => 0,
      :fid => 1
    )
    response.type.must_equal Rremove.type

    # fid for the file should have been closed by Tremove
    request, response = talk(Tclunk,
      :tag => 0,
      :fid => 1
    )
    response.type.must_equal Rerror.type
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
      response.must_be_kind_of Rerror
    else
      response.type.must_equal request.type + 1
    end

    response.tag.must_equal request.tag

    # return the conversation
    [request, response]
  end

end
