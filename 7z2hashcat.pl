#!/usr/bin/env perl

use strict;
use warnings;

use Compress::Raw::Lzma qw (LZMA_STREAM_END LZMA_DICT_SIZE_MIN);

# author:
# philsmd

# version:
# 0.7

# date released:
# April 2015

# date last updated:
# 16th January 2017

# dependencies:
# Compress::Raw::Lzma

# install dependencies like this:
#    sudo cpan Compress::Raw::Lzma
# or sudo apt-get install libcompress-raw-lzma-perl
# or sudo perl -MCPAN -e 'install Compress::Raw::Lzma'


#
# Explanation of the "hash" format:
#

# the fields of this format are separate by the dollar ("$") sign:
# ("xyz" means that the string xyz is used literally, brackets indicate variables)
#
# "$"
# "7z"
# "$"
# [data type indicator]           # see "Explanation of the data type indicator" below
# "$"
# [cost factor]                   # means: 2 ^ [cost factor] iterations
# "$"
# [length of salt]
# "$"
# [salt]
# "$"
# [length of iv]                  # the initialization vector length
# "$"
# [iv]                            # the initialization vector itself
# "$"
# [CRC32]                         # the actual "hash"
# "$"
# [length of encrypted data]      # the encrypted data length in bytes
# "$"
# [length of decrypted data]      # the decrypted data length in bytes
# "$"
# [encrypted data]                # the encrypted (and possibly also compressed data)

# in case the data was not truncated and a decompression step is needed to verify the CRC32, these fields are appended:
# "$"
# [length of data for CRC32]      # the length of the first "file" needed to verify the CRC32 checksum
# "$"
# [coder attributes]              # most of the coders/decompressors need some attributes (e.g. encoded lc, pb, lp, dictSize values);

#
# Explanation of the data type indicator
#

# This field is the first field after the hash signature (i.e. after "$7z$).
# Whenever the data is longer than the value of PASSWORD_RECOVERY_TOOL_DATA_LIMIT, the value will be 128.
# If no truncation is used:
# - the value will be 0 if the data doesn't need to be decompressed to check the CRC32 checksum
# - all values different from 128, but greater than 0 indicate that the data must be decompressed as follows:
#   - 1 means that the data must be decompressed using the LZMA1 decompressor
#   - 2 means that the data must be decompressed using the LZMA2 decompressor
#   - 3 means that the data must be decompressed using the PPMD decompressor
#   - 4 means that the data must be decompressed using the BCJ decompressor
#   - 5 means that the data must be decompressed using the BCJ2 decompressor
#   - 6 means that the data must be decompressed using the BZIP2 decompressor
#   - 7 means that the data must be decompressed using the DEFLATE decompressor

# Truncated data can only be verified using the padding attack and therefore combinations between truncation + a compressor are not allowed.
# Therefore, whenever the value is 128 or 0, neither coder attributes nor the length of the data for the CRC32 check is within the output.
# On the other hand, for all values above or equal 1 and smaller than 128, both coder attributes and the length for CRC32 check is in the output.

#
# Constants
#

my $LZMA2_MIN_COMPRESSED_LEN = 16; # the raw data (decrypted) needs to be at least: 3 + 1 + 1, header (start + size) + at least one byte of data + end
                                   # therefore we need to have at least one AES BLOCK (128 bits = 16 bytes)

# header

my $SEVEN_ZIP_MAGIC = "7z\xbc\xaf\x27\x1c";

my $SEVEN_ZIP_END                = "\x00";
my $SEVEN_ZIP_HEADER             = "\x01";
my $SEVEN_ZIP_ARCHIVE_PROPERTIES = "\x02";
my $SEVEN_ZIP_ADD_STREAMS_INFO   = "\x03";
my $SEVEN_ZIP_MAIN_STREAMS_INFO  = "\x04";
my $SEVEN_ZIP_FILES_INFO         = "\x05";
my $SEVEN_ZIP_PACK_INFO          = "\x06";
my $SEVEN_ZIP_UNPACK_INFO        = "\x07";
my $SEVEN_ZIP_SUBSTREAMS_INFO    = "\x08";
my $SEVEN_ZIP_SIZE               = "\x09";
my $SEVEN_ZIP_CRC                = "\x0a";
my $SEVEN_ZIP_FOLDER             = "\x0b";
my $SEVEN_ZIP_UNPACK_SIZE        = "\x0c";
my $SEVEN_ZIP_NUM_UNPACK_STREAM  = "\x0d";
my $SEVEN_ZIP_EMPTY_STREAM       = "\x0e";
my $SEVEN_ZIP_EMPTY_FILE         = "\x0f";
my $SEVEN_ZIP_ANTI_FILE          = "\x10";
my $SEVEN_ZIP_NAME               = "\x11";
my $SEVEN_ZIP_CREATION_TIME      = "\x12";
my $SEVEN_ZIP_ACCESS_TIME        = "\x13";
my $SEVEN_ZIP_MODIFICATION_TIME  = "\x14";
my $SEVEN_ZIP_WIN_ATTRIBUTE      = "\x15";
my $SEVEN_ZIP_ENCODED_HEADER     = "\x17";
my $SEVEN_ZIP_START_POS          = "\x18";
my $SEVEN_ZIP_DUMMY              = "\x19";

my $SEVEN_ZIP_MAX_PROPERTY_TYPE  = 2 ** 30; # 1073741824
my $SEVEN_ZIP_NOT_EXTERNAL       = "\x00";
my $SEVEN_ZIP_EXTERNAL           = "\x01";
my $SEVEN_ZIP_ALL_DEFINED        = "\x01";
my $SEVEN_ZIP_FILE_NAME_END      = "\x00\x00";

# codec

my $SEVEN_ZIP_AES               = "\x06\xf1\x07\x01"; # all the following codec values are from CPP/7zip/Archive/7z/7zHeader.h

my $SEVEN_ZIP_LZMA1             = "\x03\x01\x01";
my $SEVEN_ZIP_LZMA2             = "\x21";
my $SEVEN_ZIP_PPMD              = "\x03\x04\x01";
my $SEVEN_ZIP_BCJ               = "\x03\x03\x01\x03";
my $SEVEN_ZIP_BCJ2              = "\x03\x03\x01\x1b";
my $SEVEN_ZIP_BZIP2             = "\x04\x02\x02";
my $SEVEN_ZIP_DEFLATE           = "\x04\x01\x08";

# hash format

my $SEVEN_ZIP_HASH_SIGNATURE    = "\$7z\$";
my $SEVEN_ZIP_DEFAULT_POWER     = 19;
my $SEVEN_ZIP_DEFAULT_IV        = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";

my $SEVEN_ZIP_UNCOMPRESSED       =   0;
my $SEVEN_ZIP_LZMA1_COMPRESSED   =   1;
my $SEVEN_ZIP_LZMA2_COMPRESSED   =   2;
my $SEVEN_ZIP_PPMD_COMPRESSED    =   3;
my $SEVEN_ZIP_BCJ_COMPRESSED     =   4;
my $SEVEN_ZIP_BCJ2_COMPRESSED    =   5;
my $SEVEN_ZIP_BZIP2_COMPRESSED   =   6;
my $SEVEN_ZIP_DEFLATE_COMPRESSED =   7;
my $SEVEN_ZIP_TRUNCATED          = 128; # (0x80 or 0b10000000)

my %SEVEN_ZIP_COMPRESSOR_NAMES   = (1 => "LZMA1", 2 => "LZMA2", 3 => "PPMD", 4 => "BCJ", 5 => "BCJ2", 6 => "BZIP2",
                                    7 => "DEFLATE");

# cracker specific stuff

my $SHOW_LZMA_DECOMPRESS_AFTER_DECRYPT_WARNING = 1;

my $PASSWORD_RECOVERY_TOOL_NAME = "hashcat";
my $PASSWORD_RECOVERY_TOOL_DATA_LIMIT = 768;              # this value should always be >= 32
my @PASSWORD_RECOVERY_TOOL_SUPPORTED_DECOMPRESSORS = ();  # within this list we only need values ranging from 1 to 7
                                                          # i.e. SEVEN_ZIP_LZMA1_COMPRESSED to SEVEN_ZIP_DEFLATE_COMPRESSED

