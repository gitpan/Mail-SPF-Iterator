=head1 NAME

Mail::SPF::Iterator - iterative SPF lookup

=head1 SYNOPSIS

	use Net::DNS;
	use Mail::SPF::Iterator;
	my $spf = Mail::SPF::Iterator->new(
		$ip,       # IP4|IP6 of client
		$mailfrom, # from MAIL FROM:
		$helo,     # from HELO|EHLO
		$myname,   # optional: my hostname
	);

	# could be other resolvers too
	my $resolver = Net::DNS::Resolver->new;

	my ($result,@ans) = $spf->next; # initial query
	while ( ! $status ) {
		my ($cbid,@query) = @ans;
		die "no queries" if ! @query;
		for my $q (@query) {
			# resolve query
			my $answer = $resolver->send( $q );
			($result,@ans) = $spf->next( $cbid,$answer
				? $answer                          # valid answer
				: [ $q, $resolver->errorstring ]   # DNS problem
			);
			last if $result; # got final result
			last if @ans;    # got more DNS queries
		}
	}

	# $result = Fail|Pass|...
	# $ans[0] = comment for Received-SPF
	# $ans[1] = problem for Received-SPF on Fail

=head1 DESCRIPTION

This module provides an iterative resolving of SPF records. Contrary to
Mail::SPF, which does blocking DNS lookups, this module just returns the DNS
queries and later expects the responses.

Lookup of the DNS records will be done outside of the module and can be done
in a event driven way.

=head1 METHODS

=over 4

=item new( IP, MAILFROM, HELO, [ MYNAME ] )

Construct a new Mail::SPF::Iterator object, which maintains the state
between the steps of the iteration. For each new SPF check a new object has
to be created.

IP is the IP if the client as string (IP4 or IP6).

MAILFROM is the user@domain part from the MAIL FROM handshake, e.g. '<','>'
and any parameters removed. If only '<>' was given (like in bounces) the
value is empty.

HELO is the string send within the HELO|EHLO dialog which should be a domain
according to the RFC but often is not.

MYNAME is the name of the local host. It's only used if required by macros
inside the SPF record.

Returns the new object.

=item next([ CBID, ANSWER ])

C<next> will be initially called with no arguments to get initial DNS queries
and then will be called with the DNS answers.

ANSWER is either a DNS packet with the response to a former query or C<< [
QUERY, REASON ] >> on failures, where QUERY is the DNS packet containing the
failed query and REASON the reason, why the query failed (like TIMEOUT).

CBID is the id for the query returned from the last call to C<next>. It is
given to control, if the answer is for the current query.

If a final result was achieved it will return
C<< ( RESULT, COMMENT, PROBLEM ) >>. RESULT is the result, e.g. "Fail",
"Pass",.... COMMENT is the comment for the Received-SPF header. PROBLEM is
the problem for this header in the case of a failure (Fail, *Error)

=back

=head1 EXPORTED SYMBOLS

For convienience the constants SPF_TempError, SPF_PermError, SPF_Pass, SPF_Fail,
SPF_SoftFail, SPF_Neutral, SPF_None are exported, which have the values
C<"TempError">, C<"PermError"> ...

=head1 BUGS

The module currently needs to have the A|AAAA records in the additional data
of the DNS reply when doing a MX lookup. This will usually done by recursiv
resolvers.

Apart from that it passes the SPF test suite from opensf.org.

=head1 AUTHOR

Steffen Ullrich <sullr@cpan.org>

=head1 COPYRIGHT

Copyright by Steffen Ullrich.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut


use strict;
use warnings;

package Mail::SPF::Iterator;
our $VERSION = 0.03;

use fields qw( clientip4 clientip6 domain sender helo myname
	include_stack cb cbq cbid validated limit_dns_mech
	mech redirect explain );

use Net::DNS;
use Socket;
use URI::Escape 'uri_escape';
use base 'Exporter';


### Socket6 is not yet perl core, so check, if we can use it. Otherwise we
### hopefully don't get any IP6 data, so no need to use it.
my $can_ip6;
BEGIN {

	$can_ip6 = 0;
	$can_ip6 = eval {
		require Socket6;
		Socket6->import(qw( inet_pton inet_ntop));
		# newer Socket versions already export AF_INET6
		Socket6->import('AF_INET6') if ! defined &AF_INET6;
		1;
	};
	if ( ! $can_ip6 ) {
		no strict 'refs';
		*{'AF_INET6'} = *{'inet_pton'} = *{'inet_ntop'}
			= sub { die "no IPv6 support" };
	}
}

### create SPF_* constants and export them
our @EXPORT;
use constant SPF_Noop => '_NOOP';
BEGIN {
	my $i=0;
	for (qw(TempError PermError Pass Fail SoftFail Neutral None )) {
		++$i;
		no strict 'refs';
		*{"SPF_$_"} = eval "sub () { '$_' }";
		push @EXPORT, "SPF_$_";
	}
}


### Debugging
our $DEBUG=0;
sub DEBUG {
	$DEBUG or return; # check against debug level
	my (undef,$file,$line) = caller;
	my $msg = shift;
	$file = '...'.substr( $file,-17 ) if length($file)>20;
	$msg = sprintf $msg,@_ if @_;
	print STDERR "DEBUG: $file:$line: $msg\n";
}



### pre-compute masks for IP4, IP6
my (@mask4,@mask6);
{
	my $m = '0' x 32;
	$mask4[0] = pack( "B32",$m);
	for (1..32) {
		substr( $m,$_-1,1) = '1';
		$mask4[$_] = pack( "B32",$m);
	}

	$m = '0' x 128;
	$mask6[0] = pack( "B32",$m);
	for (1..128) {
		substr( $m,$_-1,1) = '1';
		$mask6[$_] = pack( "B128",$m);
	}
}

### mapping char to result
my %qual2rv = (
	'+' => SPF_Pass,
	'-' => SPF_Fail,
	'~' => SPF_SoftFail,
	'?' => SPF_Neutral,
);



