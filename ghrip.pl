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
#  issues/\d+xx/\d+.json --- comments on each issue
#  events.etag --- state for incremental updates using repo events stream
#  *.ts --- state for incremental updates using Last-Modified on endpoints
# To do:
#  issues/prs/list.json --- PR specifics, for subset of issues that are PRs
#
use strict;
use warnings;

use feature 'say';
use Data::Dumper;
use POSIX qw(strftime);

use List::MoreUtils qw(first_index);
use Path::Tiny qw(path);
use HTTP::Status qw(:constants);
use JSON;
use Pithub;

# The API guide politely asks users to put a username in the UA string for ease
# of contacting authors of malfunctioning/problematic clients.
use constant USERNAME => $ENV{GITHUB_USERNAME};

# Token auth raises our rate limit, only (needs no permissions at all).
# Obtained using the procedure at:
#   <https://developer.github.com/v3/oauth_authorizations/#create-a-new-authorization>
my $github = Pithub->new(
    token => $ENV{GITHUB_OAUTH_TOKEN},
    # Owner of repo, not owner of token.
    user => 'bitcoin',
    repo => 'bitcoin',
    auto_pagination => 1,
);

$github->ua->default_header('Time-Zone' => 'Etc/UTC');

$github->ua->agent(sprintf("ghrip (GitHub username %s) %s %s",
                           USERNAME, "perl-pithub", $github->ua->_agent));

# When did we last save anything?  A UNIX timestamp.  Default to grabbing
# everything to seed a first run.
my $issues_ts = 0;

# Git doesn't store timestamps, so keep our own to make API interaction as
# incremental as possible.  We could probably eliminate this by finding
# max(updated_at) over all mirrored data.
if (-r "issues/list.json.ts") {
    $issues_ts = path("issues/list.json.ts")->slurp_utf8();
}

# All issues we've mirrored, indexed by issue number.
my $mirrored_issues = [];

if (-r "issues/list.json") {
    $mirrored_issues = decode_json(path("issues/list.json")->slurp_utf8());
}

my $this_capture_ts = time() - 1;

my $issues = $github->issues->list(
    params => {
        sort => 'created',
        direction => 'asc',
        state => 'all',
        since => strftime("%FT%H:%M:%SZ", gmtime($issues_ts)),
    },
);

my $new_updated = 0;

while (my $issue = $issues->next) {
    $mirrored_issues->[$issue->{number} - 1] = $issue;
    $new_updated++;
}

if ($new_updated) {
    # If you're seeing these numbers not match on a first run, you're probably
    # seeing github spam deletion.
    printf("Writing %d issues (%d new/updated)...\n",
           scalar(@$mirrored_issues), $new_updated);
    path("issues/list.json")->spew_utf8(to_json($mirrored_issues,
                                                {utf8 => 1, pretty => 1,
                                                 canonical => 1}));
    path("issues/list.json.ts")->spew_utf8($this_capture_ts);
} else {
    say "No new/updated issues.";
}

# FIXME: Save PR extra data too!  Commit hashes are not in issue data.


# The events API seems to return a Last-Modified, but AFAICT it's inaccurate,
# meaning we have to store the ETag of our last poll.  Also we can only ever
# get all events (no 'since' support) and therefore have to keep the timestamp
# of our last poll.  Even with both those bits of state, without 'since' we
# still have to manually filter events.  This is raised as:
# <https://github.com/github/developer.github.com/pull/695>
#
# API doesn't explicitly state the order of events, but I'm assuming
# newest-first since that's what I've observed.  This is raised as:
# <https://github.com/github/developer.github.com/pull/698>
my $events;
my $events_ts = 0;
my $dropped_some_events = 1;
my @issues_to_refresh = ();

$this_capture_ts = time() - 1;

if (-r "events.etag") {
    my $events_etag = path("events.etag")->slurp_utf8();
    $events = $github->events->repos(
        prepare_request => sub {
            my ($request) = @_;
            $request->header('If-None-Match' => $events_etag);
        }
    );
} else {
    $events = $github->events->repos();
}

# It's occasionally useful to fake a timestamp (unlike an ETag) so handle it
# separately.  If you fake a timestamp, delete the .etag too to force a fresh
# grab of the events list.
if (-r "events.ts") {
    $events_ts = path("events.ts")->slurp_utf8();
}

my $previous_run_time = strftime("%FT%H:%M:%SZ", gmtime($events_ts));

