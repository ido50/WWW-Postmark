#!perl -T

use strict;
use warnings;
use Test::More tests => 6;
use WWW::Postmark;

# generate a new API method. The Postmark service provides a special token
# for testing purposes ('POSTMARK_API_TEST').
my $api = WWW::Postmark->new('POSTMARK_API_TEST');

ok($api, 'Got a proper WWW::Postmark object');

# a message that should be successful
my $res;

eval { $res = $api->send(from => 'fake@email.com', to => 'nowhere@email.com', subject => 'A test message.', body => 'This is a test message.'); };

is($res, 1, 'simple sending okay');

# a message that should failed because of wrong token
$api->{token} = 'TEST_TOKEN_THAT_SHOULD_FAIL';

eval { $res = $api->send(from => 'fake@email.com', to => 'nowhere@email.com', subject => 'A test message.', body => 'This is a test message.'); };

like($@, qr/Missing or incorrect API Key header/, 'expected token failure okay');

# a message that should failed because of no body
$api->{token} = 'POSTMARK_API_TEST';

eval { $res = $api->send(from => 'fake@email.com', to => 'nowhere@email.com', subject => 'A test message.'); };

like($@, qr/You must provide a mail body/, 'expected token failure okay');

# a message with multiple recipients that should succeed
eval { $res = $api->send(from => 'Fake Email <fake@email.com>', to => 'nowhere@email.com, Some Guy <dev@null.com>,nullify@domain.com', subject => 'A test message.', body => '<html>An HTML message</html>', cc => 'blackhole@nowhere.com, smackhole@nowhere.com'); };

is($res, 1, 'multiple recipients okay');

# an ssl message that should succeed
$api->{use_ssl} = 1;
eval { $res = $api->send(from => 'Fake Email <fake@email.com>', to => 'nowhere@email.com', subject => 'A test message.', body => '<html>An HTML message</html>'); };

is($res, 1, 'SSL sending okay');

done_testing();
