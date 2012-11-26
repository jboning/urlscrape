#!/usr/bin/perl

# Copyright (C) 2012 Josiah Boning
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Credits:
#   This plugin was inspired by a similar system written by Eric Harmon. The
#   web page design came straight from his version.
#
# Depends:
#   DateTime (libdatetime-perl)
#   DateTime::Format::Strptime (libdatetime-format-strptime-perl)

use warnings;
use strict;

my %CONFIG = (
	logdir => "", # e.g. "/home/noob/urllogger"
	server => "",
	channel => "",
	numitems => 50,
	urlroot => "", # e.g. "http://example.com/urllog"

	uuid => "", # use `uuid` to generate an id for your atom feed!
);


use vars qw($VERSION %IRSSI);

use Irssi;
use URI::URL;
use URI::Find;
use IO::File;
use IO::Handle;
use LWP::UserAgent;
use HTML::Parser;
use CGI;
use DateTime;
use DateTime::Format::Strptime;

$VERSION = "0.2";
%IRSSI = (
	authors => "Josiah Boning",
	contact => "jboning\@gmail.com",
	name => "urlscrape",
	description => "watch for URLs and log them to a webpage",
	license => "GPLv3",
	changed => "2012-11-26",
);

my $logname = "urls.txt";
my $pagename = "index.html";
my $rssname = "atom.xml";

my $tz = DateTime::TimeZone->new(name => 'local');

my $parser = HTML::Parser->new(
	api_version => 3,
	start_h => [\&start, "tagname, attr"],
	end_h => [\&end, "tagname"],
	text_h => [\&text, "text"],
	report_tags => ["title"],
);

my $title = "";
my $intitle = 0;

sub start {$intitle = 1}
sub end {$intitle = 0}
sub text {$title .= $_[0] if $intitle}

my $ua = LWP::UserAgent->new();
$ua->timeout(10);
$ua->agent("urlscrape/0.1 ");

my $fh;

print @ARGV;
## standalone log-processing mode
if (@ARGV) {
	# XXX
	$fh = IO::File->new(">log.txt");
	gen_log();
	exit(0);
}
else {
	$fh = IO::File->new(">>$CONFIG{logdir}/$logname");
}

my @curr_info = read_info();

sub read_info {
	my @lines;

	my $filename = "$CONFIG{logdir}/$logname";
	my $fh = IO::File->new("<$filename");
	while (my $line = $fh->getline()) {
		push @lines, $line;
		shift @lines if $#lines >= $CONFIG{numitems};
	}
	$fh->close();

	my @info;
	foreach my $line (@lines) {
		my ($timestamp, $nick, $type, $url, $host, $title)
			= $line =~ /(.*?)\t(.*?)\t(.*?)\t(.*?)\t(.*)\t(.*)/;
		$url = CGI::escapeHTML($url);
		$host = CGI::escapeHTML($host);
		push @info, [$timestamp, $nick, $type, $url, $host, $title];
	}
	return @info;
}

sub get_title {
	my $uri = shift;

	my $response = $ua->get($uri);

	if (!$response->is_success) {
		print $response->status_line;
		return $uri;
	}

	my $type = $response->header("Content-Type");
	if ($type =~ m!image/.*!) {
		return undef;
	}

	$title = "";
	$parser->parse($response->content);
	$title =~ s/\n//g;
	return $title;
}

sub finder_cb {
	my ($timestamp, $nick) = @_;
	return sub {
		my $uri_obj = shift;
		my $uri_text = shift;

		my $uri_string = $uri_obj->as_string;
		my $host = $uri_obj->host;
		my $title = get_title($uri_string);
		my $type = !defined($title) && "image"
			|| "other";
		$title ||= "";

		my $this_info = [$timestamp, $nick, $type, $uri_string, $host,
		                 $title];
		push @curr_info, $this_info;
		shift @curr_info if $#curr_info >= $CONFIG{numitems};

		$fh->print(join("\t", @$this_info)."\n");
		$fh->flush;
	}
}

sub public {
	my ($server, $msg, $nick, $address, $target) = @_;
	if ($target eq $CONFIG{channel}
	    && $server->{tag} eq $CONFIG{server}) {
		my $dt = DateTime->now();
		$dt->set_time_zone('GMT');
		my $timestamp = $dt->strftime("%Y-%m-%dT%TZ");
		my $finder = URI::Find->new(finder_cb($timestamp, $nick));
		if ($finder->find(\$msg)) {
			gen_page();
		}
	}
}

