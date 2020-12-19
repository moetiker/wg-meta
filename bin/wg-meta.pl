#!/usr/bin/perl
use v5.22;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use experimental 'signatures';

use WGmeta::Cli::Router;

our $VERSION = 0.01;

if (@ARGV && $ARGV[0] eq '--version') {
    print "wg-meta v$VERSION - https://github.com/sirtoobii/wg-meta\n";
    exit;
}


# command line argument parser
route_command(\@ARGV);





