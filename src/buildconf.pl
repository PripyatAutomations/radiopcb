#!/usr/bin/perl
#
# Convert $profile.json to an eeprom.bin and appropriate headers needed to build
# the radio software, either natively or cross compiled.
# $profile defaults to 'radio' but can be provided as the first (and only) argument
###############################################################################
# arguments: [profile] [import|export]
#
# XXX: This won't work on BIG ENDIAN build hosts, unless targetting a BE system
# XXX: Images created in this manner will not be compatible with LITTLE ENDIAN toolchains or devices
# XXX: Fix this someday if there's interest?
use strict;
use warnings;
use Config;
use Getopt::Std;
use IO::Handle;
use JSON;
use Data::Dumper;
use Devel::Peek;
use MIME::Base64;
use Hash::Merge qw(merge);
use Mojo::JSON::Pointer;
use String::CRC32;
use File::Path qw(make_path remove_tree);

# Toggle to 1 to show debugging messages, 0 to disable
my $DEBUG = 1;

my $eeprom_version = 1;

# Hash sort stuff (i forget what this do, but it's important ;)
Hash::Merge::set_behavior('RIGHT_PRECEDENT');

# Logging output related things
$Data::Dumper::Terse = 1;
$Data::Dumper::Indent = 1;       # mild pretty print
$Data::Dumper::Useqq = 1;        # print strings in double quotes
STDOUT->autoflush(1);

#############################
# Determine Project Version #
#############################
open(my $verfh, "<", ".version") or die("Missing .version!\n");
my $verdata = '';
while (<$verfh>) {
   $verdata = $verdata . $_;
}
close($verfh);

# remove spaces and newlines
$verdata =~ s/^\s+|\s(?=\s)|\s+$//g;
my @ver = split(/\./, $verdata);
my $version = {
   "firmware" => {
      "major" => $ver[0],
      "minor" => $ver[1]
   }
};

############
# Defaults #
############
my $default_cfg = {
   "eeprom" => {
      "size" => 16384,
      "type" => "mmap",
      "addr" => 0x0000, 
      "version" => $eeprom_version
   }
};

# Merge the version information into the default configuration
my $base_cfg = merge($default_cfg, $version);

my $run_mode = "import";

###########
# Globals #
###########
my $profile = 'radio';

# use profile name from command line, if given
if ($#ARGV >= 0) {
   $profile = $ARGV[0];
   shift @_;
}

if ($#ARGV >= 1) {
   $run_mode = $ARGV[1];
}

my $build_dir = "build/$profile";
my $config = { };
my $config_file = "config/$profile.json";
my $eeprom_file = "$build_dir/eeprom.bin";
# In-memory version of the EEPROM, either loaded or empty
my $eeprom_data = '';
# In-memory version of JUST the channels, to patch into eeprom
my $eeprom_channel_data = '';
my ( @eeprom_layout_out, @eeprom_layout_in );
my ( @eeprom_types_out, @eeprom_types_in );

my @eeprom_channels;
# pointers to config, channels, layout, types respectively
my $cptr;
my $chptr;
my ( $lptr_out, $lptr_in );
my ( $tptr_out, $tptr_in );

# Make the build directory tree, if not present
make_path("$build_dir/obj");

# Load configuration from $config_file
sub config_load {
   print "* Load config from $_[0]\n";
   open(my $fh, '<', $_[0]) or die("  * Couldn't open configuration file $_[0], please make sure it exists!\n");
   my $nbytes = 0;
   my $tmp = '';

   while (1) {
      my $res = read $fh, $tmp, 512, length($tmp);
      die "Error reading from $_[0]: $!\n" if not defined $res;
      last if not $res;
   }
   close($fh);

   $nbytes = length($tmp);
   print "  * Read $nbytes bytes from $_[0]\n";
   my $json = JSON->new;
   my $loaded_cfg = $json->decode($tmp) or die("ERROR: Can't parse configuration $_[0]!\n");

   # Merge defaults with loaded configuration
   $config = merge($base_cfg, $loaded_cfg);

   # apply mojo json pointer, so we can reference by path
   $cptr = Mojo::JSON::Pointer->new($config);
}

