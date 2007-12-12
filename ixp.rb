# A simple IXP implementation for Rumai.
#--
# Copyright 2007 Suraj N. Kurapati
# See the file named LICENSE for details.

UCHAR_BYTES  = 1
UCHAR_BITS   = 8
UCHAR_MAX    = 0xFF
UCHAR_FLAG   = 'C'.freeze

USHORT_BYTES = 2
USHORT_BITS  = 16
USHORT_MAX   = 0xFF_FF
USHORT_FLAG  = 'v'.freeze

UINT32_BYTES = 4
UINT32_BITS  = 32
UINT32_MAX   = 0xFF_FF_FF_FF
UINT32_FLAG  = 'V'.freeze


class IO
  # Reads the given number of bytes and unpacks them using String#unpack.
  def unpack aNumBytes, aPackFormat
    read(aNumBytes).unpack(aPackFormat).first
  end

  # Reads a string encoded in 9P2000 format.
  def unpack_9p_string
    read(unpack(USHORT_BYTES, USHORT_FLAG))
  end
end

class String
  def to_9p_string
    [length].pack(USHORT_FLAG) << self[0, USHORT_MAX]
  end
end

module IXP
  PROTOCOL_VERSION = '9P2000'

  # see <fcall.h> in the 9P2000 protocol.
  class Fcall
    StorageTypes = {
      :uchar  => UCHAR_FLAG,
      :ushort => USHORT_FLAG,
      :uint32 => UINT32_FLAG,
      :string => nil
    }

    class Qid
      QTDIR     = 0x80 # type bit for directories
      QTAPPEND  = 0x40 # type bit for append only files
      QTEXCL    = 0x20 # type bit for exclusive use files
      QTMOUNT   = 0x10 # type bit for mounted channel
      QTAUTH    = 0x08 # type bit for authentication file
      QTTMP     = 0x04 # type bit for non-backed-up file
      QTSYMLINK = 0x02 # type bit for symbolic link
      QTFILE    = 0x00 # type bits for plain file

      # type[1] version[4] path[8]
      attr_accessor \
        :type,    # (uchar)
        :version, # (uint32)
        :path     # (8 bytes, unsigned integer, little-endian)

      def self.load_stream aStream
        @type    = aStream.unpack(UCHAR_BYTES, UCHAR_FLAG)
        @version = aStream.unpack(UINT32_BYTES, UINT32_FLAG)
        @path    = aStream.unpack(UINT32_BYTES, UINT32_FLAG) |
                   (aStream.unpack(UINT32_BYTES, UINT32_FLAG) << UINT32_BITS)
      end

      def self.dump_stream aStream
        aStream << dump
      end

      def dump
        [
          @type,
          @version,
          @path & UINT32_MAX,
          @path & (UINT32_MAX << UINT32_BITS)
        ].pack(UCHAR_FLAG + UINT32_FLAG + UINT32_FLAG + UINT32_FLAG)
      end
    end

    attr_accessor \
      :size,    # overall message length (number of bytes)

      :type,    # (uchar)
      :fid,     # (uint32)
      :tag,     # (ushort)

      :msize,   # (uint32) Tversion, Rversion
      :version, # (char*) Tversion, Rversion

      :oldtag,  # (ushort) Tflush

      :ename,   # (char*) Rerror

      :qid,     # (Qid) Rattach, Ropen, Rcreate
      :iounit,  # (uint32) Ropen, Rcreate

      :aqid,    # (Qid) Rauth

      :afid,    # (uint32) Tauth, Tattach
      :uname,   # (char*) Tauth, Tattach
      :aname,   # (char*) Tauth, Tattach

      :perm,    # (uint32) Tcreate
      :name,    # (char*) Tcreate
      :mode,    # (uchar) Tcreate, Topen

      :newfid,  # (uint32) Twalk
      :nwname,  # (ushort) Twalk
      :wname,   # (char*) Twalk

      :nwqid,   # (ushort) Rwalk
      :wqid,    # (Qid) Rwalk

      :offset,  # (vlong) Tread, Twrite
      :count,   # (uint32) Tread, Twrite, Rread
      :data,    # (char*) Twrite, Rread

      :nstat,   # (ushort) Twstat, Rstat
      :stat     # (uchar*) Twstat, Rstat

    def initialize aFields = {}
      aFields.each_pair do |k,v|
        instance_variable_set :"@#{k}", v
      end
    end

    NOTAG = USHORT_MAX # (ushort)
    NOFID = UINT32_MAX # (uint32)
    MSIZE = 8192 # magic number used in [TR]version messages... dunno why

    # Field = Struct.new
    #   @@fields = Hash.new {|h,k| h[k] = []}
    #   def self.field aName, aType
    #     @@fields[self] <<
    #   end

    # TYPES = {
    #   100 => class Tversion
    #          end,
    # }

    Tversion = 100 # size[4] Tversion tag[2] msize[4] version[s]
    Rversion = 101 # size[4] Rversion tag[2] msize[4] version[s]
    Tauth    = 102 # size[4] Tauth tag[2] afid[4] uname[s] aname[s]
    Rauth    = 103 # size[4] Rauth tag[2] aqid[13]
    Tattach  = 104 # size[4] Tattach tag[2] fid[4] afid[4] uname[s] aname[s]
    Rattach  = 105 # size[4] Rattach tag[2] qid[13]
    Terror   = 106 # illegal
    Rerror   = 107 # size[4] Rerror tag[2] ename[s]
    Tflush   = 108 # size[4] Tflush tag[2] oldtag[2]
    Rflush   = 109 # size[4] Rflush tag[2]
    Twalk    = 110 # size[4] Twalk tag[2] fid[4] newfid[4] nwname[2] nwname*(wname[s])
    Rwalk    = 111 # size[4] Rwalk tag[2] nwqid[2] nwqid*(wqid[13])
    Topen    = 112 # size[4] Topen tag[2] fid[4] mode[1]
    Ropen    = 113 # size[4] Ropen tag[2] qid[13] iounit[4]
    Tcreate  = 114 # size[4] Tcreate tag[2] fid[4] name[s] perm[4] mode[1]
    Rcreate  = 115 # size[4] Rcreate tag[2] qid[13] iounit[4]
    Tread    = 116 # size[4] Tread tag[2] fid[4] offset[8] count[4]
    Rread    = 117 # size[4] Rread tag[2] count[4] data[count]
    Twrite   = 118 # size[4] Twrite tag[2] fid[4] offset[8] count[4] data[count]
    Rwrite   = 119 # size[4] Rwrite tag[2] count[4]
    Tclunk   = 120 # size[4] Tclunk tag[2] fid[4]
    Rclunk   = 121 # size[4] Rclunk tag[2]
    Tremove  = 122 # size[4] Tremove tag[2] fid[4]
    Rremove  = 123 # size[4] Rremove tag[2]
    Tstat    = 124 # size[4] Tstat tag[2] fid[4]
    Rstat    = 125 # size[4] Rstat tag[2] stat[n]
    Twstat   = 126 # size[4] Twstat tag[2] fid[4] stat[n]
    Rwstat   = 127 # size[4] Rwstat tag[2]

    # Parses an Fcall from the given I/O stream.
    # The stream is NOT rewound after reading.
    def self.load_stream aStream
      pkt = Fcall.new(
        :size => aStream.unpack(UINT32_BYTES, UINT32_FLAG),
        :type => aStream.unpack(UCHAR_BYTES, UCHAR_FLAG),
        :tag  => aStream.unpack(USHORT_BYTES, USHORT_FLAG)
      )

      case pkt.type
      # size[4] Tversion tag[2] msize[4] version[s]
      # size[4] Rversion tag[2] msize[4] version[s]
      when Tversion, Rversion
        pkt.msize = aStream.unpack(UINT32_BYTES, UINT32_FLAG)
        pkt.version = aStream.unpack_9p_string

      # size[4] Tauth tag[2] afid[4] uname[s] aname[s]
      # when Tauth
      #   pkt.afid = aStream.unpack(UINT32_BYTES, UINT32_FLAG)
      #   pkt.uname = aStream.unpack_9p_string
      #   pkt.aname = aStream.unpack_9p_string

      # size[4] Rauth tag[2] aqid[13]
      # when Rauth
      #   pkt.aqid = Qid.load_stream(aStream)

      else
        raise "cannot load Fcall #{pkt} with type #{pkt.type}"
      end

      p :got => pkt, :raw => pkt.dump

      pkt
    end

    # Writes this Fcall to the given I/O stream.
    def dump_stream aStream
      aStream << dump
    end

    # Tranforms this Fcall into a string of bytes.
    def dump
      data =
        case @type
        # size[4] Tversion tag[2] msize[4] version[s]
        # size[4] Rversion tag[2] msize[4] version[s]
        when Tversion, Rversion
          [@msize].pack(UINT32_FLAG) << @version.to_s.to_9p_string

        # size[4] Tauth tag[2] afid[4] uname[s] aname[s]
        # when Tauth
        #   [@afid].pack(UINT32_FLAG) <<
        #   @uname.to_s.to_9p_string <<
        #   @aname.to_s.to_9p_string

        # size[4] Rauth tag[2] aqid[13]
        # when Rauth
        #   @aqid.dump

        when Tattach # size[4] Rerror tag[2] ename[s]


        else
          raise "cannot dump Fcall #{inspect} with type #{type}"
        end

      data = [@type, @tag].pack(UCHAR_FLAG + USHORT_FLAG) << data
      size = [data.length + UINT32_BYTES].pack(UINT32_FLAG)
      size << data
    end
  end

  class Dir
    # from libc.h:

    DMDIR       = 0x80000000	# mode bit for directories
    DMAPPEND    = 0x40000000	# mode bit for append only files
    DMEXCL      = 0x20000000	# mode bit for exclusive use files
    DMMOUNT     = 0x10000000	# mode bit for mounted channel
    DMAUTH      = 0x08000000	# mode bit for authentication file
    DMTMP       = 0x04000000	# mode bit for non-backed-up file
    DMSYMLINK   = 0x02000000	# mode bit for symbolic link (Unix, 9P2000.u)
    DMDEVICE    = 0x00800000	# mode bit for device file (Unix, 9P2000.u)
    DMNAMEDPIPE = 0x00200000	# mode bit for named pipe (Unix, 9P2000.u)
    DMSOCKET    = 0x00100000	# mode bit for socket (Unix, 9P2000.u)
    DMSETUID    = 0x00080000	# mode bit for setuid (Unix, 9P2000.u)
    DMSETGID    = 0x00040000	# mode bit for setgid (Unix, 9P2000.u)

    DMREAD      = 0x4		# mode bit for read permission
    DMWRITE     = 0x2		# mode bit for write permission
    DMEXEC      = 0x1		# mode bit for execute permission

=begin
    # from 9p manpage:

    DMDIR    = 0x80000000 # directory
    DMAPPEND = 0x40000000 # append only
    DMEXCL   = 0x20000000 # exclusive use (locked)
    DMREAD   = 0400       # read permission by owner
    DMWRITE  = 0200       # write permission by owner
    DMEXEC   = 0100       # execute permission (search on directory) by owner
    DMRWXG   = 0070       # read, write, execute (search) by group
    DMRWXO   = 0007       # read, write, execute (search) by others
=end
  end
end