############################################################################
# NEW
# creates new SPF processing object
############################################################################
sub new {
	my ($class,$ip,$mailfrom,$helo,$myname) = @_;
	my $self = fields::new($class);

	my $domain =
		$mailfrom =~m{\@([\w\-.]+)$} ? $1 :
		$mailfrom =~m{\@\[([\da-f:\.]+)\]$}i ? $1 :
		$helo =~m{\@([\w\-.]+)$} ? $1 :
		$helo =~m{\@\[([\da-f:\.]+)\]$}i ? $1 :
		$helo;
	my $sender = $mailfrom || $helo;

	my $ip4 = eval { inet_aton($ip) };
	my $ip6 = ! $ip4 && $can_ip6 && eval { inet_pton(AF_INET6,$ip) };
	die "no client IP4 or IP6 known (can_ip6=$can_ip6): $ip" if ! $ip4 and ! $ip6;

	if ( $ip6 ) {
		my $m = inet_pton( AF_INET6,'::ffff:0.0.0.0' );
		if ( ($ip6 & $m) eq $m ) {
			# mapped IPv4
			$ip4 = substr( $ip6,-4 );
			$ip6 = undef;
		}
	}

	%$self = (
		clientip4 => $ip4,     # IP of client
		clientip6 => $ip6,     # IP of client
		domain => $domain,     # current domain
		sender => $sender,     # sender
		helo   => $helo,       # helo
		myname => $myname,     # name of mail host itself
		include_stack => [],   # stack in case of include
		cb => undef,           # callback for next DNS reply
		cbq => [],             # the DNS queries for cb
		cbid => 0,             # id for the callback, must be returned in next()
		validated => {},       # validated IP/domain names for PTR and %{p}
		limit_dns_mech => 10,  # Limit on Number of DNS mechanism
		mech => undef,         # spf mechanism
		redirect => undef,     # redirect from SPF record
		explain => undef,      # explain from SPF record
	);
	return $self;
}

############################################################################
# NEXT
# next step in SPF lookup
# Args: ($cbid,$dnsresp)
#   $cbid: id of callback, used to check if this is an expected reply
#   $dnsresp: DNS reply
# Returns: ($final,@args)
#   $final: undef or something of Pass|Fail|SoftFail|Neutral|None|PermError|TermpError
#   @args:  if !$final then ID+new DNS requests, if !@args the data were ignored
#           if  $final $args[0] is info and $args[1] is problem description (on errors)
#           for Received-SPF header
############################################################################
sub next {
	my ($self,$cbid,$dnsresp) = @_;

	my @rv;
	if ( my $cb = $self->{cb} ) {
		if ( $cbid != $self->{cbid} ) {
			# unexpected reply, maybe got TXT after SPF was already processed...
			return; # should ignore
		}

		my $cb_queries = $self->{cbq};
		if ( ! @$cb_queries ) {
			# we've got a reply, but no outstanding queries - ignore
			return;

		} else {
			# check if the reply matches one of the queries
			my ($q,$err);
			if ( ! UNIVERSAL::isa( $dnsresp, 'Net::DNS::Packet' )) {
				# probably [ $query, $errorstring ]
				($q,$err) = @$dnsresp;
				($q) = $q->question;
				$err ||= 'unknown error';
				DEBUG( "error '$err' to query ".$q->string );
			} else {
				($q) = $dnsresp->question;
			}
			my $qtype = $q->qtype;

			my $found;
			for (@$cb_queries) {
				# presentation2wire
				# for whatever reason \032 is not octal but chr(32), see Net::DNS::wire2presentation
				# $_->{q}->qname has still the raw (wire) value, because it was set to it
				# but the qname of the response has the non-wire presentation :(
				# fortunatly this applies only to DNS names with special chars
				( my $qname = lc($q->qname) )
					=~s{\\(?:(\d\d\d)|(.))}{ $2 || chr($1) }esg;

				if ( $qtype eq $_->{q}->qtype and $qname eq lc($_->{q}->qname)) {
					$found = $_;
					last;
				}
			}

			if ( ! $found ) {
				# unexpected response, type or domain do not match query
				my %want = map { $_->{q}->qtype => 1 } @$cb_queries;
				my %name = map { $_->{q}->qname => 1 } @$cb_queries;
				return ( SPF_TempError,
					"getting ".join("|",keys %want)." for ".join("|",keys %name),
					"unexpected DNS response"
				);

			} elsif ( ++$found->{done} > 1 ) {
				# duplicate response - ignore
				return;
			}

			if ( $err ) {
				# if we got an error and no outstanding DNS queries we consider
				# this action as failed -> TempError
				if ( ! grep { ! $_->{done} } @$cb_queries ) {
					my %want = map { $_->{q}->qtype => 1 } @$cb_queries;
					my %name = map { $_->{q}->qname => 1 } @$cb_queries;
					return ( SPF_TempError,
						"getting ".join("|",keys %want)." for ".join("|",keys %name),
						"error getting DNS response"
					);
				}
				# if we have outstanding queries return () as a sign, that we
				# ignore this error
				return;
			}
		}

		my ($sub,@arg) = @$cb;
		@rv = $sub->($self,$dnsresp,@arg);

	} else {
		# no callback yet - must be initial
		die "no callback but DNS response given" if $dnsresp;
		@rv = $self->_query_txt_spf;
	}

	# loop until I get a final result
	while (1) {
		DEBUG( "loop rv=".Data::Dumper->new([\@rv])->Maxdepth(1)->Dump );

		##### ignored, try to find next action
		if ( ! @rv ) {
			DEBUG( "ignored" );
			my $next = shift @{$self->{mech}};
			if ( ! $next ) {

				# do we have a redirect?
				if ( my $domain = $self->{redirect} ) {
					if ( ref $domain ) {
						# need to resolve %{p}
						if ( $domain->{macro} ) { # needs resolving
							@rv = $self->_resolve_macro_p($domain);
							return @rv if @rv;
						}
						$self->{redirect} = $domain = $domain->{expanded};
					}
					if ( my @err = _check_domain($domain,"redirect:$domain" )) {
						return @err
					}

					return ( SPF_PermError, "","Number of DNS mechanism exceeded" )
						if --$self->{limit_dns_mech} < 0;

					$self->{domain}   = $domain;
					$self->{mech}     = [];
					$self->{explain}  = undef;
					$self->{redirect} = undef;

					# start with new SPF record
					@rv = $self->_query_txt_spf;
					redo;
				}

				# up from include?
				my $st = $self->{include_stack};
				if (@$st) {
					my $top = pop @$st;
					delete $top->{qual};
					while ( my ($k,$v) = each %$top ) {
						$self->{$k} = $v;
					}
					redo;
				}

				# no more data
				return ( SPF_Neutral );
			}

			my ($sub,@arg) = @$next;
			@rv = $sub->($self,@arg);
			redo;
		}

		##### list of DNS packets ? -> return as (undef,cbid,@pkts)
		if ( UNIVERSAL::isa( $rv[0],'Net::DNS::Packet' )) {
			$self->{cbq} = [ map { my ($q) = $_->question; { q => $q } } @rv ];
			return ( undef, ++$self->{cbid}, @rv );
		}

		##### waiting for additional data to current request
		if ( $rv[0] eq SPF_Noop and grep { ! $_->{done} } @{ $self->{cbq}} ) {
			return;
		}

		##### else final response (status,why,err)
		if ( my $top = pop @{ $self->{include_stack} } ) { # pre-final
			DEBUG( "pre-final response $rv[0]" );
			$rv[0] = SPF_PermError if $rv[0] eq SPF_None;
			if ( $rv[0] eq SPF_TempError || $rv[0] eq SPF_PermError ) {
				# keep response as final
				last;
			} else {
				# restore saved data
				my $qual = delete $top->{qual};
				while ( my ($k,$v) = each %$top ) {
					$self->{$k} = $v;
				}
				if ( $rv[0] eq SPF_Pass ) {
					$rv[0] = $qual;  # Pass == match
				} else {
					@rv = ();        # !Pass == non-match -> ignore
				}
			}
		} else {
			DEBUG( "final response $rv[0]" );
			last;
		}
	}


	# special case when we ignore the current response and just wait
	# for more. Only used when we could get multiple responses, e.g when
	# multiple DNS requests were send ( query for SPF+TXT )
	if ( @rv == 1 and $rv[0] eq SPF_Noop ) {
		return;
	}

	# if we have a Fail but not description but an explain modifier
	# then use it as the description
	if ( $rv[0] eq SPF_Fail and ! $rv[1] and ( my $exp = $self->{explain} )) {
		if (ref $exp) {
			if ( my @xrv = $self->_resolve_macro_p($exp)) {
				die "FIXME";
			}
			$exp = $self->{explain} = $exp->{expanded};
		}
		if ( my @err = _check_domain( $exp, "explain:$exp" )) {
			return @rv; # don't change error message
		}
		$self->{cb} = [ \&_got_TXT_exp, \@rv ];
		@rv = ( undef, Net::DNS::Packet->new( $exp,'TXT','IN' ));
	}

	return @rv;
}