sub eeprom_types_load {
   print "* Load EEPROM data types from $_[0]\n";
   open(my $fh, '<', $_[0]) or warn("  * Couldn't open configuration file $_[0], using defaults!\n");
   my $nbytes = 0;
   my $tmp = '';
   my @out;

   while (1) {
      my $res = read $fh, $tmp, 512, length($tmp);
      die "$!\n" if not defined $res;
      last if not $res;
   }
   close($fh);

   $nbytes = length($tmp);
   print "  * Read $nbytes bytes from $_[0]\n";
   my $json = JSON->new;
   @out = $json->decode($tmp) or warn("ERROR: Can't parse EEPROM types file $_[0]!\n") and return;

   # Iterate over the types and print them...
   for my $item (@out) {
      for my $key (sort keys(%$item)) {
          my $ee_size = $item->{$key}{size};
          my $ee_descr = $item->{$key}{descr};
          if ($ee_size == -1) {
             $ee_size = 'variable';
          }
          if ($DEBUG) {
             printf "  * Registering EEPROM data type: '$key' with size $ee_size - %s\n", (defined($ee_descr) ? $ee_descr : "");
          }
      }
   }
   return @out;
}

# XXX: We need to pass a type and direction- in (0) or out (1) here
sub eeprom_get_type_size {
    my ($type_name, $direction) = @_;

    my @eeprom_types;
    my @eeprom_layout;
    
    if ($direction == 0) {
       @eeprom_types = @eeprom_types_in;
       @eeprom_layout = @eeprom_layout_in;
    } else {
       @eeprom_types = @eeprom_types_out;
       @eeprom_layout = @eeprom_layout_out;
    }

    # Assume the data is structured as a single hash ref in @eeprom_types
    my $eeprom_data = $eeprom_types[0];  # Dereference the first (and only) hash

    if (exists $eeprom_data->{$type_name}) {
        return $eeprom_data->{$type_name}{size};
    } else {
        warn "Type '$type_name' not found.\n";
        return undef;
    }
}

# Load eeprom_layout from eeprom_layout.json
sub eeprom_layout_load {
   print "* Load EEPROM layout definition from $_[0]\n";
   open(my $fh, '<', $_[0]) or die("ERROR: Couldn't open $_[0]!\n");
   my $nbytes = 0;
   my $tmp = '';
   my @out;

   while (1) {
      my $res = read $fh, $tmp, 512, length($tmp);
      die "$!\n" if not defined $res;
      last if not $res;
   }
   close($fh);

   $nbytes = length($tmp);
   print "  * Read $nbytes bytes from $_[0]\n";
   my $json = JSON->new;
   @out = $json->decode($tmp) or warn("ERROR: Can't parse $_[0]!\n");
   return @out;
}

sub eeprom_load {
   my $eeprom_size = $cptr->get("/eeprom/size");
   if (! -e $_[0]) {
      print "* EEPROM image $_[0] doesn't exist, using empty $eeprom_size byte image!\n";
      return;
   }

   print "* Load EEPROM data from $_[0]\n";
   open(my $EEPROM, '<:raw', $_[0]) or print "  * Not found, skipping\n" and return;
   my $nbytes = 0;

   while (1) {
      my $res = read $EEPROM, $eeprom_data, 100, length($eeprom_data);
      die "$!\n" if not defined $res;
      last if not $res;
   }
   close($EEPROM);

   $nbytes = length($eeprom_data);

   if ($nbytes == $eeprom_size) {
      print "  * Read $nbytes bytes from $_[0]\n";
   } elsif ($nbytes == 0) {
      print "  * Read empty EEPROM from $_[0]... Fixing!\n";
      return;
   } else {
      die("ERROR: Expected $eeprom_size bytes but read $nbytes from $_[0], halting to avoid damage...\n");
   }

   # Verify the checksum of the EEPROM, before allowing it to be used as source...
   eeprom_verify_checksum();
}