#
# Helper functions
#

sub usage
{
  my $prog_name = shift;

  print STDERR "Usage: $prog_name <7-Zip file>...\n";
}

my $memory_buffer_read_offset = 0;

sub my_read
{
  my $input  = shift;
  my $length = shift;

  my $type_of_input = ref ($input);

  my $output_buffer;

  if ($type_of_input eq "GLOB")
  {
    read $input, $output_buffer, $length;
  }
  else
  {
    $output_buffer = substr ($$input, $memory_buffer_read_offset, $length);

    $memory_buffer_read_offset += $length;
  }

  return $output_buffer;
}

sub get_uint32
{
  my $fp = shift;

  my $bytes = my_read ($fp, 4);

  my $num = unpack ("L", $bytes);

  return $num;
}

sub get_uint64
{
  my $fp = shift;

  my $bytes = my_read ($fp, 8);

  my ($uint1, $uint2) = unpack ("LL<", $bytes);

  my $num = $uint2 << 32 | $uint1;

  return $bytes, $num;
}

sub read_number
{
  my $fp = shift;

  my $b = ord (my_read ($fp, 1));

  if (($b & 0x80) == 0)
  {
    return $b;
  }

  my $value = ord (my_read ($fp, 1));

  for (my $i = 1; $i < 8; $i++)
  {
    my $mask = 0x80 >> $i;

    if (($b & $mask) == 0)
    {
      my $high = $b & ($mask - 1);

      $value |= ($high << ($i * 8));

      return $value;
    }

    my $next = ord (my_read ($fp, 1));

    $value |= ($next << ($i * 8));
  }

  return $value;
}

sub num_to_id
{
  my $num = shift;

  # special case:

  return "\x00" if ($num == 0);

  # normal case:

  my $id = "";

  while ($num > 0)
  {
    my $value = $num & 0xff;

    $id = chr ($value) . $id;

    $num >>= 8;
  }

  return $id;
}

sub read_id
{
  my $fp = shift;

  my $id;

  my $num = read_number ($fp);

  # convert number to their ASCII code correspondent byte

  return num_to_id ($num);
}

sub get_boolean_vector
{
  my $fp = shift;

  my $number_items = shift;

  my @booleans;

  # get the values

  my $v = 0;
  my $mask = 0;

  for (my $i = 0; $i < $number_items; $i++)
  {
    if ($mask == 0)
    {
      my $byte = my_read ($fp, 1);

      $v = ord ($byte);
      $mask = 0x80;
    }

    my $val = ($v & $mask) != 0;

    push (@booleans, $val);

    $mask >>= 1;
  }

  return @booleans;
}

sub get_boolean_vector_check_all
{
  my $fp = shift;

  my $number_items = shift;

  my @booleans;

  # check first byte to see if all are defined

  my $all_defined = my_read ($fp, 1);

  if ($all_defined eq $SEVEN_ZIP_ALL_DEFINED)
  {
    @booleans = (1) x $number_items;
  }
  else
  {
    @booleans = get_boolean_vector ($fp, $number_items);
  }

  return @booleans;
}

sub is_supported_seven_zip_file
{
  my $fp = shift;

  my $magic_len = length ($SEVEN_ZIP_MAGIC);

  my $signature = my_read ($fp, $magic_len);

  return $signature eq $SEVEN_ZIP_MAGIC;
}

sub get_decoder_properties
{
  my $attributes = shift;

  my $salt_len;
  my $salt_buf;
  my $iv_len;
  my $iv_buf;
  my $number_cycles_power;

  # set some default values

  $salt_len = 0;
  $salt_buf = "";
  $iv_len = length ($SEVEN_ZIP_DEFAULT_IV);
  $iv_buf = $SEVEN_ZIP_DEFAULT_IV;
  $number_cycles_power = $SEVEN_ZIP_DEFAULT_POWER;

  # the most important information is encoded in first and second byte
  # i.e. the salt/iv length, number cycle power

  my $offset = 0;

  my $first_byte = substr ($attributes, 0, 1);
  $first_byte = ord ($first_byte);

  $offset++;

  $number_cycles_power = $first_byte & 0x3f;

  if (($first_byte & 0xc0) == 0)
  {
    return ($salt_len, $salt_buf, $iv_len, $iv_buf, $number_cycles_power);
  }

  $salt_len = ($first_byte >> 7) & 1;
  $iv_len   = ($first_byte >> 6) & 1;

  # combine this info with the second byte

  my $second_byte = substr ($attributes, 1, 1);
  $second_byte = ord ($second_byte);

  $offset++;

  $salt_len += ($second_byte >> 4);
  $iv_len   += ($second_byte & 0x0f);

  $salt_buf = substr ($attributes, $offset, $salt_len);

  $offset += $salt_len;

  $iv_buf = substr ($attributes, $offset, $iv_len);

  # pad the iv with zeros

  my $iv_max_length = 16;

  $iv_buf .= "\x00" x $iv_max_length;
  $iv_buf = substr ($iv_buf, 0, $iv_max_length);

  return ($salt_len, $salt_buf, $iv_len, $iv_buf, $number_cycles_power);
}

sub get_digest
{
  my $index = shift;

  my $unpack_info = shift;
  my $substreams_info = shift;

  my $digest;

  my $digests_unpack_info = $unpack_info->{'digests'};
  my $digests_substreams_info = $substreams_info->{'digests'};

  my $use_unpack_info = 0;
  my $use_substreams_info = 0;

  if (defined ($digests_unpack_info))
  {
    my $digests_unpack_info_size = 0;

    if (@$digests_unpack_info)
    {
      $digests_unpack_info_size = scalar (@$digests_unpack_info);
    }

    if ($index < $digests_unpack_info_size)
    {
      if (ref (@$digests_unpack_info[$index]) eq "HASH")
      {
        $use_unpack_info = 1;
      }
    }
  }

  if (defined ($digests_substreams_info))
  {
    my $digests_substreams_info_size = 0;

    if (@$digests_substreams_info)
    {
      $digests_substreams_info_size = scalar (@$digests_substreams_info);
    }

    if ($index < $digests_substreams_info_size)
    {
      if (ref (@$digests_substreams_info[$index]) eq "HASH")
      {
        $use_substreams_info = 1;
      }
    }
  }

  if ($use_unpack_info == 1)
  {
    $digest = @$digests_unpack_info[$index];
  }
  elsif ($use_substreams_info == 1)
  {
    $digest = @$digests_substreams_info[$index];
  }

  return $digest;
}

sub has_encrypted_header
{
  my $folder = shift;

  my $encrypted;

  # get first coder

  my $coders = $folder->{'coders'};

  # get attributes of the first coder

  my $attributes = @$coders[0]->{'codec_id'};

  if ($attributes eq $SEVEN_ZIP_AES)
  {
    $encrypted = 1;
  }
  else
  {
    $encrypted = 0;
  }

  return $encrypted;
}

sub lzma_properties_decode
{
  my $attributes = shift;

  my $lclppb;

  $lclppb = substr ($attributes, 0, 1);

  my @data;

  #data[0] is the lclppb value

  $data[1] = ord (substr ($attributes, 1, 1));
  $data[2] = ord (substr ($attributes, 2, 1));
  $data[3] = ord (substr ($attributes, 3, 1));
  $data[4] = ord (substr ($attributes, 4, 1));

  my $dict_size = $data[1] | $data[2] << 8 | $data[3] << 16 | $data[4] << 24;

  if ($dict_size < LZMA_DICT_SIZE_MIN)
  {
    $dict_size = LZMA_DICT_SIZE_MIN;
  }

  my $d = ord ($lclppb);

  my $lc = int ($d % 9);
     $d  = int ($d / 9);
  my $pb = int ($d / 5);
  my $lp = int ($d % 5);

  return ($lclppb, $dict_size, $lc, $pb, $lp);
}