############################################################################
# check if the domain has the right format
# this checks the domain before the macros got expanded
############################################################################
sub _check_macro_domain {
	my ($domain,$why,$spf_level) = @_;
	my $rx = qr{
		(?:
			(?:
				[^%\s]+ |
				% (?: { [slodipvh] \d* r? [.\-+,/_=]* } | [%\-_] )
			)+
		)*
		(?:(?:
			\. [\da-z]*[a-z][\da-z]* |
			\. [\da-z]+-[\-a-z\d]*[\da-z]
		) | (?:
			% (?: { [slodipvh] \d* r? [.\-+,/_=]* } | [%\-_] )
		))
	}xi;
	_check_domain( $domain,$why,$spf_level,$rx);
}

############################################################################
# check if the domain has the right format
# this checks the domain after the macros got expanded
############################################################################
sub _check_domain {
	my ($domain,$why,$spf_level,$rx) = @_;
	$why = '' if ! defined $why;

	# domain name according to RFC2181 can by anything binary!
	# this is not only for host names
	$rx ||= qr{.*?};

	my @rv;
	if ( $domain =~m{[^\d.]}
		&& $domain =~s{^($rx)\.?$}{$1} ) {
		# looks like valid domain name
		if ( grep { length == 0 || length>63 } split( m{\.}, $domain )) {
			@rv = ( SPF_PermError,"query $why","DNS labels limited to 63 chars and should not be empty." );
		} elsif ( length($domain)>253 ) {
			@rv = ( SPF_PermError,"query $why","Domain names limited to 253 chars." );
		} else {
			DEBUG( "domain name ist OK" );
			return
		}
	} else {
		@rv = ( SPF_PermError, "query $why", "Invalid domain name" );
	}

	#DEBUG( Carp::longmess("error with domain name '$domain': @rv" ));

	# have error
	return @rv if ! defined $spf_level;
	return ( SPF_None, "query $why", "not a domain name" )
		if $spf_level == 1; # initial SPF query -> don't report as error
	return ( SPF_PermError, "query $why", "not a domain name" );
}

############################################################################
# initial query
# returns queries for SPF and TXT record, next state is _got_txt_spf
############################################################################
sub _query_txt_spf {
	my $self = shift;
	# return query for SPF and TXT, we see what we get first
	if ( my @err = _check_domain($self->{domain}, "SPF/TXT record", $self->{cbid} == 0 ? 1:0 ) ) {
		return @err;
	}

	$self->{cb} = [ \&_got_txt_spf ];
	DEBUG( "want SPF/TXT for $self->{domain}" );
	return (
		scalar(Net::DNS::Packet->new( $self->{domain}, 'SPF','IN' )),
		scalar(Net::DNS::Packet->new( $self->{domain}, 'TXT','IN' )),
	);
}