sub eeprom_patch {
   my $changes = 0;
   my $errors = 0;
   my $warnings = 0;
   my $eeprom_size = $cptr->get("/eeprom/size");
   my $curr_offset = 0;

   print "* Patch in-memory image\n";

   if ($eeprom_data eq "") {
      $eeprom_data = "\x00" x $eeprom_size;
   }

   # Walk over the layout structure and see if we have a value set in the config...
   for my $item (@eeprom_layout_out) {
       for my $key (sort { $item->{$a}{offset} <=> $item->{$b}{offset} } keys %$item) {
          my $ee_key = $item->{$key}{key};
          my $ee_default = $item->{$key}{default};
          my $ee_off_raw = $item->{$key}{offset};
          my $ee_offset = $ee_off_raw;
          my $ee_offset_relative = 0;
          # Size override
          my $ee_size = $item->{$key}{size};
          my $ee_type = $item->{$key}{type};
          my $eeprom_size = $cptr->get("/eeprom/size");
          # Try to lookup the size from the type:
          my $type_size = -1;
          my $cval;
          my $defval = 0;

          if ($ee_type =~ m/^packed:/) {
             my $short_type = $ee_type;
             $short_type =~ s/packed\://;
#             print "    * Packed type $short_type\n";
          } else {
             $type_size = eeprom_get_type_size($ee_type, 1);
          }

          if (defined($ee_off_raw)) {
             if ($ee_off_raw =~ m/^\+/) {
                # Is this a relative offset?
                $ee_offset_relative = 1;
                $ee_offset =~ s/\+//;
                $curr_offset += $ee_offset;
#                print "* RELative OFFset: Updated to $curr_offset\n";
#                $ee_offset = $curr_offset;
             } else {
                # Absolute offset
                $ee_offset_relative = 0;
#                print "* ABSolute OFFset: Updating ($ee_offset) to ($curr_offset)\n";
                $curr_offset = $ee_offset;
             }
          }

          if (!defined($ee_key)) {
             printf "*skip* no key\n";
             next;
          }

          $changes++;

          # skip unsaved keys (checksum mostly)
          my $ee_protect = $item->{$key}{protect};
          if (defined($ee_protect)) {
             print "  => Skipped key $ee_key, it is protected.\n";
             next;
          }

          my $bin_data = 0;

          # if this key is 'channels' use eeprom_channel_data instead
          if ($ee_key =~ m/^channels$/) {
             $cval = $eeprom_channel_data;
             $bin_data = 1;
          } else {
             $cval = $cptr->get("/$ee_key");
          }

          my $final_size = $type_size;
          
          if (defined($ee_size) && $ee_size > 0) {
#             if ($type_size == -1) {
##                print "     ~ Variable field of type $ee_type forced to $ee_size bytes\n";
#             } else {
#                print "     ~ Overriding default size $type_size for [$ee_type] ($ee_size)\n";
#             }
             $final_size = $ee_size;
          }

          if (!defined($cval)) {
             $warnings++;
             if (defined($ee_default)) {
                $defval = 1;
                $cval = $ee_default;
             } else {
                printf "  => Not patching %d byte%s @ <%04d>: key $ee_key: <Warning - no value set!>\n", $final_size, ($final_size == 1 ? " " : "s"), $curr_offset;
                next;
             }
          }

          # Validate the offset and size will fit within the rom
          if (($ee_offset < 0 || $ee_offset > $eeprom_size) || ($curr_offset + $final_size > $eeprom_size) && ($ee_offset + $final_size >= $eeprom_size)) {
             print "Invalid offset/size ($ee_offset, $final_size) - our EEPROM is $eeprom_size\n";
             next;
          }
          if ($bin_data) {
             printf "  => Patching %d byte%s @ <%04d>: [%s] %s = <binary>%s\n", $final_size, ($final_size == 1 ? " " : "s"), $curr_offset, $ee_type, $ee_key, ($defval == 0 ? "" : " <Warning - default value!>");
          } else {
             printf "  => Patching %d byte%s @ <%04d>: [%s] %s = %s%s\n", $final_size, ($final_size == 1 ? " " : "s"), $curr_offset, $ee_type, $ee_key, $cval, ($defval == 0 ? "" : " <Warning - default value!>");
          }

          # Pad out the memory location with NULLs to get rid of old contents...
          substr($eeprom_data, $curr_offset, $final_size, "\x00" x $final_size);

          # Here we chose which type
          # XXX: Need to use eeprom_types sizes, etc here - overriding as needed...
          if ($ee_type eq 'call') {
             # callsign (8 bytes)
             my $packedcall = pack("Z8", $cval);
             substr($eeprom_data, $curr_offset, 8, $packedcall);
          } elsif ($ee_type eq 'class') {
             # license privileges (2 byte enum) - Add more plz
             if ($cval =~ "US/Technician") {
                $cval = 'UT';
             } elsif ($cval =~ "US/General") {
                $cval = 'UG';
             } elsif ($cval =~ "US/Advanced") {
                $cval = 'UA';
             } elsif ($cval =~ "US/Extra") {
                $cval = 'UE';
             }
             substr($eeprom_data, $curr_offset, 2, pack("a2", $cval));
          } elsif ($ee_type eq 'int') {
             # integer (4 bytes)
             if ($cval =~ m/^0x/) {
                # Convert hex string cval to int cval for embedding...
                $cval = hex($cval);
             }
            substr($eeprom_data, $curr_offset, 4, pack("I", $cval));
          } elsif ($ee_type eq 'ip4') {
             # ipv4 address (4 bytes)
             my @tmpip = split(/\./, $cval);
             my $packedip = pack("CCCC", $tmpip[0], $tmpip[1], $tmpip[2], $tmpip[3]);
            substr($eeprom_data, $curr_offset, 4, $packedip);
          } elsif ($ee_type eq 'str') {
             # string (variable length)
             if ($final_size == 0) {
                print "   * Skipping 0 length key\n";
                next;
             }
             substr($eeprom_data, $curr_offset, $final_size, $cval);
          }

          # Try to make sure the offsets are lining up....
          if ($curr_offset != $ee_offset) {
             printf "Calculated offset (%04d) and layout offset (%04d) mismatch, halting to avoid damage!\n", $curr_offset, $ee_offset;
             die();
          }
          $curr_offset += $final_size;
       }
   }

   if ($errors > 0) {
      print "*** There were $errors errors while processing $changes patches, aborting without change!\n";
      die();
   }

   print "* Finished patching, there were $warnings warnings from $changes patches\n";
}

# Confirm the checksum is correct
sub eeprom_verify_checksum {
   print "* Verifying image checksum...\n";
   # XXX: should this be in or out?
   my $eeprom_size = $cptr->get("/eeprom/size");

   # XXX: This should get the offset from @eeprom_layout!
   my $ed_offset = ($eeprom_size - 4);
   my $chksum = crc32(substr($eeprom_data, 0, -4));
   my $saved_chksum = unpack("L", substr($eeprom_data, $ed_offset, 4));

   if ($saved_chksum eq "\0\0\0\0") {
      printf "  * Ignoring empty EEPROM checksum\n";
   } elsif ($chksum eq $saved_chksum) {
      printf "  * Valid checksum (CRC32) <%x>, continuing!\n", $chksum;
   } else {
      printf "  * Stored checksum (CRC32) <%x> doesn't match calculated <%x>, bailing to prevent damage!\n", $saved_chksum, $chksum;
      return 1;
   }
}

# Update the in-memory image's checksum before saving
sub eeprom_update_checksum {
   my $chksum = crc32(substr($eeprom_data, 0, -4));
   my $eeprom_size = $cptr->get("/eeprom/size");
   printf "* Updating in-memory EEPROM image checksum to <%x>\n", $chksum;

   # XXX: This should get the offset from @eeprom_layout!
   my $ed_offset = ($eeprom_size - 4);

   # patch the checksum
   substr($eeprom_data, $ed_offset, 4, pack("l", $chksum));
}

# Write out our EEPROM, if it looks valid
sub eeprom_save {
   my $nbytes = length($eeprom_data);
   my $eeprom_size = $cptr->get("/eeprom/size");

   # Do some sanity checks on the EEPROM...
   if ($nbytes == 0) {
      die("ERROR: Refusing to write empty (0 byte) EEPROM to $_[0]\n");
   }

   if ($nbytes != $eeprom_size) {
      die("ERROR: Our EEPROM ($_[0]) is $eeprom_size bytes, but we ended up with $nbytes bytes of data. Halting to avoid damage!\n");
   }

   # If we made it here, update the eeprom checksum...
   eeprom_update_checksum();

   # Write out the eeprom image
   print "* Saving EEPROM to $_[0]\n";
   open(my $EEPROM, '>:raw', $_[0]) or die("ERROR: Couldn't open $_[0] for writing: $!\n");
   print $EEPROM $eeprom_data or die("write error: $_[0]: $!\n");
   close $EEPROM;

   print "  * Wrote $nbytes bytes to $_[0]\n";
}

# If the channels.json file exists, load it
sub eeprom_load_channels {
   my $chan_data_sz = $lptr_out->get('/channels/size');
   print "* Loading channel memories from $_[0]\n";
   $eeprom_channel_data = "\x00" x $chan_data_sz;
   open(my $fh, '<', $_[0]) or do {
      warn("  * Couldn't open channel memories file $_[0], not importing channel memories!\n");
      return;
   };

   my $nbytes = 0;
   my $tmp = '';

   while (1) {
      my $res = read $fh, $tmp, 512, length($tmp);
      die "$!\n" if not defined $res;
      last if not $res;
   }
   close($fh);

   $nbytes = length($tmp);
   print "  * Read $nbytes bytes from $_[0]\n";
   my $json = JSON->new;
   @eeprom_channels = $json->decode($tmp) or warn("ERROR: Can't parse channels file $_[0]!\n") and return;

   # apply mojo json pointer, so we can reference by path
   $chptr = Mojo::JSON::Pointer->new(@eeprom_channels);
}