sub lzma_alone_header_field_encode
{
  my $num = shift;
  my $length = shift;

  my $value;

  my $length_doubled = $length * 2;
  my $big_endian_val = pack ("H*", sprintf ("%0${length_doubled}x", $num));

  # what follows is just some easy way to convert endianess (there might be better ways of course)

  $value = "";

  for (my $i = $length - 1; $i >= 0; $i--)
  {
    $value .= substr ($big_endian_val, $i, 1);
  }

  return $value;
}

sub extract_hash_from_archive
{
  my $fp = shift;
  my $archive = shift;
  my $file_path = shift;

  my $hash_buf = "";

  # check if everything is defined/initialized
  # and retrieve the single "objects"

  return undef unless (defined ($archive));

  my $parsed_header = $archive->{'parsed_header'};
  return undef unless (defined ($parsed_header));

  my $signature_header = $archive->{'signature_header'};
  return undef unless (defined ($signature_header));

  my $streams_info = $parsed_header->{'streams_info'};
  return undef unless (defined ($streams_info));

  my $unpack_info = $streams_info->{'unpack_info'};
  return undef unless (defined ($unpack_info));

  my $substreams_info = $streams_info->{'substreams_info'};

  my $digests = $unpack_info->{'digests'};
  return undef unless (defined ($digests));

  my $folders = $unpack_info->{'folders'};
  return undef unless (defined ($folders));

  my $pack_info = $streams_info->{'pack_info'};
  return undef unless (defined ($pack_info));

  # init file seek values

  my $position_after_header = $signature_header->{'position_after_header'};
  my $position_pack = $pack_info->{'pack_pos'};
  my $current_seek_position = $position_after_header + $position_pack;

  #
  # start:
  #

  # get first folder/coder

  my $folder_id = 0;

  my $folder = @$folders[$folder_id];

  my $number_coders = $folder->{'number_coders'};

  # check if header is encrypted

  my $has_encrypted_header = 0;

  if ($number_coders > 1)
  {
    $has_encrypted_header = 0;
  }
  else
  {
    $has_encrypted_header = has_encrypted_header ($folder);
  }

  # get the first coder

  my $coder_id = 0;

  my $coder = $folder->{'coders'}[$coder_id];
  return undef unless (defined ($coder));

  my $codec_id = $coder->{'codec_id'};

  # set index and seek to postition

  my $current_index = 0;

  seek $fp, $current_seek_position, 0;

  # if it is lzma compressed, we need to decompress it first

  if ($codec_id eq $SEVEN_ZIP_LZMA1)
  {
    # get the sizes

    my $unpack_size = $unpack_info->{'unpack_sizes'}[$current_index];

    my $data_len = $pack_info->{'pack_sizes'}[$current_index];

    # get the data

    my $data = my_read ($fp, $data_len);

    # lzma "header" stuff

    my $attributes = $coder->{'attributes'};

    my ($property_lclppb, $dict_size, $lc, $pb, $lp) = lzma_properties_decode ($attributes);

    return undef unless (length ($property_lclppb) == 1);

    # the alone-format header is defined like this:
    #
    #   +------------+----+----+----+----+--+--+--+--+--+--+--+--+
    #   | Properties |  Dictionary Size  |   Uncompressed Size   |
    #   +------------+----+----+----+----+--+--+--+--+--+--+--+--+
    #

    my $decompressed_header = "";

    # we loop over this code section max. 2 times to try two variants of headers (with the correct/specific values and with default values)

    for (my $try_number = 1; $try_number <= 2; $try_number++)
    {
      my ($dict_size_encoded, $uncompressed_size_encoded);
      my $lz = new Compress::Raw::Lzma::AloneDecoder (AppendOutput => 1);

      if ($try_number == 1)
      {
        $dict_size_encoded         = lzma_alone_header_field_encode ($dict_size,   4); # 4 bytes (the "Dictionary Size" field), little endian
        $uncompressed_size_encoded = lzma_alone_header_field_encode ($unpack_size, 8); # 8 bytes (the "Uncompressed Size" field), little endian
      }
      else
      {
        # this is the fallback case (using some default values):

        $dict_size_encoded         = pack ("H*", "00008000");         # "default" dictionary size (2^23 = 0x00800000)
        $uncompressed_size_encoded = pack ("H*", "ffffffffffffffff"); # means: unknown uncompressed size
      }

      my $lzma_alone_format_header = $property_lclppb . $dict_size_encoded . $uncompressed_size_encoded;

      my $lzma_header = $lzma_alone_format_header . $data;

      my $status = $lz->code ($lzma_header, $decompressed_header);

      if (length ($status) > 0)
      {
        if ($try_number == 2)
        {
          if ($status != LZMA_STREAM_END)
          {
            print STDERR "WARNING: the LZMA header decompression for the file '" . $file_path . "' failed with status: '" . $status . "'\n";

            if ($status eq "Data is corrupt")
            {
              print STDERR "\n";
              print STDERR "INFO: for some reasons, for large LZMA buffers, we sometimes get a 'Data is corrupt' error.\n";
              print STDERR "      This is a known issue of this tool and needs to be investigated.\n";

              print STDERR "\n";
              print STDERR "      The problem might have to do with this small paragraph hidden in the 7z documentation (quote):\n";
              print STDERR "      'The reference LZMA Decoder ignores the value of the \"Corrupted\" variable.\n";
              print STDERR "       So it continues to decode the stream, even if the corruption can be detected\n";
              print STDERR "       in the Range Decoder. To provide the full compatibility with output of the\n";
              print STDERR "       reference LZMA Decoder, another LZMA Decoder implementation must also\n";
              print STDERR "       ignore the value of the \"Corrupted\" variable.'\n";
              print STDERR "\n";
              print STDERR "      (taken from the DOC/lzma-specification.txt file of the 7z-SDK: see for instance:\n";
              print STDERR "       https://github.com/jljusten/LZMA-SDK/blob/master/DOC/lzma-specification.txt#L343-L347)\n";
            }

            return undef;
          }
        }
      }

      last if (length ($decompressed_header) > 0); # if we got some output it seems that it worked just fine
    }

    return undef unless (length ($decompressed_header) > 0);

    # in theory we should also check that the length is correct
    # return undef unless (length ($decompressed_header) == $unpack_size);

    # check the decompressed 7zip header

    $memory_buffer_read_offset = 0; # decompressed_header is a new memory buffer (which uses a offset to speed things up)

    my $id = read_id (\$decompressed_header);

    return undef unless ($id eq $SEVEN_ZIP_HEADER);

    my $header = read_seven_zip_header (\$decompressed_header);

    # override the "old" archive object

    $archive = {
      "signature_header" => $signature_header,
      "parsed_header" => $header
    };

    $parsed_header = $archive->{'parsed_header'};
    return "" unless (defined ($parsed_header));

    # this didn't change at all
    # $signature_header = $archive->{'signature_header'};
    # return undef unless (defined ($signature_header));

    $streams_info = $parsed_header->{'streams_info'};

    if (! defined ($streams_info))
    {
      print STDERR "WARNING: the file '" . $file_path . "' does not contain any meaningful data (the so-called streams info), it might only contain a list of empty files\n";

      return "";
    }

    $unpack_info = $streams_info->{'unpack_info'};
    return "" unless (defined ($unpack_info));

    $substreams_info = $streams_info->{'substreams_info'};

    $digests = $unpack_info->{'digests'};
    return "" unless (defined ($digests));

    $folders = $unpack_info->{'folders'};
    return "" unless (defined ($folders));

    my $number_folders = $unpack_info->{'number_folders'};

    $pack_info = $streams_info->{'pack_info'};
    return "" unless (defined ($pack_info));

    # loop over all folders/coders to check if we find an AES encrypted stream

    $position_pack = $pack_info->{'pack_pos'};
    $current_seek_position = $position_after_header + $position_pack; # reset the seek position

    for (my $folder_pos = 0; $folder_pos < $number_folders; $folder_pos++)
    {
      $folder = @$folders[$folder_pos];
      last unless (defined ($folder));

      $number_coders = $folder->{'number_coders'};

      for (my $coder_pos = 0; $coder_pos < $number_coders; $coder_pos++)
      {
        $coder = $folder->{'coders'}[$coder_pos];
        last unless (defined ($coder));

        $coder_id = $coder_pos; # Attention: coder_id != codec_id !

        $codec_id = $coder->{'codec_id'};

        # we stop after first AES found, but in theory we could also deal
        # with several different AES streams (in that case we would need
        # to print several hash buffers, but this is a very special case)

        last if ($codec_id eq $SEVEN_ZIP_AES);

        # ELSE: update seek position and index:

        my $pack_size = $pack_info->{'pack_sizes'}[$current_index];
        $current_seek_position += $pack_size;

        $current_index++;
      }

      last if ($codec_id eq $SEVEN_ZIP_AES);

      last unless (defined ($coder));
    }

    # if not AES we can't do anything

    if ($codec_id ne $SEVEN_ZIP_AES)
    {
      print STDERR "WARNING: no AES data found in the 7z file '" . $file_path . "'\n";

      return "";
    }
  }
  elsif ($codec_id eq $SEVEN_ZIP_LZMA2)
  {
    print STDERR "WARNING: lzma2 compression found within '" . $file_path . "' is currently not supported, ";
    print STDERR "but could be probably added easily\n";

    return "";
  }
  elsif ($codec_id ne $SEVEN_ZIP_AES)
  {
    print STDERR "WARNING: unsupported coder with codec id '" . unpack ("H*", $codec_id) . "' in file '" . $file_path . "' found.\n";
    print STDERR "If you think this codec method from DOC/Methods.txt of the 7-Zip source code ";
    print STDERR "should be supported, please file a problem report/feature request\n";

    return "";
  }

  #
  # finally: fill hash_buf
  #

  # first get the data with help of pack info

  my $unpack_size = $unpack_info->{'unpack_sizes'}[$current_index];

  my $data_len = $pack_info->{'pack_sizes'}[$current_index];

  my $digests_index = $current_index; # correct ?

  # reset the file pointer to the position after signature header and get the data

  seek $fp, $current_seek_position, 0;

  # get remaining hash info (iv, number cycles power)

  my $digest = get_digest ($digests_index, $unpack_info, $substreams_info);

  return undef unless ((defined ($digest)) && ($digest->{'defined'} == 1));

  my $attributes = $coder->{'attributes'};

  my ($salt_len, $salt_buf, $iv_len, $iv_buf, $number_cycles_power) = get_decoder_properties ($attributes);

  my $crc = $digest->{'crc'};

  # special case: we can truncate the data_len and use 32 bytes in total for both iv + data (last 32 bytes of data)

  my $is_truncated = 0;

  my $data;

  if ($has_encrypted_header == 0)
  {
    my $length_difference = $data_len - $unpack_size;

    if ($length_difference > 3)
    {
      if ($data_len > $PASSWORD_RECOVERY_TOOL_DATA_LIMIT)
      {
        seek $fp, $data_len - 32, 1;

        $iv_buf = my_read ($fp, 16);
        $iv_len = 16;

        $data = my_read ($fp, 16);
        $data_len = 16;

        $unpack_size %= 16;

        $is_truncated = 1;
      }
    }
  }

  if (! defined ($data))
  {
    $data = my_read ($fp, $data_len);
  }

  return undef unless (length ($data) == $data_len);

  if ($data_len > $PASSWORD_RECOVERY_TOOL_DATA_LIMIT)
  {
    print STDERR "WARNING: the file '". $file_path . "' unfortunately can't be used with $PASSWORD_RECOVERY_TOOL_NAME since the data length\n";
    print STDERR "in this particular case is too long ($data_len of the maximum allowed $PASSWORD_RECOVERY_TOOL_DATA_LIMIT bytes) ";
    print STDERR "and it can't be truncated.\n";
    print STDERR "This should only happen in very rare cases.\n";

    return "";
  }

  my $type_of_compression    = $SEVEN_ZIP_UNCOMPRESSED;
  my $compression_attributes = "";

  for (my $coder_pos = $coder_id; $coder_pos < $number_coders; $coder_pos++)
  {
    $coder = $folder->{'coders'}[$coder_pos];
    last unless (defined ($coder));

    $codec_id = $coder->{'codec_id'};

    if ($codec_id eq $SEVEN_ZIP_LZMA1)
    {
      $compression_attributes = unpack ("H*", $coder->{'attributes'});
      $type_of_compression    = $SEVEN_ZIP_LZMA1_COMPRESSED;
    }
    elsif ($codec_id eq $SEVEN_ZIP_LZMA2)
    {
      $compression_attributes = unpack ("H*", $coder->{'attributes'});
      $type_of_compression    = $SEVEN_ZIP_LZMA2_COMPRESSED;
    }
    elsif ($codec_id eq $SEVEN_ZIP_PPMD_COMPRESSED)
    {
      $compression_attributes = unpack ("H*", $coder->{'attributes'});
      $type_of_compression    = $SEVEN_ZIP_PPMD_COMPRESSED;
    }
    elsif ($codec_id eq $SEVEN_ZIP_BCJ_COMPRESSED)
    {
      $compression_attributes = unpack ("H*", $coder->{'attributes'});
      $type_of_compression    = $SEVEN_ZIP_BCJ_COMPRESSED;
    }
    elsif ($codec_id eq $SEVEN_ZIP_BCJ2_COMPRESSED)
    {
      $compression_attributes = unpack ("H*", $coder->{'attributes'});
      $type_of_compression    = $SEVEN_ZIP_BCJ2_COMPRESSED;
    }
    elsif ($codec_id eq $SEVEN_ZIP_BZIP2_COMPRESSED)
    {
      $compression_attributes = unpack ("H*", $coder->{'attributes'});
      $type_of_compression    = $SEVEN_ZIP_BZIP2_COMPRESSED;
    }
    elsif ($codec_id eq $SEVEN_ZIP_DEFLATE_COMPRESSED)
    {
      $compression_attributes = unpack ("H*", $coder->{'attributes'});
      $type_of_compression    = $SEVEN_ZIP_DEFLATE_COMPRESSED;
    }
  }

  # show a warning if LZMA/LZMA2 decompression is currently not supported by the cracker

  if ($SHOW_LZMA_DECOMPRESS_AFTER_DECRYPT_WARNING == 1)
  {
    if ($is_truncated == 0)
    {
      if (grep ("/^$type_of_compression$/", @PASSWORD_RECOVERY_TOOL_SUPPORTED_DECOMPRESSORS) == 0)
      {
        print STDERR "WARNING: to correctly verify the CRC checksum of the data contained within the file '". $file_path . "',\n";
        print STDERR "the data must be decompressed using " . $SEVEN_ZIP_COMPRESSOR_NAMES{$type_of_compression};
        print STDERR " after the decryption step.\n";
        print STDERR "\n";
        print STDERR "$PASSWORD_RECOVERY_TOOL_NAME currently does not support this particular decompression.\n";
        print STDERR "\n";

        if ($type_of_compression == $SEVEN_ZIP_LZMA2_COMPRESSED) # this special case should only work for LZMA2 
        {
          if ($data_len <= $LZMA2_MIN_COMPRESSED_LEN)
          {
            print STDERR "INFO: it might still be possible to crack the password of this archive since the data part seems\n";
            print STDERR "to be very short and therefore it might use the LZMA2 uncompressed chunk feature\n";
            print STDERR "\n";
          }
        }
      }
    }
  }

  my $type_of_data = 0; # this variable will hold the "number" after the "$7z$" hash signature

  if ($is_truncated == 1)
  {
    $type_of_data = $SEVEN_ZIP_TRUNCATED; # note: this means that we neither need the crc_len, nor the coder attributes
  }
  else
  {
    $type_of_data = $type_of_compression;
  }

  $hash_buf = sprintf ("%s%i\$%i\$%i\$%s\$%i\$%s\$%i\$%i\$%i\$%s",
    $SEVEN_ZIP_HASH_SIGNATURE,
    $type_of_data,
    $number_cycles_power,
    $salt_len,
    unpack ("H*", $salt_buf),
    $iv_len,
    unpack ("H*", $iv_buf),
    $crc,
    $data_len,
    $unpack_size,
    unpack ("H*", $data)
  );

  return $hash_buf if ($type_of_data == $SEVEN_ZIP_UNCOMPRESSED);
  return $hash_buf if ($type_of_data == $SEVEN_ZIP_TRUNCATED);

  my $crc_len = $substreams_info->{'unpack_sizes'}[0]; # we always stick to the first file here

  $hash_buf .= sprintf ("\$%i\$%s",
    $crc_len,
    $compression_attributes
  );

  return $hash_buf;
}

