# Primitives for the 9P2000 protocol.
#
# See http://cm.bell-labs.com/sys/man/5/INDEX.html
#
# See http://swtch.com/plan9port/man/man9/
#
#--
# Copyright protects this work.
# See LICENSE file for details.
#++

module Rumai
  module IXP
    # define constants for easier bit manipulation of 9P2000 field values
    # uchar (1 byte), ushort (2 bytes), uint32 (4 bytes), uint64 (8 bytes)
    4.times do |n|
      bytes = 2 ** n
      bits  = 8 * bytes
      limit = 2 ** bits
      mask  = limit - 1

      const_set "BYTE#{bytes}_BITS", bits
      const_set "BYTE#{bytes}_LIMIT", limit
      const_set "BYTE#{bytes}_MASK", mask
    end

    ##
    # A 9P2000 byte stream.
    #
    module Stream
      # uchar, ushort, uint32 (all of them little-endian)
      PACKING_FLAGS = { 1 => 'C', 2 => 'v', 4 => 'V' }.freeze

      ##
      # Unpacks the given number of bytes from this 9P2000 byte stream.
      #
      def read_9p num_bytes
        read(num_bytes).unpack(PACKING_FLAGS[num_bytes])[0]
      end
    end

    ##
    # A common container for exceptions concerning IXP.
    #
    class Error < StandardError
    end

    ##
    # A serializable 9P2000 data structure.
    #
    module Struct
      attr_reader :fields

      ##
      # Allows field values to be initialized via the constructor.
      #
      # [field_values]
      #   a mapping from field name to field value
      #
      def initialize field_values = {}
        @fields = self.class.fields
        @values = field_values
      end

      ##
      # Transforms this object into a string of 9P2000 bytes.
      #
      def to_9p
        @fields.inject('') {|s,f| s << f.to_9p(@values) }
      end

      ##
      # Populates this object with information
      # from the given 9P2000 byte stream.
      #
      def load_9p stream
        @fields.each do |f|
          f.load_9p stream, @values
        end
      end

      ##
      # Provides a convenient DSL (for defining fields)
      # to all objects which *include* this module.
      #
      def self.included target
        class << target
          # Returns a list of fields which compose this Struct.
          def fields
            @fields ||=
              if superclass.respond_to? :fields
                superclass.fields.dup
              else
                []
              end
          end

          ##
          # Defines a new field in this Struct.
          #
          # [args] arguments for Field.new()
          #
          def field name, format = nil, *args
            c = Field.factory(format)
            f = c.new(name.to_sym, format, *args)
            fields << f # register field as being part of this structure

            # provide accessor methods to field values
            self.class_eval %{
              def #{f.name}
                @values[#{f.name.inspect}]
              end

              def #{f.name}= value
                @values[#{f.name.inspect}] = value
              end
            }

            return f
          end

          ##
          # Creates a new instance of this class from the
          # given 9P2000 byte stream and returns the instance.
          #
          def from_9p stream, msg_class = self
            msg = msg_class.new
            msg.load_9p(stream)
            msg
          end
        end
      end

      private

      ##
      # A field inside a Struct.
      #
      # A field's value is considered to be either:
      # * array of format when <code>counter && format.is_a? Class</code>
      # * raw byte string when <code>counter && format.nil?</code>
      #
      class Field
        attr_reader :name, :format, :counter, :countee

        ##
        # [name]
        #   unique (among all fields in a struct) name for the field
        #
        # [format]
        #   number of bytes, a class, or nil
        #
        # [counter]
        #   field which counts the length of this field's value
        #
        def initialize name, format = nil, counter = nil
          @name = name
          @format = format
          @countee = nil
          self.counter = counter
        end

        ##
        # Sets the counter for this field (implying that the
        # length of this field is counted by the given field).
        #
        def counter= field
          if @counter = field
            extend CounteeField
            @counter.countee = self
          end
        end

        ##
        # Sets the countee for this field (implying that
        # this field counts the length of the given field).
        #
        def countee= field
          if @countee = field
            extend CounterField
          end
        end

        ##
        # Returns a Field class that best represents the given format.
        #
        def self.factory format
          if format == String
            StringField

          elsif format.is_a? Class
            ClassField

          elsif format == 8
            Integer8Field

          else
            Field
          end
        end

        ##
        # Transforms this object into a string of 9P2000 bytes.
        #
        def to_9p field_values
          value_to_9p field_values[@name]
        end

        ##
        # Populates this object with information
        # taken from the given 9P2000 byte stream.
        #
        def load_9p stream, field_values
          field_values[@name] = value_from_9p stream
        end

        private

        ##
        # Converts the given value, according to the format
        # of this field, into a string of 9P2000 bytes.
        #
        def value_to_9p value
          value.to_i.to_9p @format.to_i
        end

        ##
        # Parses a value, according to the format of
        # this field, from the given 9P2000 byte stream.
        #
        def value_from_9p stream
          stream.read_9p @format.to_i
        end

        ##
        # Methods for a field that counts the length of another field.
        #
        module CounterField
          def to_9p field_values
            value_to_9p field_values[@countee.name].length
          end
        end

        ##
        # Methods for a field whose length is counted by another field.
        #
        module CounteeField
          def to_9p field_values
            value = field_values[@name]

            if @format
              value.map {|v| value_to_9p v}.join
            else
              value.to_s # raw byte sequence
            end
          end

          def load_9p stream, field_values
            count = field_values[@counter.name].to_i

            field_values[@name] =
              if @format
                Array.new(count) { value_from_9p stream }
              else
                stream.read(count) # raw byte sequence
              end
          end
        end
      end

      #:stopdoc:

      ##
      # A field whose value knows how to convert itself to and from 9p.
      #
      class ClassField < Field
        def value_to_9p value
          value.to_9p
        end

        def value_from_9p stream
          @format.from_9p stream
        end
      end

      ##
      # A field whose value is a string.
      #
      class StringField < ClassField
        def value_to_9p value
          value.to_s.to_9p
        end
      end

      ##
      # A field whose value is a 8-byte integer.
      #
      class Integer8Field < Field
        def value_to_9p value
          v = value.to_i
          (BYTE4_MASK & v).to_9p(4) <<               # lower bytes
          (BYTE4_MASK & (v >> BYTE4_BITS)).to_9p(4)  # higher bytes
        end

        def value_from_9p stream
          stream.read_9p(4) | (stream.read_9p(4) << BYTE4_BITS)
        end
      end

      #:startdoc:
    end

    ##
    # Holds information about a file being accessed on a 9P2000 server.
    #
    # See http://cm.bell-labs.com/magic/man2html/5/intro
    #
    class Qid
      include Struct

      # type[1] version[4] path[8]
      field :type    , 1
      field :version , 4
      field :path    , 8

      # from http://swtch.com/usr/local/plan9/include/libc.h
      QTDIR       = 0x80       # type bit for directories
      QTAPPEND    = 0x40       # type bit for append only files
      QTEXCL      = 0x20       # type bit for exclusive use files
      QTMOUNT     = 0x10       # type bit for mounted channel
      QTAUTH      = 0x08       # type bit for authentication file
      QTTMP       = 0x04       # type bit for non-backed-up file
      QTSYMLINK   = 0x02       # type bit for symbolic link
      QTFILE      = 0x00       # type bits for plain file
    end

    ##
    # Holds information about a file on a 9P2000 server.
    #
    # See http://cm.bell-labs.com/magic/man2html/5/stat
    #
    class Stat
      include Struct

      field :size   , 2
      field :type   , 2
      field :dev    , 4
      field :qid    , Qid
      field :mode   , 4
      field :atime  , Time
      field :mtime  , Time
      field :length , 8
      field :name   , String
      field :uid    , String
      field :gid    , String
      field :muid   , String

      # from http://swtch.com/usr/local/plan9/include/libc.h
      DMDIR       = 0x80000000 # mode bit for directories
      DMAPPEND    = 0x40000000 # mode bit for append only files
      DMEXCL      = 0x20000000 # mode bit for exclusive use files
      DMMOUNT     = 0x10000000 # mode bit for mounted channel
      DMAUTH      = 0x08000000 # mode bit for authentication file
      DMTMP       = 0x04000000 # mode bit for non-backed-up file
      DMSYMLINK   = 0x02000000 # mode bit for symbolic link (Unix, 9P2000.u)
      DMDEVICE    = 0x00800000 # mode bit for device file (Unix, 9P2000.u)
      DMNAMEDPIPE = 0x00200000 # mode bit for named pipe (Unix, 9P2000.u)
      DMSOCKET    = 0x00100000 # mode bit for socket (Unix, 9P2000.u)
      DMSETUID    = 0x00080000 # mode bit for setuid (Unix, 9P2000.u)
      DMSETGID    = 0x00040000 # mode bit for setgid (Unix, 9P2000.u)
      DMREAD      = 0x4        # mode bit for read permission
      DMWRITE     = 0x2        # mode bit for write permission
      DMEXEC      = 0x1        # mode bit for execute permission

      ##
      # Tests if this file is a directory.
      #
      def directory?
        mode & DMDIR > 0
      end
    end

    ##
    # Fcall is the basic unit of communication in the 9P2000 protocol.
    # It is analogous to a "packet" in the Internetwork Protocol (IP).
    #
    # See http://cm.bell-labs.com/magic/man2html/2/fcall
    #
    class Fcall
      include Struct

      # The first two fields are disabled because they are automatically
      # calculated by the Fcall#to_9p and Fcall::from_9p methods below:
      #
      # field :size , 4  # disabled
      # field :type , 1  # disabled
      #
      field   :tag  , 2

      ##
      # Transforms this object into a string of 9P2000 bytes.
      #
      def to_9p
        data = type.to_9p(1) << super
        size = (data.length + 4).to_9p(4)
        size << data
      end

      class << self
        alias __from_9p__ from_9p
        undef from_9p

        ##
        # Creates a new instance of this class from the
        # given 9P2000 byte stream and returns the instance.
        #
        def from_9p stream
          size = stream.read_9p(4)
          type = stream.read_9p(1)

          unless fcall = TYPE_TO_CLASS[type]
            raise Error, "illegal fcall type: #{type}"
          end

          __from_9p__ stream, fcall
        end
      end

      NOTAG = BYTE2_MASK # (ushort)
      NOFID = BYTE4_MASK # (uint32)
    end

    # size[4] Tversion tag[2] msize[4] version[s]
    class Tversion < Fcall
      field     :msize   , 4
      field     :version , String

      VERSION = '9P2000'.freeze
      MSIZE = 8192 # magic number defined in Plan9 for [TR]version and [TR]read
    end

    # size[4] Rversion tag[2] msize[4] version[s]
    class Rversion < Fcall
      field     :msize   , 4
      field     :version , String
    end

    # size[4] Tauth tag[2] afid[4] uname[s] aname[s]
    class Tauth < Fcall
      field     :afid    , 4
      field     :uname   , String
      field     :aname   , String
    end

    # size[4] Rauth tag[2] aqid[13]
    class Rauth < Fcall
      field     :aqid    , Qid
    end

    # size[4] Tattach tag[2] fid[4] afid[4] uname[s] aname[s]
    class Tattach < Fcall
      field     :fid     , 4
      field     :afid    , 4
      field     :uname   , String
      field     :aname   , String
    end

    # size[4] Rattach tag[2] qid[13]
    class Rattach < Fcall
      field     :qid     , Qid
    end

    # illegal
    class Terror < Fcall
      def to_9p
        raise Error, 'the Terror fcall cannot be transmitted'
      end
    end

    # size[4] Rerror tag[2] ename[s]
    class Rerror < Fcall
      field     :ename   , String
    end

    # size[4] Tflush tag[2] oldtag[2]
    class Tflush < Fcall
      field     :oldtag  , 2
    end

    # size[4] Rflush tag[2]
    class Rflush < Fcall
    end

    # size[4] Twalk tag[2] fid[4] newfid[4] nwname[2] nwname*(wname[s])
    class Twalk < Fcall
      field     :fid     , 4
      field     :newfid  , 4
      c = field :nwname  , 2
      field     :wname   , String , c
    end

    # size[4] Rwalk tag[2] nwqid[2] nwqid*(wqid[13])
    class Rwalk < Fcall
      c = field :nwqid   , 2
      field     :wqid    , Qid    , c
    end

    # size[4] Topen tag[2] fid[4] mode[1]
    class Topen < Fcall
      field     :fid     , 4
      field     :mode    , 1

      # from http://swtch.com/usr/local/plan9/include/libc.h
      OREAD       = 0          # open for read
      OWRITE      = 1          # write
      ORDWR       = 2          # read and write
      OEXEC       = 3          # execute, == read but check execute permission
      OTRUNC      = 16         # or'ed in (except for exec), truncate file first
      OCEXEC      = 32         # or'ed in, close on exec
      ORCLOSE     = 64         # or'ed in, remove on close
      ODIRECT     = 128        # or'ed in, direct access
      ONONBLOCK   = 256        # or'ed in, non-blocking call
      OEXCL       = 0x1000     # or'ed in, exclusive use (create only)
      OLOCK       = 0x2000     # or'ed in, lock after opening
      OAPPEND     = 0x4000     # or'ed in, append only
    end

    # size[4] Ropen tag[2] qid[13] iounit[4]
    class Ropen < Fcall
      field     :qid     , Qid
      field     :iounit  , 4
    end

    # size[4] Tcreate tag[2] fid[4] name[s] perm[4] mode[1]
    class Tcreate < Fcall
      field     :fid     , 4
      field     :name    , String
      field     :perm    , 4
      field     :mode    , 1
    end

    # size[4] Rcreate tag[2] qid[13] iounit[4]
    class Rcreate < Fcall
      field     :qid     , Qid
      field     :iounit  , 4
    end

    # size[4] Tread tag[2] fid[4] offset[8] count[4]
    class Tread < Fcall
      field     :fid     , 4
      field     :offset  , 8
      field     :count   , 4
    end

    # size[4] Rread tag[2] count[4] data[count]
    class Rread < Fcall
      c = field :count   , 4
      field     :data    , nil    , c
    end

    # size[4] Twrite tag[2] fid[4] offset[8] count[4] data[count]
    class Twrite < Fcall
      field     :fid     , 4
      field     :offset  , 8
      c = field :count   , 4
      field     :data    , nil    , c
    end

    # size[4] Rwrite tag[2] count[4]
    class Rwrite < Fcall
      field     :count   , 4
    end

    # size[4] Tclunk tag[2] fid[4]
    class Tclunk < Fcall
      field     :fid     , 4
    end

    # size[4] Rclunk tag[2]
    class Rclunk < Fcall
    end

    # size[4] Tremove tag[2] fid[4]
    class Tremove < Fcall
      field     :fid     , 4
    end

    # size[4] Rremove tag[2]
    class Rremove < Fcall
    end

    # size[4] Tstat tag[2] fid[4]
    class Tstat < Fcall
      field     :fid     , 4
    end

    # size[4] Rstat tag[2] stat[n]
    class Rstat < Fcall
      field     :nstat   , 2
      field     :stat    , Stat
    end

    # size[4] Twstat tag[2] fid[4] stat[n]
    class Twstat < Fcall
      field     :fid     , 4
      field     :nstat   , 2
      field     :stat    , Stat
    end

    # size[4] Rwstat tag[2]
    class Rwstat < Fcall
    end

    ##
    # A remote function call (fcall).
    #
    class Fcall
      CLASS_TO_TYPE = {
        Tversion => 100,
        Rversion => 101,
        Tauth    => 102,
        Rauth    => 103,
        Tattach  => 104,
        Rattach  => 105,
        Terror   => 106,
        Rerror   => 107,
        Tflush   => 108,
        Rflush   => 109,
        Twalk    => 110,
        Rwalk    => 111,
        Topen    => 112,
        Ropen    => 113,
        Tcreate  => 114,
        Rcreate  => 115,
        Tread    => 116,
        Rread    => 117,
        Twrite   => 118,
        Rwrite   => 119,
        Tclunk   => 120,
        Rclunk   => 121,
        Tremove  => 122,
        Rremove  => 123,
        Tstat    => 124,
        Rstat    => 125,
        Twstat   => 126,
        Rwstat   => 127,
      }.freeze

      TYPE_TO_CLASS = CLASS_TO_TYPE.invert.freeze

      ##
      # Returns the value of the 'type' field for this fcall.
      #
      def self.type
        CLASS_TO_TYPE[self]
      end

      ##
      # Returns the value of the 'type' field for this fcall.
      #
      def type
        self.class.type
      end
    end
  end
end

class Integer
  ##
  # Transforms this object into a string of 9P2000 bytes.
  #
  def to_9p num_bytes
    [self].pack Rumai::IXP::Stream::PACKING_FLAGS[num_bytes]
  end
end

# count[2] s[count]
class String
  ##
  # Transforms this object into a string of 9P2000 bytes.
  #
  def to_9p
    length.to_9p(2) << self[0, Rumai::IXP::BYTE2_MASK]
  end

  ##
  # Creates a new instance of this class from the
  # given 9P2000 byte stream and returns the instance.
  #
  def self.from_9p stream
    stream.read(stream.read_9p(2))
  end
end

class Time
  ##
  # Transforms this object into a string of 9P2000 bytes.
  #
  def to_9p
    to_i.to_9p(4)
  end

  ##
  # Creates a new instance of this class from the
  # given 9P2000 byte stream and returns the instance.
  #
  def self.from_9p stream
    at stream.read_9p(4)
  end
end

class IO
  include Rumai::IXP::Stream
end

require 'stringio'
class StringIO
  include Rumai::IXP::Stream
end