# Apply channels to the eeprom in memory
sub eeprom_insert_channels {
   my $ee_data_offset = 0;

   if (@eeprom_channels) {
      print "* Installing channel memories\n";
      # Iterate over the types and print them...
      my $ch_num = 0;

      for my $wrap (@eeprom_channels) {
         for my $item (keys(%$wrap)) {
            my $t = $wrap->{$item};

            # walk through the groups
            for my $group (sort keys(%$t)) {
               my $g = $wrap->{$item}{$group};

               # Find the channel
               for my $key (sort { $a <=> $b } keys(%$g)) {
                  my $ch = $g->{$key};
                  my $ch_agc = $ch->{'agc'};
                  my $ch_bandwidth = $ch->{'bandwidth'};
                  my $ch_freq = $ch->{'freq'};
                  my $ch_mode = $ch->{'mode'};
                  my $ch_name = $ch->{'name'};
                  my $ch_nb = $ch->{'nb'};
                  my $ch_pl_mode = $ch->{'pl_mode'};
                  my $ch_tx_dcs = $ch->{'tx_dcs'};
                  my $ch_rx_dcs = $ch->{'rx_dcs'};
                  my $ch_tx_pl = $ch->{'tx_pl'};
                  my $ch_rx_pl = $ch->{'rx_pl'};
                  my $ch_tx_power = $ch->{'tx_power'};
                  my $ch_rf_gain = $ch->{'rf_gain'};
                  my $ch_split_dir = $ch->{'split_direction'};
                  my $ch_split_off = $ch->{'split_offset'};
                  my $ch_txpower_str;
                  my $this_data = '';
                  my $this_len = 0;

                  if (defined($ch_tx_power) && $ch_tx_power != 0) {
                     $ch_txpower_str = $ch_tx_power . "W";
                  } else {
                     $ch_txpower_str = "OFF";
                  }
                  # XXX: Pack all the data into an object for insertion
#                     my $packedcall = pack("Z8", $cval);
#                     substr($eeprom_channel_data, $curr_offset, 8, $packedcall);
#                     $ee_data_offset += $this_len;
                  
                  # did we get anything to store?
                  $this_len = length($this_data);
                  printf "  + Added channel %03d [$group] \"$ch_name\" %0.3f Khz $ch_mode <%.1d Khz bw> TX: $ch_txpower_str (%d bytes)\n", $ch_num, ($ch_freq/1000), ($ch_bandwidth/1000, $this_len);

                  if ($this_len > 0) {
                  # Insert it into the total stored
                  }

                  $ch_num++;
               }
            }
         }
      }
      print "* Packed $ch_num channel memories into ", length($eeprom_channel_data), " bytes.\n";
   } else {
      print "* No channel memories defined, skipping.\n";
   }
}

# XXX: Extract channels from the eeprom in memory
sub eeprom_export_channels {
}

# Save the EEPROM types header
sub generate_eeprom_types_h {
   my $file = $_[0];
   my $nbytes = 0;

   if ($file eq '') {
      die("generate_eeprom_types_h: No argument given\n");
   }

   print "  * Generating $_[0]\n";
   open(my $fh, '>:raw', $_[0]) or die("ERROR: Couldn't open $_[0] for writing: $!\n");
   print $fh "/*\n * This file is autogenerated by buildconf, please do not edit it directly.\n";
   print $fh " * Please edit $config_file then re-run './buildconf.pl $profile' to make changes.\n */\n";
   print $fh "#if     !defined(_eeprom_types_h)\n#define _eeprom_types_h\n\n";
   
   # Start the types enum
   print $fh "enum ee_data_type {                      /* Type of the data */\n";

   # Iterate over the types and emit a line in the enum
   for my $item (@eeprom_types_out) {
      for my $key (sort keys(%$item)) {
         my $t_type = $tptr_out->get("/$key");
         my $key_u = uc($key);
         print $fh "   EE_", $key_u, ",";
         my $t_descr = $item->{$key}{descr};
         if (defined($t_descr)) {
            print $fh "\t\t\t/* $t_descr */";
         }
         print $fh "\n";
      }
   }
   # End the types enum
   print $fh "};\n";
   print $fh "typedef enum ee_data_type ee_data_type;\n";
   print $fh "\n";
   print $fh "#endif /* defined(__eprom_types_h) */\n";
   close $fh;
}

# Save the key to offset/size/type mappings
sub generate_eeprom_layout_h {
   my $file = $_[0];
   my $nbytes = 0;

   if ($file eq '') {
      die("generate_eeprom_layout_h: No argument given\n");
   }

   print "  * Generating $_[0]\n";
   open(my $fh, '>:raw', $_[0]) or die("ERROR: Couldn't open $_[0] for writing: $!\n");

   print $fh "/*\n * This file is autogenerated by buildconf, please do not edit it directly.\n";
   print $fh " * Please edit $config_file then re-run './buildconf.pl $profile' to make changes.\n */\n";
   print $fh "#if     !defined(_eeprom_layout_h)\n#define _eeprom_layout_h\n";

   my $eeprom_size = $cptr->get("/eeprom/size");
   print $fh "/* This is only useed in eeprom.c */\n";
   print $fh "#if   defined(EEPROM_C)\n";
   print $fh "static struct eeprom_layout eeprom_layout[] = {\n";

   # this needs reworked so that we get the enum types out of eeprom_types
   # XXX: We also should generate the eeprom_layout.type enum here, so we include all types...
   for my $item (@eeprom_layout_out) {
      for my $key (sort keys(%$item)) {
          my $ee_key = $item->{$key}{key};
          my $ee_offset = $item->{$key}{offset};
          my $ee_size = $item->{$key}{size};
          my $ee_type = $item->{$key}{type};

          my $type_size = -1;
          if ($ee_type =~ m/^packed:/) {
             my $short_type = $ee_type;
             $short_type =~ s/packed\://;
#             print "    * Packed type $short_type\n";
          } else {
             $type_size = eeprom_get_type_size($ee_type, 1);
          }
          my $final_size = $type_size;
          
          if (defined($ee_size) && $ee_size > 0) {
#             print "     ~ Overriding default size $type_size for [$ee_type] ($ee_size)\n";
             $final_size = $ee_size;
          }

          # expand the enum type name (EE_WHATEVER)
          my $ee_type_enum = "EE_" . uc($ee_type);

          if (defined($ee_key)) {
             my $cval = $cptr->get("/$ee_key");
             if (defined($cval)) {
                print $fh "   { .key = \"$ee_key\", .type = $ee_type_enum, .offset = $ee_offset, .size = $final_size },\n"
             }
          }
       }
   }
   print $fh "};\n";
   print $fh "#endif /* defined(EEPROM_C) */\n";
   print $fh "#endif /* defined(__eprom_layout_h) */\n";
   close $fh;
}

# Export a build configuration, to include the needed parts to support our configuration....
sub generate_config_h {
   my $file = $_[0];
   my $nbytes = 0;

   if ($file eq '') {
      die("generate_config_h: No argument given\n");
   }

   print "  * Generating $_[0]\n";
   open(my $fh, '>:raw', $_[0]) or die("ERROR: Couldn't open $_[0] for writing: $!\n");

   print $fh "/*\n * This file is autogenerated by buildconf, please do not edit it directly.\n";
   print $fh " * Please edit $config_file then re-run './buildconf.pl $profile' to make changes.\n */\n";
   print $fh "#if !defined(_config_h)\n#define _config_h\n";
   printf $fh "#define VERSION \"%02d.%02d\"\n", $version->{firmware}{major}, $version->{firmware}{minor};
   printf $fh "#define VERSION_MAJOR 0x%x\n", $version->{firmware}{major};
   printf $fh "#define VERSION_MINOR 0x%x\n", $version->{firmware}{minor};

   if (defined($config->{i2c})) {
      if (defined($config->{i2c}{myaddr})) {
         printf $fh "#define MY_I2C_ADDR %s\n", $config->{i2c}{myaddr};
      }
   }

   if (!defined($config->{eeprom}{type}) || !defined($config->{eeprom}{addr})) {
      die("ERROR: Invalid configuration, edit $file and try again!\n");
   }

   if ($config->{eeprom}{type} eq "mmap") {
      print $fh "#define EEPROM_TYPE_MMAP true\n";
      print $fh "#undef EEPROM_TYPE_I2C\n";
      printf $fh "#define EEPROM_MMAP_ADDR %s\n", $config->{eeprom}{addr};
   } elsif ($config->{eeprom}{type} eq "i2c") {
      print $fh "#undef EEPROM_TYPE_MMAP\n";
      print $fh "#define EEPROM_TYPE_I2C\n";
      printf $fh "#define EEPROM_I2C_ADDR %s\n", $config->{eeprom}{addr};
   }

   if (defined($config->{features})) {
      if (defined($config->{features}{'cat-kpa500'}) && $config->{features}{'cat-kpa500'} eq 1) {
         printf $fh "#define CAT_KPA500 true\n";
      }

      if (defined($config->{features}{'cat-yaesu'}) && $config->{features}{'cat-yaesu'} eq 1) {
         printf $fh "#define CAT_YAESU true\n";
      }
   }

   if (!defined($config->{eeprom}{size})) {
      die("ERROR: eeprom.size not set!\n");
   }

   printf $fh "#define EEPROM_SIZE %d\n", $config->{eeprom}{size};

   my $max_bands = '';
   if (defined($config->{features}{'max-bands'})) {
      $max_bands = $config->{features}{'max-bands'};
   } else {
      $max_bands = 10;
   }
   printf $fh "#define MAX_BANDS %d\n", $max_bands;

   # Platform specific selections:
   my $platform = $cptr->get("/build/platform");

   if ($platform eq "posix") {
      print $fh "#define HOST_EEPROM_FILE \"$eeprom_file\"\n";
      print $fh "#define HOST_LOG_FILE \"firmware.log\"\n";
      print $fh "#define HOST_CAT_PIPE \"cat.fifo\"\n";
      print $fh "#define HOST_POSIX\n";
      print $fh "#define HOST_LINUX\t// This should not be here, but i2c depends on it for now\n";
   }

   # footer
   print $fh "#endif\n";
   close $fh;
}

sub generate_atu_tables_h {
   my $file = $_[0];
   my $nbytes = 0;

   if ($file eq '') {
      die("generate_atu_tables_h: No argument given\n");
   }

   print "  * Generating $_[0]\n";
   open(my $fh, '>:raw', $_[0]) or die("ERROR: Couldn't open $_[0] for writing: $!\n");

   print $fh "/*\n * This file is autogenerated by buildconf, please do not edit it directly.\n";
   print $fh " * Please edit $config_file then re-run './buildconf.pl $profile' to make changes.\n */\n";
   print $fh "#if     !defined(_atu_tables_h)\n#define _atu_tables_h\n";
   my $atu = $cptr->get("/atu");

   if (defined($atu)) {
      my $tuners = keys %$atu;
      print $fh "#if defined(ANT_TUNER)\n";
      print $fh "#define MAX_TUNERS $tuners\n";
      print $fh "#define MAX_CVALS 32\n";
      print $fh "#define MAX_LVALS 32\n";

      print $fh " static float atu_table_c[MAX_TUNERS+1][MAX_CVALS] = {\n";
      # Walk through the configured tuners and emit a row for each C
      for my $tuner (sort keys(%$atu)) {
         if (!defined($atu->{$tuner}{C}) || !defined($atu->{$tuner}{L})) {
            die("Tuner configuration without L or C values is invalid, bailing\n");
         }

         my $c = $atu->{$tuner}{C};
         my $l = $atu->{$tuner}{L};

         print $fh "   /* Tuner unit $tuner: Capacitors in pF */\n";
         print $fh "   { ";
         foreach (@$c) {
            print $fh $_ + 0, ", ";
         }
         print $fh "},\n";
      }
      print $fh "   { -1, -1, -1, -1 } /* terminator row */\n";
      print $fh " };\n";

      print $fh " static float atu_table_l[MAX_TUNERS+1][MAX_LVALS] = {\n";
      # Walk through the configured tuners and emit a row for each C
      for my $tuner (sort keys(%$atu)) {
         if (!defined($atu->{$tuner}{C}) || !defined($atu->{$tuner}{L})) {
            die("Tuner configuration without L or C values is invalid, bailing\n");
         }

         my $c = $atu->{$tuner}{C};
         my $l = $atu->{$tuner}{L};

         print $fh "   /* Tuner unit $tuner: Inductors in uH */\n";
         print $fh "   { ";
         foreach (@$l) {
            print $fh $_ + 0, ", ";
         }
         print $fh "},\n";
      }
      print $fh "   { -1, -1, -1, -1 } /* terminator row */\n";
      print $fh " };\n";
   } else {
      print "* No ATUs configured\n";
      print $fh "#endif /* !defined(__atu_tables_h) */\n";
      return;
   }

   print $fh "#endif /* defined(ANT_TUNER) */\n";
   print $fh "#endif /* !defined(__atu_tables_h) */\n";
   close $fh;
}

