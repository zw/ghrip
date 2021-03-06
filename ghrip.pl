#!/usr/bin/perl
#
# Poll GitHub for issue/pull request data associated with a repository and
# commit that data to its own repository.
#
# See README.md for usage.
#
# Copyright 2015 Isaac Wilcox
#
# Licence: Apache Licence, Version 2.0; see LICENCE.txt.
#
use strict;
use warnings;

use feature 'say';
use Data::Dumper;
use POSIX qw(strftime);
use IO::Handle;

use List::MoreUtils qw(first_index uniq);
use Path::Tiny qw(path);
use JSON;
use Pithub;

# The API guide politely asks users to put a username in the UA string for ease
# of contacting authors of malfunctioning/problematic clients.
use constant USERNAME => $ENV{GITHUB_USERNAME};

# We record the timestamp of each update, but if your clock isn't true you
# could miss events or updates.  Fudge timestamps backwards by this many
# seconds to provide a safety margin.
use constant TIMESTAMP_SAFETY_MARGIN => 60;

# Easier to see progress if STDOUT is hot.
STDOUT->autoflush(1);

# Token auth raises our rate limit, only (needs no permissions at all).
# Obtained using the procedure at:
#   <https://developer.github.com/v3/oauth_authorizations/#create-a-new-authorization>
my $github = Pithub->new(
    token => $ENV{GITHUB_OAUTH_TOKEN},
    # Owner of repo, not owner of token.
    user => 'bitcoin',
    repo => 'bitcoin',
    auto_pagination => 1,
    # The default in v0.01026 onwards.
    per_page => 100,
);

$github->ua->default_header('Time-Zone' => 'Etc/UTC');

$github->ua->agent(sprintf("ghrip (GitHub username %s) %s %s",
                           USERNAME, "perl-pithub", $github->ua->_agent));
init_ratelimiting($github);

my $state = load_state("state.json");

my $to_refresh = identify_stales_from_events($github, $state);

