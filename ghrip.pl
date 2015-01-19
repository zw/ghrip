#!/usr/bin/perl
#
# Poll GitHub for issue/pull request data associated with the bitcoin/bitcoin
# repository (or any other) and commit that data to its own repository.
# Much less featureful and mature than <https://github.com/joeyh/github-backup>
# but will also do pull request comments, might be more incremental, and trades
# beauty for pragmatism.
#
# Expects to be run in a repo with an 'issues/' directory; populates it with:
#  issues/list.json --- all issues in one fat file, including labels and
#                       milestones
#  issues/\d+.json --- normal comments on each issue
#  *.ts --- UNIX timestamps of the corresponding files
#
use strict;
use warnings;

use feature 'say';
use Data::Dumper;
use POSIX qw(strftime);

use List::MoreUtils qw(first_index);
use Path::Tiny qw(path);
use HTTP::Headers;
use JSON;
use Net::GitHub;

# The API guide politely asks users to put a username in the UA string for ease
# of contacting authors of malfunctioning/problematic clients.
use constant USERNAME => $ENV{GITHUB_USERNAME};

# Token auth raises our rate limit, only (needs no permissions at all).
# Obtained using the procedure at:
#   <https://developer.github.com/v3/oauth_authorizations/#create-a-new-authorization>
my $github = Net::GitHub->new(
    version => 3,
    access_token => $ENV{GITHUB_OAUTH_TOKEN}
);

$github->ua->default_headers(HTTP::Headers->new('Time-Zone' => 'Etc/UTC'));

# Make Net::GitHub's UA string follow the "software/ver.sion" RFC while we're
# putting our own in there.
$github->ua->agent(sprintf("ghrip (GitHub username %s) %s/%s %s",
                           USERNAME, "perl-net-github", $Net::GitHub::VERSION,
                           $github->ua->_agent));

$github->set_default_user_repo('bitcoin', 'bitcoin');

# When did we last save anything?  A UNIX timestamp.  Default to grabbing
# everything to seed a first run.
my $last_capture_ts = 0;

# Git doesn't store timestamps, so keep our own to make API interaction as
# incremental as possible.  We could probably eliminate this by finding
# max(updated_at) over all mirrored data.
if (-r "issues/list.json.ts") {
    $last_capture_ts = path("issues/list.json.ts")->slurp_utf8();
}

# All issues we've mirrored, indexed by issue number.
my $mirrored_issues = [];

if (-r "issues/list.json") {
    $mirrored_issues = decode_json(path("issues/list.json")->slurp_utf8());
}

my $this_capture_ts = time() - 1;

my @issues = $github->issue->repos_issues({
    sort => 'created',
    direction => 'asc',
    state => 'all',
    since => strftime("%FT%H:%M:%SZ", gmtime($last_capture_ts)),
});
while ($github->issue->has_next_page()) {
    push(@issues, $github->issue->next_page());
}

foreach my $issue (@issues) {
    $mirrored_issues->[$issue->{number} - 1] = $issue;
}

# If you're seeing these numbers not match on a first run, you're probably
# seeing github spam deletion.
printf("Writing %d issues (%d updated)...\n",
       scalar(@$mirrored_issues), scalar(@issues));
path("issues/list.json")->spew_utf8(to_json($mirrored_issues,
                                            {utf8 => 1, pretty => 1,
					     canonical => 1}));
path("issues/list.json.ts")->spew_utf8($this_capture_ts);


# Comments on issues.  Note that the issue description is rendered like a
# comment by GitHub's site but isn't listed as one by this API.
my $mirrored_comments;
foreach my $issue (@$mirrored_issues[0..2]) {
    next if !defined($issue);
    # FIXME: body is almost verbatim repetition of the issues list capture.
    #        See how the pattern evolves once we're capturing review comments.
    $mirrored_comments = [];
    $last_capture_ts = 0;
    my $file = sprintf("issues/%d.json", $issue->{number});
    my $ts_file = $file . ".ts";

    if (-r $ts_file) {
        $last_capture_ts = path($ts_file)->slurp_utf8();
    }

    $this_capture_ts = time() - 1;

    say $file;
    if (-r $file) {
        $mirrored_comments = decode_json(path($file)->slurp_utf8());
    }
    # 'sort' and 'direction' don't appear to work on this endpoint, but 'since'
    # does.  <https://github.com/github/developer.github.com/pull/692> asks for
    # documentation of this; the dependent net-github-issue-comments.patch is
    # needed to take advantage of it.  (Or switch to Pithub, which lets you
    # fudge this with 'params => { since => ... }'.)
    my @comments = $github->issue->comments($issue->{number}, {
        since => strftime("%FT%H:%M:%SZ", gmtime($last_capture_ts)),
    });
    while ($github->issue->has_next_page()) {
        # Net::GitHub has its own rate limiting might be wrong/outdated, since
        # comments in Query.pm say "the rate limit is per minute, not per day"
        # but the API docs say per hour.
	sleep(1);
        push(@comments, $github->issue->next_page());
    }

    foreach my $comment (@comments) {
        my $updated = first_index { $_->{id} == $comment->{id} } @$mirrored_comments;
        if ($updated > -1) {
            $mirrored_comments->[$updated] = $comment;
        } else {
            push(@$mirrored_comments, $comment);
        }
    }

    printf("Writing %d comments on issue $issue->{number} (%d updated)...\n",
           scalar(@$mirrored_comments), scalar(@comments));
    path($file)->spew_utf8(to_json($mirrored_comments, {utf8 => 1, pretty => 1,
                                                        canonical => 1}));
    path($ts_file)->spew_utf8($this_capture_ts);
}

# TODO: capture review comments almost exactly the same way.