sub generate_filter_tables_h {
   my $file = $_[0];
   my $nbytes = 0;

   if ($file eq '') {
      die("generate_filter_tables_h: No argument given\n");
   }

   print "  * Generating $_[0]\n";
   open(my $fh, '>:raw', $_[0]) or die("ERROR: Couldn't open $_[0] for writing: $!\n");

   print $fh "/*\n * This file is autogenerated by buildconf, please do not edit it directly.\n";
   print $fh " * Please edit $config_file then re-run './buildconf.pl $profile' to make changes.\n */\n";
   print $fh "#if     !defined(_atu_tables_h)\n#define _atu_tables_h\n";
   my $filters = $cptr->get("/filters");

   if (defined($filters)) {
      my $filter_count = keys %$filters;
      print $fh "#if defined(FILTERS_C)\n";
      print $fh "#define MAX_FILTERS $filter_count\n";
      # Walk through the configured tuners and emit a row for each C
   } else {
      print "* No filters configured\n";
      print $fh "#endif /* !defined(__atu_tables_h) */\n";
      return;
   }

   print $fh "#endif /* defined(FILTERS_C) */\n";
   print $fh "#endif /* !defined(__atu_tables_h) */\n";
   close $fh;
}

# Create all C headers
sub generate_headers {
   print "* Generating EEPROM layout C headers:\n";
   generate_atu_tables_h($build_dir . "/atu_tables.h");
   generate_config_h($build_dir . "/build_config.h");
   generate_eeprom_types_h($build_dir . "/eeprom_types.h");
   generate_eeprom_layout_h($build_dir . "/eeprom_layout.h");
   generate_filter_tables_h($build_dir . "/filter_tables.h");
}

#############################################################

print "* Host byte Order: ", $Config{byteorder}, "\n";

# Load the configuration
config_load($config_file);

######
# Here we figure out if existing ROM and current versions are different and act appropriately
my $need_upgrade = 0;
my $curr_eeprom_version = 0;

# Load the EEPROM types definitions
@eeprom_types_out = eeprom_types_load("res/eeprom_types.json");

# apply mojo json pointer, so we can reference by path
$tptr_out = Mojo::JSON::Pointer->new(@eeprom_types_out);

# Load the EEPROM layout definitions
@eeprom_layout_out = eeprom_layout_load("res/eeprom_layout.json");
# apply mojo json pointer, so we can reference by path
$lptr_out = Mojo::JSON::Pointer->new(@eeprom_layout_out);

if ($need_upgrade) {
   print "** Upgrade needed: EEPROM from $curr_eeprom_version to $eeprom_version\n";
   @eeprom_types_in = eeprom_types_load("res/archive/$curr_eeprom_version/eeprom_types.json");
   @eeprom_layout_in = eeprom_layout_load("res/archive/$curr_eeprom_version/eeprom_layout.json");
   $lptr_in = Mojo::JSON::Pointer->new(@eeprom_layout_in);
   $tptr_in = Mojo::JSON::Pointer->new(@eeprom_types_in);
} else {
   @eeprom_layout_in = @eeprom_layout_out;
   @eeprom_types_in = @eeprom_types_out;
   $lptr_in = $lptr_out;
   $tptr_in = $tptr_out;
}

# Try loading the eeprom into memory
eeprom_load($eeprom_file);

#####
# XXX: Are we importing or exporting?


if ($run_mode =~ m/^import$/) {
   # If we have a channels.json, import them and apply
   eeprom_load_channels('config/channels.json');

   # Patch in the channel memories
   eeprom_insert_channels();

   # Apply loaded configuration to in-memory EEPROM image
   eeprom_patch($config);

   # Disable interrupt while saving
   my $saved_signal = $SIG{INT};
   $SIG{INT} = 'IGNORE';

   # Save the patched eeprom.bin
   eeprom_save($eeprom_file);

   # Restore the signal handler (if any)
   $SIG{INT} = $saved_signal;

   # And generate headers for the C bits...
   generate_headers();
   
} elsif ($run_mode =~ m/^export$/) {
   print "*** exporting is not yet supported ;( ***\n";
   die();
}
