#!/usr/bin/perl -w
# 
# Regenerate (overwriting only if changed):
#
#    embed.h
#    embedvar.h
#    global.sym
#    perlapi.c
#    perlapi.h
#    proto.h
#
# from information stored in
#
#    embed.fnc
#    intrpvar.h
#    perlvars.h
#    pp.sym     (which has been generated by opcode.pl)
#
# Accepts the standard regen_lib -q and -v args.
#
# This script is normally invoked from regen.pl.

require 5.004;	# keep this compatible, an old perl is all we may have before
                # we build the new one

use strict;

BEGIN {
    # Get function prototypes
    require 'regen_lib.pl';
}

my $SPLINT = 0; # Turn true for experimental splint support http://www.splint.org
my $unflagged_pointers;

#
# See database of global and static function prototypes in embed.fnc
# This is used to generate prototype headers under various configurations,
# export symbols lists for different platforms, and macros to provide an
# implicit interpreter context argument.
#

sub do_not_edit ($)
{
    my $file = shift;

    my $years = '1993, 1994, 1995, 1996, 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005, 2006, 2007, 2008, 2009';

    $years =~ s/1999,/1999,\n  / if length $years > 40;

    my $warning = <<EOW;
 -*- buffer-read-only: t -*-

   $file

   Copyright (C) $years, by Larry Wall and others

   You may distribute under the terms of either the GNU General Public
   License or the Artistic License, as specified in the README file.

!!!!!!!   DO NOT EDIT THIS FILE   !!!!!!!
This file is built by embed.pl from data in embed.fnc, embed.pl,
pp.sym, intrpvar.h, and perlvars.h.
Any changes made here will be lost!

Edit those files and run 'make regen_headers' to effect changes.

EOW

    $warning .= <<EOW if $file eq 'perlapi.c';

Up to the threshold of the door there mounted a flight of twenty-seven
broad stairs, hewn by some unknown art of the same black stone.  This
was the only entrance to the tower; ...

    [p.577 of _The Lord of the Rings_, III/x: "The Voice of Saruman"]


EOW

    if ($file =~ m:\.[ch]$:) {
	$warning =~ s:^: * :gm;
	$warning =~ s: +$::gm;
	$warning =~ s: :/:;
	$warning =~ s:$:/:;
    }
    else {
	$warning =~ s:^:# :gm;
	$warning =~ s: +$::gm;
    }
    $warning;
} # do_not_edit

open IN, "embed.fnc" or die $!;

my @embed;
my (%has_va, %has_nocontext);

