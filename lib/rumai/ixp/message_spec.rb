# Unit test for 9p.rb
#--
# Copyright 2007 Suraj N. Kurapati
# See the file named LICENSE for details.

require 'message'
include IXP

require 'pp' if $DEBUG

# Transmits the given request and returns the received response.
def xmit aRequest
  # send the request
  req = aRequest
    if $DEBUG
      puts
      pp req
      pp req.to_9p
    end
  PIPE << req.to_9p

  # recv the response
  rsp = Fcall.from_9p(PIPE)
    if $DEBUG
      puts
      pp rsp
      pp rsp.to_9p
    end

    [Rerror.type, req.type + 1].should include(rsp.type)
    req.tag.should == rsp.tag
  rsp
end

# set up the connection to wmii's IXP server
  ADDR = ENV['WMII_ADDRESS'].sub(/.*!/, '') rescue
         "/tmp/ns.#{ENV['USER']}.#{ENV['DISPLAY'] || ':0'}/wmii"

  require 'socket'
  PIPE = UNIXSocket.new(ADDR)

  describe Tversion do
    it 'should establish a connection' do
      req = Tversion.new(
        :tag     => Fcall::NOTAG,
        :msize   => Tversion::MSIZE,
        :version => Tversion::VERSION
      )
      rsp = xmit(req)

      rsp.type.should    == Rversion.type
      rsp.version.should == req.version
    end
  end

# read a directory
  describe Tattach do
    it 'should attach to FS root' do
      req = Tattach.new(
        :tag   => 0,
        :fid   => 0,
        :afid  => Fcall::NOFID,
        :uname => ENV['USER'],
        :aname => ''
      )
      rsp = xmit(req)

      rsp.type.should == Rattach.type
    end
  end

  describe Tstat do
    it 'should stat FS root' do
      req = Tstat.new(
        :tag => 0,
        :fid => 0
      )
      rsp = xmit(req)

      rsp.type.should == Rstat.type
    end
  end

  describe Topen do
    it 'should open the FS root for reading' do
      req = Topen.new(
        :tag  => 0,
        :fid  => 0,
        :mode => Topen::OREAD
      )
      rsp = xmit(req)

      rsp.type.should == Ropen.type
    end
  end

  describe Tread do
    it 'should return a Stat for every file in FS root' do
      req = Tread.new(
        :tag    => 0,
        :fid    => 0,
        :offset => 0,
        :count  => Tversion::MSIZE
      )
      rsp = xmit(req)

      rsp.type.should == Rread.type

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
  end

  describe Tclunk do
    it 'should close the fid for FS root' do
      req = Tclunk.new(
        :tag    => 0,
        :fid    => 0
      )
      rsp = xmit(req)

      rsp.type.should == Rclunk.type
    end
  end

  describe 'A closed fid' do
    it 'should not be readable' do
      req = Tread.new(
        :tag    => 0,
        :fid    => 0,
        :offset => 0,
        :count  => Tversion::MSIZE
      )
      rsp = xmit(req)

      rsp.type.should == Rerror.type
    end
  end

# read & write a file
  describe Tattach do
    it 'should attach to /' do
      req = Tattach.new(
        :tag   => 0,
        :fid   => 0,
        :afid  => Fcall::NOFID,
        :uname => ENV['USER'],
        :aname => ''
      )
      rsp = xmit(req)

      rsp.type.should == Rattach.type
    end
  end

  describe Twalk do
    it 'should walk to /rbar/status' do
      req = Twalk.new(
        :tag    => 0,
        :fid    => 0,
        :newfid => 1,
        :wname => %w[rbar status]
      )
      rsp = xmit(req)

      rsp.type.should == Rwalk.type
    end
  end

  describe Tclunk do
    it 'should close the fid for /' do
      req = Tclunk.new(
        :tag    => 0,
        :fid    => 0
      )
      rsp = xmit(req)

      rsp.type.should == Rclunk.type
    end
  end

  describe Topen do
    it 'should open /rbar/status for writing' do
      req = Topen.new(
        :tag  => 0,
        :fid  => 1,
        :mode => Topen::ORDWR
      )
      rsp = xmit(req)

      rsp.type.should == Ropen.type
    end
  end

  describe Twrite do
    it 'should replace the file content' do
      writeReq = Twrite.new(
        :tag    => 0,
        :fid    => 1,
        :offset => 0,
        :data   => "hello world!!!"
      )
      writeRsp = xmit(writeReq)

      writeRsp.type.should == Rwrite.type
      writeRsp.count.should == writeReq.data.length


      readReq = Tread.new(
        :tag    => 0,
        :fid    => 1,
        :offset => 0,
        :count => writeRsp.count
      )
      readRsp = xmit(readReq)

      readRsp.type.should == Rread.type
      readRsp.data.should == writeReq.data
    end
  end

  describe Tclunk do
    it 'should close the fid for /rbar/status' do
      req = Tclunk.new(
        :tag    => 0,
        :fid    => 1
      )
      rsp = xmit(req)

      rsp.type.should == Rclunk.type
    end
  end

# at_exit do
#   puts "just making sure there is no more data in the pipe"
#   while c = PIPE.getc
#     puts c
#   end
# end
