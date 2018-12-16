#!/usr/bin/env perl

# This test assumes the following system environment:
#  - The current locale is UTF-8.
#  - Locale fr_FR.ISO-8859-1 is available.

use strict;
use warnings;
use utf8;

use Test::More tests => 34;

use Digest::MD5;
use File::Basename;
use IPC::Open3;
use Symbol 'gensym';

my $opustags = '../opustags';
BAIL_OUT("$opustags does not exist or is not executable") if (! -x $opustags);

sub opustags {
	my %opt;
	%opt = %{pop @_} if ref $_[-1];
	my ($pid, $pin, $pout, $perr);
	$perr = gensym;
	$pid = open3($pin, $pout, $perr, $opustags, @_);
	binmode($pin, $opt{mode} // ':utf8');
	binmode($pout, $opt{mode} // ':utf8');
	binmode($perr, ':utf8');
	local $/;
	print $pin $opt{in} if defined $opt{in};
	close $pin;
	my $out = <$pout>;
	my $err = <$perr>;
	waitpid($pid, 0);
	[$out, $err, $?]
}

####################################################################################################
# Tests related to the overall opustags executable, like the help message.
# No Opus file is manipulated here.

is_deeply(opustags(), ['', <<EOF, 256], 'no options is a failure');
error: No arguments specified. Use -h for help.
EOF

my $help = opustags('--help');
$help->[0] =~ /^([^\n]*+)/;
my $version = $1;
like($version, qr/^opustags version (\d+\.\d+\.\d+)/, 'get the version string');

my $expected_help = <<"EOF";
$version

Usage: opustags --help
       opustags [OPTIONS] FILE
       opustags OPTIONS FILE -o FILE

Options:
  -h, --help              print this help
  -o, --output FILE       set the output file
  -i, --in-place          overwrite the input file instead of writing a different output file
  -y, --overwrite         overwrite the output file if it already exists
  -a, --add FIELD=VALUE   add a comment
  -d, --delete FIELD      delete all previously existing comments of a specific type
  -D, --delete-all        delete all the previously existing comments
  -s, --set FIELD=VALUE   replace a comment (shorthand for --delete FIELD --add FIELD=VALUE)
  -S, --set-all           replace all the comments with the ones read from standard input

See the man page for extensive documentation.
EOF

is_deeply(opustags('--help'), [$expected_help, '', 0], '--help displays the help message');
is_deeply(opustags('-h'), [$expected_help, '', 0], '-h displays the help message too');

is_deeply(opustags('--derp'), ['', <<"EOF", 256], 'unrecognized option shows an error');
error: Unrecognized option '--derp'.
EOF

is_deeply(opustags('../opustags'), ['', <<"EOF", 256], 'not an Ogg stream');
error: Input is not a valid Ogg file.
EOF

####################################################################################################
# Test the main features of opustags on an Ogg Opus sample file.

sub md5 {
	my ($file) = @_;
	open(my $fh, '<', $file) or return;
	my $ctx = Digest::MD5->new;
	$ctx->addfile($fh);
	$ctx->hexdigest
}

is(md5('gobble.opus'), '111a483596ac32352fbce4d14d16abd2', 'the sample is the one we expect');
is_deeply(opustags('gobble.opus'), [<<'EOF', '', 0], 'read the initial tags');
encoder=Lavc58.18.100 libopus
EOF

unlink('out.opus');
is_deeply(opustags(qw(gobble.opus -o out.opus)), ['', '', 0], 'copy the file without changes');
is(md5('out.opus'), '111a483596ac32352fbce4d14d16abd2', 'the copy is faithful');

# empty out.opus
{ my $fh; open($fh, '>', 'out.opus') and close($fh) or die }
is_deeply(opustags(qw(gobble.opus -o out.opus)), ['', <<'EOF', 256], 'refuse to override');
error: 'out.opus' already exists. Use -y to overwrite.
EOF
is(md5('out.opus'), 'd41d8cd98f00b204e9800998ecf8427e', 'the output wasn\'t written');

is_deeply(opustags(qw(gobble.opus -o /dev/null)), ['', '', 0], 'write to /dev/null');

is_deeply(opustags(qw(gobble.opus -o out.opus --overwrite)), ['', '', 0], 'overwrite');
is(md5('out.opus'), '111a483596ac32352fbce4d14d16abd2', 'successfully overwritten');

is_deeply(opustags(qw(--in-place out.opus -a A=B --add=A=C --add), "TITLE=Foo Bar",
                   qw(--delete A --add TITLE=七面鳥 --set encoder=whatever -s 1=2 -s X=1 -a X=2 -s X=3)),
          ['', '', 0], 'complex tag editing');
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'check the footprint');

is_deeply(opustags('out.opus'), [<<'EOF', '', 0], 'check the tags written');
A=B
A=C
TITLE=Foo Bar
TITLE=七面鳥
encoder=whatever
1=2
X=1
X=2
X=3
EOF

is_deeply(opustags(qw(out.opus -d A -d foo -s X=4 -a TITLE=gobble -d TITLE)), [<<'EOF', '', 0], 'dry editing');
encoder=whatever
1=2
X=4
TITLE=gobble
EOF
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'the file did not change');

is_deeply(opustags(qw(-i out.opus -a fatal=yes -a FOO -a BAR)), ['', <<'EOF', 256], 'bad tag with --add');
error: Comment does not contain an equal sign: FOO.
EOF
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'the file did not change');

is_deeply(opustags('out.opus', '-D', '-a', "X=foo\nbar\tquux"), [<<'END_OUT', <<'END_ERR', 0], 'control characters');
X=foo
bar	quux
END_OUT
warning: Some tags contain newline characters. These are not supported by --set-all.
warning: Some tags contain control characters.
END_ERR

is_deeply(opustags(qw(-i out.opus -s fatal=yes -s FOO -s BAR)), ['', <<'EOF', 256], 'bad tag with --set');
error: Comment does not contain an equal sign: FOO.
EOF
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'the file did not change');

is_deeply(opustags(qw(out.opus --delete-all -a OK=yes)), [<<'EOF', '', 0], 'delete all');
OK=yes
EOF

is_deeply(opustags(qw(out.opus --set-all -a A=B -s X=Z -d OK), {in => <<'END_IN'}), [<<'END_OUT', '', 0], 'set all');
OK=yes again
ARTIST=七面鳥

A=A
X=Y
END_IN
OK=yes again
ARTIST=七面鳥
A=A
X=Y
A=B
X=Z
END_OUT

is_deeply(opustags(qw(out.opus -S), {in => <<'END_IN'}), [<<'END_OUT', <<'END_ERR', 256], 'set all with bad tags');
whatever
wrong=yes
END_IN
END_OUT
error: Malformed tag: whatever
END_ERR

sub slurp {
	my ($filename) = @_;
	local $/;
	open(my $fh, '<', $filename);
	binmode($fh);
	my $data = <$fh>;
	$data
}

my $data = slurp 'out.opus';
is_deeply(opustags('-', '-o', '-', {in => $data, mode => ':raw'}), [$data, '', 0], 'read opus from stdin and write to stdout');

unlink('out.opus');

####################################################################################################
# Test muxed streams

system('ffmpeg -loglevel error -y -i gobble.opus -c copy -map 0:0 -map 0:0 -shortest muxed.ogg') == 0
	or BAIL_OUT('could not create a muxed stream');

is_deeply(opustags('muxed.ogg'), ['', <<'END_ERR', 256], 'muxed streams detection');
error: Muxed streams are not supported yet.
END_ERR

unlink('muxed.ogg');

####################################################################################################
# Locale

opustags(qw(gobble.opus -a TITLE=七面鳥 -a ARTIST=éàç -o out.opus -y));

$ENV{LC_ALL} = 'fr_FR.ISO-8859-1';

is_deeply(opustags(qw(-S out.opus), {in => <<"END_IN", mode => ':raw'}), [<<"END_OUT", '', 0], 'set all in ISO-8859-1');
T=\xef\xef\xf6
END_IN
T=\xef\xef\xf6
END_OUT

is_deeply(opustags('-i', 'out.opus', "--add=I=\xf9\xce", {mode => ':raw'}), ['', '', 0], 'write tags in ISO-8859-1');

is_deeply(opustags('out.opus', {mode => ':raw'}), [<<"END_OUT", <<'END_ERR', 0], 'read tags in ISO-8859-1');
encoder=Lavc58.18.100 libopus
TITLE=???
ARTIST=\xe9\xe0\xe7
I=\xf9\xce
END_OUT
warning: Some tags have been transliterated to your system encoding.
END_ERR

$ENV{LC_ALL} = '';

is_deeply(opustags('out.opus'), [<<"END_OUT", '', 0], 'read tags in UTF-8');
encoder=Lavc58.18.100 libopus
TITLE=七面鳥
ARTIST=éàç
I=ùÎ
END_OUT