sub read_seven_zip_signature_header
{
  my $fp = shift;

  my $signature;

  # ArchiveVersion

  my $major_version = my_read ($fp, 1);

  $major_version = ord ($major_version);

  my $minor_version = my_read ($fp, 1);

  $minor_version = ord ($minor_version);

  # StartHeaderCRC

  my_read ($fp, 4); # skip start header CRC

  # StartHeader

  my $next_header_offset = get_uint64 ($fp);
  my $next_header_size   = get_uint64 ($fp);

  my_read ($fp, 4); # next header CRC

  my $position_after_header = tell $fp;

  $signature = {
    "major_version" => $major_version,
    "minor_version" => $minor_version,
    "next_header_offset" => $next_header_offset,
    "next_header_size" => $next_header_size,
    "position_after_header" => $position_after_header
  };

  return $signature;
}

sub skip_seven_zip_data
{
  my $fp = shift;

  # determine the length to skip

  my $len = my_read ($fp, 1);

  # do skip len bytes

  $len = ord ($len);

  my_read ($fp, $len);
}

sub wait_for_seven_zip_id
{
  my $fp = shift;
  my $id = shift;

  while (1)
  {
    my $new_id = read_id ($fp);

    if ($new_id eq $id)
    {
      return 1;
    }
    elsif ($new_id eq $SEVEN_ZIP_END)
    {
      return 0;
    }

    skip_seven_zip_data ($fp);
  }

  return 0;
}

