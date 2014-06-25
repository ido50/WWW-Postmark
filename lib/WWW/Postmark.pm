package WWW::Postmark;

# ABSTRACT: API for the Postmark mail service for web applications.

use strict;
use warnings;
use feature 'switch';

use Carp;
use Email::Valid;
use HTTP::Tiny;
use JSON;

our $VERSION = "0.6";
$VERSION = eval $VERSION;

my $ua = HTTP::Tiny->new(timeout => 45);

=encoding utf-8

=head1 NAME

WWW::Postmark - API for the Postmark mail service for web applications.

=head1 SYNOPSIS

	use WWW::Postmark;

	my $api = WWW::Postmark->new('api_token');
	
	# or, if you want to use SSL
	my $api = WWW::Postmark->new('api_token', 1);

	# send an email
	$api->send(from => 'me@domain.tld', to => 'you@domain.tld, them@domain.tld',
	subject => 'an email message', body => "hi guys, what's up?");

=head1 DESCRIPTION

The WWW::Postmark module provides a simple API for the Postmark web service,
that provides email sending facilities for web applications. Postmark is
located at L<http://postmarkapp.com>. It is a paid service that charges
according the amount of emails you send, and requires signing up in order
to receive an API token.

You can send emails either through HTTP or HTTPS with SSL encryption. You
can send your emails to multiple recipients at once (but there's a 20
recipients limit). If WWW::Postmark receives a successful response from
the Postmark service, it will return a true value; otherwise it will die.

To make it clear, Postmark is not an email marketing service for sending
email campaigns or newsletters to multiple subscribers at once. It's meant
for sending emails from web applications in response to certain events,
like someone signing up to your website.

Postmark provides a test API token that doesn't really send the emails.
The token is 'POSTMARK_API_TEST', and you can use it for testing purposes
(the tests in this distribution use this token).

Besides sending emails, this module also provides support for Postmark's
spam score API, which allows you to get a SpamAssassin report for an email
message. See documentation for the C<spam_score()> method for more info.

=head1 METHODS

=head2 new( [ $api_token, $use_ssl] )

Creates a new instance of this class, with a Postmark API token that you've
received from the Postmark app. By default, requests are made through HTTP;
if you want to send them with SSL encryption, pass a true value for
C<$use_ssl>.

If you do not provide an API token, you will only be able to use Postmark's
spam score API (you will not be able to send emails).

=cut

sub new {
	my ($class, $token, $use_ssl) = @_;

	carp "You have not provided a Postmark API token, you will not be able to send emails."
		unless $token;

	$use_ssl ||= 0;
	$use_ssl = 1 if $use_ssl;

	bless { token => $token, use_ssl => $use_ssl }, $class;
}

=head2 send( %params )