############################################################################
# processes response to SPF|TXT query
# parses response and starts processing
############################################################################
sub _got_txt_spf {
	my ($self,$dnsresp) = @_;

	my ($q) = $dnsresp->question;
	my $qtype = $q->qtype;
	DEBUG( "got $qtype for SPF/TXT query: ".$dnsresp->string );

	my $rcode = $dnsresp->header->rcode;
	for my $dummy ( $rcode eq 'NOERROR' ? (1):() ) {

		# RFC4408 says in 4.5:
		# 2. If any records of type SPF are in the set, then all records of
		#    type TXT are discarded.
		# But it says that if both SPF and TXT are given they should be the
		# same (3.1.1)
		# so I think we can ignore the requirement 4.5.2 and just take the
		# first record which is valid SPF

		my (@spfdata,$rrtype);
		if ( $qtype eq 'TXT' or $qtype eq 'SPF' ) {
			for my $rr ($dnsresp->answer) {
				$rrtype = $rr->type;
				$rrtype eq 'TXT' or $rrtype eq 'SPF' or next;
				my $txtdata = join( '', $rr->char_str_list );
				push @spfdata,$1 if $txtdata =~m{^v=spf1(?:$| \s*)(.*)}i;
			}
		}
		@spfdata or last; # no usable SPF reply
		if (@spfdata>1) {
			return ( SPF_PermError,
				"checking $qtype for $self->{domain}",
				"multiple SPF records"
			);
		}
		unless ( eval { $self->_parse_spf( $spfdata[0] ) }) {
			# this is an invalid SPF record
			# make it a permanent error
			# it does not matter if the TXT is bad and the SPF is right
			# because according to RFC if both provide SPF (v=spf1..)
			# they should be the same
			return ( SPF_PermError,
				"checking $qtype for $self->{domain}",
				"invalid SPF record: $@"
			);
		}

		# looks good, return so that next() processes the next query
		return;
	}

	# FAILED:
	# If this is the first response, wait for the other
	if ( grep { ! $_->{done} } @{ $self->{cbq}} ) {
		return (SPF_Noop);
	}

	# otherwise it means that we got no SPF records
	# return SPF_None if this was the initial query ($self->{mech} is undef)
	# and SPF_PermError if as a result from redirect or include
	# ($self->{mech} is [])
	return ( $self->{mech} ? SPF_PermError : SPF_None,
		'no SPF records provided' );
}


############################################################################
# parse SPF record, returns \@parts if record looks valid,
# otherwise die()s with somewhat helpful error message
############################################################################
sub _parse_spf {
	my ($self,$data) = @_;
	my (@mech,$redirect,$explain);
	for ( split( ' ', $data )) {
		my ($qual,$mech,$mod,$arg) = m{^(?:
			([~\-+?]?) # Qualifier
			(all|ip[46]|a|mx|ptr|exists|include)   # Mechanism
			|(redirect|exp)   # Modifier
			|[a-zA-Z][\w.\-]*=  # unknown modifier + '='
		)(.*)  # Arguments
		$}x
			or die "bad SPF part: $_";

		if ( $mech ) {
			$qual = $qual2rv{ $qual || '+' };

			if ( $mech eq 'all' ) {
				die "no arguments allowed with mechanism 'all': '$_'"
					if $arg ne '';
				push @mech, [ \&_mech_all, $qual ]

			} elsif ( $mech eq 'ip4' ) {
				my ($ip,$plen) = $arg =~m{^:(\d+\.\d+\.\d+\.\d+)(?:/([1-9]\d*|0))?$}
					or die "bad argument for mechanism 'ip4' in '$_'";
				$plen = 32 if ! defined $plen;
				$plen>32 and die "invalid prefix len >32 in '$_'";
				eval { $ip = inet_aton( $ip ) }
					or die "bad ip '$ip' in '$_'";
				next if ! $self->{clientip4}; # don't use for IP6
				push @mech, [ \&_mech_ip4, $qual, $ip,$plen ];

			} elsif ( $mech eq 'ip6' ) {
				my ($ip,$plen) = $arg =~m{^:([\da-fA-F:\.]+)(?:/([1-9]\d*|0))?$}
					or die "bad argument for mechanism 'ip6' in '$_'";
				$plen = 128 if ! defined $plen;
				$plen>128 and die "invalid prefix len >128 in '$_'";
				eval { $ip = inet_pton( AF_INET6,$ip ) }
					or die "bad ip '$ip' in '$_'"
					if $can_ip6;
				next if ! $self->{clientip6}; # don't use for IP4
				push @mech, [ \&_mech_ip6, $qual, $ip,$plen ];

			} elsif ( $mech eq 'a' or $mech eq 'mx' ) {
				my ($domain,$plen4,$plen6) =
					( $arg || '' )=~m{^(?::(.+?))?(?:/(?:([1-9]\d*|0)|/([1-9]\d*|0)))?$}
					or die "bad argument for mechanism '$mech' in '$_'";
				if ( defined $plen4 ) {
					$plen4>32 and die "invalid prefix len >32 in '$_'";
				} elsif ( defined $plen6 ) {
					$plen6>128 and die "invalid prefix len >128 in '$_'";
				}
				if ( $self->{clientip4} ) {
					next if defined $plen6; # ignore IP6 checks when we are using IP4
					$plen4 = 32 if ! defined $plen4;
				} else {
					next if defined $plen4; # ignore IP4 checks when we are using IP6
					$plen6 = 128 if ! defined $plen6;
				}
				if ( ! $domain ) {
					$domain = $self->{domain};
				} else {
					if ( my @err = _check_macro_domain($domain)) {
						die $err[2] || 'Invalid domain name';
					}
					$domain = $self->_macro_expand($domain);
				}
				my $sub = $mech eq 'a' ? \&_mech_a : \&_mech_mx;
				push @mech, [ \&_resolve_macro_p, $domain ] if ref($domain);
				push @mech, [ $sub, $qual, $domain, $self->{clientip4} ? $plen4:$plen6 ];

			} elsif ( $mech eq 'ptr' ) {
				my ($domain) = ( $arg || '' )=~m{^(?::([^/]+))?$}
					or die "bad argument for mechanism '$mech' in '$_'";
				$domain = $domain ? $self->_macro_expand($domain) : $self->{domain};
				push @mech, [ \&_resolve_macro_p, $domain ] if ref($domain);
				push @mech, [ \&_mech_ptr, $qual, $domain ];

			} elsif ( $mech eq 'exists' ) {
				my ($domain) = ( $arg || '' )=~m{^:([^/]+)$}
					or die "bad argument for mechanism '$mech' in '$_'";
				$domain = $self->_macro_expand($domain);
				push @mech, [ \&_resolve_macro_p, $domain ] if ref($domain);
				push @mech, [ \&_mech_exists, $qual, $domain ];

			} elsif ( $mech eq 'include' ) {
				my ($domain) = ( $arg || '' )=~m{^:([^/]+)$}
					or die "bad argument for mechanism '$mech' in '$_'";
				$domain = $self->_macro_expand($domain);
				push @mech, [ \&_resolve_macro_p, $domain ] if ref($domain);
				push @mech, [ \&_mech_include, $qual, $domain ];

			} else {
				die "unhandled mechanism '$mech'"
			}

		} elsif ( $mod ) {
			# RFC 4408 doesn't say anything about multiple redirect or
			# explain - they don't make sense, but we won't consider
			# it as an error here, we just use only the first spec
			if ( $mod eq 'redirect' ) {
				die "redirect was specified more than once" if $redirect;
				my ($domain) = ( $arg || '' )=~m{^=([^/]+)$}
					or die "bad argument for modifier '$mod' in '$_'";
				if ( my @err = _check_macro_domain($domain)) {
					die $err[2] || 'Invalid domain name';
				}
				$redirect = $self->_macro_expand($domain);

			} elsif ( $mod eq 'exp' ) {
				die "$explain was specified more than once" if $explain;
				my ($domain) = ( $arg || '' )=~m{^=([^/]+)$}
					or die "bad argument for modifier '$mod' in '$_'";
				if ( my @err = _check_macro_domain($domain)) {
					die $err[2] || 'Invalid domain name';
				}
				$explain = $self->_macro_expand($domain);

			} elsif ( $mod ) {
				die "unhandled modifier '$mod'"
			}
		} else {
			# unknown modifier - check if arg is valid macro-string
			# (will die() on error) but ignore modifier
			$self->_macro_expand($arg || '');
		}
	}
	$self->{mech} = \@mech;
	$self->{explain} = $explain;
	$self->{redirect} = $redirect;
	return 1;
}

