require 'pp' if $DEBUG

##
# XXX: using an explicit class instead of Kernel#describe()
#      because, in Ruby 1.8, constants referenced in the blocks
#      are resolved in the scope where the block was defined, not
#      inside the class in which the block is being class_eval()ed.
#
#      Thankfully, this bug is fixed in Ruby 1.9! :-)
#      See this article for examples and proof:
#       http://www.pgrs.net/2007/9/12/ruby-constants-have-weird-behavior-in-class_eval/
#
#
# NOTE: this affects us because miniunit's Kernel#describe()
#       method evaluates its block using class_eval()
#
class The_IXP_library < MiniTest::Spec
  include Rumai::IXP

  before do
    unless defined? @conn
      # connect to the wmii IXP server
      addr = ENV['WMII_ADDRESS'].sub(/.*!/, '') rescue
      "/tmp/ns.#{ENV['USER']}.#{ENV['DISPLAY'] || ':0'}/wmii"

      require 'socket'
      @conn = UNIXSocket.new(addr)
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
      rsp.type.must_equal Rversion.type
      rsp.version.must_equal req.version
    end
  end

  it 'can read a directory' do
    transaction 'attach to FS root', Tattach.new(
      :tag   => 0,
      :fid   => 0,
      :afid  => Fcall::NOFID,
      :uname => ENV['USER'],
      :aname => ''
    ) do |req, rsp|
      rsp.type.must_equal Rattach.type
    end

    transaction 'stat FS root', Tstat.new(
      :tag => 0,
      :fid => 0
    ) do |req, rsp|
      rsp.type.must_equal Rstat.type
    end

    transaction 'open the FS root for reading', Topen.new(
      :tag  => 0,
      :fid  => 0,
      :mode => Topen::OREAD
    ) do |req, rsp|
      rsp.type.must_equal Ropen.type
    end

    transaction 'fetch a Stat for every file in FS root', Tread.new(
      :tag    => 0,
      :fid    => 0,
      :offset => 0,
      :count  => Tversion::MSIZE
    ) do |req, rsp|
      rsp.type.must_equal Rread.type

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
      rsp.type.must_equal Rclunk.type
    end

    transaction 'closed fid should not be readable', Tread.new(
      :tag    => 0,
      :fid    => 0,
      :offset => 0,
      :count  => Tversion::MSIZE
    ) do |req, rsp|
      rsp.type.must_equal Rerror.type
    end
  end

  it 'can read & write a file' do
    transaction 'attach to /', Tattach.new(
      :tag   => 0,
      :fid   => 0,
      :afid  => Fcall::NOFID,
      :uname => ENV['USER'],
      :aname => ''
    ) do |req, rsp|
      rsp.type.must_equal Rattach.type
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
      rsp.type.must_equal Rwalk.type
    end

    transaction "create #{leaf.inspect}", Tcreate.new(
      :tag  => 0,
      :fid  => 1,
      :name => leaf,
      :perm => 0644,
      :mode => Topen::ORDWR
    ) do |req, rsp|
      rsp.type.must_equal Rcreate.type
    end

    transaction "close the fid for #{root.inspect}", Tclunk.new(
      :tag => 0,
      :fid => 1
    ) do |req, rsp|
      rsp.type.must_equal Rclunk.type
    end

    transaction "walk to #{file.inspect} from /", Twalk.new(
      :tag    => 0,
      :fid    => 0,
      :newfid => 1,
      :wname => file
    ) do |req, rsp|
      rsp.type.must_equal Rwalk.type
    end

    transaction 'close the fid for /', Tclunk.new(
      :tag => 0,
      :fid => 0
    ) do |req, rsp|
      rsp.type.must_equal Rclunk.type
    end

    transaction "open #{file.inspect} for writing", Topen.new(
      :tag  => 0,
      :fid  => 1,
      :mode => Topen::ORDWR
    ) do |req, rsp|
      rsp.type.must_equal Ropen.type
    end

    write_req, write_rsp = transaction "write to #{file.inspect}", Twrite.new(
      :tag    => 0,
      :fid    => 1,
      :offset => 0,
      :data   => "hello world!!!"
    ) do |req, rsp|
      rsp.type.must_equal Rwrite.type
      rsp.count.must_equal req.data.length, 'count man?'
    end

    transaction "verify stuff was written to #{file.inspect}", Tread.new(
      :tag    => 0,
      :fid    => 1,
      :offset => 0,
      :count  => write_rsp.count
    ) do |req, rsp|
      rsp.type.must_equal Rread.type
      rsp.data.must_equal write_req.data
    end

    transaction "remove #{file.inspect}", Tremove.new(
      :tag => 0,
      :fid => 1
    ) do |req, rsp|
      rsp.type.must_equal Rremove.type
    end

    transaction "fid for #{file.inspect} should have been closed by Tremove", Tclunk.new(
      :tag => 0,
      :fid => 1
    ) do |req, rsp|
      rsp.type.must_equal Rerror.type
    end
  end

  private

  # Transmits the given request and returns the received response.
  def send_and_recv request
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
        response.must_be_kind_of Rerror
      else
        response.type.must_equal request.type + 1
      end

      response.tag.must_equal request.tag

    response
  end

  def transaction description, request
    begin
      response = send_and_recv(request)
      yield request, response if block_given?
      [request, response]
    rescue MiniTest::Assertion => e
      e.message << "\n\n\t task: #{description}\n\n\t with: #{request.class}"
      raise e
    end
  end
end