Receives a hash representing the email message that should be sent and
attempts to send it through the Postmark service. If the message was
successfully sent, a hash reference of Postmark's response is returned
(refer to L<the relevant Postmark documentation|http://developer.postmarkapp.com/developer-build.html#success-response>);
otherwise, this method will croak with an approriate error message (see
L</"DIAGNOSTICS"> for a full list).

The following keys are required when using this method:

=over

=item * from

The email address of the sender. Either pass the email address itself
in the format 'mail_address@domain.tld' or also provide a name, like
'My Name <mail_address@domain.tld>'.

=item * to

The email address(es) of the recipient(s). You can use both formats as in
'to', but here you can give multiple addresses. Use a comma to separate
them. Note, however, that Postmark limits this to 20 recipients and sending
will fail if you attempt to send to more than 20 addresses.

=item * subject

The subject of your message.

=item * body

The body of your message. This could be plain text, or HTML. If you want
to send HTML, be sure to open with '<html>' and close with '</html>'. This
module will look for these tags in order to find out whether you're sending
a text message or an HTML message.

Since version 0.3, however, you can explicitly specify the type of your
message, and also send both plain text and HTML. To do so, use the C<html>
and/or C<text> attributes. Their presence will override C<body>.

=item * html

Instead of using C<body> you can also specify the HTML content directly.

=item * text

... or the plain text part of the email.

=back

You can optionally supply the following parameters as well:

=over

=item * cc, bcc

Same rules as the 'to' parameter.

=item * tag

Can be used to label your mail messages according to different categories,
so you can analyze statistics of your mail sendings through the Postmark service.

=item * reply_to

Will force recipients of your email to send their replies to this mail
address when replying to your email.

=item * track_opens

Set to a true value to enable Postmark's open tracking functionality.

=back

=cut

sub send {
	my ($self, %params) = @_;

	# do we have an API token?
	croak "You have not provided a Postmark API token, you cannot send emails"
		unless $self->{token};

	# make sure there's a from address
	croak "You must provide a valid 'from' address in the format 'address\@domain.tld', or 'Your Name <address\@domain.tld>'."
		unless $params{from} && Email::Valid->address($params{from});

	# make sure there's at least on to address
	croak $self->_recipient_error('to')
		unless $params{to};

	# validate all 'to' addresses
	$self->_validate_recipients('to', $params{to});

	# make sure there's a subject
	croak "You must provide a mail subject."
		unless $params{subject};

	# make sure there's a mail body
	croak "You must provide a mail body."
		unless $params{body} or $params{html} or $params{text};

	# if cc and/or bcc are provided, validate them
	if ($params{cc}) {
		$self->_validate_recipients('cc', $params{cc});
	}
	if ($params{bcc}) {
		$self->_validate_recipients('bcc', $params{bcc});
	}

	# if reply_to is provided, validate it
	if ($params{reply_to}) {
		croak "You must provide a valid reply-to address, in the format 'address\@domain.tld', or 'Some Name <address\@domain.tld>'."
			unless Email::Valid->address($params{reply_to});
	}

	# parse the body param, unless html or text are present
	unless ($params{html} || $params{text}) {
		my $body = delete $params{body};
		if ($body =~ m/^\<html\>/i && $body =~ m!\</html\>$!i) {
			# this is an HTML message
			$params{html} = $body;
		} else {
			# this is a test message
			$params{text} = $body;
		}
	}

	# all's well, let's try an send this

	# create the message data structure
	my $msg = {
		From => $params{from},
		To => $params{to},
		Subject => $params{subject},
	};

	$msg->{HtmlBody} = $params{html} if $params{html};
	$msg->{TextBody} = $params{text} if $params{text};
	$msg->{Cc} = $params{cc} if $params{cc};
	$msg->{Bcc} = $params{bcc} if $params{bcc};
	$msg->{Tag} = $params{tag} if $params{tag};
	$msg->{ReplyTo} = $params{reply_to} if $params{reply_to};
	$msg->{TrackOpens} = 1 if $params{track_opens};

	# create and send the request
	my $res = $ua->request(
		'POST',
		$self->{use_ssl} ? 'https://api.postmarkapp.com/email' : 'http://api.postmarkapp.com/email',
		{
			headers => {
				'Accept' => 'application/json',
				'Content-Type' => 'application/json',
				'X-Postmark-Server-Token' => $self->{token},
			},
			content => encode_json($msg),
		}
	);

	# analyze the response
	if ($res->{success}) {
		# woooooooooooooeeeeeeeeeeee
		return decode_json($res->{content});
	} else {
		croak "Failed sending message: ".$self->_analyze_response($res);
	}
}

=head2 spam_score( $raw_email, [ $options ] )

Use Postmark's SpamAssassin API to determine the spam score of an email
message. You need to provide the raw email text to this method, with all
headers intact. If C<$options> is 'long' (the default), this method
will return a hash-ref with a 'report' key, containing the full
SpamAssasin report, and a 'score' key, containing the spam score. If
C<$options> is 'short', only the spam score will be returned (directly, not
in a hash-ref).

If the API returns an error, this method will croak.

Note that the SpamAssassin API is currently HTTP only, there is no HTTPS
interface, so the C<use_ssl> option to the C<new()> method is ignored here.

For more information about this API, go to L<http://spamcheck.postmarkapp.com>.

=cut

sub spam_score {
	my ($self, $raw_email, $options) = @_;

	croak 'You must provide the raw email text to spam_score().'
		unless $raw_email;

	$options ||= 'long';

	my $res = $ua->request(
		'POST',
		'http://spamcheck.postmarkapp.com/filter',
		{
			headers => {
				'Accept' => 'application/json',
				'Content-Type' => 'application/json',
			},
			content => encode_json({
				email => $raw_email,
				options => $options,
			}),
		}
	);

	# analyze the response
	if ($res->{success}) {
		# doesn't mean we have succeeded, an error may have been returned
		my $ret = decode_json($res->{content});
		if ($ret->{success}) {
			return $options eq 'long' ? $ret : $ret->{score};
		} else {
			croak "Postmark spam score API returned error: ".$ret->{message};
		}
	} else {
		croak "Failed determining spam score: $res->{content}";
	}
}

##################################
##      INTERNAL METHODS        ##
##################################

sub _validate_recipients {
	my ($self, $field, $param) = @_;

	# split all addresses
	my @ads = split(/, ?/, $param);

	# make sure there are no more than twenty
	croak $self->_recipient_error($field)
		if scalar @ads > 20;

	# validate them
	foreach (@ads) {
		croak $self->_recipient_error($field)
			unless Email::Valid->address($_);
	}

	# all's well
	return 1;
}

sub _recipient_error {
	my ($self, $field) = @_;

	return "You must provide a valid '$field' address or addresses, in the format 'address\@domain.tld', or 'Some Name <address\@domain.tld>'. If you're sending to multiple addresses, separate them with commas. You can send up to 20 maximum addresses.";
}

sub _analyze_response {
	my ($self, $res) = @_;

	given ($res->{status}) {
		when (401) {
			return "Missing or incorrect API Key header.";
		}
		when (422) {
			# error is in the JSON thingy
			my $msg = decode_json($res->{content});

			my $code_msg;
			given ($msg->{ErrorCode}) {
				when (0) {
					$code_msg = 'Bad or missing API token';
				}
				when (300) {
					$code_msg = 'Invalid email request';
				}
				when (400) {
					$code_msg = 'Sender signature not found';
				}
				when (401) {
					$code_msg = 'Sender signature not confirmed';
				}
				when (402) {
					$code_msg = 'Invalid JSON';
				}
				when (403) {
					$code_msg = 'Incompatible JSON';
				}
				when (405) {
					$code_msg = 'Not allowed to send';
				}
				when (406) {
					$code_msg = 'Inactive recipient';
				}
				when (407) {
					$code_msg = 'Bounce not found';
				}
				when (408) {
					$code_msg = 'Bounce query exception';
				}
				when (409) {
					$code_msg = 'JSON required';
				}
				when (410) {
					$code_msg = 'Too many batch messages';
				}
				default {
					$code_msg = "Unknown Postmark error code $msg->{ErrorCode}";
				}
			}
			return $code_msg . ': '. $msg->{Message};
		}
		when (500) {
			return 'Postmark service error. The service might be down.';
		}
		default {
			return "Unknown HTTP error code $res->{status}.";
		}
	}
}

=head1 DIAGNOSTICS

The following exceptions are thrown by this module:

=over

=item C<< "You have not provided a Postmark API token, you cannot send emails" >>

This means you haven't provided the C<new()> subroutine your Postmark API token.
Using the Postmark API requires an API token, received when registering to their
service via their website.

=item C<< "You must provide a mail subject." >>

This error means you haven't given the C<send()> method a subject for your email
message. Messages sent with this module must have a subject.

=item C<< "You must provide a mail body." >>

This error means you haven't given the C<send()> method a body for your email
message. Messages sent with this module must have content.

=item C<< "You must provide a valid 'from' address in the format 'address\@domain.tld', or 'Your Name <address\@domain.tld>'." >>

This error means the address (or one of the addresses) you're trying to send
an email to with the C<send()> method is not a valid email address (in the sense
that it I<cannot> be an email address, not in the sense that the email address does not
exist (For example, "asdf" is not a valid email address).

=item C<< "You must provide a valid reply-to address, in the format 'address\@domain.tld', or 'Some Name <address\@domain.tld>'." >>

This error, when providing the C<reply-to> parameter to the C<send()> method,
means the C<reply-to> value is not a valid email address.

=item C<< "You must provide a valid '%s' address or addresses, in the format 'address\@domain.tld', or 'Some Name <address\@domain.tld>'. If you're sending to multiple addresses, separate them with commas. You can send up to 20 maximum addresses." >>

Like the above two error messages, but for other email fields such as C<cc> and C<bcc>.

=item C<< "Failed sending message: %s" >>

This error is thrown when sending an email fails. The error message should
include the actual reason for the failure. Usually, the error is returned by
the Postmark API. For a list of errors returned by Postmark and their meaning,
take a look at L<http://developer.postmarkapp.com/developer-build.html>.

=item C<< "Unknown Postmark error code %s" >>

This means Postmark returned an error code that this module does not
recognize. The error message should include the error code. If you find
that error code in L<http://developer.postmarkapp.com/developer-build.html>,
it probably means this is a new error code this module does not know about yet,
so please open an appropriate bug report.

=item C<< "Unknown HTTP error code %s." >>

This means the Postmark API returned an unexpected HTTP status code. The error
message should include the status code returned.

=item C<< "You must provide the raw email text to spam_score()." >>

This error means you haven't passed the C<spam_score()> method the
requried raw email text.

=item C<< "Postmark spam score API returned error: %s" >>

This error means the spam score API failed parsing your raw email
text. The error message should include the actual reason for the failure.
This would be an I<expected> API error. I<Unexpected> API errors will
be thrown with the next error message.

=item C<< "Failed determining spam score: %s" >>

This error means the spam score API returned an HTTP error. The error
message should include the actual error message returned.

=back

=head1 CONFIGURATION AND ENVIRONMENT
  
C<WWW::Postmark> requires no configuration files or environment variables.

=head1 DEPENDENCIES

C<WWW::Postmark> B<depends> on the following CPAN modules:

=over

=item * L<Carp>

=item * L<Email::Valid>

=item * L<HTTP::Tiny>

=item * L<JSON>

=back

C<WWW::Postmark> recommends L<JSON::XS> for parsing JSON (the Postmark API
is JSON based). If installed, L<JSON> will automatically load L<JSON::XS>
instead.

=head1 INCOMPATIBILITIES WITH OTHER MODULES

None reported.

=head1 BUGS AND LIMITATIONS

No bugs have been reported.

Please report any bugs or feature requests to
C<bug-WWW-Postmark@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=WWW-Postmark>.

=head1 AUTHOR

Ido Perlmuter <ido@ido50.net>

With help from: Casimir Loeber.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2010-2014, Ido Perlmuter C<< ido@ido50.net >>.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself, either version
5.8.1 or any later version. See L<perlartistic|perlartistic> 
and L<perlgpl|perlgpl>.

The full text of the license can be found in the
LICENSE file included with this module.

=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

=cut

1;
__END__