############################################################################
# handles mechanism 'all'
# matches all time
############################################################################
sub _mech_all {
	my ($self,$qual) = @_;
	return ( $qual,'matches default');
}

############################################################################
# handle mechanism 'ip4'
# matches if clients IP4 address is in ip/mask
############################################################################
sub _mech_ip4 {
	my ($self,$qual,$ip,$plen) = @_;
	defined $self->{clientip4} or return (); # ignore rule, no IP4 address
	return ($qual,"matches ip4:".inet_ntoa($ip)."/$plen" )
		if ($self->{clientip4} & $mask4[$plen]) eq ($ip & $mask4[$plen]); # rules matches
	return (); # ignore, no match
}

############################################################################
# handle mechanism 'ip6'
# matches if clients IP6 address is in ip/mask
############################################################################
sub _mech_ip6 {
	my ($self,$qual,$ip,$plen) = @_;
	defined $self->{clientip6} or return (); # ignore rule, no IP6 address
	return ($qual,"matches ip6:".inet_ntop(AF_INET6,$ip)."/$plen" )
		if ($self->{clientip6} & $mask6[$plen]) eq ($ip & $mask6[$plen]); # rules matches
	return (); # ignore, no match
}

############################################################################
# handle mechanism 'a'
# check if one of the A/AAAA records for $domain resolves to
# clientip/plen, either directly or via CNAME resolving, in which case
# we expect the resolved CNAME to be in the hints of the response
############################################################################
sub _mech_a {
	my ($self,$qual,$domain,$plen) = @_;
	$domain = $domain->{expanded} if ref $domain;
	if ( my @err = _check_domain($domain, "a:$domain/$plen")) {
		# spec is not clear here:
		# variante1: no match on invalid domain name -> return
		# variante2: propagate err -> return @err
		# we use variante2 for now
		return @err;
	}

	return ( SPF_PermError, "","Number of DNS mechanism exceeded" )
		if --$self->{limit_dns_mech} < 0;

	my $typ = $self->{clientip4} ? 'A':'AAAA';
	$self->{cb} = [ \&_got_A, $qual,$typ,$domain,$plen ];
	return scalar(Net::DNS::Packet->new( $domain, $typ,'IN' ));
}

sub _got_A {
	my ($self,$dnsresp,$qual,$typ,$domain,$plen) = @_;

	if ( $dnsresp->header->rcode eq 'NXDOMAIN' ) {
		# no records found
	} elsif ( $dnsresp->header->rcode ne 'NOERROR' ) {
		return ( SPF_TempError,
			"getting $typ for $domain",
			"error resolving $domain"
		);
	}

	my (%cname,@answer);
	# check first in the answer
	for my $rr ($dnsresp->answer) {
		my $rrtype = $rr->type;
		if ( $rrtype eq 'CNAME' ) {
			$cname{ $rr->cname } = 1;
		} elsif ( $rrtype eq $typ ) {
			push @answer, $rr->address;
		}
	}

	# and the in the additional section
	for my $rr ($dnsresp->additional) {
		if ( $rr->type eq $typ && $cname{$rr->name} ) {
			push @answer, $rr->address;
		}
	}

	if ( ! @answer ) {
		# no A/AAAA records in response - ignore
		return;
	}

	# process all found addresses
	if ( $typ eq 'A' ) {
		my $mask = $mask4[$plen];
		for my $addr (@answer) {
			my $packed = $addr=~m{^[\d.]+$} && eval { inet_aton($addr) }
				or return ( SPF_TempError,
					"getting A for $domain",
					"bad address in A record"
				);
			if ( ($packed & $mask) eq ($self->{clientip4} & $mask) ) {
				# match!
				DEBUG( "check $addr against ".inet_ntoa( $self->{clientip4})."/$plen -> MATCH" );
				return ($qual,"matches domain: $domain/$plen with IP4 $addr" )
			} else {
				DEBUG( "check $addr against ".inet_ntoa( $self->{clientip4})."/$plen -> NO MATCH -- answer="
					.inet_ntoa( $packed&$mask)." ip=".inet_ntoa($self->{clientip4}&$mask)." mask=".inet_ntoa($mask) );
			}
		}
	} else { # AAAA
		my $mask = $mask6[$plen];
		for my $addr (@answer) {
			my $packed = eval { inet_pton(AF_INET6,$addr) }
				or return ( SPF_TempError,
					"getting AAAA for $domain",
					"bad address in AAAA record"
				);
			if ( ($packed & $mask) eq ($self->{clientip6} & $mask) ) {
				# match!
				return ($qual,"matches domain: $domain//$plen with IP6 $addr" )
			}
		}
	}

	# no match
	return;
}


############################################################################
# handle mechanism 'mx'
# similar to mech 'a', we expect the A/AAAA records for the MX in the
# additional section of the DNS response
############################################################################
sub _mech_mx {
	my ($self,$qual,$domain,$plen) = @_;
	$domain = $domain->{expanded} if ref $domain;
	if ( my @err = _check_domain($domain, "mx:$domain".( defined $plen ? "/$plen":"" ))) {
		return @err
	}

	return ( SPF_PermError, "","Number of DNS mechanism exceeded" )
		if --$self->{limit_dns_mech} < 0;

	$self->{cb} = [ \&_got_MX,$qual,$domain,$plen ];
	return scalar(Net::DNS::Packet->new( $domain, 'MX','IN' ));
}

sub _got_MX {
	my ($self,$dnsresp,$qual,$domain,$plen) = @_;

	if ( $dnsresp->header->rcode eq 'NXDOMAIN' ) {
		# no records found
	} elsif ( $dnsresp->header->rcode ne 'NOERROR' ) {
		return ( SPF_TempError,
			"getting MX form $domain",
			"error resolving $domain"
		);
	}

	my (%mx,@answer);
	# check first in the answer
	for my $rr ($dnsresp->answer) {
		if ( $rr->type eq 'MX' ) {
			$mx{ $rr->exchange } = 1;
		}
	}

	# domain has no MX ?
	return if ! %mx;

	# and the in the additional section
	my $atyp = $self->{clientip4} ? 'A':'AAAA';
	for my $rr ($dnsresp->additional) {
		if ( $rr->type eq $atyp && $mx{$rr->name} ) {
			push @answer, $rr->address;
		}
	}

	if ( ! @answer ) {
		# no A/AAAA records in additional section
		return;
	}

	# process all found addresses
	if ( $atyp eq 'A' ) {
		$plen = 32 if ! defined $plen;
		my $mask = $mask4[$plen];
		for my $addr (@answer) {
			my $packed = $addr=~m{^[\d.]+$} && eval { inet_aton($addr) }
				or return ( SPF_TempError,
					"getting A for $domain",
					"bad address in A record"
				);

			if ( ($packed & $mask) eq  ($self->{clientip4} & $mask) ) {
				# match!
				return ($qual,"matches domain: $domain/$plen with IP4 $addr" )
			}
		}
	} else { # AAAA
		$plen = 128 if ! defined $plen;
		my $mask = $mask6[$plen];
		for my $addr (@answer) {
			my $packed = eval { inet_pton(AF_INET6,$addr) }
				or return ( SPF_TempError,
					"getting AAAA for $domain",
					"bad address in AAAA record"
				);
			if ( ($packed & $mask) eq ($self->{clientip6} & $mask) ) {
				# match!
				return ($qual,"matches domain: $domain//$plen with IP6 $addr" )
			}
		}
	}

	# no match
	return;
}


############################################################################
# handle mechanis 'exists'
# just check, if I get any A record for the domain (lookup for A even if
# I use IP6 - this is RBL style)
############################################################################
sub _mech_exists {
	my ($self,$qual,$domain) = @_;
	$domain = $domain->{expanded} if ref $domain;
	if ( my @err = _check_domain($domain, "exists:$domain" )) {
		return @err
	}

	return ( SPF_PermError, "","Number of DNS mechanism exceeded" )
		if --$self->{limit_dns_mech} < 0;

	$self->{cb} = [ \&_got_A_exists,$qual,$domain ];
	return scalar(Net::DNS::Packet->new( $domain, 'A','IN' ));
}

sub _got_A_exists {
	my ($self,$dnsresp,$qual,$domain) = @_;

	return if $dnsresp->header->rcode ne 'NOERROR';

	my (%cname,@answer);
	# check first in the answer
	for my $rr ($dnsresp->answer) {
		my $rrtype = $rr->type;
		if ( $rrtype eq 'CNAME' ) {
			$cname{ $rr->cname } = 1;
		} elsif ( $rrtype eq 'A' ) {
			push @answer, $rr->address;
		}
	}

	# and the in the additional section
	for my $rr ($dnsresp->additional) {
		if ( $rr->type eq 'A' && $cname{$rr->name} ) {
			push @answer, $rr->address;
		}
	}

	return if ! @answer; # no A records
	return ($qual,"domain $domain exists" )
}



############################################################################
# PTR
# this is the most complex and most expensive mechanism:
# - first get domains from PTR records for IP (clientip4|clientip6)
# - filter for domains which match $domain (because only these are interesting
#   for matching)
# - then verify the domains, if they point back to the IP by doing A|AAAA
#   lookups until one domain can be validated
############################################################################
sub _mech_ptr {
	my ($self,$qual,$domain) = @_;
	$domain = $domain->{expanded} if ref $domain;
	if ( my @err = _check_domain($domain, "ptr:$domain" )) {
		return @err
	}

	return ( SPF_PermError, "","Number of DNS mechanism exceeded" )
		if --$self->{limit_dns_mech} < 0;

	my $ip = $self->{clientip4} || $self->{clientip6};
	if ( exists $self->{validated}{$ip}{$domain} ) {
		# already checked
		if ( ! $self->{validated}{$ip}{$domain} ) {
			# could not be validated
			return; # ignore
		} else {
			return ($qual,"$domain validated" );
		}
	}

	my $query;
	if ( $self->{clientip4} ) {
		$query = join( '.', reverse split( m/\./,
			inet_ntoa($self->{clientip4}) ))
			.'.in-addr.arpa'
	} else {
		$query = join( '.', split( //,
			reverse unpack("H*",$self->{clientip6}) ))
			.'.ip6.arpa';
	}

	$self->{cb} = [ \&_got_PTR,$qual,$query,$domain ];
	return scalar(Net::DNS::Packet->new( $query, 'PTR','IN' ));
}

sub _got_PTR {
	my ($self,$dnsresp,$qual,$query,$domain) = @_;

	if ( $dnsresp->header->rcode ne 'NOERROR' ) {
		# can not be validated - ignore mech
		return;
	}

	my @names;
	for my $rr ($dnsresp->answer) {
		push @names, lc($rr->ptrdname) if $rr->type eq 'PTR';
	}
	return if ! @names; # can not be validated - ignore mech

	# strip records, which do not end in $domain
	@names = grep { $_ eq $domain || m{\.\Q$domain\E$} } @names;
	return if ! @names; # return if no matches inside $domain

	# limit to no more then 10 names!
	@names = splice( @names,0,10 );

	# validate the rest by looking up the IP and verifying it
	# with the original IP (clientip)
	my $typ = $self->{clientip4} ? 'A':'AAAA';

	$self->{cb} = [ \&_got_A_ptr, $qual,$typ, \@names ];
	return scalar(Net::DNS::Packet->new( $names[0], $typ,'IN' ));
}

sub _got_A_ptr {
	my ($self,$dnsresp,$qual,$typ,$names) = @_;

	for my $dummy ( $dnsresp->header->rcode eq 'NOERROR' ? (1):() ) {
		my (%cname,@addr);
		# check first in the answer
		for my $rr ($dnsresp->answer) {
			my $rrtype = $rr->type;
			if ( $rrtype eq 'CNAME' ) {
				$cname{ $rr->cname } = 1;
			} elsif ( $rrtype eq $typ ) {
				push @addr, $rr->address;
			}
		}

		# and the in the additional section
		for my $rr ($dnsresp->additional) {
			if ( $rr->type eq $typ && $cname{$rr->name} ) {
				push @addr, $rr->address;
			}
		}

		if ( ! @addr ) {
			# no addr for domain? - try next
			last;
		}

		# check if @addr contains clientip
		my $match;
		if ( $self->{clientip4} ) {
			for(@addr) {
				m{^[\d\.]+$} or next;
				eval { inet_aton($_) } eq $self->{clientip4} or next;
				$match = 1;
				last;
			}
		} else {
			for(@addr) {
				eval { inet_pton(AF_INET6,$_) } eq $self->{clientip6} or next;
				$match = 1;
				last;
			}
		}

		# cache verification status
		my $ip = $self->{clientip4} || $self->{clientip6};
		$self->{validated}{$ip}{$names->[0]} = $match;

		# return $qual if we have verified the ptr
		if ( $match ) {
			return ( $qual,"verified clientip with ptr" )
		}
	}

	# try next
	shift @$names;
	@$names or return; # no next

	# cb stays the same
	return scalar(Net::DNS::Packet->new( $names->[0], $typ,'IN' ));
}


############################################################################
# mechanism include
# include SPF from other domain, propagete errors and consider Pass
# from this inner SPF as match for the include mechanism
############################################################################
sub _mech_include {
	my ($self,$qual,$domain) = @_;
	$domain = $domain->{expanded} if ref $domain;
	if ( my @err = _check_domain($domain, "include:$domain" )) {
		return @err
	}

	return ( SPF_PermError, "","Number of DNS mechanism exceeded" )
		if --$self->{limit_dns_mech} < 0;

	# push and reset current domain and SPF record
	push @{$self->{include_stack}}, {
		domain   => $self->{domain},
		mech     => $self->{mech},
		explain  => $self->{explain},
		redirect => $self->{redirect},
		qual     => $qual,
	};
	$self->{domain}   = $domain;
	$self->{mech}     = [];
	$self->{explain}  = undef;
	$self->{redirect} = undef;

	# start with new SPF record
	return $self->_query_txt_spf;
}


############################################################################
# create explain message from TXT record
############################################################################
sub _got_TXT_exp {
	my ($self,$dnsresp,$oldrv) = @_;
	my @rv = @$oldrv;

	my $txtdata;
	if ( $dnsresp->header->rcode eq 'NOERROR' ) {
		for my $rr ($dnsresp->answer) {
			my $rrtype = $rr->type;
			if ( $rrtype eq 'TXT' ) {
				length( my $t = $rr->txtdata ) or next;
				if ( defined $txtdata ) {
					# only one record should be returned
					$txtdata = undef;
					last;
				} else {
					$txtdata = $t
				}
			}
		}

		# valid TXT record found -> expand macros
		if ( $txtdata and ( my $t = eval { $self->_macro_expand( $txtdata,'exp' ) })) {
			$t = $t->[0] if ref($t); # FIXME: no more %{p} expansion!
			# result should be limited to US-ASCII!
			# further limit to printable chars
			$rv[2] = $t if $t !~m{[\x00-\x1f\x7e-\xff]};
		}
	}

	return @rv;
}