if ($events->success()) { # as opposed to 304 Not Modified
    # Track seen issue numbers so they only get considered for comment refresh
    # once, to minimise the number of requests.
    my %seen = ();

    # Any new events that turn up while we're walking through them all, we'll
    # grab on the next run.
    while (my $event = $events->next) {
        if ($event->{created_at} lt $previous_run_time) {
            $dropped_some_events = 0;
            last;
        }
        next unless $event->{type} =~ /(Issue|PullRequestReview)CommentEvent/;

        # Would be nice to grab the comment straight from the event, but
        # <https://developer.github.com/v3/#summary-representations> suggests
        # it may be incomplete.
        #
        # Queue rather than fetch because only once we've seen the very last
        # event can we know whether we've dropped events and need to walk all
        # issues.
        my $issue_key = $event->{type} eq 'IssueCommentEvent' ?
                        'issue' : 'pull_request';
        my $issue = $event->{payload}{$issue_key};

        unless ($seen{$issue->{number}}) {
            push(@issues_to_refresh, $issue);
            $seen{$issue->{number}} = 1;
        }
    }
}

# 0.01026 onwards: $events->etag().
path("events.etag")->spew_utf8($events->response->header('ETag'));
path("events.ts")->spew_utf8($this_capture_ts);

# Need to refresh every issue if we've dropped any events.
if ($dropped_some_events) {
    @issues_to_refresh = @$mirrored_issues;
}

# Comments on issues.  Note that the issue description is rendered like a
# comment by GitHub's site but isn't listed as one by this API.
my $mirrored_comments;
foreach my $issue (@issues_to_refresh) {
    # Skip holes left by GitHub spam deletion.
    next if !defined($issue);
    # FIXME: body is almost verbatim repetition of the issues list capture.
    #        See how the pattern evolves once we're capturing review comments.
    $mirrored_comments = [];

    # Split comments into groups of 100 to avoid upsetting GitHub's web
    # interface.
    my $nnxx = sprintf("%03d", $issue->{number});
    $nnxx =~ s/\d\d$/xx/;
    my $file = sprintf("issues/%s/%d.json", $nnxx, $issue->{number});

    my $comments_ts = 0;
    my $ts_file = $file . ".ts";

    if (-r $ts_file) {
        $comments_ts = path($ts_file)->slurp_utf8();
    }

    if (-r $file) {
        $mirrored_comments = decode_json(path($file)->slurp_utf8());
    }

    $this_capture_ts = time() - 1;

    # 'sort' and 'direction' don't appear to work on this endpoint, but 'since'
    # does.  <https://github.com/github/developer.github.com/pull/692> asks for
    # documentation of this.
    my @comments;
    my $comments = $github->issues->comments->list(
        issue_id => $issue->{number},
	params => { since => strftime("%FT%H:%M:%SZ", gmtime($comments_ts)) },
    );
    while (my $comment = $comments->next()) {
        push(@comments, $comment);
    }

    my @review_comments = ();
    # PRs that came from disk are just the issue part, which has a (minimal)
    # pull_request k/v; PRs that came from events queries are just the PR
    # part, which has (at least) a head k/v.
    if (exists($issue->{pull_request}) || exists($issue->{head})) {
        my $review_comments = $github->pull_requests->comments->list(
            pull_request_id => $issue->{number},
            params => { since => strftime("%FT%H:%M:%SZ",
                                          gmtime($comments_ts)) },
        );
        while (my $comment = $review_comments->next()) {
            push(@review_comments, $comment);
        }
    }

    # Mixing PR review comments with normal relies on their 'id' field sets
    # being disjoint; the API docs make no explicit guarantee of this!
    # This is raised as:
    #   <https://github.com/github/developer.github.com/pull/696>
    foreach my $comment (@comments, @review_comments) {
        my $updated = first_index { $_->{id} == $comment->{id} } @$mirrored_comments;
        if ($updated > -1) {
            $mirrored_comments->[$updated] = $comment;
        } else {
            push(@$mirrored_comments, $comment);
        }
    }

    @$mirrored_comments = sort { $a->{created_at} cmp $b->{created_at} } @$mirrored_comments;
    printf("Writing %d comments on issue $issue->{number} (%d updated)...\n",
           scalar(@$mirrored_comments), scalar(@comments) + scalar(@review_comments));
    path($file)->spew_utf8(to_json($mirrored_comments, {utf8 => 1, pretty => 1,
                                                        canonical => 1}));
    path($ts_file)->spew_utf8($this_capture_ts);
}