sub read_seven_zip_digests
{
  my $fp = shift;

  my $number_items = shift;

  my @digests;

  # init

  for (my $i = 0; $i < $number_items; $i++)
  {
    my $digest = {
      "crc" => "",
      "defined" => 0
    };

    push (@digests, $digest)
  }

  # get number of items

  my @digests_defined = get_boolean_vector_check_all ($fp, $number_items);

  # for each number of item, get a digest

  for (my $i = 0; $i < $number_items; $i++)
  {
    my $crc = 0;

    for (my $i = 0; $i < 4; $i++)
    {
      my $val = my_read ($fp, 1);

      $val = ord ($val);

      $crc |= ($val << (8 * $i));
    }

    $digests[$i]->{'crc'} = $crc;
    $digests[$i]->{'defined'} = $digests_defined[$i];
  }

  return @digests;
}

sub read_seven_zip_pack_info
{
  my $fp = shift;

  my $pack_info;

  # PackPos

  my $pack_pos = read_number  ($fp);

  # NumPackStreams

  my $number_pack_streams = read_number ($fp);

  # must be "size" id

  if (! wait_for_seven_zip_id ($fp, $SEVEN_ZIP_SIZE))
  {
    return undef;
  }

  my @pack_sizes = (0) x $number_pack_streams;

  for (my $i = 0; $i < $number_pack_streams; $i++)
  {
    $pack_sizes[$i] = read_number ($fp);
  }

  $pack_info = {
    "number_pack_streams" => $number_pack_streams,
    "pack_pos" => $pack_pos,
    "pack_sizes" => \@pack_sizes
  };

  # read remaining data

  while (1)
  {
    my $id = read_id ($fp);

    if ($id eq $SEVEN_ZIP_END)
    {
      return $pack_info;
    }
    elsif ($id eq $SEVEN_ZIP_CRC)
    {
      my $digests = read_seven_zip_digests ($fp, $number_pack_streams);

      # we do not need those digests, ignore them
      # (but we need to read them from the stream)

      next;
    }

    skip_seven_zip_data ($fp);
  }

  # something went wrong

  return undef;
}

sub read_seven_zip_folders
{
  my $fp = shift;

  my $folder;

  my @coders = ();
  my @bindpairs = ();
  my $index_main_stream = 0;
  my $sum_input_streams  = 0;
  my $sum_output_streams = 0;
  my $sum_packed_streams = 1;

  # NumCoders

  my $number_coders = read_number ($fp);

  # loop

  for (my $i = 0; $i < $number_coders; $i++)
  {
    my $main_byte = my_read ($fp, 1);

    $main_byte = ord ($main_byte);

    if ($main_byte & 0xC0)
    {
      return undef;
    }

    my $codec_id_size = $main_byte & 0xf;

    if ($codec_id_size > 8)
    {
      return undef;
    }

    # the codec id (very important info for us):
    # codec_id: 06F10701 -> AES-256 + SHA-256
    # codec_id: 030101   -> lzma  (we need to decompress - k_LZMA)
    # codec_id: 21       -> lzma2 (we need to decompress - k_LZMA2)

    my $codec_id = my_read ($fp, $codec_id_size);

    # NumInStreams

    my $number_input_streams = 1;

    # NumOutStreams

    my $number_output_streams = 1;

    if (($main_byte & 0x10) != 0)
    {
      $number_input_streams  = read_number ($fp);
      $number_output_streams = read_number ($fp);
    }

    $sum_input_streams  += $number_input_streams;
    $sum_output_streams += $number_output_streams;

    # attributes

    my $attributes;

    if (($main_byte & 0x020) != 0)
    {
      my $property_size = read_number ($fp);

      $attributes = my_read ($fp, $property_size);
    }

    $coders[$i] = {
      "codec_id" => $codec_id,
      "number_input_streams" => $number_input_streams,
      "number_output_streams" => $number_output_streams,
      "attributes" => $attributes
    };
  }

  if (($sum_input_streams != 1) || ($sum_output_streams != 1))
  {
    # InStreamUsed / OutStreamUsed

    my @input_stream_used  = (0) x $sum_input_streams;
    my @output_stream_used = (0) x $sum_output_streams;

    # BindPairs

    my $number_bindpairs = $sum_output_streams - 1;

    for (my $i = 0; $i < $number_bindpairs; $i++)
    {
      # input

      my $index_input = read_number ($fp);

      if ($input_stream_used[$index_input] == 1)
      {
        return undef; # the stream is used already, shouldn't happen at all
      }

      $input_stream_used[$index_input] = 1;

      # output

      my $index_output = read_number ($fp);

      if ($output_stream_used[$index_output] == 1)
      {
        return undef;
      }

      $output_stream_used[$index_output] = 1;

      my @new_bindpair = ($index_input, $index_output);

      push (@bindpairs, \@new_bindpair);
    }

    # PackedStreams

    $sum_packed_streams = $sum_input_streams - $number_bindpairs;

    if ($sum_packed_streams != 1)
    {
      for (my $i = 0; $i < $sum_packed_streams; $i++)
      {
        # we can ignore this

        read_number ($fp); # my $index = read_number ($fp);
      }
    }

    # determine the main stream

    $index_main_stream = -1;

    for (my $i = 0; $i < $sum_output_streams; $i++)
    {
      if ($output_stream_used[$i] == 0)
      {
        $index_main_stream = $i;

        last;
      }
    }

    if ($index_main_stream == -1)
    {
      return undef; # should not happen
    }
  }

  $folder = {
    "number_coders" => $number_coders,
    "coders" => \@coders,
    "bindpairs" => \@bindpairs,
    "index_main_stream"  => $index_main_stream,
    "sum_input_streams"  => $sum_input_streams,
    "sum_output_streams" => $sum_output_streams,
    "sum_packed_streams" => $sum_packed_streams,
  };

  return $folder;
}

sub read_seven_zip_unpack_info
{
  my $fp = shift;

  my $unpack_info;

  my $number_folders = 0;
  my @folders = ();
  my @datastream_indices = ();
  my @unpack_sizes;
  my @digests;
  my @main_unpack_size_index;
  my @coder_unpack_sizes;

  # check until we see the "folder" id

  if (! wait_for_seven_zip_id ($fp, $SEVEN_ZIP_FOLDER))
  {
    return undef;
  }

  # NumFolders

  $number_folders = read_number ($fp);

  # External

  my $external = my_read ($fp, 1);

  # loop

  my $sum_coders_output_streams = 0;
  my $sum_folders = 0;

  for (my $i = 0; $i < $number_folders; $i++)
  {
    if ($external eq $SEVEN_ZIP_NOT_EXTERNAL)
    {
      my $folder = read_seven_zip_folders ($fp);

      $folders[$i] = $folder;

      $main_unpack_size_index[$i] = $folder->{'index_main_stream'};
      $coder_unpack_sizes[$i] = $sum_coders_output_streams;

      $sum_coders_output_streams += $folder->{'sum_output_streams'};

      $sum_folders++;
    }
    elsif ($external eq $SEVEN_ZIP_EXTERNAL)
    {
      $datastream_indices[$i] = read_number ($fp);
    }
    else
    {
      return undef;
    }
  }

  if (!wait_for_seven_zip_id ($fp, $SEVEN_ZIP_UNPACK_SIZE))
  {
    return undef;
  }

  for (my $i = 0; $i < $sum_coders_output_streams; $i++)
  {
    $unpack_sizes[$i] = read_number ($fp);
  }

  # read remaining data

  while (1)
  {
    my $id = read_id ($fp);

    if ($id eq $SEVEN_ZIP_END)
    {
      $unpack_info = {
        "number_folders" => $number_folders,
        "folders" => \@folders,
        "datastream_indices" => \@datastream_indices,
        "digests" => \@digests,
        "unpack_sizes" => \@unpack_sizes,
        "main_unpack_size_index" => \@main_unpack_size_index,
        "coder_unpack_sizes" => \@coder_unpack_sizes
      };

      return $unpack_info;
    }
    elsif ($id eq $SEVEN_ZIP_CRC)
    {
      my @new_digests = read_seven_zip_digests ($fp, $sum_folders);

      for (my $i = 0; $i < $sum_folders; $i++)
      {
        $digests[$i]->{'defined'} = $new_digests[$i]->{'defined'};
        $digests[$i]->{'crc'} = $new_digests[$i]->{'crc'};
      }

      next;
    }

    skip_seven_zip_data ($fp);
  }

  # something went wrong

  return undef;
}

sub get_folder_unpack_size
{
  my $unpack_info  = shift;
  my $folder_index = shift;

  my $index = $unpack_info->{'coder_unpack_sizes'}[$folder_index] + $unpack_info->{'main_unpack_size_index'}[$folder_index];

  return $unpack_info->{'unpack_sizes'}[$index];
}

sub has_valid_folder_crc
{
  my $digests = shift;
  my $index   = shift;

  if (! defined (@$digests[$index]))
  {
    return 0;
  }

  my $digest = @$digests[$index];

  if ($digest->{'defined'} != 1)
  {
    return 0;
  }

  if (length ($digest->{'crc'}) < 1)
  {
    return 0;
  }

  return 1;
}

sub read_seven_zip_substreams_info
{
  my $fp = shift;

  my $unpack_info = shift;

  my $number_folders = $unpack_info->{'number_folders'};
  my $folders = $unpack_info->{'folders'};

  my $folders_digests = $unpack_info->{'digests'};

  my $substreams_info;
  my @number_unpack_streams = (1) x $number_folders;
  my @unpack_sizes;
  my @digests;

  # get the numbers of unpack streams

  my $id;

  while (1)
  {
    $id = read_id ($fp);

    if ($id eq $SEVEN_ZIP_NUM_UNPACK_STREAM)
    {
      for (my $i = 0; $i < $number_folders; $i++)
      {
        $number_unpack_streams[$i] = read_number ($fp);
      }

      next;
    }
    elsif ($id eq $SEVEN_ZIP_CRC)
    {
      last;
    }
    elsif ($id eq $SEVEN_ZIP_SIZE)
    {
      last;
    }
    elsif ($id eq $SEVEN_ZIP_END)
    {
      last;
    }

    skip_seven_zip_data ($fp);
  }

  if ($id eq $SEVEN_ZIP_SIZE)
  {
    for (my $i = 0; $i < $number_folders; $i++)
    {
      my $number_substreams = $number_unpack_streams[$i];

      if ($number_substreams == 0)
      {
        next;
      }

      my $sum_unpack_sizes = 0;

      for (my $j = 1; $j < $number_substreams; $j++)
      {
        my $size = read_number ($fp);

        push (@unpack_sizes, $size);

        $sum_unpack_sizes += $size;
      }

      # add the folder unpack size itself

      my $folder_unpack_size = get_folder_unpack_size ($unpack_info, $i);

      if ($folder_unpack_size < $sum_unpack_sizes)
      {
        return undef;
      }

      my $size = $folder_unpack_size - $sum_unpack_sizes;

      push (@unpack_sizes, $size);
    }

    $id = read_id ($fp);
  }
  else
  {
    for (my $i = 0; $i < $number_folders; $i++)
    {
      my $number_substreams = $number_unpack_streams[$i];

      if ($number_substreams > 1)
      {
        return undef;
      }

      if ($number_substreams == 1)
      {
        push (@unpack_sizes, get_folder_unpack_size ($unpack_info, $i));
      }
    }
  }

  my $number_digests = 0;

  for (my $i = 0; $i < $number_folders; $i++)
  {
    my $number_substreams = $number_unpack_streams[$i];

    if (($number_substreams != 1) || (has_valid_folder_crc ($folders_digests, $i) == 0))
    {
      $number_digests += $number_substreams;
    }
  }

  while (1)
  {
    if ($id eq $SEVEN_ZIP_END)
    {
      last;
    }
    elsif ($id eq $SEVEN_ZIP_CRC)
    {
      my @is_digest_defined = get_boolean_vector_check_all ($fp, $number_digests);

      my $k  = 0;
      my $k2 = 0;

      for (my $i = 0; $i < $number_folders; $i++)
      {
        my $number_substreams = $number_unpack_streams[$i];

        if (($number_substreams == 1) && (has_valid_folder_crc ($folders_digests, $i)))
        {
          $digests[$k]->{'defined'} = 1;
          $digests[$k]->{'crc'} = @$folders_digests[$i]->{'crc'};

          $k++;
        }
        else
        {
          for (my $j = 0; $j < $number_substreams; $j++)
          {
            my $defined = $is_digest_defined[$k2];

            # increase k2

            $k2++;

            if ($defined == 1)
            {
              my $digest = 0;

              for (my $i = 0; $i < 4; $i++)
              {
                my $val = my_read ($fp, 1);

                $val = ord ($val);

                $digest |= ($val << (8 * $i));
              }

              $digests[$k]->{'defined'} = 1;
              $digests[$k]->{'crc'} = $digest;
            }
            else
            {
              $digests[$k]->{'defined'} = 0;
              $digests[$k]->{'crc'} = 0;
            }

            $k++;
          }
        }
      }
    }
    else
    {
      skip_seven_zip_data ($fp);
    }

    $id = read_id ($fp);
  }

  my $len_defined = scalar (@digests);
  my $len_unpack_sizes = scalar (@unpack_sizes);

  if ($len_defined != $len_unpack_sizes)
  {
    my $k = 0;

    for (my $i = 0; $i < $number_folders; $i++)
    {
      my $number_substreams = $number_unpack_streams[$i];

      if (($number_substreams == 1) && (has_valid_folder_crc ($folders_digests, $i)))
      {
        $digests[$k]->{'defined'} = 1;
        $digests[$k]->{'crc'} = @$folders_digests[$i]->{'crc'};

        $k++;
      }
      else
      {
        for (my $j = 0; $j < $number_substreams; $j++)
        {
          $digests[$k]->{'defined'} = 0;
          $digests[$k]->{'crc'} = 0;

          $k++;
        }
      }
    }
  }

  $substreams_info = {
    "unpack_stream_numbers" => \@number_unpack_streams,
    "unpack_sizes" => \@unpack_sizes,
    "number_digests" => $number_digests,
    "digests" => \@digests
  };

  return $substreams_info;
}