while (<IN>) {
    chomp;
    next if /^:/;
    while (s|\\$||) {
	$_ .= <IN>;
	chomp;
    }
    s/\s+$//;
    my @args;
    if (/^\s*(#|$)/) {
	@args = $_;
    }
    else {
	@args = split /\s*\|\s*/, $_;
	my $func = $args[2];
	if ($func) {
	    ++$has_va{$func} if $args[-1] =~ /\.\.\./;
	    ++$has_nocontext{$1} if $func =~ /(.*)_nocontext/;
	}
    }
    push @embed, \@args;
}

# walk table providing an array of components in each line to
# subroutine, printing the result
sub walk_table (&@) {
    my ($function, $filename, $trailer) = @_;
    my $F;
    if (ref $filename) {	# filehandle
	$F = $filename;
    }
    else {
	$F = safer_open("$filename-new");
	print $F do_not_edit ($filename);
    }
    foreach (@embed) {
	my @outs = &{$function}(@$_);
	# $function->(@args) is not 5.003
	print $F @outs;
    }
    print $F $trailer if $trailer;
    unless (ref $filename) {
	safer_close($F);
	rename_if_different("$filename-new", $filename);
    }
}

# generate proto.h
my $wrote_protected = 0;

sub write_protos {
    my $ret;
    if (@_ == 1) {
	my $arg = shift;
	$ret = "$arg\n";
    }
    else {
	my ($flags,$retval,$plain_func,@args) = @_;
	my @nonnull;
	my $has_context = ( $flags !~ /n/ );
	my $never_returns = ( $flags =~ /r/ );
	my $commented_out = ( $flags =~ /m/ );
	my $binarycompat = ( $flags =~ /b/ );
	my $is_malloc = ( $flags =~ /a/ );
	my $can_ignore = ( $flags !~ /R/ ) && !$is_malloc;
	my @names_of_nn;
	my $func;

	my $splint_flags = "";
	if ( $SPLINT && !$commented_out ) {
	    $splint_flags .= '/*@noreturn@*/ ' if $never_returns;
	    if ($can_ignore && ($retval ne 'void') && ($retval !~ /\*/)) {
		$retval .= " /*\@alt void\@*/";
	    }
	}

	if ($flags =~ /s/) {
	    $retval = "STATIC $splint_flags$retval";
	    $func = "S_$plain_func";
	}
	else {
	    $retval = "PERL_CALLCONV $splint_flags$retval";
	    if ($flags =~ /[bp]/) {
		$func = "Perl_$plain_func";
	    } else {
		$func = $plain_func;
	    }
	}
	$ret = "$retval\t$func(";
	if ( $has_context ) {
	    $ret .= @args ? "pTHX_ " : "pTHX";
	}
	if (@args) {
	    my $n;
	    for my $arg ( @args ) {
		++$n;
		if ( $arg =~ /\*/ && $arg !~ /\b(NN|NULLOK)\b/ ) {
		    warn "$func: $arg needs NN or NULLOK\n";
		    ++$unflagged_pointers;
		}
		my $nn = ( $arg =~ s/\s*\bNN\b\s+// );
		push( @nonnull, $n ) if $nn;

		my $nullok = ( $arg =~ s/\s*\bNULLOK\b\s+// ); # strip NULLOK with no effect

		# Make sure each arg has at least a type and a var name.
		# An arg of "int" is valid C, but want it to be "int foo".
		my $temp_arg = $arg;
		$temp_arg =~ s/\*//g;
		$temp_arg =~ s/\s*\bstruct\b\s*/ /g;
		if ( ($temp_arg ne "...")
		     && ($temp_arg !~ /\w+\s+(\w+)(?:\[\d+\])?\s*$/) ) {
		    warn "$func: $arg ($n) doesn't have a name\n";
		}
		if ( $SPLINT && $nullok && !$commented_out ) {
		    $arg = '/*@null@*/ ' . $arg;
		}
		if (defined $1 && $nn && !($commented_out && !$binarycompat)) {
		    push @names_of_nn, $1;
		}
	    }
	    $ret .= join ", ", @args;
	}
	else {
	    $ret .= "void" if !$has_context;
	}
	$ret .= ")";
	my @attrs;
	if ( $flags =~ /r/ ) {
	    push @attrs, "__attribute__noreturn__";
	}
	if ( $flags =~ /D/ ) {
	    push @attrs, "__attribute__deprecated__";
	}
	if ( $is_malloc ) {
	    push @attrs, "__attribute__malloc__";
	}
	if ( !$can_ignore ) {
	    push @attrs, "__attribute__warn_unused_result__";
	}
	if ( $flags =~ /P/ ) {
	    push @attrs, "__attribute__pure__";
	}
	if( $flags =~ /f/ ) {
	    my $prefix	= $has_context ? 'pTHX_' : '';
	    my $args	= scalar @args;
 	    my $pat	= $args - 1;
	    my $macro	= @nonnull && $nonnull[-1] == $pat  
				? '__attribute__format__'
				: '__attribute__format__null_ok__';
	    push @attrs, sprintf "%s(__printf__,%s%d,%s%d)", $macro,
				$prefix, $pat, $prefix, $args;
	}
	if ( @nonnull ) {
	    my @pos = map { $has_context ? "pTHX_$_" : $_ } @nonnull;
	    push @attrs, map { sprintf( "__attribute__nonnull__(%s)", $_ ) } @pos;
	}
	if ( @attrs ) {
	    $ret .= "\n";
	    $ret .= join( "\n", map { "\t\t\t$_" } @attrs );
	}
	$ret .= ";";
	$ret = "/* $ret */" if $commented_out;
	if (@names_of_nn) {
	    $ret .= "\n#define PERL_ARGS_ASSERT_\U$plain_func\E\t\\\n\t"
		. join '; ', map "assert($_)", @names_of_nn;
	}
	$ret .= @attrs ? "\n\n" : "\n";
    }
    $ret;
}

# generates global.sym (API export list)
{
  my %seen;
  sub write_global_sym {
      if (@_ > 1) {
	  my ($flags,$retval,$func,@args) = @_;
	  # If a function is defined twice, for example before and after an
	  # #else, only process the flags on the first instance for global.sym
	  return '' if $seen{$func}++;
	  if ($flags =~ /[AX]/ && $flags !~ /[xm]/
	      || $flags =~ /b/) { # public API, so export
	      $func = "Perl_$func" if $flags =~ /[pbX]/;
	      return "$func\n";
	  }
      }
      return '';
  }
}

walk_table(\&write_protos,     "proto.h", "/* ex: set ro: */\n");
warn "$unflagged_pointers pointer arguments to clean up\n" if $unflagged_pointers;
walk_table(\&write_global_sym, "global.sym", "# ex: set ro:\n");

sub readsyms (\%$) {
    my ($syms, $file) = @_;
    local (*FILE, $_);
    open(FILE, "< $file")
	or die "embed.pl: Can't open $file: $!\n";
    while (<FILE>) {
	s/[ \t]*#.*//;		# Delete comments.
	if (/^\s*(\S+)\s*$/) {
	    my $sym = $1;
	    warn "duplicate symbol $sym while processing $file line $.\n"
		if exists $$syms{$sym};
	    $$syms{$sym} = 1;
	}
    }
    close(FILE);
}

# Perl_pp_* and Perl_ck_* are in pp.sym
readsyms my %ppsym, 'pp.sym';

sub readvars(\%$$@) {
    my ($syms, $file,$pre,$keep_pre) = @_;
    local (*FILE, $_);
    open(FILE, "< $file")
	or die "embed.pl: Can't open $file: $!\n";
    while (<FILE>) {
	s/[ \t]*#.*//;		# Delete comments.
	if (/PERLVARA?I?S?C?\($pre(\w+)/) {
	    my $sym = $1;
	    $sym = $pre . $sym if $keep_pre;
	    warn "duplicate symbol $sym while processing $file line $.\n"
		if exists $$syms{$sym};
	    $$syms{$sym} = $pre || 1;
	}
    }
    close(FILE);
}

my %intrp;
my %globvar;

readvars %intrp,  'intrpvar.h','I';
readvars %globvar, 'perlvars.h','G';

my $sym;

sub undefine ($) {
    my ($sym) = @_;
    "#undef  $sym\n";
}

sub hide {
    my ($from, $to, $indent) = @_;
    $indent = '' unless defined $indent;
    my $t = int(length("$indent$from") / 8);
    "#${indent}define $from" . "\t" x ($t < 3 ? 3 - $t : 1) . "$to\n";
}

sub bincompat_var ($$) {
    my ($pfx, $sym) = @_;
    my $arg = ($pfx eq 'G' ? 'NULL' : 'aTHX');
    undefine("PL_$sym") . hide("PL_$sym", "(*Perl_${pfx}${sym}_ptr($arg))");
}

sub multon ($$$) {
    my ($sym,$pre,$ptr) = @_;
    hide("PL_$sym", "($ptr$pre$sym)");
}

sub multoff ($$) {
    my ($sym,$pre) = @_;
    return hide("PL_$pre$sym", "PL_$sym");
}

my $em = safer_open('embed.h-new');

print $em do_not_edit ("embed.h"), <<'END';

/* (Doing namespace management portably in C is really gross.) */

/* By defining PERL_NO_SHORT_NAMES (not done by default) the short forms
 * (like warn instead of Perl_warn) for the API are not defined.
 * Not defining the short forms is a good thing for cleaner embedding. */

#ifndef PERL_NO_SHORT_NAMES

/* Hide global symbols */

#if !defined(PERL_IMPLICIT_CONTEXT)

END

# Try to elimiate lots of repeated
# #ifdef PERL_CORE
# foo
# #endif
# #ifdef PERL_CORE
# bar
# #endif
# by tracking state and merging foo and bar into one block.
my $ifdef_state = '';

walk_table {
    my $ret = "";
    my $new_ifdef_state = '';
    if (@_ == 1) {
	my $arg = shift;
	$ret = "$arg\n" if $arg =~ /^#\s*(if|ifn?def|else|endif)\b/;
    }
    else {
	my ($flags,$retval,$func,@args) = @_;
	unless ($flags =~ /[om]/) {
	    if ($flags =~ /s/) {
		$ret = hide($func,"S_$func");
	    }
	    elsif ($flags =~ /p/) {
		$ret = hide($func,"Perl_$func");
	    }
	}
	if ($ret ne '' && $flags !~ /A/) {
	    if ($flags =~ /E/) {
		$new_ifdef_state
		    = "#if defined(PERL_CORE) || defined(PERL_EXT)\n";
	    }
	    else {
		$new_ifdef_state = "#ifdef PERL_CORE\n";
	    }

	    if ($new_ifdef_state ne $ifdef_state) {
		$ret = $new_ifdef_state . $ret;
	    }
        }
    }
    if ($ifdef_state && $new_ifdef_state ne $ifdef_state) {
	# Close the old one ahead of opening the new one.
	$ret = "#endif\n$ret";
    }
    # Remember the new state.
    $ifdef_state = $new_ifdef_state;
    $ret;
} $em;

if ($ifdef_state) {
    print $em "#endif\n";
}

for $sym (sort keys %ppsym) {
    $sym =~ s/^Perl_//;
    print $em hide($sym, "Perl_$sym");
}

print $em <<'END';

#else	/* PERL_IMPLICIT_CONTEXT */

END

my @az = ('a'..'z');

$ifdef_state = '';
walk_table {
    my $ret = "";
    my $new_ifdef_state = '';
    if (@_ == 1) {
	my $arg = shift;
	$ret = "$arg\n" if $arg =~ /^#\s*(if|ifn?def|else|endif)\b/;
    }
    else {
	my ($flags,$retval,$func,@args) = @_;
	unless ($flags =~ /[om]/) {
	    my $args = scalar @args;
	    if ($flags =~ /n/) {
		if ($flags =~ /s/) {
		    $ret = hide($func,"S_$func");
		}
		elsif ($flags =~ /p/) {
		    $ret = hide($func,"Perl_$func");
		}
	    }
	    elsif ($args and $args[$args-1] =~ /\.\.\./) {
	        # we're out of luck for varargs functions under CPP
	    }
	    else {
		my $alist = join(",", @az[0..$args-1]);
		$ret = "#define $func($alist)";
		my $t = int(length($ret) / 8);
		$ret .=  "\t" x ($t < 4 ? 4 - $t : 1);
		if ($flags =~ /s/) {
		    $ret .= "S_$func(aTHX";
		}
		elsif ($flags =~ /p/) {
		    $ret .= "Perl_$func(aTHX";
		}
		$ret .= "_ " if $alist;
		$ret .= $alist . ")\n";
	    }
	}
	unless ($flags =~ /A/) {
	    if ($flags =~ /E/) {
		$new_ifdef_state
		    = "#if defined(PERL_CORE) || defined(PERL_EXT)\n";
	    }
	    else {
		$new_ifdef_state = "#ifdef PERL_CORE\n";
	    }

	    if ($new_ifdef_state ne $ifdef_state) {
		$ret = $new_ifdef_state . $ret;
	    }
        }
    }
    if ($ifdef_state && $new_ifdef_state ne $ifdef_state) {
	# Close the old one ahead of opening the new one.
	$ret = "#endif\n$ret";
    }
    # Remember the new state.
    $ifdef_state = $new_ifdef_state;
    $ret;
} $em;

if ($ifdef_state) {
    print $em "#endif\n";
}

for $sym (sort keys %ppsym) {
    $sym =~ s/^Perl_//;
    if ($sym =~ /^ck_/) {
	print $em hide("$sym(a)", "Perl_$sym(aTHX_ a)");
    }
    elsif ($sym =~ /^pp_/) {
	print $em hide("$sym()", "Perl_$sym(aTHX)");
    }
    else {
	warn "Illegal symbol '$sym' in pp.sym";
    }
}

print $em <<'END';

#endif	/* PERL_IMPLICIT_CONTEXT */

#endif	/* #ifndef PERL_NO_SHORT_NAMES */

END

print $em <<'END';

/* Compatibility stubs.  Compile extensions with -DPERL_NOCOMPAT to
   disable them.
 */

#if !defined(PERL_CORE)
#  define sv_setptrobj(rv,ptr,name)	sv_setref_iv(rv,name,PTR2IV(ptr))
#  define sv_setptrref(rv,ptr)		sv_setref_iv(rv,NULL,PTR2IV(ptr))
#endif

#if !defined(PERL_CORE) && !defined(PERL_NOCOMPAT)

/* Compatibility for various misnamed functions.  All functions
   in the API that begin with "perl_" (not "Perl_") take an explicit
   interpreter context pointer.
   The following are not like that, but since they had a "perl_"
   prefix in previous versions, we provide compatibility macros.
 */
#  define perl_atexit(a,b)		call_atexit(a,b)
END

walk_table {
    my ($flags,$retval,$func,@args) = @_;
    return unless $func;
    return unless $flags =~ /O/;

    my $alist = join ",", @az[0..$#args];
    my $ret = "#  define perl_$func($alist)";
    my $t = (length $ret) >> 3;
    $ret .=  "\t" x ($t < 5 ? 5 - $t : 1);
    "$ret$func($alist)\n";
} $em;

print $em <<'END';

/* varargs functions can't be handled with CPP macros. :-(
   This provides a set of compatibility functions that don't take
   an extra argument but grab the context pointer using the macro
   dTHX.
 */
#if defined(PERL_IMPLICIT_CONTEXT) && !defined(PERL_NO_SHORT_NAMES)
END

foreach (sort keys %has_va) {
    next unless $has_nocontext{$_};
    next if /printf/; # Not clear to me why these are skipped but they are.
    print $em hide($_, "Perl_${_}_nocontext", "  ");
}

print $em <<'END';
#endif

#endif /* !defined(PERL_CORE) && !defined(PERL_NOCOMPAT) */

#if !defined(PERL_IMPLICIT_CONTEXT)
/* undefined symbols, point them back at the usual ones */
END

foreach (sort keys %has_va) {
    next unless $has_nocontext{$_};
    next if /printf/; # Not clear to me why these are skipped but they are.
    print $em hide("Perl_${_}_nocontext", "Perl_$_", "  ");
}

print $em <<'END';
#endif

/* ex: set ro: */
END

safer_close($em);
rename_if_different('embed.h-new', 'embed.h');

$em = safer_open('embedvar.h-new');

print $em do_not_edit ("embedvar.h"), <<'END';

/* (Doing namespace management portably in C is really gross.) */

/*
   The following combinations of MULTIPLICITY and PERL_IMPLICIT_CONTEXT
   are supported:
     1) none
     2) MULTIPLICITY	# supported for compatibility
     3) MULTIPLICITY && PERL_IMPLICIT_CONTEXT

   All other combinations of these flags are errors.

   only #3 is supported directly, while #2 is a special
   case of #3 (supported by redefining vTHX appropriately).
*/

#if defined(MULTIPLICITY)
/* cases 2 and 3 above */

#  if defined(PERL_IMPLICIT_CONTEXT)
#    define vTHX	aTHX
#  else
#    define vTHX	PERL_GET_INTERP
#  endif

END

for $sym (sort keys %intrp) {
    print $em multon($sym,'I','vTHX->');
}

print $em <<'END';

#else	/* !MULTIPLICITY */

/* case 1 above */

END

for $sym (sort keys %intrp) {
    print $em multoff($sym,'I');
}

print $em <<'END';

END

print $em <<'END';

#endif	/* MULTIPLICITY */

#if defined(PERL_GLOBAL_STRUCT)

END

for $sym (sort keys %globvar) {
    print $em multon($sym,   'G','my_vars->');
    print $em multon("G$sym",'', 'my_vars->');
}

print $em <<'END';

#else /* !PERL_GLOBAL_STRUCT */

END

for $sym (sort keys %globvar) {
    print $em multoff($sym,'G');
}

print $em <<'END';

#endif /* PERL_GLOBAL_STRUCT */

/* ex: set ro: */
END

safer_close($em);
rename_if_different('embedvar.h-new', 'embedvar.h');

my $capi = safer_open('perlapi.c-new');
my $capih = safer_open('perlapi.h-new');

print $capih do_not_edit ("perlapi.h"), <<'EOT';

/* declare accessor functions for Perl variables */
#ifndef __perlapi_h__
#define __perlapi_h__

#if defined (MULTIPLICITY) && defined (PERL_GLOBAL_STRUCT)

START_EXTERN_C

#undef PERLVAR
#undef PERLVARA
#undef PERLVARI
#undef PERLVARIC
#undef PERLVARISC
#define PERLVAR(v,t)	EXTERN_C t* Perl_##v##_ptr(pTHX);
#define PERLVARA(v,n,t)	typedef t PL_##v##_t[n];			\
			EXTERN_C PL_##v##_t* Perl_##v##_ptr(pTHX);
#define PERLVARI(v,t,i)	PERLVAR(v,t)
#define PERLVARIC(v,t,i) PERLVAR(v, const t)
#define PERLVARISC(v,i)	typedef const char PL_##v##_t[sizeof(i)];	\
			EXTERN_C PL_##v##_t* Perl_##v##_ptr(pTHX);

#include "perlvars.h"

#undef PERLVAR
#undef PERLVARA
#undef PERLVARI
#undef PERLVARIC
#undef PERLVARISC

END_EXTERN_C

#if defined(PERL_CORE)

/* accessor functions for Perl "global" variables */

/* these need to be mentioned here, or most linkers won't put them in
   the perl executable */

#ifndef PERL_NO_FORCE_LINK

START_EXTERN_C

#ifndef DOINIT
EXTCONST void * const PL_force_link_funcs[];
#else
EXTCONST void * const PL_force_link_funcs[] = {
#undef PERLVAR
#undef PERLVARA
#undef PERLVARI
#undef PERLVARIC
#define PERLVAR(v,t)	(void*)Perl_##v##_ptr,
#define PERLVARA(v,n,t)	PERLVAR(v,t)
#define PERLVARI(v,t,i)	PERLVAR(v,t)
#define PERLVARIC(v,t,i) PERLVAR(v,t)
#define PERLVARISC(v,i) PERLVAR(v,char)

/* In Tru64 (__DEC && __osf__) the cc option -std1 causes that one
 * cannot cast between void pointers and function pointers without
 * info level warnings.  The PL_force_link_funcs[] would cause a few
 * hundred of those warnings.  In code one can circumnavigate this by using
 * unions that overlay the different pointers, but in declarations one
 * cannot use this trick.  Therefore we just disable the warning here
 * for the duration of the PL_force_link_funcs[] declaration. */

#if defined(__DECC) && defined(__osf__)
#pragma message save
#pragma message disable (nonstandcast)
#endif

#include "perlvars.h"

#if defined(__DECC) && defined(__osf__)
#pragma message restore
#endif

#undef PERLVAR
#undef PERLVARA
#undef PERLVARI
#undef PERLVARIC
#undef PERLVARISC
};
#endif	/* DOINIT */

END_EXTERN_C

#endif	/* PERL_NO_FORCE_LINK */

#else	/* !PERL_CORE */

EOT

foreach $sym (sort keys %globvar) {
    print $capih bincompat_var('G',$sym);
}

print $capih <<'EOT';

#endif /* !PERL_CORE */
#endif /* MULTIPLICITY && PERL_GLOBAL_STRUCT */

#endif /* __perlapi_h__ */

/* ex: set ro: */
EOT
safer_close($capih);
rename_if_different('perlapi.h-new', 'perlapi.h');

print $capi do_not_edit ("perlapi.c"), <<'EOT';

#include "EXTERN.h"
#include "perl.h"
#include "perlapi.h"

#if defined (MULTIPLICITY) && defined (PERL_GLOBAL_STRUCT)

/* accessor functions for Perl "global" variables */
START_EXTERN_C

#undef PERLVARI
#define PERLVARI(v,t,i) PERLVAR(v,t)

#undef PERLVAR
#undef PERLVARA
#define PERLVAR(v,t)	t* Perl_##v##_ptr(pTHX)				\
			{ dVAR; PERL_UNUSED_CONTEXT; return &(PL_##v); }
#define PERLVARA(v,n,t)	PL_##v##_t* Perl_##v##_ptr(pTHX)		\
			{ dVAR; PERL_UNUSED_CONTEXT; return &(PL_##v); }
#undef PERLVARIC
#undef PERLVARISC
#define PERLVARIC(v,t,i)	\
			const t* Perl_##v##_ptr(pTHX)		\
			{ PERL_UNUSED_CONTEXT; return (const t *)&(PL_##v); }
#define PERLVARISC(v,i)	PL_##v##_t* Perl_##v##_ptr(pTHX)	\
			{ dVAR; PERL_UNUSED_CONTEXT; return &(PL_##v); }
#include "perlvars.h"

#undef PERLVAR
#undef PERLVARA
#undef PERLVARI
#undef PERLVARIC
#undef PERLVARISC

END_EXTERN_C

#endif /* MULTIPLICITY && PERL_GLOBAL_STRUCT */

/* ex: set ro: */
EOT

safer_close($capi);
rename_if_different('perlapi.c-new', 'perlapi.c');

# ex: set ts=8 sts=4 sw=4 noet:
