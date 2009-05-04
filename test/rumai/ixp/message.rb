require 'pp' if $DEBUG

class << Object.new
  include Rumai::IXP

  D .< do
    unless defined? @conn
      # connect to the wmii IXP server
      require 'socket'
      @conn = UNIXSocket.new(Rumai::IXP_SOCK_ADDR)
    end

    # at_exit do
    #   puts "just making sure there is no more data in the pipe"
    #   while c = @conn.getc
    #     puts c
    #   end
    # end

    transaction 'establish a new session', Tversion.new(
      :tag     => Fcall::NOTAG,
      :msize   => Tversion::MSIZE,
      :version => Tversion::VERSION
    ) do |req, rsp|
      T { rsp.type == Rversion.type }
      T { rsp.version == req.version }
    end
  end

  D 'can read a directory' do
    transaction 'attach to FS root', Tattach.new(
      :tag   => 0,
      :fid   => 0,
      :afid  => Fcall::NOFID,
      :uname => ENV['USER'],
      :aname => ''
    ) do |req, rsp|
      T { rsp.type == Rattach.type }
    end

    transaction 'stat FS root', Tstat.new(
      :tag => 0,
      :fid => 0
    ) do |req, rsp|
      T { rsp.type == Rstat.type }
    end

    transaction 'open the FS root for reading', Topen.new(
      :tag  => 0,
      :fid  => 0,
      :mode => Topen::OREAD
    ) do |req, rsp|
      T { rsp.type == Ropen.type }
    end

    transaction 'fetch a Stat for every file in FS root', Tread.new(
      :tag    => 0,
      :fid    => 0,
      :offset => 0,
      :count  => Tversion::MSIZE
    ) do |req, rsp|
      T { rsp.type == Rread.type }

      if $DEBUG
        s = StringIO.new(rsp.data, 'r')
        a = []
        until s.eof?
          t = Stat.from_9p(s)
          a << t
        end
        pp a
      end
    end

    transaction 'close the fid for FS root', Tclunk.new(
      :tag    => 0,
      :fid    => 0
    ) do |req, rsp|
      T { rsp.type == Rclunk.type }
    end

    transaction 'closed fid should not be readable', Tread.new(
      :tag    => 0,
      :fid    => 0,
      :offset => 0,
      :count  => Tversion::MSIZE
    ) do |req, rsp|
      T { rsp.type == Rerror.type }
    end
  end

  D 'can read & write a file' do
    transaction 'attach to /', Tattach.new(
      :tag   => 0,
      :fid   => 0,
      :afid  => Fcall::NOFID,
      :uname => ENV['USER'],
      :aname => ''
    ) do |req, rsp|
      T { rsp.type == Rattach.type }
    end

    file = %W[rbar temp#{$$}]
    root = file[0..-2]
    leaf = file.last

    transaction "walk to #{root.inspect}", Twalk.new(
      :tag    => 0,
      :fid    => 0,
      :newfid => 1,
      :wname => root
    ) do |req, rsp|
      T { rsp.type == Rwalk.type }
    end

    transaction "create #{leaf.inspect}", Tcreate.new(
      :tag  => 0,
      :fid  => 1,
      :name => leaf,
      :perm => 0644,
      :mode => Topen::ORDWR
    ) do |req, rsp|
      T { rsp.type == Rcreate.type }
    end

    transaction "close the fid for #{root.inspect}", Tclunk.new(
      :tag => 0,
      :fid => 1
    ) do |req, rsp|
      T { rsp.type == Rclunk.type }
    end

    transaction "walk to #{file.inspect} from /", Twalk.new(
      :tag    => 0,
      :fid    => 0,
      :newfid => 1,
      :wname => file
    ) do |req, rsp|
      T { rsp.type == Rwalk.type }
    end

    transaction 'close the fid for /', Tclunk.new(
      :tag => 0,
      :fid => 0
    ) do |req, rsp|
      T { rsp.type == Rclunk.type }
    end

    transaction "open #{file.inspect} for writing", Topen.new(
      :tag  => 0,
      :fid  => 1,
      :mode => Topen::ORDWR
    ) do |req, rsp|
      T { rsp.type == Ropen.type }
    end

    write_req, write_rsp = transaction "write to #{file.inspect}", Twrite.new(
      :tag    => 0,
      :fid    => 1,
      :offset => 0,
      :data   => "hello world!!!"
    ) do |req, rsp|
      T { rsp.type == Rwrite.type }
      T { rsp.count == req.data.length }
    end

    transaction "verify stuff was written to #{file.inspect}", Tread.new(
      :tag    => 0,
      :fid    => 1,
      :offset => 0,
      :count  => write_rsp.count
    ) do |req, rsp|
      T { rsp.type == Rread.type }
      T { rsp.data == write_req.data }
    end

    transaction "remove #{file.inspect}", Tremove.new(
      :tag => 0,
      :fid => 1
    ) do |req, rsp|
      T { rsp.type == Rremove.type }
    end

    transaction "fid for #{file.inspect} should have been closed by Tremove", Tclunk.new(
      :tag => 0,
      :fid => 1
    ) do |req, rsp|
      T { rsp.type == Rerror.type }
    end
  end

  # Transmits the given request and returns the received response.
  def self.send_and_recv request
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
        T { response.kind_of? Rerror }
      else
        T { response.type == request.type + 1 }
      end

      T { response.tag == request.tag }

    response
  end

  def self.transaction description, request
    response = send_and_recv(request)
    yield request, response if block_given?
    [request, response]
  end
end