############################################################################
# expand Macros
############################################################################
sub _macro_expand {
	my ($self,$domain,$explain) = @_;
	my $new_domain = '';
	my $mchars = $explain ? qr{[slodipvhcrt]}i : qr{[slodipvh]}i;
	my $need_validated;
	DEBUG( Carp::longmess("keine domain" )) if ! $domain;
	DEBUG( "domain=$domain" );
	while ( $domain =~ m{\G (?:
		([^%]+) |                                              # text
		%(?:
			([%_\-]) |                                         # char: %_, %-, %%
			{ ($mchars) (\d*)(r?) ([.\-+,/_=]*) } | # macro: %l1r+- ->  %(l)(1)(r)(+-)
			(.|$)                                              # bad char
		))}xg ) {
		my ($text,$char,$macro,$macro_n,$macro_r,$macro_delim,$bad)
			= ($1,$2,$3,$4,$5,$6,$7);

		if ( defined $text ) {
			$new_domain .= $text;

		} elsif ( defined $char ) {
			$new_domain .=
				$char eq '%' ? '%' :
				$char eq '_' ? ' ' :
				'%20'

		} elsif ( $macro ) {
			$macro_delim ||= '.';
			my $imacro = lc($macro);
			my $expand =
				$imacro eq 's' ? $self->{sender} :
				$imacro eq 'l' ? $self->{sender} =~m{^([^@]+)\@} ? $1 : 'postmaster' :
				$imacro eq 'o' ? $self->{sender} =~m{\@(.*)} ? $1 : $self->{sender} :
				$imacro eq 'd' ? $self->{domain} :
				$imacro eq 'i' ? $self->{clientip4} ?
					inet_ntoa($self->{clientip4}) :
					do { ( my $x = inet_ntop($self->{clientip6})) =~s{:}{.}g; $x } :
				$imacro eq 'v' ? $self->{clientip4} ? 'in-addr' : 'ip6':
				$imacro eq 'h' ? $self->{helo} :
				$imacro eq 'c' ? $self->{clientip4} ?
					inet_ntoa($self->{clientip4}) :
					inet_ntop($self->{clientip6}) :
				$imacro eq 'r' ? $self->{myname} || 'unknown' :
				$imacro eq 't' ? time() :
				$imacro eq 'p' ? do {
					my $ip = $self->{clientip4} || $self->{clientip6};
					my $v = $self->{validated}{$ip};
					my $d = $self->{domain};
					if ( ! $v ) {
						# nothing validated pointing to IP
						$need_validated = { ip => $ip, domain => $d };
						'unknown'
					} elsif ( $v->{$d} ) {
						# <domain> itself is validated
						$d;
					} elsif ( my @xd = grep { $v->{$_} } keys %$v ) {
						if ( my @sd = grep { m{\.\Q$d\E$} } @xd ) {
							# subdomain if <domain> is validated
							$sd[0]
						} else {
							# any other domain pointing to IP
							$xd[0]
						}
					}
				} :
				die "unknown macro $macro";

			my $rx = eval "qr{[$macro_delim]}";
			my @parts = split( $rx, $expand );
			@parts = reverse @parts if $macro_r;
			if ( length $macro_n ) {
				die "bad macro definition '$domain'" if ! $macro_n; # must be != 0
				@parts = splice( @parts,-$macro_n );
			}
			$new_domain .= join('.',@parts);
			if ( $imacro ne $macro ) {
				# upper case - URI escape
				$new_domain = uri_escape($new_domain);
			}

		} else {
			die "bad macro definition '$domain'";
		}
	}

	if ( ! $explain ) {
		# should be less than 253 bytes
		while ( length($new_domain)>253 ) {
			$new_domain =~s{^[^.]*\.}{} or last;
		}
		$new_domain = '' if length($new_domain)>253;
	}

	if ( $need_validated ) {
		return { expanded => $new_domain, %$need_validated, macro => $domain }
	} else {
		return $new_domain;
	}
}

############################################################################
# resolve macro %{p}, e.g. find validated domain name for IP and replace
# %{p} with it. This has many thing similar with the ptr: method
############################################################################
sub _resolve_macro_p {
	my ($self,$rec) = @_;
	my $ip = ref($rec) && $rec->{ip} or return; # nothing to resolve

	# could it already be resolved w/o further lookups?
	my $d = eval { $self->_macro_expand( $rec->{macro} ) };
	if ( ! ref $d ) {
		%$rec = ( expanded => $d ) if ! $@;
		return;
	}

	my $query;
	if ( length($ip) == 4 ) {
		$query = join( '.', reverse split( m/\./,
			inet_ntoa($ip) )) .'.in-addr.arpa'
	} else {
		$query = join( '.', split( //,
			reverse unpack("H*",$ip) )) .'.ip6.arpa';
	}

	$self->{cb} = [ \&_validate_got_PTR, $rec ];
	return scalar(Net::DNS::Packet->new( $query, 'PTR','IN' ));
}

sub _validate_got_PTR {
	my ($self,$dnsresp,$rec ) = @_;

	return if $dnsresp->header->rcode ne 'NOERROR';

	my @names;
	for my $rr ($dnsresp->answer) {
		push @names, lc($rr->ptrdname) if $rr->type eq 'PTR';
	}
	@names or return; # no records

	# prefer records, which are $domain or end in $domain
	if ( my $domain = $rec->{domain} ) {
		unshift @names, grep { $_ eq $domain } @names;
		unshift @names, grep { m{\.\Q$domain\E$} } @names;
		{ my %n; @names = grep { !$n{$_}++ } @names } # uniq
	}

	# limit to no more then 10 names!
	@names = splice( @names,0,10 );

	# validate the rest by looking up the IP and verifying it
	# with the original IP (clientip)
	my $typ = length($rec->{ip}) == 4 ? 'A':'AAAA';

	$self->{cb} = [ \&_validate_got_A_ptr, $rec,\@names ];
	return scalar(Net::DNS::Packet->new( $names[0], $typ,'IN' ));
}

sub _validate_got_A_ptr {
	my ($self,$dnsresp,$rec,$names) = @_;

	my $typ = length($rec->{ip}) == 4 ? 'A':'AAAA';
	if ( $dnsresp->header->rcode eq 'NOERROR' ) {
		my (%cname,@addr);
		# check first in the answer
		for my $rr ($dnsresp->answer) {
			my $rrtype = $rr->type;
			if ( $rrtype eq 'CNAME' ) {
				$cname{ $rr->cname } = 1;
			} elsif ( $rrtype eq $typ ) {
				push @addr, $rr->address;
			}
		}

		# and the in the additional section
		for my $rr ($dnsresp->additional) {
			if ( $rr->type eq $typ && $cname{$rr->name} ) {
				push @addr, $rr->address;
			}
		}

		if ( ! @addr ) {
			# no addr for domain? - ignore - maybe
			# the domain only provides the other kind of records?
			return;
		}

		# check if @addr contains clientip
		my $match;
		my $ip = $rec->{ip};
		if ( length($ip) == 4 ) {
			for(@addr) {
				m{^[\d\.]+$} or next;
				eval { inet_aton($_) } eq $ip or next;
				$match = 1;
				last;
			}
		} else {
			for(@addr) {
				eval { inet_pton(AF_INET6,$_) } eq $ip or next;
				$match = 1;
				last;
			}
		}

		# cache verification status
		$self->{validated}{$ip}{$names->[0]} = $match;

		# expand macro if we have verified the ptr
		if ( $match ) {
			if ( my $t = eval { $self->_macro_expand( $rec->{macro} ) }) {
				%$rec = ( expanded => $t );
			}
			return;
		}
	}

	# try next
	shift @$names;
	@$names or return; # no next

	# cb stays the same
	return scalar(Net::DNS::Packet->new( $names->[0], $typ,'IN' ));
}


1;