sub gen_log {
	my ($mon, $mday, $year);

	# XXX will not work if logs are not from the local timezone
	# (here's hoping this does the right thing with DST)
	my $strp = DateTime::Format::Strptime->new(
		pattern => "%Y-%b-%d %T",
		locale => 'en_US',
		time_zone => 'local'
	);

	while (my $line = <STDIN>) {
		# Keep track of the day (for timestamps)
		if ($line =~ /^--- Log opened \w+ (\w+) (\d+) \S+ (\d+)/) {
			($mon, $mday, $year) = ($1, $2, $3);
			next;
		}
		if ($line =~ /^--- Day changed \w+ (\w+) (\d+) (\d+)/) {
			($mon, $mday, $year) = ($1, $2, $3);
			next;
		}

		if ($line !~ /^(\d{2}:\d{2}:\d{2}) <.(\S+)> /) {
			next;
		}
		my ($time, $nick) = ($1, $2);

		# doing the datetime calculation on every line seems a bit
		# expensive. the biggest cost is still going to be fetching
		# from the web, though, so no biggie.
		my $dt = $strp->parse_datetime("$year-$mon-$mday $time");
		$dt->set_time_zone('UTC');
		my $timestamp = $dt->strftime("%Y-%m-%dT%TZ");
		my $finder = URI::Find->new(finder_cb($timestamp, $nick));
		$finder->find(\$line);
	}
}

Irssi::signal_add('message public' => \&public);

sub gen_page {
	my $title = "$CONFIG{channel} URL Log";
	my $now = DateTime->now();
	$now->set_time_zone('UTC');
	my $timestamp = $now->strftime("%Y-%m-%dT%TZ");

	my $page = <<EOF;
<html>
<head>
<title>$title</title>
<link href="atom.xml" type="application/atom+xml" rel="alternate" title="$CONFIG{channel} URL Feed" />
<style type="text/css">
body {
	font-family: "Lucida Sans Unicode", "Lucida Grande", sans-serif;
	font-size: 10pt;
}
li img {
	border: 0;
	max-width: 300px;
	max-height: 300px;
	margin-right: 10px;
	vertical-align: text-bottom;
}
ul {
	list-style-type: none;
	padding-left: 20px;
}
li {
	padding: 5px;
}
ol li img {
	vertical-align: text-top;
}
ol li:nth-child(even) {
	background-color: #EEE;
}
</style>
</head>
<body>
<h1>$title</h1>
<p>
<ol>
EOF
	foreach my $info (reverse @curr_info) {
		my ($timestamp, $nick, $type, $url, $host, $title) = @$info;
		$title ||= $url;
		$page .= "<li>";
		if ($type eq "image") {
			$page .= qq(<a href="$url"><img src="$url" /></a>);
		}
		elsif ($type eq "other") {
			$page .= qq!<a href="$url">$title</a> (at $host)!;
		}
		$page .= "</li>\n";
	}
	$page .= <<EOF;
</ol>
</p>
</body>
</html>
EOF
	my $fh = IO::File->new(">$CONFIG{logdir}/index.html");
	$fh->print($page);
	$fh->close();

	my $atom = <<EOF;
<?xml version="1.0" encoding="utf-8"?>

<feed xmlns="http://www.w3.org/2005/Atom">
	<title>$title</title>
	<link href="$CONFIG{urlroot}/atom.xml" rel="self" />
	<link href="$CONFIG{urlroot}/" />
	<id>urn:uuid:$CONFIG{uuid}</id>
	<updated>$timestamp</updated>
	<author><name>urlscrape</name></author>
EOF

	foreach my $info (reverse @curr_info) {
		my ($timestamp, $nick, $type, $url, $host, $title) = @$info;
		$title ||= $url;
		my $id = $timestamp.$nick.$url;
		$id =~ tr/[0-9][A-Z][a-z]()+,-.:=@;$_!*'/_/c;
		$atom .= <<EOF;
	<entry>
		<title>$title</title>
		<author><name>$nick</name></author>
		<link href="$url" rel="alternate" />
		<id>urn:custom:$id</id>
		<published>$timestamp</published>
		<updated>$timestamp</updated>
EOF
		if ($type eq "image") {
			$atom .= <<EOF;
		<content type="xhtml">
			<div xmlns="http://www.w3.org/1999/xhtml">
				<img src="$url" />
			</div>
		</content>
EOF
		}
		$atom .= <<EOF;
	</entry>
EOF
	}

	$atom .= <<EOF;
</feed>
EOF
	$fh = IO::File->new(">$CONFIG{logdir}/atom.xml");
	$fh->print($atom);
	$fh->close();
}
