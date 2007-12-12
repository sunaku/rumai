require 'socket'
ADDR = ENV['WMII_ADDRESS'].sub(/.*!/, '') rescue "/tmp/ns.#{ENV['USER']}.#{ENV['DISPLAY'] || ':0'}/wmii"
CONN = UNIXSocket.new(ADDR)

require 'ixp'
include IXP

def xmit aRequest
  aRequest.dump_9p_stream CONN
  Fcall.load_9p_stream CONN
end

describe :Tversion do
  it 'should establish a connection' do
    req = Fcall.new(
      :type    => Fcall::Tversion,
      :tag     => Fcall::NOTAG,
      :msize   => Fcall::MSIZE,
      :version => PROTOCOL_VERSION
    )
    rsp = xmit(req)

    rsp.type.should    == Fcall::Rversion
    rsp.tag.should     == req.tag
    rsp.version.should == req.version
  end

  it 'should attach to FS root' do
    req = Fcall.new(
      :type => Fcall::Tattach,
      :tag => 0,
      :fid => 0,
      :afid => Fcall::NOFID,
      :uname => ENV['USER'],
      :aname => ''
    )
    rsp = xmit(req)

    rsp.type.should == Fcall::Rattach
    rsp.tag.should  == req.tag
  end
end
