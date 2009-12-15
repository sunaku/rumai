#--
# Copyright protects this work.
# See LICENSE file for details.
#++

require 'pp' if $DEBUG
require 'dfect/nice'
require 'socket'

test 'IXP' do
  extend Rumai::IXP

  prepare! do
    # connect to the wmii IXP server
    @conn = UNIXSocket.new(Rumai::IXP_SOCK_ADDR)

    # at_exit do
    #   puts "just making sure there is no more data in the pipe"
    #   while c = @conn.getc
    #     puts c
    #   end
    # end

    test 'establish a new session' do
      request, response = talk Tversion.new(
        :tag     => Fcall::NOTAG,
        :msize   => Tversion::MSIZE,
        :version => Tversion::VERSION
      )
      aver { response.type == Rversion.type }
      aver { response.version == request.version }
    end
  end

  test 'can read a directory' do
    test 'attach to FS root' do
      request, response = talk Tattach.new(
        :tag   => 0,
        :fid   => 0,
        :afid  => Fcall::NOFID,
        :uname => ENV['USER'],
        :aname => ''
      )
      aver { response.type == Rattach.type }
    end

    test 'stat FS root' do
      request, response = talk Tstat.new(
        :tag => 0,
        :fid => 0
      )
      aver { response.type == Rstat.type }
    end

    test 'open the FS root for reading' do
      request, response = talk Topen.new(
        :tag  => 0,
        :fid  => 0,
        :mode => Topen::OREAD
      )
      aver { response.type == Ropen.type }
    end

    test 'fetch a Stat for every file in FS root' do
      request, response = talk Tread.new(
        :tag    => 0,
        :fid    => 0,
        :offset => 0,
        :count  => Tversion::MSIZE
      )
      aver { response.type == Rread.type }

      if $DEBUG
        s = StringIO.new(response.data, 'r')
        a = []

        until s.eof?
          t = Stat.from_9p(s)
          a << t
        end

        pp a
      end
    end

    test 'close the fid for FS root' do
      request, response = talk Tclunk.new(
        :tag    => 0,
        :fid    => 0
      )
      aver { response.type == Rclunk.type }
    end

    test 'closed fid should not be readable' do
      request, response = talk Tread.new(
        :tag    => 0,
        :fid    => 0,
        :offset => 0,
        :count  => Tversion::MSIZE
      )
      aver { response.type == Rerror.type }
    end
  end

  D 'can read & write a file' do
    test 'attach to /' do
      request, response = talk Tattach.new(
        :tag   => 0,
        :fid   => 0,
        :afid  => Fcall::NOFID,
        :uname => ENV['USER'],
        :aname => ''
      )
      aver { response.type == Rattach.type }
    end

    file = %W[rbar temp#{$$}]
    root = file[0..-2]
    leaf = file.last

    test "walk to #{root.inspect}" do
      request, response = talk Twalk.new(
        :tag    => 0,
        :fid    => 0,
        :newfid => 1,
        :wname => root
      )
      aver { response.type == Rwalk.type }
    end

    test "create #{leaf.inspect}" do
      request, response = talk Tcreate.new(
        :tag  => 0,
        :fid  => 1,
        :name => leaf,
        :perm => 0644,
        :mode => Topen::ORDWR
      )
      aver { response.type == Rcreate.type }
    end

    test "close the fid for #{root.inspect}" do
      request, response = talk Tclunk.new(
        :tag => 0,
        :fid => 1
      )
      aver { response.type == Rclunk.type }
    end

    test "walk to #{file.inspect} from /" do
      request, response = talk Twalk.new(
        :tag    => 0,
        :fid    => 0,
        :newfid => 1,
        :wname => file
      )
      aver { response.type == Rwalk.type }
    end

    test 'close the fid for /' do
      request, response = talk Tclunk.new(
        :tag => 0,
        :fid => 0
      )
      aver { response.type == Rclunk.type }
    end

    test "open #{file.inspect} for writing" do
      request, response = talk Topen.new(
        :tag  => 0,
        :fid  => 1,
        :mode => Topen::ORDWR
      )
      aver { response.type == Ropen.type }
    end

    test "write to #{file.inspect}" do
      write_request, write_response = talk Twrite.new(
        :tag    => 0,
        :fid    => 1,
        :offset => 0,
        :data   => "#a1a2a3 #b1b2b3 #c1c2c3 hello world!!!"
      )
      aver { write_response.type == Rwrite.type }
      aver { write_response.count == write_request.data.length }

      test "verify the write" do
        read_request, read_response = talk Tread.new(
          :tag    => 0,
          :fid    => 1,
          :offset => 0,
          :count  => write_response.count
        )
        aver { read_response.type == Rread.type }
        aver { read_response.data == write_request.data }
      end
    end

    test "remove #{file.inspect}" do
      request, response = talk Tremove.new(
        :tag => 0,
        :fid => 1
      )
      aver { response.type == Rremove.type }
    end

    test "fid for #{file.inspect} should have been closed by Tremove" do
      request, response = talk Tclunk.new(
        :tag => 0,
        :fid => 1
      )
      aver { response.type == Rerror.type }
    end
  end

  ##
  # Transmits the given request and returns the received response.
  #
  def talk request
    # send the request
    if $DEBUG
      puts
      pp request
      pp request.to_9p
    end

    @conn << request.to_9p

    # receive the response
    response = Fcall.from_9p(@conn)

    if $DEBUG
      puts
      pp response
      pp response.to_9p
    end

    if response.type == Rerror.type
      aver { response.kind_of? Rerror }
    else
      aver { response.type == request.type + 1 }
    end

    aver { response.tag == request.tag }

    # return the conversation
    [request, response]
  end
end
