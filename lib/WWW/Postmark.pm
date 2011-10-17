package WWW::Postmark;

use strict;
use warnings;
use feature "switch";
use LWP::UserAgent;
use JSON::Any;
use Email::Valid;
use Try::Tiny;
use Carp;

# ABSTRACT: API for the Postmark mail service for web applications.

my $ua = LWP::UserAgent->new;
$ua->timeout(30);
$ua->env_proxy;

my $json = JSON::Any->new;

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
according the amount of emails you send (right now first 1,000 emails are
free), and requires signing up in order to receive an API token.

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

=head1 METHODS

=head2 new( $api_token, [$use_ssl] )

Creates a new instance of this class, with a Postmark API token that you've
received from the Postmark app. By default, requests are made through HTTP;
if you want to send them with SSL encryption, pass a true value for
C<$use_ssl>.

=cut

sub new {
	my ($class, $token, $use_ssl) = @_;

	croak "You must provide your Postmark API token." unless $token;

	$use_ssl ||= 0;
	$use_ssl = 1 if $use_ssl;

	bless { token => $token, use_ssl => $use_ssl }, $class;
}

=head2 send( from => 'you@mail.com', to => 'them@mail.com', subject => 
'An email message', body => $message_body, [ cc => 'someone@mail.com',
bcc => 'otherone@mail.com, anotherone@mail.com', tag => 'sometag',
reply_to => 'do-not-reply@mail.com' ] )

Receives a hash representing the email message that should be sent and
attempts to send it through the Postmark service. If the message was
successfully sent, a true value is returned; otherwise, this method will
croak with an approriate error message (see L</"ERRORS> for a full list).

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

Either this parameter or html and/or text are required.

=item * html

Instead of using C<body> you can also specify the html content directly.

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

=back

=cut

sub send {
	my ($self, %params) = @_;

	# make sure there's a from address
	croak "You must provide a valid 'from' address in the format 'address\@domain.tld', or 'Your Name <address\@domain.tld>'."
		unless $params{from} && Email::Valid->address($params{from});

	# make sure there's at least on to address
	croak $self->_recipient_error('to')
		unless $params{to};

	# validate all 'to' addresses
	try {
		$self->_validate_recipients('to', $params{to});
	} catch {
		croak $_;
	}

	# make sure there's a subject
	croak "You must provide a mail subject."
		unless $params{subject};

	# make sure there's a mail body
	croak "You must provide a mail body."
		unless $params{body} or $params{html} or $params{text};

	# if cc and/or bcc are provided, validate them
	if ($params{cc}) {
		try {
			$self->_validate_recipients('cc', $params{cc});
		} catch {
			croak $_;
		}
	}
	if ($params{bcc}) {
		try {
			$self->_validate_recipients('bcc', $params{bcc});
		} catch {
			croak $_;
		}
	}

	# if reply_to is provided, validate it
	if ($params{reply_to}) {
		croak "You must provide a valid reply-to address, in the format 'address\@domain.tld', or 'Some Name <address\@domain.tld>'."
			unless Email::Valid->address($params{reply_to});
	}

	# parse the body param
	my $body = delete $params{body};
	if ($body =~ m/^\<html\>/i && $body =~ m!\</html\>$!i) {
		# this is an HTML message
		$params{html} = $body;
	} else {
		# this is a test message
		$params{text} = $body;
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
	$msg->{Bcc} = $params{Bcc} if $params{bcc};
	$msg->{Tag} = $params{tag} if $params{tag};
	$msg->{ReplyTo} = $params{reply_to} if $params{reply_to};

	# create an HTTP::Request object
	my $req = HTTP::Request->new('post', $self->{use_ssl} ? 'https://api.postmarkapp.com/email' : 'http://api.postmarkapp.com/email', ['Accept' => 'application/json', 'Content-Type' => 'application/json', 'X-Postmark-Server-Token' => $self->{token} ], $json->to_json($msg));

	# send the request
	my $res = $ua->request($req);

	# analyze the response
	if ($res->is_success) {
		# woooooooooooooeeeeeeeeeeee
		return 1;
	} else {
		croak "Failed sending message: ".$self->_analyze_response($res);
	}
}

=head1 INTERNAL METHODS

The following methods are only to be used internally.

=head2 _validate_recipients

=cut

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

=head2 _recipient_error( $field )

=cut

sub _recipient_error {
	my ($self, $field) = @_;

	return "You must provide a valid '$field' address or addresses, in the format 'address\@domain.tld', or 'Some Name <address\@domain.tld>'. If you're sending to multiple addresses, separate them with commas. You can send up to 20 maximum addresses.";
}

=head2 _analyze_response( $res )

=cut

sub _analyze_response {
	my ($self, $res) = @_;

	given ($res->code) {
		when (401) {
			return "Missing or incorrect API Key header.";
		}
		when (422) {
			# error is in the JSON thingy
			my $msg = $json->from_json($res->content);

			my $code_msg;
			given ($msg->{ErrorCode}) {
				when (407) {
					$code_msg = "Bounce not found";
				}
				when (408) {
					$code_msg = "Bounce query exception";
				}
				when (406) {
					$code_msg = "Inactive recipient";
				}
				when (403) {
					$code_msg = "Incompatible JSON";
				}
				when (300) {
					$code_msg = "Invalid email request";
				}
				when (402) {
					$code_msg = "Invalid JSON";
				}
				when (409) {
					$code_msg = "JSON required";
				}
				when (0) {
					$code_msg = "Bad or missing API token";
				}
				when (401) {
					$code_msg = "Sender signature not confirmed";
				}
				when (400) {
					$code_msg = "Sender signature not found";
				}
				when (405) {
					$code_msg = "Not allowed to send";
				}
				default {
					$code_msg = "Unknown error";
				}
			}
			return $code_msg . ': '. $msg->{Message};
		}
		when (500) {
			return "Postmark service error. The service might be down.";
		}
		default {
			return "Unknown error.";
		}
	}
}

=head1 AUTHOR

Ido Perlmuter, C<< <ido at ido50 dot net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-www-postmark at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=WWW-Postmark>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc WWW::Postmark

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=WWW-Postmark>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/WWW-Postmark>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/WWW-Postmark>

=item * Search CPAN

L<http://search.cpan.org/dist/WWW-Postmark/>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2010 Ido Perlmuter.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1;
