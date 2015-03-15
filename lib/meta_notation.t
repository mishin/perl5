#!./perl

BEGIN {
    chdir 't' if -d 't';
    @INC = '../lib';
    require './test.pl';
}

use strict;
use warnings;

eval "require 'meta_notation.pm'";
if ($@) {
    fail("Could not find 'meta_notation.pm'");
}
else {

    is(_meta_notation("\007\010\011\c?Z\x{103}"), "^G^H^I^?Z\x{103}");

    if ($::IS_ASCII || $::IS_ASCII) {
        is(_meta_notation("\x{c1}\x{e2}"), 'M-AM-b');
    }
    else {
        is(_meta_notation("\x{c1}\x{e2}"), '\\x{c1}\\x{e2}');
    }
}

done_testing();