sub read_seven_zip_streams_info
{
  my $fp = shift;

  my $streams_info;

  my $pack_info;
  my $unpack_info;
  my $substreams_info;

  # get the type of streams info (id)

  my $id = read_id ($fp);

  if ($id eq $SEVEN_ZIP_PACK_INFO)
  {
    $pack_info = read_seven_zip_pack_info ($fp);

    return undef unless (defined ($pack_info));

    $id = read_id ($fp);
  }

  if ($id eq $SEVEN_ZIP_UNPACK_INFO)
  {
    $unpack_info = read_seven_zip_unpack_info ($fp);

    return undef unless (defined ($unpack_info));

    $id = read_id ($fp);
  }

  if ($id eq $SEVEN_ZIP_SUBSTREAMS_INFO)
  {
    $substreams_info = read_seven_zip_substreams_info ($fp, $unpack_info);

    return undef unless (defined ($substreams_info));

    $id = read_id ($fp);
  }
  else
  {
    my @number_unpack_streams = ();
    my @unpack_sizes = ();
    my $number_digests = 0;
    my $digests;

    if (defined ($unpack_info))
    {
      my $folders = $unpack_info->{'folders'};

      my $number_folders = $unpack_info->{'number_folders'};

      for (my $i = 0; $i < $number_folders; $i++)
      {
        $number_unpack_streams[$i] = 1;

        my $folder_unpack_size = get_folder_unpack_size ($unpack_info, $i);

        push (@unpack_sizes, $folder_unpack_size);
      }
    }

    $substreams_info = {
      "unpack_stream_numbers" => \@number_unpack_streams,
      "unpack_sizes" => \@unpack_sizes,
      "number_digests" => $number_digests,
      "digests" => $digests
    };
  }

  $streams_info = {
    "pack_info" => $pack_info,
    "unpack_info" => $unpack_info,
    "substreams_info" => $substreams_info
  };

  return $streams_info;
}

sub folder_seven_zip_decode
{
  my $streams_info = shift;

  my $number_coders = 0;

  for (my $i = 0; $i < $number_coders; $i++)
  {
  }
  #parse_folder ();

  return;
}

sub read_seven_zip_archive_properties
{
  my $fp = shift;

  # also the 7-Zip source code just skip data from the archive property entry

  while (1)
  {
    my $id = read_id ($fp);

    if ($id eq $SEVEN_ZIP_END)
    {
      return 1;
    }

    skip_seven_zip_data ($fp);
  }

  # something went wrong

  return 0;
}

sub get_uint64_defined_vector
{
  my $fp = shift;

  my $number_items = shift;

  my @values;

  # first check if the values are defined

  my @defines = get_boolean_vector_check_all ($fp, $number_items);

  my $external = my_read ($fp, 1);

  if ($external eq $SEVEN_ZIP_EXTERNAL)
  {
    # ignored for now
  }

  for (my $i = 0; $i < $number_items; $i++)
  {
    my $defined = $defines[$i];

    my $value = 0;

    if ($defined != 0)
    {
      $value = get_uint64 ($fp);
    }

    $values[$i] = $value;
  }

  return @values;
}

sub read_seven_zip_files_info
{
  my $fp = shift;

  my $streams_info = shift;

  my $files_info;

  my @files;

  # NumFiles

  my $number_files = read_number ($fp);

  # init file

  for (my $i = 0; $i < $number_files; $i++)
  {
    $files[$i]->{'name_utf16'} = "";
    $files[$i]->{'attribute_defined'} = 0;
    $files[$i]->{'attribute'} = 0;
    $files[$i]->{'is_empty_stream'} = 0;
    $files[$i]->{'start_position'} = 0;
    $files[$i]->{'creation_time'} = 0;
    $files[$i]->{'access_time'} = 0;
    $files[$i]->{'modification_time'} = 0;
    $files[$i]->{'size'} = 0;
    $files[$i]->{'has_stream'} = 0;
    $files[$i]->{'is_dir'} = 0;
    $files[$i]->{'crc_defined'} = 0;
    $files[$i]->{'crc'} = "";
  }

  my $number_empty_streams = 0;

  my @empty_streams = (0) x $number_files;
  my @empty_files   = (0) x $number_files;
  my @anti_files    = (0) x $number_files;

  # loop over all properties

  while (1)
  {
    my $property_type_val = read_number ($fp);

    my $property_type = num_to_id ($property_type_val);

    if ($property_type eq $SEVEN_ZIP_END)
    {
      last;
    }

    # Size

    my $size = read_number ($fp);

    # check and act according to the type of property found

    my $is_known_type = 1;

    if ($property_type_val > $SEVEN_ZIP_MAX_PROPERTY_TYPE)
    {
      # ignore (isKnownType false in 7-Zip source code)

      my_read ($fp, $size);
    }
    else
    {
      if ($property_type eq $SEVEN_ZIP_NAME)
      {
        my $external = my_read ($fp, 1);

        if ($external eq $SEVEN_ZIP_EXTERNAL)
        {
          # TODO: not implemented yet

          return undef;
        }

        my $files_size = scalar (@files);

        for (my $i = 0; $i < $files_size; $i++)
        {
          my $name = "";

          while (1)
          {
            my $name_part = my_read ($fp, 2);

            if ($name_part eq $SEVEN_ZIP_FILE_NAME_END)
            {
              last;
            }
            else
            {
              $name .= $name_part;
            }
          }

          $files[$i]->{'name_utf16'} = $name;
        }
      }
      elsif ($property_type eq $SEVEN_ZIP_WIN_ATTRIBUTE)
      {
        my $files_size = scalar (@files);

        my @booleans = get_boolean_vector_check_all ($fp, $number_files);

        my $external = my_read ($fp, 1);

        if ($external eq $SEVEN_ZIP_EXTERNAL)
        {
          # TODO: not implemented yet

          return undef;
        }

        for (my $i = 0; $i < $number_files; $i++)
        {
          my $defined = $booleans[$i];

          $files[$i]->{'attribute_defined'} = $defined;

          if ($defined)
          {
            my $attributes = get_uint32 ($fp);

            $files[$i]->{'attribute'} = $attributes;
          }
        }
      }
      elsif ($property_type eq $SEVEN_ZIP_EMPTY_STREAM)
      {
        @empty_streams = get_boolean_vector ($fp, $number_files);

        $number_empty_streams = 0;

        # loop over all boolean and set the files attribute + empty/anti stream vector

        my $number_booleans = scalar (@empty_streams);

        for (my $i = 0; $i < $number_booleans; $i++)
        {
          my $boolean = $empty_streams[$i];

          $files[$i]->{'is_empty_stream'} = $boolean;

          if ($boolean)
          {
            $number_empty_streams++;
          }
        }

        for (my $i = 0; $i < $number_empty_streams; $i++)
        {
          $empty_files[$i] = 0;
          $anti_files[$i]  = 0;
        }
      }
      elsif ($property_type eq $SEVEN_ZIP_EMPTY_FILE)
      {
        @empty_files = get_boolean_vector ($fp, $number_empty_streams);
      }
      elsif ($property_type eq $SEVEN_ZIP_ANTI_FILE)
      {
        @anti_files = get_boolean_vector ($fp, $number_empty_streams);
      }
      elsif ($property_type eq $SEVEN_ZIP_START_POS)
      {
        my @start_positions = get_uint64_defined_vector ($fp, $number_files);

        my $number_start_positions = scalar (@start_positions);

        for (my $i = 0; $i < $number_start_positions; $i++)
        {
          $files[$i]->{'start_position'} = $start_positions[$i];
        }
      }
      elsif ($property_type eq $SEVEN_ZIP_CREATION_TIME)
      {
        my @creation_times = get_uint64_defined_vector ($fp, $number_files);

        my $number_creation_times = scalar (@creation_times);

        for (my $i = 0; $i < $number_creation_times; $i++)
        {
          $files[$i]->{'creation_time'} = $creation_times[$i];
        }
      }
      elsif ($property_type eq $SEVEN_ZIP_ACCESS_TIME)
      {
        my @access_times = get_uint64_defined_vector ($fp, $number_files);

        my $number_access_times = scalar (@access_times);

        for (my $i = 0; $i < $number_access_times; $i++)
        {
          $files[$i]->{'access_time'} = $access_times[$i];
        }
      }
      elsif ($property_type eq $SEVEN_ZIP_MODIFICATION_TIME)
      {
        my @modification_times = get_uint64_defined_vector ($fp, $number_files);

        my $number_modification_times = scalar (@modification_times);

        for (my $i = 0; $i < $number_modification_times; $i++)
        {
          $files[$i]->{'modification_time'} = $modification_times[$i];
        }
      }
      elsif ($property_type eq $SEVEN_ZIP_DUMMY)
      {
        my $compare_bytes = "\x00" x $size;

        my $bytes = my_read ($fp, $size);

        if ($bytes ne $compare_bytes)
        {
          return undef;
        }
      }
      else
      {
        # ignore (isKnownType also in 7-Zip source code)

        my_read ($fp, $size);
      }
    }
  }

  # next id should be SEVEN_ZIP_END, but we (and 7-ZIP source code too) do not care

  my $id = read_id ($fp);

  # check anti files

  my $number_anti_items = 0;

  for (my $i = 0; $i < $number_empty_streams; $i++)
  {
    if ($anti_files[$i] != 0)
    {
      $number_anti_items++;
    }
  }

  # set digests depending on empty/anti files

  my $index_sizes = 0;
  my $index_empty_files = 0;

  my $unpack_info = $streams_info->{'unpack_info'};
  my $substreams_info = $streams_info->{'substreams_info'};

  for (my $i = 0; $i < $number_files; $i++)
  {
    my $is_anti = 0;
    my $has_stream = 1;

    if ($empty_streams[$i] == 1)
    {
      $has_stream = 0;
    }

    $files[$i]->{'has_stream'} = $has_stream;
    $files[$i]->{'crc'} = "";

    if ($has_stream == 1)
    {
      $is_anti = 0;

      $files[$i]->{'is_dir'} = 0;
      $files[$i]->{'size'} = $unpack_info->{'unpack_sizes'}[$index_sizes];

      $files[$i]->{'crc_defined'} = 0;
      $files[$i]->{'crc'} = "";

      my $is_crc_defined = has_valid_folder_crc ($unpack_info->{'digests'}, $index_sizes);

      if ($is_crc_defined == 1)
      {
        $files[$i]->{'crc_defined'} = 1;

        my $crc_item = $unpack_info->{'digests'}[$index_sizes];

        $files[$i]->{'crc'} = $crc_item->{crc};
      }
      else
      {
        # can we really do this too?

        $is_crc_defined = has_valid_folder_crc ($substreams_info->{'digests'}, $index_sizes);

        if ($is_crc_defined == 1)
        {
          $files[$i]->{'crc_defined'} = 1;

          my $crc_item = $substreams_info->{'digests'}[$index_sizes];

          $files[$i]->{'crc'} = $crc_item->{crc};
        }
      }

      $index_sizes++;
    }
    else
    {
      my $is_dir = 0;

      if ($empty_files[$index_empty_files] == 0)
      {
        $files[$i]->{'is_dir'} = 1;
      }
      else
      {
        $files[$i]->{'is_dir'} = 0;
      }

      $files[$i]->{'size'} = 0;

      $files[$i]->{'crc_defined'} = 0;
      $files[$i]->{'crc'} = "";

      $index_empty_files++;
    }
  }

  $files_info = {
    "number_files" => $number_files,
    "files" => \@files
  };

  return $files_info;
}