if (! -d "issues") {
    mkdir("issues") or die "couldn't mkdir issues/: $!";

    print <<EOM;
This being the first run, we have to grab all individual objects.  This can be
slow, especially on larger projects where we're likely to run into the API's
rate limits.
EOM
    # identify_stale_*_comments are wasteful and slow on large numbers of
    # issues, so just use the full lists.  Also it minimises confusion to
    # mirror things in numerical order the first time.
    my $all_issues = [ sort {$a <=> $b}
                            identify_stale_issues($github, $state) ];
    my $all_PRs = [ sort {$a <=> $b}
                         identify_stale_PRs($github, $state) ];
    @{$to_refresh}{qw/issues issue_comments/} = ($all_issues) x 2;
    @{$to_refresh}{qw/PRs PR_comments/} = ($all_PRs) x 2;

    # Even though we're skipping stale comment checks we still want the
    # side-effect of setting the all-comments watermarks so that the second run
    # doesn't consider all comments new.
    my $ts = time() - TIMESTAMP_SAFETY_MARGIN;
    $state->{pending}{issues}{comments_last_checked_at} = $ts;
    $state->{pending}{PRs}{comments_last_checked_at} = $ts;
} else {
    if (!defined($to_refresh)) {
        print <<EOM;
The API has expired some events before we got to see them; falling back to
checking individual objects (slower!).  Avoid this in future by running me
more frequently.  (Can't hurt; I do nothing reasonably gracefully!).
EOM
        $to_refresh = {
            issues         => [ identify_stale_issues($github, $state) ],
            issue_comments => [ identify_stale_issue_comments($github, $state) ],
            PRs            => [ identify_stale_PRs($github, $state) ],
            PR_comments    => [ identify_stale_PR_comments($github, $state) ],
        };
    }
}

refresh_issues($github, $state, uniq @{$to_refresh->{issues}});
refresh_issue_comments($github, $state, uniq @{$to_refresh->{issue_comments}});
refresh_PRs($github, $state, uniq @{$to_refresh->{PRs}});
refresh_PR_comments($github, $state, uniq @{$to_refresh->{PR_comments}});

commit_pending_state($state);

say "All done.";

exit(0);

# Takes a Pithub object and a hashref of incremental update state.
# Returns a hashref:
#    $to_refresh = {
#        issues         => [ <issue number>, <issue number>, ...],
#        issue_comments => [ <issue number>, <issue number>, ...],
#        PRs            => [ <issue number>, <issue number>, ...],
#        PR_comments    => [ <issue number>, <issue number>, ...],
#    };
#  - undef means we've dropped events and must fall back to less efficient
#    approaches to find updates
# Side-effects:
#  - incremental update/conditional request state is updated
#  - makes requests to the API, consuming rate limit allowance
#
sub identify_stales_from_events {
    my $github = shift;
    my $state = shift;

    # The events API seems to return a Last-Modified, but AFAICT it's
    # inaccurate, meaning we have to store the ETag of our last poll.  Also we
    # can only ever get all events (no 'since' support) and therefore have to
    # keep the timestamp of our last poll.  Even with both those bits of state,
    # without 'since' we still have to manually filter events.  This is raised
    # as: <https://github.com/github/developer.github.com/pull/695>
    my $events;

    # UNIX timestamp of the most recent event seen on the last run.
    my $events_ts = 0;
    my $dropped_some_events = 1;

    my $to_refresh = {};
    my %eventtype_to_key = (
        IssuesEvent => 'issues',
        PullRequestEvent => 'PRs',
        IssueCommentEvent => 'issue_comments',
        PullRequestReviewCommentEvent => 'PR_comments',
    );

    my $this_capture_ts = time() - TIMESTAMP_SAFETY_MARGIN;

    say "Examining recent events.";
    if (exists($state->{events}{last_processed_etag})) {
        my $events_etag = $state->{events}{last_processed_etag};
        $events = $github->events->repos(
            prepare_request => sub {
                my ($request) = @_;
                $request->header('If-None-Match' => $events_etag);
            }
        );
    } else {
        $events = $github->events->repos();
    }

    # It's occasionally useful to fake a timestamp (unlike an ETag) so handle
    # it separately.  If you fake a timestamp, delete the ETag too to force a
    # fresh grab of the events list.
    if (exists($state->{events}{last_checked_at})) {
        $events_ts = $state->{events}{last_checked_at};
    }

    if ($events_ts && $events->success()) { # as opposed to 304 Not Modified
        my $previous_run_time = strftime("%FT%TZ", gmtime($events_ts));

        # Any new events that turn up while we're walking through them all, we'll
        # grab on the next run.
        # API doesn't explicitly state the order of events, but I'm assuming
        # newest-first since that's what I've observed.  This is raised as:
        # <https://github.com/github/developer.github.com/pull/698>
        while (my $event = $events->next) {
            # Done if we've seen all new since last time.
            if ($event->{created_at} lt $previous_run_time) {
                $dropped_some_events = 0;
                last;
            }
            # Enqueue for detailed fetch rather than use the data straight from
            # the event, because:
            #  - <https://developer.github.com/v3/#summary-representations>
            #    suggests event may be incomplete
            #  - the events stream doesn't mention comment updates, but we want
            #    those
            #  - only once we've seen the very last (oldest) event can we know
            #    whether we've dropped events and need to walk /all/ issues
            my $key = $eventtype_to_key{$event->{type}};
            if (defined($key)) {
                my $issue = $event->{payload}{issue}
                            || $event->{payload}{pull_request};

                push(@{$to_refresh->{$key}}, $issue->{number});
            }
        }
    }

    # Pithub 0.01026 onwards: $events->etag().
    $state->{pending}{events}{last_processed_etag}
        = $events->response->header('ETag');
    $state->{pending}{events}{last_checked_at} = $this_capture_ts;

    if ($dropped_some_events) {
        # Need to refresh every issue/comment stream if we've dropped any
        # events.
        $to_refresh = undef;
    } else {
        # But if we'll be up to date once the identified issues/PRs/comments
        # are on disk then it's useful to record that in case we don't update
        # again for months; fallback methods can make use of knowing what we
        # last saw.
        $state->{pending}{issues}{last_checked_at} = $this_capture_ts;
        $state->{pending}{PRs}{last_checked_at} = $this_capture_ts;
        $state->{pending}{issues}{comments_last_checked_at} = $this_capture_ts;
        $state->{pending}{PRs}{comments_last_checked_at} = $this_capture_ts;
    }
    return $to_refresh;
}


# Get numbers of all issues (including PRs) whose issue data has changed since
# we last grabbed them.  If an issue is also a PR and its PR data has changed
# but its issue data hasn't, it won't be included here.
#
# Takes a Pithub object and a hashref of incremental update state.
#
# Returns a list of issue numbers.  The range of issue numbers may not be
# contiguous even if this is the first run, since GitHub deletes some issues
# (presumably for spam reasons)
#
# Side-effects:
#  - makes progress noise on STDOUT
#  - incremental update/conditional request state is updated
#  - makes requests to the API, consuming rate limit allowance
#
sub identify_stale_issues {
    return _identify_stale_issues(0, @_);
}

# Get a list of all PRs whose PR data has changed since we last grabbed them.
#
# Takes a Pithub object and a hashref of incremental update state.
#
# Returns a list of issue numbers.  The range will not be contiguous even on
# the first run, since not all issues are PRs.
#
# Side-effects:
#  - makes progress noise on STDOUT
#  - incremental update/conditional request state is updated
#  - makes requests to the API, consuming rate limit allowance
#
sub identify_stale_PRs {
    return _identify_stale_issues(1, @_);
}

# Well, issues-or-issue-derivatives.
sub _identify_stale_issues {
    my $isPR = shift;
    my $github = shift;
    my $state = shift;

    my @stales = ();

    # UNIX timestamp of the newest change seen during the previous run.
    my $ts = 0;

    my $ts_key = $isPR ? "PRs" : "issues";

    if (exists($state->{$ts_key}{last_checked_at})) {
        $ts = $state->{$ts_key}{last_checked_at};
    }
    my $time = strftime("%FT%TZ", gmtime($ts));

    my $this_capture_ts = time() - TIMESTAMP_SAFETY_MARGIN;

    my $updates;
    if ($isPR) {
        # Updates to PRs can be reasonably efficiently detected by grabbing the
        # list sorted by updated_at newest-first, then walking through only as
        # many pages as necessary.
        $updates = $github->pull_requests->list(
            params => {
                state => 'all',
                sort => 'updated',
                direction => 'desc',
            },
        );
    } else {
        # Updatable issues themselves can be pretty efficiently detected with a
        # single (though maybe paginated) request to the /issues endpoint with
        # 'since=<timestamp>'.
        $updates = $github->issues->list(
            params => {
                state => 'all',
                since => $time,
                sort => 'updated',
                direction => 'asc',
            },
        );
    }
  
    printf("Examining %s.\n", $isPR ? "PR-specific bits of PR issues"
                                    : "issues"); 
    my $new_updated = 0;

    while (my $update = $updates->next) {
        last if $isPR && $update->{updated_at} lt $time;
        push(@stales, $update->{number});
        $new_updated++;
        printf("\r%d %s examined...",
               $new_updated, $isPR ? "PRs" : "issues");
    }

    if ($new_updated) {
        say "done";
    }
    $state->{pending}{$ts_key}{last_checked_at} = $this_capture_ts;

    return @stales;
}

# Get a list of all issues whose comments have changed since we last grabbed
# them.
#
# Takes a Pithub object.
# Returns a list of issue numbers.
# Side-effects:
#  - files containing incremental update/conditional request state are updated
#  - makes requests to the API, consuming rate limit allowance
#
sub identify_stale_issue_comments {
    return _identify_stale_issue_comments(0, @_);
}

# Get a list of all PRs whose review comments have changed since we last
# grabbed them.
#
# Takes a Pithub object.
# Returns a list of issue numbers.
# Side-effects:
#  - files containing incremental update/conditional request state are updated
#  - makes requests to the API, consuming rate limit allowance
#
sub identify_stale_PR_comments {
    return _identify_stale_issue_comments(1, @_);
}

# Well, stale issues-or-derivatives comments.
sub _identify_stale_issue_comments {
    my $isPR = shift;
    my $github = shift;
    my $state = shift;

    my $type_key = $isPR ? "PRs" : "issues";
    my @with_stale_comments = ();

    # UNIX timestamp of the newest PR change seen during the previous run.
    my $ts = 0;

    if (exists($state->{$type_key}{comments_last_checked_at})) {
        $ts = $state->{$type_key}{comments_last_checked_at};
    }

    my $this_capture_ts = time() - TIMESTAMP_SAFETY_MARGIN;

    # Stale comments can be pretty efficiently detected with a single
    # (though maybe paginated) request to the /thingy/comments endpoint with
    # 'since=<timestamp>'.
    # XXX: but this is ugly, because what we get back is (at a superficial
    #      glance) no less detailed than the /issues/nnn/comments version we
    #      grab later, so we're grabbing the content twice
    #
    # Pithub (at least up to 0.01028) doesn't have a method for the
    # /issues/comments endpoint.  XXX: submit a PR making issue_id optional on
    # list().
    my $path = sprintf("/repos/%s/%s/%s/comments",
                       $github->user, $github->repo,
                       $isPR ? "pulls" : "issues");
    my $comments = $github->request(
        method => 'GET',
        path => $path,
        params => {
            since => strftime("%FT%TZ", gmtime($ts)),
            sort => 'updated',
            direction => 'asc',
        },
    );

    printf("Examining %s comments.\n", $isPR ? "PR review" : "issue"); 
    my $new_updated = 0;

    while (my $comment = $comments->next) {
        # Returned objects don't have any straightforward issue number, so
        # parse it out of <thingy>_url :(
        # XXX: raise this against API!  Parsing is brittle.
        my $issue_number = $comment->{$isPR ? 'pull_request_url'
                                            : 'issue_url'};
        $issue_number =~ s|.*/(\d+)$|$1|;
        push(@with_stale_comments, int($issue_number));
        $new_updated++;
        printf("\r%d %s comments examined...",
               $new_updated, $isPR ? "PR review" : "issue");
    }

    if ($new_updated) {
        say "done";
    }

    $state->{pending}{$type_key}{comments_last_checked_at} = $this_capture_ts;

    return @with_stale_comments;
}

# Refresh all the given issues.
#
# Takes a Pithub object plus a bunch of issue numbers.
# Doesn't return anything.
# Side-effects:
#  - makes some progress noise on STDOUT
#  - files containing issue data are updated
#  - makes requests to the API, consuming rate limit allowance
#
sub refresh_issues {
    _refresh_issues(0, @_);
}

# Refresh all the given PRs.
#
# Takes a Pithub object plus a bunch of PR numbers.
# Doesn't return anything.
# Side-effects:
#  - makes some progress noise on STDOUT
#  - files containing PR data are updated
#  - makes requests to the API, consuming rate limit allowance
#
sub refresh_PRs {
    _refresh_issues(1, @_);
}

# Or PRs.
sub _refresh_issues {
    my $isPR = shift;
    my $github = shift;
    my $state = shift;

    my @stale = @_;

    my $type = $isPR ? "PR" : "issue";

    my $new_updated = 0;

    foreach my $issue_number (@stale) {
        # Shouldn't be called with non-stale issues, but an interruption of a
        # first run or infrequent (non-events-based) update can be slow and
        # inefficient unless we allow for it.
        my $etag = $state->{"${type}s"}{$issue_number}{ETag};
        my @condition;
        if (defined($etag)) {
            @condition = (prepare_request => sub {
                my ($request) = @_;
                $request->header('If-None-Match' => $etag);
            });
        }

        my $issue_result;
        if ($isPR) {
            $issue_result = $github->pull_requests->get(
                pull_request_id => $issue_number,
                @condition,
            );
        } else {
            $issue_result = $github->issues->get(
                issue_id => $issue_number,
                @condition,
            );
        }

        if ($issue_result->success()) { # as opposed to 304 Not Modified
            my $issue_file = sprintf("issues/%s/%d%s.json",
                                     nxx($issue_number), $issue_number,
                                     $isPR ? "-PR" : "");
            path($issue_file)->spew_utf8(
                to_json($issue_result->first(), {
                    utf8 => 1, pretty => 1, canonical => 1
                })
            );
            $state->{"${type}s"}{$issue_number}{ETag}
                = $issue_result->response->header('ETag');
            save_state($state);
            $new_updated++;
            printf("\r%5d new/updated %ss mirrored...",
                   $new_updated, $type);
        }
    }

    if ($new_updated) {
        say "done";
    } else {
        printf("No new/updated %ss.\n", $type);
    }
}


# Refresh the comments on all the given issues.
#
# Takes a Pithub object plus a bunch of issue numbers.
# Doesn't return anything.
# Side-effects:
#  - makes some progress noise on STDOUT
#  - files containing comment data are updated
#  - files containing incremental update/conditional request state are updated
#  - makes requests to the API, consuming rate limit allowance
#
sub refresh_issue_comments {
    _refresh_issue_comments(0, @_);
}

# Refresh the review comments on all the given PRs.
#
# Takes a Pithub object plus a bunch of issue numbers.
# Doesn't return anything.
# Side-effects:
#  - makes some progress noise on STDOUT
#  - files containing comment data are updated
#  - files containing incremental update/conditional request state are updated
#  - makes requests to the API, consuming rate limit allowance
#
sub refresh_PR_comments {
    _refresh_issue_comments(1, @_);
}

sub _refresh_issue_comments {
    my $isPR = shift;
    my $github = shift;
    my $state = shift;
    my @stale = @_;

    my $type_key = $isPR ? "PRs" : "issues";

    foreach my $issue_number (@stale) {
        my $file = sprintf("issues/%s/%d-comments.json",
                           nxx($issue_number), $issue_number);

        # Issue comments and PR review comments are merged.  This relies on
        # their 'id' field sets being disjoint; the API docs make no explicit
        # guarantee of this!  This is raised as:
        #   <https://github.com/github/developer.github.com/pull/696>
        my @comments = ();
        if (-r $file) {
            @comments = @{decode_json(path($file)->slurp_utf8())};
        }

        my $ts = 0;
        if (exists($state->{$type_key}{$issue_number}{comments_last_checked_at})) {
            $ts = $state->{$type_key}{$issue_number}{comments_last_checked_at};
        }
        my $time = strftime("%FT%TZ", gmtime($ts)),

        my $this_capture_ts = time() - TIMESTAMP_SAFETY_MARGIN;

        # 'since' works on /issues/<number>/comments but isn't documented;
        # <https://github.com/github/developer.github.com/pull/692> asks for
        # documentation of this.  'sort' and 'direction' don't work on
        # /issues/<number>/comments.  All three work on
        # /pulls/<number>/comments.
        my $comments;
        my @params = (params => {
            since => strftime("%FT%TZ", gmtime($ts))
        });
        if ($isPR) {
            $comments = $github->pull_requests->comments->list(
                pull_request_id => $issue_number,
                @params,
            );
        } else {
            $comments = $github->issues->comments->list(
                issue_id => $issue_number,
                @params,
            );
        }

        my $new_updated = 0;
        while (my $comment = $comments->next()) {
            my $updated = first_index { $_->{id} == $comment->{id} } @comments;
            if ($updated > -1) {
                $comments[$updated] = $comment;
            } else {
                push(@comments, $comment);
            }
            $new_updated++;
            printf("\r%d: %5d new/updated %s comments mirrored...",
                   $issue_number, $new_updated,
                   $isPR ? "PR review" : "issue");
        }

        if ($new_updated) {
            say "done";
            @comments = sort { $a->{created_at} cmp $b->{created_at} }
                             @comments;
            path($file)->spew_utf8(
                to_json(\@comments, {
                    utf8 => 1, pretty => 1, canonical => 1
                })
            );
        }
        $state->{$type_key}{$issue_number}{comments_last_checked_at}
            = $this_capture_ts;
        save_state($state);
    }

    if (!@stale) {
        printf("No issues need their %s comments refreshed.\n",
               $isPR ? "PR review" : "issue");
    }
}

# Given an issue number, ensure dir issues/nxx/ exists then return the string
# nxx.  So for 456, create ./issues/4xx/ and return "4xx".  This splits issue
# data into groups of 100, making it possible in a pinch to browse it within
# GitHub's web interface.  This is useful when using ghrip in less serious
# siuations than GitHub repo takedown/outage, e.g. reading original versions
# of issue comments or PR review comments across rebases.
sub nxx {
    my $issue_num = shift;

    my $nxx = sprintf("%03d", $issue_num);
    $nxx =~ s/\d\d$/xx/;
    if (! -d "issues/$nxx") {
        mkdir("issues/$nxx") or die "couldn't mkdir issues/$nxx/: $!";
    }
    return $nxx;
}

# Add handlers to Pithub's LWP::UserAgent to manage GitHub API rate limits.
# Future requests will block when rate limit is hit and resume when it resets
# and will have the side-effect of explaining that on STDOUT.
#
# Takes a Pithub object.
# Doesn't return anything.
# Side-effects: as described above, plus a call to the /rate_limit endpoint,
#     which /should/ be idempotent (but I could swear I've seen it misbehave).
sub init_ratelimiting {
    my $github = shift;

    my $limits_result = $github->request(
        method => 'GET',
        # XXX: add this to Pithub
        path => '/rate_limit',
    );
    my $limits = $limits_result->first->{resources}{core};

    $github->ua->add_handler(request_prepare => sub {
        if (! $limits->{remaining}) {
            my $reset_with_margin = $limits->{reset} + TIMESTAMP_SAFETY_MARGIN;

            say "\nAPI rate limit hit at " . strftime("%R", localtime())
                . "; blocking current request until"
                . strftime("%R", localtime($reset_with_margin));

            do { # might be woken early
                sleep($reset_with_margin - time());
            } while (time() < $reset_with_margin);

            say "API rate limit should now have reset; resuming at "
                . strftime("%R", localtime()) . "...";
        }
    });
    $github->ua->add_handler(response_done => sub {
        my ($response, $ua, $h) = @_;

        $limits->{remaining} = $response->header('X-RateLimit-Remaining');
        $limits->{reset} = $response->header('X-RateLimit-Reset');
    });
}

{
my $state_filename;

sub load_state {
    $state_filename = shift;

    my $state = {};
    if (-r $state_filename) {
        $state = decode_json(path($state_filename)->slurp_utf8());
    }
    return $state;
}

sub save_state {
    my $state = shift;

    path($state_filename)->spew_utf8(
        to_json($state, {
            utf8 => 1, pretty => 1, canonical => 1
        })
    );
}

sub commit_pending_state {
    my $state = shift;

    # XXX: Perhaps a neater way to do this would be for API-calling subs to add
    # at_exit coderefs for clean up and just run them all here, so that pending
    # state management is kept close to immediate state management.
    $state->{events}{last_processed_etag}
        = delete($state->{pending}{events}{last_processed_etag});
    $state->{events}{last_checked_at}
        = delete($state->{pending}{events}{last_checked_at});
    delete($state->{pending}{events});

    $state->{issues}{last_checked_at}
        = delete($state->{pending}{issues}{last_checked_at});
    if (defined($state->{pending}{issues}{comments_last_checked_at})) {
        $state->{issues}{comments_last_checked_at}
            = delete($state->{pending}{issues}{comments_last_checked_at});
    }

    $state->{PRs}{last_checked_at}
        = delete($state->{pending}{PRs}{last_checked_at});
    if (defined($state->{pending}{PRs}{comments_last_checked_at})) {
        $state->{PRs}{comments_last_checked_at}
            = delete($state->{pending}{PRs}{comments_last_checked_at});
    }
    delete($state->{pending});

    save_state($state);
}
}
