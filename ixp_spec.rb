require 'socket'
ADDR = ['WMII_ADDRESS'].sub(/.*!/, '') rescue "/tmp/ns.#{ENV['USER']}.#{ENV['DISPLAY'] || ':0'}/wmii"
CONN = UNIXSocket.new(ADDR)

require 'ixp'
include IXP

describe :Tversion do
  before(:each) do
    @req = Fcall.new(
      :type => Fcall::Tversion,
      :tag => Fcall::NOTAG,
      :msize => Fcall::MSIZE,
      :version => PROTOCOL_VERSION
    )
  end

  it 'should establish a connection' do
    @req.dump_stream CONN
    rsp = Fcall.load_stream CONN

    rsp.type.should == Fcall::Rversion
    rsp.tag.should == @req.tag
    rsp.version.should == @req.version
  end
end