sub read_seven_zip_header
{
  my $fp = shift;

  my $header;

  my $additional_streams_info;
  my $streams_info;
  my $files_info;

  # get the type of header

  my $id = read_id ($fp);

  if ($id eq $SEVEN_ZIP_ARCHIVE_PROPERTIES)
  {
    # we just ignore the data here (but we need to read it from the stream!)

    if (! read_seven_zip_archive_properties ($fp))
    {
      return undef;
    }

    $id = read_id ($fp);
  }

  if ($id eq $SEVEN_ZIP_ADD_STREAMS_INFO)
  {
    $additional_streams_info = read_and_decode_seven_zip_packed_stream ($fp);

    return undef unless (defined ($additional_streams_info));

    # do we need to change the start position here ?

    $id = read_id ($fp);
  }

  if ($id eq $SEVEN_ZIP_MAIN_STREAMS_INFO)
  {
    $streams_info = read_seven_zip_streams_info ($fp);

    return undef unless (defined ($streams_info));

    $id = read_id ($fp);
  }

  if ($id eq $SEVEN_ZIP_FILES_INFO)
  {
    $files_info = read_seven_zip_files_info ($fp, $streams_info);

    return undef unless (defined ($files_info));
  }

  $header = {
    "additional_streams_info" => $additional_streams_info,
    "streams_info" => $streams_info,
    "files_info" => $files_info,
    "type" => "raw"
  };

  return $header;
}

sub read_and_decode_seven_zip_packed_stream
{
  my $fp = shift;

  my $packed_stream;

  $packed_stream = read_seven_zip_streams_info ($fp);

  # for each folder, get the decoder and decode the data

  return $packed_stream;
}

sub parse_seven_zip_header
{
  my $fp = shift;

  my $header;
  my $streams_info;

  # get the type of the header (id)

  my $id = read_id ($fp);

  # check if either encoded/packed or encrypted: to get the details we need to check the method

  if ($id ne $SEVEN_ZIP_HEADER)
  {
    if ($id ne $SEVEN_ZIP_ENCODED_HEADER)
    {
      print STDERR "WARNING: only encoded headers are allowed if no raw header is present\n";

      return undef;
    }

    $streams_info = read_and_decode_seven_zip_packed_stream ($fp);

    return undef unless (defined ($streams_info));

    $header = {
      "additional_streams_info" => undef,
      "streams_info" => $streams_info,
      "files_info" => undef,
      "type" => "encoded"
    }

    # Note: now the 7-Zip code normally parses the header (which we got from the decode operation above)
    # but we do not really need to do this here. Skip
  }
  else
  {
    $header = read_seven_zip_header ($fp);
  }

  return $header;
}

sub read_seven_zip_next_header
{
  my $fp = shift;

  my $header_size   = shift;
  my $header_offset = shift;

  my $header;

  # get the header of size header_size at relative position header_offset

  seek $fp, $header_offset, 1;

  # read the header

  $header = parse_seven_zip_header ($fp);

  return $header;
}

sub read_seven_zip_archive
{
  my $fp = shift;

  my $archive;

  # SignatureHeader

  my $signature = read_seven_zip_signature_header ($fp);

  return undef unless (defined ($signature));

  # parse the header

  my $parsed_header = read_seven_zip_next_header ($fp, $signature->{'next_header_size'}, $signature->{'next_header_offset'});

  return undef unless (defined ($parsed_header));

  $archive = {
    "signature_header" => $signature,
    "parsed_header" => $parsed_header
  };

  return $archive;
}

sub seven_zip_get_hash
{
  my $file_path = shift;

  my $hash_buf = "";

  # open file for reading

  my $seven_zip_file;

  if (! open ($seven_zip_file, "<$file_path"))
  {
    print STDERR "WARNING: could not open the file '$file_path' for reading\n";

    return $hash_buf;
  }

  binmode ($seven_zip_file);

  # check if valid and supported 7z file

  if (! is_supported_seven_zip_file ($seven_zip_file))
  {
    print STDERR "WARNING: the file '$file_path' is not a supported 7-Zip file\n";

    return $hash_buf;
  }

  my $archive = read_seven_zip_archive ($seven_zip_file);

  $hash_buf = extract_hash_from_archive ($seven_zip_file, $archive, $file_path);

  # cleanup

  close ($seven_zip_file);

  return $hash_buf;
}

#
# Start
#

if (scalar (@ARGV) lt 1)
{
  usage ($0);

  exit (1);
}

foreach my $file_name (@ARGV)
{
  if (! -e $file_name)
  {
    print STDERR "WARNING: could not open file '$file_name'\n";

    next;
  }

  my $hash_buf = seven_zip_get_hash ($file_name);

  next unless (defined ($hash_buf));
  next unless (length ($hash_buf) > 0);

  print $hash_buf . "\n";
}

exit (0);
